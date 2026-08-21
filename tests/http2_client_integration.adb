with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Flyology;
with Flyology.Bytes;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Methods;
with Flyology.IO.TLS.OpenSSL;

procedure HTTP2_Client_Integration is
   package Client renames Flyology.HTTP.Client;
   package OpenSSL renames Flyology.IO.TLS.OpenSSL;
   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element_Offset;
   use type Flyology.HTTP.Protocol;

   Origin_Text : constant String :=
     Ada.Environment_Variables.Value ("FLYOLOGY_HTTP2_TEST_ORIGIN");
   Scenario : constant String :=
     Ada.Environment_Variables.Value ("FLYOLOGY_HTTP2_TEST_SCENARIO");
   Certificate : constant String :=
     Ada.Environment_Variables.Value ("FLYOLOGY_HTTP2_TEST_CA");
   Library_Directory : constant String :=
     (if Ada.Environment_Variables.Exists ("FLYOLOGY_TEST_OPENSSL_DIR")
      then Ada.Environment_Variables.Value ("FLYOLOGY_TEST_OPENSSL_DIR")
      else "");
   Model : constant Flyology.Execution_Model :=
     (if Ada.Environment_Variables.Value
        ("FLYOLOGY_HTTP2_TEST_MODEL", "native") = "lightweight"
      then Flyology.Lightweight_Task else Flyology.Native_Task);

   protected type Outcome (Expected : Positive) is
      procedure Report (Passed : Boolean; Detail : String := "");
      entry Await_All;
      function Passed return Boolean;
      function Detail return String;
   private
      Count : Natural := 0;
      OK    : Boolean := True;
      Message : Unbounded_String;
   end Outcome;

   protected body Outcome is
      procedure Report (Passed : Boolean; Detail : String := "") is
      begin
         Count := Count + 1;
         OK := OK and Passed;
         if not Passed and then Length (Message) = 0 then
            Message := To_Unbounded_String (Detail);
         end if;
      end Report;

      entry Await_All when Count = Expected is
      begin
         null;
      end Await_All;

      function Passed return Boolean is (OK);
      function Detail return String is (To_String (Message));
   end Outcome;

   procedure Check_Body
     (Reply    : in out Client.Response;
      Expected : String)
   is
      Value : constant String := Flyology.Bytes.To_Byte_String
        (Client.Read_All (Reply, Maximum => 300_000));
   begin
      pragma Assert
        (Client.Negotiated_Protocol (Reply) =
           Flyology.HTTP.HTTP_2_Protocol);
      pragma Assert (Client.Status (Reply) = 200);
      pragma Assert (Value = Expected);
   end Check_Body;

   procedure Check_Flow (Reply : in out Client.Response) is
      Value : constant Ada.Streams.Stream_Element_Array :=
        Flyology.Bytes.To_Array
          (Client.Read_All (Reply, Maximum => 300_000));
   begin
      pragma Assert (Value'Length = 256 * 1_024);
      for Index in Value'Range loop
         pragma Assert
           (Natural (Value (Index)) = Natural (Index - Value'First) mod 256);
      end loop;
   end Check_Flow;

   Item : aliased Client.Client (Capacity => 1);
   Backend : aliased OpenSSL.OpenSSL_Provider;
begin
   if Scenario = "prior" then
      Client.Configure
        (Item, Flyology.HTTP.Parse_Origin (Origin_Text),
         Client.HTTP_2_Prior_Knowledge);
   else
      OpenSSL.Initialize_Client
        (Backend, CA_File => Certificate,
         Library_Directory => Library_Directory);
      Client.Configure
        (Item, Flyology.HTTP.Parse_Origin (Origin_Text), Backend'Access,
         (if Scenario = "fallback" then Client.Negotiate_HTTP_2
          else Client.Require_HTTP_2));
   end if;

   if Scenario in
     "multiplex" | "continuation" | "peer-capacity" | "stream-order"
   then
      declare
         Results : Outcome (2);
         task type Caller (Second : Boolean) is
            pragma Task_Info (Model);
         end Caller;

         task body Caller is
            Value : Client.Request;
         begin
            Client.Set_Target
              (Value, (if Second then "/second" else "/first"));
            if Scenario = "continuation" then
               Client.Add_Header (Value, "x-large", (1 .. 16_000 => 'x'));
            end if;
            declare
               Reply : Client.Response :=
                 Client.Execute (Item, Value, Timeout => 30.0);
               Content : constant String := Flyology.Bytes.To_Byte_String
                 (Client.Read_All (Reply, Maximum => 100));
            begin
               Results.Report
                 (Client.Negotiated_Protocol (Reply) =
                    Flyology.HTTP.HTTP_2_Protocol
                    and then
                      (if Scenario = "multiplex"
                       then Content in "first-response" | "second"
                       else Content = "flyology-http2"));
            end;
         exception
            when Event : others =>
               Results.Report
                 (False, Ada.Exceptions.Exception_Information (Event));
         end Caller;

         First  : Caller (False);
         Second : Caller (True);
      begin
         Results.Await_All;
         if not Results.Passed then
            raise Program_Error with Results.Detail;
         end if;
      end;
   elsif Scenario = "shutdown-race" then
      declare
         protected type Gate is
            procedure Mark_Ready;
            entry Await_Ready;
            procedure Release;
            entry Await_Release;
         private
            Ready    : Boolean := False;
            Released : Boolean := False;
         end Gate;

         protected body Gate is
            procedure Mark_Ready is
            begin
               Ready := True;
            end Mark_Ready;

            entry Await_Ready when Ready is
            begin
               null;
            end Await_Ready;

            procedure Release is
            begin
               Released := True;
            end Release;

            entry Await_Release when Released is
            begin
               null;
            end Await_Release;
         end Gate;

         Sync    : Gate;
         Results : Outcome (2);

         task Caller is
            pragma Task_Info (Model);
         end Caller;

         task body Caller is
            Value : Client.Request;
         begin
            Client.Set_Target (Value, "/shutdown-race");
            declare
               Reply : constant Client.Response :=
                 Client.Execute (Item, Value, Timeout => 30.0);
            begin
               pragma Assert (Client.Status (Reply) = 200);
               Sync.Mark_Ready;
               Sync.Await_Release;
            end;
            Results.Report (True);
         exception
            when Event : others =>
               Sync.Mark_Ready;
               Sync.Release;
               Results.Report
                 (False, Ada.Exceptions.Exception_Information (Event));
         end Caller;

         task Stopper is
            pragma Task_Info (Model);
         end Stopper;

         task body Stopper is
         begin
            Sync.Await_Ready;
            Sync.Release;
            Client.Shutdown (Item, Timeout => 5.0);
            Results.Report (True);
         exception
            when Event : others =>
               Results.Report
                 (False, Ada.Exceptions.Exception_Information (Event));
         end Stopper;
      begin
         Results.Await_All;
         if not Results.Passed then
            raise Program_Error with Results.Detail;
         end if;
      end;
   elsif Scenario = "reset-race" then
      declare
         First : Client.Request;
      begin
         Client.Set_Target (First, "/reset-race");
         declare
            Reply : constant Client.Response :=
              Client.Execute (Item, First, Timeout => 30.0);
         begin
            pragma Assert (Client.Status (Reply) = 200);
         end;
      end;
      declare
         Second : Client.Request;
      begin
         Client.Set_Target (Second, "/after-reset");
         declare
            Reply : Client.Response :=
              Client.Execute (Item, Second, Timeout => 30.0);
         begin
            Check_Body (Reply, "flyology-http2");
         end;
      end;
   else
      declare
         Results : Outcome (1);
         task Caller is
            pragma Task_Info (Model);
         end Caller;

         task body Caller is
            Value : Client.Request;
         begin
            Client.Set_Target (Value, "/" & Scenario);
            if Scenario in "upload" | "early-final" then
               declare
                  type Payload_Access is access
                    Ada.Streams.Stream_Element_Array;
                  procedure Free is new Ada.Unchecked_Deallocation
                    (Ada.Streams.Stream_Element_Array, Payload_Access);
                  Payload : Payload_Access := new
                    Ada.Streams.Stream_Element_Array (1 .. 256 * 1_024);
               begin
                  for Index in Payload.all'Range loop
                     Payload.all (Index) := Ada.Streams.Stream_Element
                       (Natural (Index - Payload.all'First) mod 256);
                  end loop;
                  Client.Set_Body (Value, Payload.all);
                  Free (Payload);
               end;
               if Scenario = "early-final" then
                  Client.Set_Method
                    (Value, Flyology.HTTP.To_Method ("POST"));
               end if;
            elsif Scenario = "refused-post" then
               Client.Set_Method (Value, Flyology.HTTP.To_Method ("POST"));
            elsif Scenario = "head-empty-data" then
               Client.Set_Method (Value, Flyology.HTTP.Methods.HEAD);
            end if;
            if Scenario in
              "require-failure" | "refused-post" | "bad-preface" |
              "informational-end"
            then
               begin
                  declare
                     Reply : Client.Response :=
                       Client.Execute (Item, Value, Timeout => 30.0);
                     pragma Unreferenced (Reply);
                  begin
                     Results.Report
                       (False, "HTTP/2 request unexpectedly succeeded");
                  end;
               exception
                  when Flyology.HTTP.Protocol_Error =>
                     Results.Report (True);
               end;
            else
               declare
                  Reply : Client.Response :=
                    Client.Execute (Item, Value, Timeout => 30.0);
               begin
                  if Scenario = "flow" then
                     Check_Flow (Reply);
                  elsif Scenario = "early-final" then
                     pragma Assert (Client.Status (Reply) = 413);
                     pragma Assert
                       (Flyology.Bytes.Length (Client.Read_All (Reply)) = 0);
                  elsif Scenario = "head-empty-data" then
                     pragma Assert
                       (Client.Header (Reply, "content-length") =
                          "5368709129");
                     pragma Assert
                       (Flyology.Bytes.Length (Client.Read_All (Reply)) = 0);
                  elsif Scenario = "zero-read" then
                     declare
                        Empty : Ada.Streams.Stream_Element_Array (1 .. 0);
                        Last : Ada.Streams.Stream_Element_Offset;
                        Finished : Boolean;
                     begin
                        Client.Read_Body (Reply, Empty, Last, Finished);
                        pragma Assert (Last = Empty'First - 1);
                        pragma Assert (not Finished);
                     end;
                     Check_Body (Reply, "flyology-http2");
                  elsif Scenario = "fallback" then
                     pragma Assert
                       (Client.Negotiated_Protocol (Reply) =
                          Flyology.HTTP.HTTP_1_1_Protocol);
                     pragma Assert
                       (Flyology.Bytes.To_Byte_String
                          (Client.Read_All (Reply)) = "fallback");
                  else
                     Check_Body (Reply, "flyology-http2");
                  end if;
               end;
               Results.Report (True);
            end if;
         exception
            when Event : others =>
               Results.Report
                 (False, Ada.Exceptions.Exception_Information (Event));
         end Caller;
      begin
         Results.Await_All;
         if not Results.Passed then
            raise Program_Error with Results.Detail;
         end if;
      end;
   end if;
   Client.Shutdown (Item, Timeout => 5.0);
   Ada.Text_IO.Put_Line ("HTTP/2 client integration passed");
end HTTP2_Client_Integration;
