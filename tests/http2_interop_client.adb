with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.Bytes;
with Flyology.Execution_Groups;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Methods;
with Flyology.IO.TLS.OpenSSL;
with Interfaces.C;

procedure HTTP2_Interop_Client is
   package Client renames Flyology.HTTP.Client;
   package OpenSSL renames Flyology.IO.TLS.OpenSSL;
   package Unbounded renames Ada.Strings.Unbounded;

   use type Flyology.Execution_Model;
   use type Flyology.HTTP.Protocol;
   use type Interfaces.C.int;

   Origin_Text : constant String :=
     Ada.Environment_Variables.Value ("FLYOLOGY_HTTP2_INTEROP_ORIGIN");
   Certificate : constant String :=
     Ada.Environment_Variables.Value ("FLYOLOGY_HTTP2_INTEROP_CA");
   Expected_Peer : constant String :=
     Ada.Environment_Variables.Value ("FLYOLOGY_HTTP2_INTEROP_PEER", "");
   Quick : constant Boolean :=
     Ada.Environment_Variables.Value
       ("FLYOLOGY_HTTP2_INTEROP_QUICK", "false") = "true";
   No_Warm : constant Boolean :=
     Ada.Environment_Variables.Value
       ("FLYOLOGY_HTTP2_INTEROP_NO_WARM", "false") = "true";
   Library_Directory : constant String :=
     (if Ada.Environment_Variables.Exists ("FLYOLOGY_TEST_OPENSSL_DIR")
      then Ada.Environment_Variables.Value ("FLYOLOGY_TEST_OPENSSL_DIR")
      else "");
   Model : constant Flyology.Execution_Model :=
     (if Ada.Environment_Variables.Value
        ("FLYOLOGY_HTTP2_INTEROP_MODEL", "native") = "lightweight"
      then Flyology.Lightweight_Task else Flyology.Native_Task);

   function Open_FD_Count return Interfaces.C.int
     with Import, Convention => C,
          External_Name => "flyology_test_open_fd_count";

   function Patterned (Length : Natural) return String is
      Result : String (1 .. Length);
   begin
      for Index in Result'Range loop
         Result (Index) := Character'Val
           (Character'Pos ('a') + (Index - Result'First) mod 26);
      end loop;
      return Result;
   end Patterned;

   protected type Outcome (Expected : Positive) is
      procedure Report (Passed : Boolean; Detail : String := "");
      entry Await_All;
      function Passed return Boolean;
      function Detail return String;
   private
      Count   : Natural := 0;
      OK      : Boolean := True;
      Message : Unbounded.Unbounded_String;
   end Outcome;

   protected body Outcome is
      procedure Report (Passed : Boolean; Detail : String := "") is
      begin
         Count := Count + 1;
         OK := OK and Passed;
         if not Passed and then Unbounded.Length (Message) = 0 then
            Message := Unbounded.To_Unbounded_String (Detail);
         end if;
      end Report;

      entry Await_All when Count = Expected is
      begin
         null;
      end Await_All;

      function Passed return Boolean is (OK);
      function Detail return String is (Unbounded.To_String (Message));
   end Outcome;

   Backend : aliased OpenSSL.OpenSSL_Provider;

   generic
      Execution : Flyology.Execution_Model;
   procedure Run;

   procedure Run is
      procedure Campaign (Full : Boolean) is
         HTTP : aliased Client.Client (Capacity => 1);
         Pool : constant Client.Pool_Configuration :=
           (Max_Idle                    => 1,
            Idle_Timeout                => -1.0,
            Max_Connection_Age          => -1.0,
            Max_Requests_Per_Connection => 0);

         procedure Check
           (Value    : Client.Request;
            Expected : String;
            Maximum  : Natural := 300_000)
         is
            Reply : Client.Response :=
              Client.Execute (HTTP, Value, Timeout => 30.0);
            Content : constant String := Flyology.Bytes.To_Byte_String
              (Client.Read_All (Reply, Maximum => Maximum));
         begin
            pragma Assert (Client.Status (Reply) = 200);
            pragma Assert
              (Client.Negotiated_Protocol (Reply) =
                 Flyology.HTTP.HTTP_2_Protocol);
            if Expected_Peer /= "" then
               pragma Assert
                 (Client.Header (Reply, "x-peer") = Expected_Peer);
            end if;
            pragma Assert (Content = Expected);
         end Check;

         procedure Get (Target, Expected : String) is
            Value : Client.Request;
         begin
            Client.Set_Target (Value, Target);
            Check (Value, Expected);
         end Get;

      begin
         Client.Configure
           (HTTP, Flyology.HTTP.Parse_Origin (Origin_Text), Backend'Access,
            Client.Require_HTTP_2, Pool);
         Get ("/small", "flyology-http2-interop");

         if Full then
            declare
               Results : Outcome (2);
               task type Caller (Second : Boolean) is
                  pragma Task_Info (Execution);
               end Caller;

               task body Caller is
                  Value : Client.Request;
               begin
                  Client.Set_Target
                    (Value, (if Second then "/second" else "/first"));
                  Check (Value, (if Second then "second" else "first"));
                  Results.Report (True);
               exception
                  when Error : others =>
                     Results.Report
                       (False, Ada.Exceptions.Exception_Information (Error));
               end Caller;

               First  : Caller (False);
               Second : Caller (True);
            begin
               Results.Await_All;
               if not Results.Passed then
                  raise Program_Error with Results.Detail;
               end if;
            end;

            if not Quick then
               Get ("/large", Patterned (256 * 1_024));
               declare
                  Value : Client.Request;
                  Content : constant String := Patterned (64 * 1_024);
               begin
                  Client.Set_Target (Value, "/echo");
                  Client.Set_Method (Value, Flyology.HTTP.Methods.POST);
                  Client.Set_Body (Value, Content);
                  Check (Value, Content);
               end;
               declare
                  Value : Client.Request;
               begin
                  Client.Set_Target (Value, "/small");
                  Client.Set_Method (Value, Flyology.HTTP.Methods.HEAD);
                  Check (Value, "");
               end;
            end if;
         end if;

         Client.Shutdown (HTTP, Timeout => 5.0);
         declare
            State : constant Client.Client_Diagnostics :=
              Client.Diagnostics (HTTP);
         begin
            if Full then
               Ada.Text_IO.Put_Line
                 ("HTTP/2 interop passed: created=" &
                  Natural'Image (State.Transports_Created) & " reused=" &
                  Natural'Image (State.Transport_Reuses) & " closed=" &
                  Natural'Image (State.Transports_Closed));
            end if;
            pragma Assert (State.Pending_Transports = 0);
            pragma Assert (State.Active_Exchanges = 0);
            pragma Assert (State.Reusable_Transports = 0);
            pragma Assert (State.Closing_Transports = 0);
            pragma Assert (State.Transports_Created = 1);
            pragma Assert (State.Transports_Closed = 1);
         end;
      end Campaign;
   begin
      if No_Warm then
         Campaign (Full => True);
      else
         --  Establish the selected owner runtime before the descriptor
         --  baseline. The full campaign is the first path that creates
         --  lightweight caller tasks; their process-wide event-loop wake
         --  descriptor is intentionally retained by Flyology and is not a
         --  client transport leak.
         declare
            task Runtime_Warmer is
               pragma Task_Info (Execution);
            end Runtime_Warmer;
            task body Runtime_Warmer is
            begin
               delay 0.0;
            end Runtime_Warmer;
         begin
            null;
         end;
         Campaign (Full => False);
         declare
            Baseline : constant Interfaces.C.int := Open_FD_Count;
         begin
            Campaign (Full => True);
            pragma Assert (Open_FD_Count = Baseline);
         end;
      end if;
   end Run;

   procedure Run_Native is new Run (Flyology.Native_Task);
   procedure Run_Lightweight is new Run (Flyology.Lightweight_Task);
begin
   pragma Assert (Flyology.Execution_Groups.Configured_Pool_Size = 1);
   OpenSSL.Initialize_Client
     (Backend, CA_File => Certificate,
      Library_Directory => Library_Directory);
   if Model = Flyology.Native_Task then
      Run_Native;
   else
      Run_Lightweight;
   end if;
end HTTP2_Interop_Client;
