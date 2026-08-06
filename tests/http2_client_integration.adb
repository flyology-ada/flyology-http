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

   if Scenario = "multiplex" then
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
                      (Content = "first-response"
                         or else Content = "second"));
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
            if Scenario = "upload" then
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
            elsif Scenario = "refused-post" then
               Client.Set_Method (Value, Flyology.HTTP.To_Method ("POST"));
            end if;
            if Scenario in "require-failure" | "refused-post" then
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
