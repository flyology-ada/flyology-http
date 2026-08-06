with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Text_IO;
with Flyology;
with Flyology.Bytes;
with Flyology.HTTP;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Connections;
with Flyology.HTTP.WebSocket_Client;
with Flyology.IO.Connections;
with Flyology.IO.Connections.TLS;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with Flyology.IO.TLS.OpenSSL;

procedure WebSocket_Client_TLS_Smoke is
   package WS renames Flyology.HTTP.WebSocket_Client;
   package Server renames Flyology.HTTP.Server;
   package Connections renames Flyology.IO.Connections;
   package Connection_TLS renames Flyology.IO.Connections.TLS;
   package OpenSSL renames Flyology.IO.TLS.OpenSSL;
   package Sockets renames Flyology.IO.Sockets;

   use type Server.WebSocket_Data_Kind;
   use type WS.Data_Kind;
   use type Sockets.Selector_Status;

   Certificate : constant String := "tests/fixtures/tls/server-cert.pem";
   Private_Key : constant String := "tests/fixtures/tls/server-key.pem";
   Library_Directory : constant String :=
     (if Ada.Environment_Variables.Exists ("FLYOLOGY_TEST_OPENSSL_DIR")
      then Ada.Environment_Variables.Value ("FLYOLOGY_TEST_OPENSSL_DIR")
      else "");

   function Decimal (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal;

   protected type Outcome is
      procedure Report (Passed : Boolean);
      entry Wait;
      function Passed return Boolean;
   private
      Count : Natural := 0;
      OK    : Boolean := True;
   end Outcome;

   protected body Outcome is
      procedure Report (Passed : Boolean) is
      begin
         Count := Count + 1;
         OK := OK and Passed;
      end Report;
      entry Wait when Count = 2 is
      begin
         null;
      end Wait;
      function Passed return Boolean is (OK);
   end Outcome;

   generic
      Model : Flyology.Execution_Model;
   procedure Run;

   procedure Run is
      Server_Backend : OpenSSL.OpenSSL_Provider;
      Listener : Sockets.Socket_Type;
      Address : Sockets.Endpoint;
      Result : Outcome;
   begin
      OpenSSL.Initialize_Server
        (Server_Backend, Certificate, Private_Key,
         Library_Directory => Library_Directory);
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener);
      Address := Sockets.Get_Socket_Name (Listener);
      declare
         task Server_Task;
         task Client_Task is
            pragma Task_Info (Model);
         end Client_Task;

         task body Server_Task is
            Manager : aliased Connections.Server (Capacity => 1);
            Socket : Sockets.Socket_Type;
            Peer : Sockets.Endpoint;
            Status : Sockets.Selector_Status;
            Channel : aliased Connections.Connection;
         begin
            Sockets.Accept_Socket
              (Listener, Socket, Peer, Timeout => 5.0, Status => Status);
            pragma Assert (Status = Sockets.Completed);
            Connections.Take (Manager, Socket, Channel);
            Connection_TLS.Upgrade
              (Channel, Server_Backend, Flyology.IO.TLS.Server, "",
               Timeout => 5.0);
            declare
               Transport : aliased
                 Flyology.HTTP.Server.Connections.Connection_Transport
                   (Channel'Access);
               Connection : Server.Connection (Transport'Access);
               Request : Server.Request;
               Request_Closed : Boolean;
               Kind : Server.WebSocket_Data_Kind;
               Data : Flyology.Bytes.Unbounded_Bytes;
               Closed : Boolean;
            begin
               Server.Read_Request
                 (Connection, Request, Request_Closed, Timeout => 5.0);
               Server.Accept_WebSocket
                 (Connection, Request, Timeout => 5.0);
               Server.Receive_WebSocket
                 (Connection, Kind, Data, Closed, Timeout => 5.0,
                  Message_Timeout => 5.0);
               pragma Assert
                 (not Closed and then Kind = Server.Text_Frame
                  and then Flyology.Bytes.To_Byte_String (Data) = "secure");
               Server.Send_WebSocket
                 (Connection, "reply", Timeout => 5.0);
               Server.Receive_WebSocket
                 (Connection, Kind, Data, Closed, Timeout => 5.0,
                  Message_Timeout => 5.0);
               pragma Assert (Closed);
            end;
            Connection_TLS.Shutdown (Channel, Timeout => 5.0);
            Connections.Close (Channel);
            Sockets.Close_Socket (Listener);
            Result.Report (True);
         exception
            when Occurrence : others =>
               Ada.Text_IO.Put_Line
                 ("WSS server failed: " &
                  Ada.Exceptions.Exception_Information (Occurrence));
               Result.Report (False);
         end Server_Task;

         task body Client_Task is
            Item : WS.Client;
            Request : WS.Request;
         begin
            declare
               Backend : aliased OpenSSL.OpenSSL_Provider;
            begin
               OpenSSL.Initialize_Client
                 (Backend, CA_File => Certificate,
                  Library_Directory => Library_Directory);
               WS.Configure
                 (Item,
                  Flyology.HTTP.Parse_Origin
                    ("https://localhost:" &
                     Decimal (Natural (Address.Port))),
                  Backend'Access);
            end;
            WS.Connect (Item, Request, Timeout => 5.0);
            WS.Send (Item, "secure", Timeout => 5.0);
            declare
               Kind : WS.Data_Kind;
               Data : Flyology.Bytes.Unbounded_Bytes;
               Closed : Boolean;
            begin
               WS.Receive (Item, Kind, Data, Closed, Timeout => 5.0);
               pragma Assert
                 (not Closed and then Kind = WS.Text_Message
                  and then Flyology.Bytes.To_Byte_String (Data) = "reply");
            end;
            WS.Close (Item, Timeout => 5.0);
            Result.Report (True);
         exception
            when Occurrence : others =>
               Ada.Text_IO.Put_Line
                 ("WSS client failed: " &
                  Ada.Exceptions.Exception_Information (Occurrence));
               Result.Report (False);
         end Client_Task;
      begin
         Result.Wait;
      end;
      pragma Assert (Result.Passed);
   end Run;

   procedure Run_Native is new Run (Flyology.Native_Task);
   procedure Run_Lightweight is new Run (Flyology.Lightweight_Task);
begin
   Run_Native;
   Run_Lightweight;
end WebSocket_Client_TLS_Smoke;
