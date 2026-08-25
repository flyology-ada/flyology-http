with Ada.Exceptions;
with Ada.Streams;
with Ada.Environment_Variables;
with Ada.Text_IO;
with Flyology;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Connections;
with Flyology.IO;
with Flyology.IO.Connections;
with Flyology.IO.Connections.TLS;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with Flyology.IO.TLS.OpenSSL;
with Flyology.IO.Timers;
with Flyology.Operations;

procedure HTTP_Operations_Smoke is
   package HTTP renames Flyology.HTTP.Server;
   package HTTP_Connections renames Flyology.HTTP.Server.Connections;
   package Connections renames Flyology.IO.Connections;
   package Connection_TLS renames Flyology.IO.Connections.TLS;
   package TLS renames Flyology.IO.TLS;
   package OpenSSL renames Flyology.IO.TLS.OpenSSL;
   package Sockets renames Flyology.IO.Sockets;
   package Timers renames Flyology.IO.Timers;
   package Operations renames Flyology.Operations;

   use type Ada.Streams.Stream_Element_Offset;
   use type Operations.Terminal_Outcome;

   CRLF : constant String := Character'Val (13) & Character'Val (10);
   Certificate : constant String := "tests/fixtures/tls/server-cert.pem";
   Private_Key : constant String := "tests/fixtures/tls/server-key.pem";
   Library_Directory : constant String :=
     (if Ada.Environment_Variables.Exists ("FLYOLOGY_TEST_OPENSSL_DIR")
      then Ada.Environment_Variables.Value ("FLYOLOGY_TEST_OPENSSL_DIR")
      else "");

   function Bytes (Value : String) return Ada.Streams.Stream_Element_Array is
      Result : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Value'Length));
   begin
      for Index in Value'Range loop
         Result
           (Ada.Streams.Stream_Element_Offset (Index - Value'First + 1)) :=
             Ada.Streams.Stream_Element (Character'Pos (Value (Index)));
      end loop;
      return Result;
   end Bytes;

   function Text (Value : Ada.Streams.Stream_Element_Array) return String is
      Result : String (1 .. Natural (Value'Length));
      Cursor : Positive := Result'First;
   begin
      for Item of Value loop
         Result (Cursor) := Character'Val (Item);
         Cursor := Cursor + 1;
      end loop;
      return Result;
   end Text;

   procedure Send (Peer : Sockets.Socket_Type; Value : String) is
   begin
      Sockets.Send_All (Peer, Bytes (Value), Timeout => 1.0);
   end Send;

   procedure Check_Lightweight_Lane is
      protected Result is
         procedure Publish (Passed : Boolean);
         entry Await (Passed : out Boolean);
      private
         Ready : Boolean := False;
         Value : Boolean := False;
      end Result;

      protected body Result is
         procedure Publish (Passed : Boolean) is
         begin
            Value := Passed;
            Ready := True;
         end Publish;

         entry Await (Passed : out Boolean) when Ready is
         begin
            Passed := Value;
         end Await;
      end Result;

      Request : HTTP.Request;
      Closed  : Boolean := True;

      task Worker is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Worker;

      task body Worker is
      begin
         declare
            Manager : aliased Connections.Server (Capacity => 1);
            Channel : aliased Connections.Connection (Manager'Access);
            Socket  : Sockets.Socket_Type;
            Peer    : Sockets.Socket_Type;
         begin
            Sockets.Create_Socket_Pair (Socket, Peer);
            Connections.Take (Manager, Socket, Channel);
            Send
              (Peer,
               "GET /lightweight HTTP/1.1" & CRLF
               & "Host: local");
            declare
               Transport : aliased HTTP_Connections.Connection_Transport
                 (Channel'Access);
               Client : aliased HTTP.Connection (Transport'Access);
            begin
               declare
                  Set : aliased Operations.Completion_Set (2);
               begin
                  declare
                     Head : aliased HTTP.Read_Request_Head_Operation :=
                       HTTP.Read_Request_Head
                         (Set'Access, Client'Access, Timeout => 1.0);
                     Timer : Timers.Timer_Operation :=
                       Timers.Sleep_For (Set'Access, 0.0);
                  begin
                     Send (Peer, "host" & CRLF & CRLF);
                     Operations.Wait_All (Set);
                     Timers.Finish (Timer);
                     HTTP.Finish (Head, Request, Closed);
                     pragma Assert (not Closed);
                     pragma Assert
                       (HTTP.Target (Request) = "/lightweight");
                  end;
                  pragma Assert (not Closed);
                  pragma Assert
                    (HTTP.Target (Request) = "/lightweight");
               end;
               pragma Assert
                 (not Closed,
                  "lightweight closed=" & Boolean'Image (Closed)
                  & " target=" & HTTP.Target (Request));
               pragma Assert (HTTP.Target (Request) = "/lightweight");
               Sockets.Close_Socket (Peer);
               declare
                  Set : aliased Operations.Completion_Set (1);
                  Head : HTTP.Read_Request_Head_Operation :=
                    HTTP.Read_Request_Head
                      (Set'Access, Client'Access, Timeout => 1.0);
               begin
                  Operations.Wait_All (Set);
                  HTTP.Finish (Head, Request, Closed);
                  pragma Assert (Closed);
                  pragma Assert (HTTP.Target (Request) = "");
               end;
            end;
            Connections.Close (Channel);
         end;
         Result.Publish (True);
      exception
         when Error : others =>
            Ada.Text_IO.Put_Line (Ada.Exceptions.Exception_Information (Error));
            Result.Publish (False);
      end Worker;

      Passed : Boolean;
   begin
      Result.Await (Passed);
      pragma Assert (Passed);
      pragma Assert (Closed);
      pragma Assert (HTTP.Target (Request) = "");
   end Check_Lightweight_Lane;

   procedure Check_Partial_And_Composed is
      Manager : aliased Connections.Server (Capacity => 1);
      Channel : aliased Connections.Connection (Manager'Access);
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
   begin
      Sockets.Create_Socket_Pair (Socket, Peer);
      Connections.Take (Manager, Socket, Channel);
      declare
         Transport : aliased HTTP_Connections.Connection_Transport
           (Channel'Access);
         Client : aliased HTTP.Connection (Transport'Access);
         Request : HTTP.Request;
         Closed : Boolean;
      begin
         Send
           (Peer,
            "POST /composed HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Content-L");
         declare
            Set : aliased Operations.Completion_Set (3);
            Head : aliased HTTP.Read_Request_Head_Operation :=
              HTTP.Read_Request_Head
                (Set'Access, Client'Access, Timeout => 1.0);
            Timer : Timers.Timer_Operation :=
              Timers.Sleep_For (Set'Access, 0.001);
            Gate : Operations.Gate_Operation := Operations.Wait_All
              (Set'Access,
               [Operations.Reference (Head), Operations.Reference (Timer)]);
            Matched : Operations.Completion_Batch (Set.Capacity);
         begin
            Send
              (Peer,
               "ength: 5" & CRLF & "Connection: close" & CRLF & CRLF
               & "he");
            Operations.Wait_All (Set);
            Operations.Finish (Gate, Matched);
            Timers.Finish (Timer);
            HTTP.Finish (Head, Request, Closed);
            pragma Assert (not Closed);
            pragma Assert (HTTP.Method (Request) = "POST");
            pragma Assert (HTTP.Target (Request) = "/composed");
         end;

         declare
            Set : aliased Operations.Completion_Set (1);
            Data : aliased Ada.Streams.Stream_Element_Array :=
              [1 => 0, 2 => 0, 3 => 0, 4 => 0, 5 => 0];
            Read : aliased HTTP.Read_Body_Operation :=
              HTTP.Read_Body
                (Set'Access, Client'Access, Data'Access);
            Last : Ada.Streams.Stream_Element_Offset;
            Finished : Boolean;
         begin
            Send (Peer, "llo");
            Operations.Wait_All (Set);
            HTTP.Finish (Read, Last, Finished);
            pragma Assert (Finished);
            pragma Assert (Last = Data'Last);
            pragma Assert (Text (Data) = "hello");
         end;
      end;
      Connections.Close (Channel);
      Sockets.Close_Socket (Peer);
   end Check_Partial_And_Composed;

   procedure Check_Accept_Body is
      Manager : aliased Connections.Server (Capacity => 1);
      Channel : aliased Connections.Connection (Manager'Access);
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
   begin
      Sockets.Create_Socket_Pair (Socket, Peer);
      Connections.Take (Manager, Socket, Channel);
      declare
         Transport : aliased HTTP_Connections.Connection_Transport
           (Channel'Access);
         Client : aliased HTTP.Connection (Transport'Access);
         Request : HTTP.Request;
         Closed : Boolean;
         Set : aliased Operations.Completion_Set (1);
         Head : HTTP.Read_Request_Head_Operation (Set'Access);
         Acceptance : HTTP.Accept_Body_Operation (Set'Access);
         Read : HTTP.Read_Body_Operation (Set'Access);
         Response : Ada.Streams.Stream_Element_Array (1 .. 25);
         Data : aliased Ada.Streams.Stream_Element_Array := [1 => 0];
         Last : Ada.Streams.Stream_Element_Offset;
         Finished : Boolean;
      begin
         Send
           (Peer,
            "POST /continue HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Content-Length: 1" & CRLF
            & "Expect: 100-continue" & CRLF & CRLF);
         HTTP.Read_Request_Head (Client'Access, Operation => Head);
         Operations.Wait_All (Set);
         HTTP.Finish (Head, Request, Closed);
         Operations.Release (Head);
         pragma Assert (not Closed);

         HTTP.Accept_Body (Client'Access, Operation => Acceptance);
         Operations.Wait_All (Set);
         HTTP.Finish (Acceptance);
         Operations.Release (Acceptance);
         Sockets.Receive_Exactly (Peer, Response, Timeout => 1.0);
         pragma Assert
           (Text (Response) = "HTTP/1.1 100 Continue" & CRLF & CRLF);

         Send (Peer, "x");
         HTTP.Read_Body (Client'Access, Data'Access, Operation => Read);
         Operations.Wait_All (Set);
         HTTP.Finish (Read, Last, Finished);
         Operations.Release (Read);
         pragma Assert
           (Finished and then Last = Data'Last and then Text (Data) = "x");

         Sockets.Close_Socket (Peer);
         HTTP.Read_Request_Head (Client'Access, Operation => Head);
         Operations.Wait_All (Set);
         HTTP.Finish (Head, Request, Closed);
         Operations.Release (Head);
         pragma Assert (Closed);
         pragma Assert (HTTP.Target (Request) = "");
      end;
      Connections.Close (Channel);
   end Check_Accept_Body;

   procedure Check_Synchronous_Parity is
      Manager : aliased Connections.Server (Capacity => 1);
      Channel : aliased Connections.Connection (Manager'Access);
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
   begin
      Sockets.Create_Socket_Pair (Socket, Peer);
      Connections.Take (Manager, Socket, Channel);
      Send
        (Peer,
         "POST /synchronous HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF & "Content-Length: 4" & CRLF
         & CRLF & "same");
      declare
         Transport : aliased HTTP_Connections.Connection_Transport
           (Channel'Access);
         Client : HTTP.Connection (Transport'Access);
         Request : HTTP.Request;
         Closed : Boolean := False;
         Data : Ada.Streams.Stream_Element_Array (1 .. 4);
         Last : Ada.Streams.Stream_Element_Offset;
         Finished : Boolean;
      begin
         HTTP.Read_Request_Head
           (Client, Request, Closed,
            Header_Timeout => 1.0, Request_Timeout => 1.0);
         pragma Assert
           (not Closed,
            "closed=" & Boolean'Image (Closed)
            & " target=" & HTTP.Target (Request));
         HTTP.Read_Body (Client, Data, Last, Finished);
         pragma Assert (not Closed);
         pragma Assert (Finished);
         pragma Assert (HTTP.Target (Request) = "/synchronous");
         pragma Assert (Last = Data'Last and then Text (Data) = "same");
      end;
      Connections.Close (Channel);
      Sockets.Close_Socket (Peer);
   end Check_Synchronous_Parity;

   procedure Check_Cancellation_And_Cleanup is
      Manager : aliased Connections.Server (Capacity => 1);
      Channel : aliased Connections.Connection (Manager'Access);
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
   begin
      Sockets.Create_Socket_Pair (Socket, Peer);
      Connections.Take (Manager, Socket, Channel);
      declare
         Transport : aliased HTTP_Connections.Connection_Transport
           (Channel'Access);
         Client : aliased HTTP.Connection (Transport'Access);
      begin
         declare
            Set : aliased Operations.Completion_Set (1);
            Head : aliased HTTP.Read_Request_Head_Operation :=
              HTTP.Read_Request_Head
                (Set'Access, Client'Access, Timeout => 1.0);
            Request : HTTP.Request;
            Closed : Boolean;
            Cancelled : Boolean := False;
         begin
            Operations.Cancel (Head);
            pragma Assert (Operations.Is_Terminal (Head));
            begin
               HTTP.Finish (Head, Request, Closed);
            exception
               when Operations.Operation_Cancelled =>
                  Cancelled := True;
            end;
            pragma Assert (Cancelled);
         end;

         declare
            Token : aliased Flyology.Cancellation.Token;
            Set : aliased Operations.Completion_Set (1);
            Head : aliased HTTP.Read_Request_Head_Operation :=
              HTTP.Read_Request_Head
                (Set'Access, Client'Access, Timeout => 1.0,
                 Token => Token'Access);
            Request : HTTP.Request;
            Closed : Boolean;
            Cancelled : Boolean := False;
         begin
            Token.Request;
            Operations.Wait_All (Set);
            begin
               HTTP.Finish (Head, Request, Closed);
            exception
               when Operations.Operation_Cancelled =>
                  Cancelled := True;
            end;
            pragma Assert (Cancelled);
         end;

         declare
            Set : aliased Operations.Completion_Set (1);
            Head : constant HTTP.Read_Request_Head_Operation :=
              HTTP.Read_Request_Head
                (Set'Access, Client'Access, Timeout => 1.0);
         begin
            pragma Assert (Operations.Is_Active (Head));
         end;

         Send
           (Peer,
            "GET /after-cleanup HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF & "Connection: close" & CRLF
            & CRLF);
         declare
            Set : aliased Operations.Completion_Set (1);
            Head : aliased HTTP.Read_Request_Head_Operation :=
              HTTP.Read_Request_Head
                (Set'Access, Client'Access, Timeout => 1.0);
            Request : HTTP.Request;
            Closed : Boolean;
         begin
            Operations.Wait_All (Set);
            HTTP.Finish (Head, Request, Closed);
            pragma Assert (not Closed);
            pragma Assert (HTTP.Target (Request) = "/after-cleanup");
         end;
      end;
      Connections.Close (Channel);
      Sockets.Close_Socket (Peer);
   end Check_Cancellation_And_Cleanup;

   procedure Check_Retained_Failures is
      Manager : aliased Connections.Server (Capacity => 1);
      Channel : aliased Connections.Connection (Manager'Access);
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
   begin
      Sockets.Create_Socket_Pair (Socket, Peer);
      Connections.Take (Manager, Socket, Channel);
      declare
         Transport : aliased HTTP_Connections.Connection_Transport
           (Channel'Access);
         Client : aliased HTTP.Connection (Transport'Access);
         Set : aliased Operations.Completion_Set (2);
         Head : aliased HTTP.Read_Request_Head_Operation :=
           HTTP.Read_Request_Head
             (Set'Access, Client'Access, Timeout => 0.0);
         Timer : Timers.Timer_Operation := Timers.Sleep_For (Set'Access, 0.0);
         Batch : Operations.Completion_Batch (Set.Capacity);
         Request : HTTP.Request;
         Closed : Boolean;
         Timed_Out : Boolean := False;
      begin
         Operations.Wait_For_Success (Set, Batch);
         pragma Assert
           (Operations.Outcome (Head) = Operations.Failed);
         Timers.Finish (Timer);
         begin
            HTTP.Finish (Head, Request, Closed);
         exception
            when Flyology.IO.Timeout_Error =>
               Timed_Out := True;
         end;
         pragma Assert (Timed_Out);
      end;
      Send (Peer, "malformed" & CRLF & CRLF);
      declare
         Transport : aliased HTTP_Connections.Connection_Transport
           (Channel'Access);
         Client : aliased HTTP.Connection (Transport'Access);
         Set : aliased Operations.Completion_Set (2);
         Head : aliased HTTP.Read_Request_Head_Operation :=
           HTTP.Read_Request_Head
             (Set'Access, Client'Access, Timeout => 1.0);
         Timer : Timers.Timer_Operation := Timers.Sleep_For (Set'Access, 0.0);
         Request : HTTP.Request;
         Closed : Boolean;
         Failed : Boolean := False;
      begin
         Operations.Wait_All (Set);
         pragma Assert
           (Operations.Outcome (Head) = Operations.Failed);
         Timers.Finish (Timer);
         begin
            HTTP.Finish (Head, Request, Closed);
         exception
            when Flyology.HTTP.Protocol_Error =>
               Failed := True;
         end;
         pragma Assert (Failed);
      end;
      Connections.Close (Channel);
      Sockets.Close_Socket (Peer);
   end Check_Retained_Failures;

   procedure Check_Simultaneous is
      Manager : aliased Connections.Server (Capacity => 2);
      Channel_1 : aliased Connections.Connection (Manager'Access);
      Channel_2 : aliased Connections.Connection (Manager'Access);
      Socket_1, Peer_1, Socket_2, Peer_2 : Sockets.Socket_Type;
   begin
      Sockets.Create_Socket_Pair (Socket_1, Peer_1);
      Sockets.Create_Socket_Pair (Socket_2, Peer_2);
      Connections.Take (Manager, Socket_1, Channel_1);
      Connections.Take (Manager, Socket_2, Channel_2);
      declare
         Transport_1 : aliased HTTP_Connections.Connection_Transport
           (Channel_1'Access);
         Transport_2 : aliased HTTP_Connections.Connection_Transport
           (Channel_2'Access);
         Client_1 : aliased HTTP.Connection (Transport_1'Access);
         Client_2 : aliased HTTP.Connection (Transport_2'Access);
         Set : aliased Operations.Completion_Set (3);
         Head_1 : aliased HTTP.Read_Request_Head_Operation :=
           HTTP.Read_Request_Head (Set'Access, Client_1'Access);
         Head_2 : aliased HTTP.Read_Request_Head_Operation :=
           HTTP.Read_Request_Head (Set'Access, Client_2'Access);
         Timer : Timers.Timer_Operation := Timers.Sleep_For (Set'Access, 0.0);
         Batch : Operations.Completion_Batch (Set.Capacity);
         Request : HTTP.Request;
         Closed : Boolean;
      begin
         Operations.Wait_Some (Set, Required => 1, Completed => Batch);
         pragma Assert (Batch.Count = 1);
         Timers.Finish (Timer);

         Send
           (Peer_1, "GET /one HTTP/1.1" & CRLF & "Host: localhost"
            & CRLF & CRLF);
         Operations.Wait_At_Least
           (Set, Required => 1, Completed => Batch);
         pragma Assert (Batch.Count = 1);
         HTTP.Finish (Head_1, Request, Closed);
         pragma Assert (not Closed);
         pragma Assert (HTTP.Target (Request) = "/one");

         Send
           (Peer_2, "GET /two HTTP/1.1" & CRLF & "Host: localhost"
            & CRLF & CRLF);
         Operations.Wait_For_Successes
           (Set, Required => 1, Completed => Batch);
         pragma Assert (Batch.Count = 1);
         HTTP.Finish (Head_2, Request, Closed);
         pragma Assert (not Closed);
         pragma Assert (HTTP.Target (Request) = "/two");
      end;
      Connections.Close (Channel_1);
      Connections.Close (Channel_2);
      Sockets.Close_Socket (Peer_1);
      Sockets.Close_Socket (Peer_2);
   end Check_Simultaneous;

   procedure Check_Upgraded_TLS is
      Client_Backend : OpenSSL.OpenSSL_Provider;
      Server_Backend : aliased OpenSSL.OpenSSL_Provider;
      Manager : aliased Connections.Server (Capacity => 1);
      Channel : aliased Connections.Connection (Manager'Access);
      Client_Socket : Sockets.Socket_Type;
      Server_Socket : Sockets.Socket_Type;
      Client : TLS.Connection;
      Peer_Passed : Boolean := False;
   begin
      OpenSSL.Initialize_Client
        (Client_Backend, CA_File => Certificate,
         Library_Directory => Library_Directory);
      OpenSSL.Initialize_Server
        (Server_Backend, Certificate, Private_Key,
         Library_Directory => Library_Directory);
      Sockets.Create_Socket_Pair (Client_Socket, Server_Socket);
      TLS.Take
        (Client_Backend, Client_Socket, TLS.Client, "localhost", Client);
      Connections.Take (Manager, Server_Socket, Channel);
      declare
         Set : aliased Operations.Completion_Set (1);
         task Peer;

         task body Peer is
         begin
            TLS.Handshake (Client, Timeout => 5.0);
            TLS.Send_All
              (Client,
               Bytes
                 ("GET /tls-operation HTTP/1.1" & CRLF
                  & "Host: localhost" & CRLF
                  & "Connection: close" & CRLF & CRLF),
               Timeout => 5.0);
            TLS.Shutdown (Client, Timeout => 5.0);
            Peer_Passed := True;
         exception
            when others =>
               null;
         end Peer;
      begin
         declare
            Secure : Connection_TLS.Upgrade_Operation :=
              Connection_TLS.Upgrade
                (Set'Access, Channel'Access, Server_Backend'Access,
                 TLS.Server, "", Timeout => 5.0);
         begin
            Operations.Wait_All (Set);
            Connection_TLS.Finish (Secure);
         end;
         declare
            Transport : aliased HTTP_Connections.Connection_Transport
              (Channel'Access);
            HTTP_Connection : aliased HTTP.Connection (Transport'Access);
            Head : aliased HTTP.Read_Request_Head_Operation :=
              HTTP.Read_Request_Head
                (Set'Access, HTTP_Connection'Access, Timeout => 5.0);
            Request : HTTP.Request;
            Closed : Boolean;
         begin
            Operations.Wait_All (Set);
            HTTP.Finish (Head, Request, Closed);
            pragma Assert (not Closed);
            pragma Assert (HTTP.Target (Request) = "/tls-operation");
         end;
         Connection_TLS.Shutdown (Channel, Timeout => 5.0);
      end;
      pragma Assert (Peer_Passed);
      TLS.Close (Client);
      Connections.Close (Channel);
   end Check_Upgraded_TLS;

begin
   Check_Lightweight_Lane;
   Check_Partial_And_Composed;
   Check_Accept_Body;
   Check_Synchronous_Parity;
   Check_Cancellation_And_Cleanup;
   Check_Retained_Failures;
   Check_Simultaneous;
   Check_Upgraded_TLS;
end HTTP_Operations_Smoke;
