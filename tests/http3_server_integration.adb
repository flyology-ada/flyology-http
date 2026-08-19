with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Flyology.Bytes;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.HTTP_3;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Routing;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.IO.TLS.ALPN;
with Flyology.IO.TLS.OpenSSL;
with Flyology.QUIC.Connections;
with Flyology.QUIC.Connections.IO;
with Flyology.QUIC.Test_Connections;

procedure HTTP3_Server_Integration is
   package App renames Flyology.HTTP.Server.Applications;
   package Client renames Flyology.HTTP.Client;
   package H3 renames Flyology.HTTP.HTTP_3;
   package QUIC renames Flyology.QUIC.Connections;
   package QUIC_IO renames Flyology.QUIC.Connections.IO;
   package Sockets renames Flyology.IO.Sockets;
   package ALPN renames Flyology.IO.TLS.ALPN;
   package OpenSSL renames Flyology.IO.TLS.OpenSSL;
   package Fixtures renames Flyology.QUIC.Test_Connections;

   use Ada.Strings.Unbounded;
   use type H3.Event_Kind;
   use type H3.Operation_Status;
   use type QUIC.Operation_Status;
   use type QUIC.Timeout_Status;
   use type QUIC.Timestamp;
   use type Ada.Real_Time.Time;
   use type Flyology.HTTP.Origin_Scheme;
   use type Flyology.HTTP.Protocol;

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

   type Context is limited null record;
   package Routing is new Flyology.HTTP.Server.Routing (Context);

   Routes : aliased Routing.Router
     (Capacity => 2, Slashes => Routing.Strict_Slashes);
   State : aliased Context;
   Server_Backend : aliased OpenSSL.OpenSSL_Provider;
   Probe : Sockets.Socket_Type;
   HTTP_Probe : Sockets.Socket_Type;
   Address : Sockets.Endpoint;
   HTTP_Address : Sockets.Endpoint;
   IPv6_Address : Sockets.Endpoint (Sockets.IPv6);
   IPv6_HTTP_Address : Sockets.Endpoint (Sockets.IPv6);

   protected Outcome is
      procedure Fail (Message : String);
      function Passed return Boolean;
      function Message return String;
   private
      Failed : Boolean := False;
      Detail : Unbounded_String;
   end Outcome;

   protected body Outcome is
      procedure Fail (Message : String) is
      begin
         if not Failed then
            Detail := To_Unbounded_String (Message);
         end if;
         Failed := True;
      end Fail;

      function Passed return Boolean is (not Failed);

      function Message return String is (To_String (Detail));
   end Outcome;

   procedure Observe
     (Application : in out Context;
      X           : in out App.Exchange;
      Next        : in out Routing.Components.Next_Handler) is
   begin
      X.Add_Header ("X-Middleware", "visited");
      Next.Call (Application, X);
   end Observe;

   procedure Hello (Application : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (Application);
   begin
      pragma Assert (X.Request_Protocol = Flyology.HTTP.HTTP_3_Protocol);
      pragma Assert (X.Request_Scheme = Flyology.HTTP.Secure_HTTPS);
      pragma Assert (X.Request_Method = "POST");
      pragma Assert (X.Parameter ("name") = "Ada");
      pragma Assert
        (Flyology.HTTP.Server.Content (X.Request_Value) = "payload");
      X.Begin_Stream (200, "text/plain");
      X.Write_Chunk ("hello ");
      X.Write_Chunk (X.Parameter ("name"));
      X.End_Stream;
   end Hello;

   procedure Discover
     (Application : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (Application);
   begin
      if X.Request_Scheme = Flyology.HTTP.Plain_HTTP then
         pragma Assert
           (X.Request_Protocol = Flyology.HTTP.HTTP_1_1_Protocol);
         X.Text (200, "clear routes");
      else
         pragma Assert
           (X.Request_Protocol in Flyology.HTTP.HTTP_1_1_Protocol |
              Flyology.HTTP.HTTP_2_Protocol);
         pragma Assert (X.Request_Scheme = Flyology.HTTP.Secure_HTTPS);
         X.Text (200, "same routes");
      end if;
   end Discover;
begin
   Routes.Add_Middleware (Observe'Access);
   Routes.Post
     ("/hello/{name}", Hello'Access, Name => "hello",
      Policy =>
        (Routing.Default_Route_Policy with delta
           Body_Handling => App.Buffer_Body,
           Max_Body      => 64));
   Routes.Get ("/discover", Discover'Access, Name => "discover");

   OpenSSL.Initialize_Server
     (Server_Backend, Certificate, Private_Key,
      Protocols => ALPN."&" (ALPN.Offer ("h2"), "http/1.1"),
      Library_Directory => Library_Directory);

   --  Reserve a currently free loopback port. The unified server binds both
   --  TCP and UDP to this same concrete endpoint after Probe is closed.
   Sockets.Create_Socket (Probe);
   Sockets.Bind_Socket
     (Probe,
      Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
   Address := Sockets.Get_Socket_Name (Probe);
   Sockets.Create_Socket (HTTP_Probe);
   Sockets.Bind_Socket
     (HTTP_Probe,
      Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
   HTTP_Address := Sockets.Get_Socket_Name (HTTP_Probe);
   Sockets.Close_Socket (HTTP_Probe);
   Sockets.Close_Socket (Probe);
   IPv6_Address := Sockets.Network_Endpoint
     (Sockets.Loopback_IPv6, Address.Port);
   IPv6_HTTP_Address := Sockets.Network_Endpoint
     (Sockets.Loopback_IPv6, HTTP_Address.Port);

   declare
      Stop : aliased Flyology.Cancellation.Token;
      task type Server_Task_Type;
      for Server_Task_Type'Storage_Size use 16 * 1_024 * 1_024;
      Server_Task : Server_Task_Type;

      task body Server_Task_Type is
      begin
         begin
            Routes.Serve
              (State,
               IPv4_HTTP_Endpoint => HTTP_Address,
               IPv6_HTTP_Endpoint => IPv6_HTTP_Address,
               IPv4_HTTPS_Endpoint => Address,
               IPv6_HTTPS_Endpoint => IPv6_Address,
               HTTPS_Origin => Flyology.HTTP.Parse_Origin
                 ("https://localhost:" & Decimal (Natural (Address.Port))),
               TLS_Backend => Server_Backend,
               Certificate_DER => Fixtures.Server_Certificate,
               Private_Key => Fixtures.Server_Private_Key,
               Cleartext_Capacity => 4,
               TCP_Capacity => 4,
               --  HTTP_3_Capacity is a dual-stack total: Routing.Serve
               --  gives IPv6 HTTP_3_Capacity / 2 slots and IPv4 the rest.
               --  Both client profiles below target "localhost", which
               --  resolves to every loopback family, and the connection race
               --  completes a full QUIC handshake on each family before it
               --  discards the losing lane. Each address family therefore
               --  admits up to five concurrent connections here: two live
               --  client profiles, two losing race lanes awaiting release,
               --  and one raw Initial. Size for eight per family so a raw
               --  Initial is never discarded by a momentarily full registry.
               HTTP_3_Capacity => 16,
               Timeout => 10.0,
               Handshake_Timeout => 10.0,
               Max_Connection_Age => 20.0,
               TCP_Max_Requests => 10,
               --  Keep the pooled-credit regression on one connection.  The
               --  loop below deliberately crosses the initial MAX_DATA
               --  window before the server's lifetime request cap.
               HTTP_3_Max_Requests => 8_100,
               Drain_Timeout => 10.0,
               Token => Stop'Access);
         exception
            when Error : others =>
               Outcome.Fail (Ada.Exceptions.Exception_Information (Error));
               Stop.Request;
         end;
      end Server_Task_Type;

      procedure Run_Client (Raw_Address : Sockets.Endpoint) is
         type Client_Phase is
           (Initialize_Mixed_Client,
            Mixed_Discover,
            Mixed_H3_Request,
            Mixed_TCP_Fallback,
            Mixed_Shutdown,
            Pooled_Configure,
            Pooled_Exchange,
            Pooled_Shutdown,
            Raw_Handshake,
            Raw_Start,
            Raw_Request,
            Raw_Response,
            Raw_Close);

         Socket : Sockets.Socket_Type;
         Transport : QUIC.Connection;
         Session : H3.Session;
         Flight : QUIC.Datagram_Batch;
         QUIC_Status : QUIC.Operation_Status;
         H3_Status : H3.Operation_Status;
         Phase : Client_Phase := Initialize_Mixed_Client;
         Exchange_Number : Natural := 0;
         Attempt_Number : Natural := 0;
         pragma Volatile (Phase);
         pragma Volatile (Exchange_Number);
         pragma Volatile (Attempt_Number);

         --  The raw lane drives one QUIC connection directly, so it owns the
         --  monotonic clock and the RFC 9002 recovery loop the pooled client
         --  and the routed server keep internally.
         Raw_Epoch : Ada.Real_Time.Time := Ada.Real_Time.Clock;

         function Failure_Context return String is
           (Sockets.Image (Raw_Address) &
            " phase=" & Client_Phase'Image (Phase) &
            " exchange=" & Decimal (Exchange_Number) &
            " attempt=" & Decimal (Attempt_Number));

         function Raw_Now return QUIC.Timestamp is
            Elapsed : constant Duration := Ada.Real_Time.To_Duration
              (Ada.Real_Time.Clock - Raw_Epoch);
         begin
            return QUIC.Timestamp (Long_Long_Integer (Elapsed * 1_000_000.0));
         end Raw_Now;

         --  Wait no longer than the next probe deadline, so a handshake
         --  flight lost on the loopback path is retransmitted rather than
         --  stalling the whole attempt budget.
         function Raw_Receive_Timeout return Duration is
            Current : constant QUIC.Timestamp := Raw_Now;
         begin
            if not QUIC.Has_Recovery_Timeout (Transport) then
               return 10.0;
            end if;
            declare
               Deadline : constant QUIC.Timestamp :=
                 QUIC.Recovery_Deadline (Transport);
            begin
               if Deadline <= Current then
                  return 0.0;
               end if;
               return Duration'Min
                 (10.0, Duration (Deadline - Current) / 1_000_000.0);
            end;
         end Raw_Receive_Timeout;

         procedure Recover_Raw_Handshake is
            Probes : QUIC.Datagram_Batch;
            Status : QUIC.Timeout_Status;
         begin
            QUIC.Process_Timeout (Transport, Raw_Now, Probes, Status);
            if Status = QUIC.Probes_Ready then
               QUIC_IO.Send (Socket, Probes, Timeout => 10.0);
            elsif Status not in QUIC.Not_Due | QUIC.No_Pending_Recovery then
               raise Program_Error with
                 "raw QUIC recovery failed: "
                 & QUIC.Timeout_Status'Image (Status)
                 & " " & Failure_Context;
            end if;
         end Recover_Raw_Handshake;
      begin
      declare
         HTTP : aliased Client.Client (Capacity => 2);
         Client_Backend : aliased OpenSSL.OpenSSL_Provider;
         Request : Client.Request;

         protected Dual_Stack_Gate is
            procedure Ready;
            entry Await_Ready;
            procedure Release;
            entry Await_Release;
            procedure Fail_Open;
         private
            Is_Ready : Boolean := False;
            Is_Released : Boolean := False;
         end Dual_Stack_Gate;

         protected body Dual_Stack_Gate is
            procedure Ready is
            begin
               Is_Ready := True;
            end Ready;

            entry Await_Ready when Is_Ready is
            begin
               null;
            end Await_Ready;

            procedure Release is
            begin
               Is_Released := True;
            end Release;

            entry Await_Release when Is_Released is
            begin
               null;
            end Await_Release;

            procedure Fail_Open is
            begin
               Is_Ready := True;
               Is_Released := True;
            end Fail_Open;
         end Dual_Stack_Gate;
      begin
         Phase := Initialize_Mixed_Client;
         OpenSSL.Initialize_Client
           (Client_Backend, CA_File => Certificate,
            Library_Directory => Library_Directory);
         Client.Configure
           (HTTP,
            Flyology.HTTP.Parse_Origin
              ("https://localhost:" & Decimal (Natural (Address.Port))),
            Client_Backend'Access,
            Client.Negotiate_HTTP_3,
            HTTP_3_Certificate_DER => Fixtures.Server_Certificate,
            Pool =>
              (Max_Idle => 2,
               Idle_Timeout => 30.0,
               Max_Connection_Age => 300.0,
               Max_Requests_Per_Connection => 0));
         Client.Set_Target (Request, "/discover");
         Phase := Mixed_Discover;
         declare
            Reply : Client.Response :=
              Client.Execute (HTTP, Request, Timeout => 10.0);
         begin
            pragma Assert (Client.Status (Reply) = 200);
            pragma Assert
              (Client.Header (Reply, "Alt-Svc") =
                 "h3="":" & Decimal (Natural (Address.Port)) &
                 """; ma=86400");
            pragma Assert
              (Flyology.Bytes.To_Byte_String (Client.Read_All (Reply)) =
                 "same routes");
         end;

         declare
            task H3_Request;

            task body H3_Request is
               H3_Value : Client.Request;
            begin
               Client.Set_Method
                 (H3_Value, Flyology.HTTP.To_Method ("POST"));
               Client.Set_Target (H3_Value, "/hello/Ada");
               Client.Set_Body (H3_Value, "payload");
               declare
                  Reply : Client.Response :=
                    Client.Execute (HTTP, H3_Value, Timeout => 10.0);
               begin
                  pragma Assert (Client.Status (Reply) = 200);
                  pragma Assert
                    (Client.Negotiated_Protocol (Reply) =
                       Flyology.HTTP.HTTP_3_Protocol);
                  pragma Assert
                    (Client.Header (Reply, "X-Middleware") = "visited");
                  Dual_Stack_Gate.Ready;
                  Dual_Stack_Gate.Await_Release;
                  pragma Assert
                    (Flyology.Bytes.To_Byte_String (Client.Read_All (Reply)) =
                       "hello Ada");
               end;
            exception
               when Error : others =>
                  Outcome.Fail
                    (Sockets.Image (Raw_Address) &
                     " phase=" & Client_Phase'Image (Mixed_H3_Request) &
                     " exchange=0 attempt=0: " &
                     Ada.Exceptions.Exception_Information (Error));
                  Dual_Stack_Gate.Fail_Open;
            end H3_Request;
         begin
            Dual_Stack_Gate.Await_Ready;
            if Outcome.Passed then
               Phase := Mixed_TCP_Fallback;
               declare
                  TCP_Value : Client.Request;
               begin
                  Client.Set_Target (TCP_Value, "/discover");
                  declare
                     Reply : Client.Response :=
                       Client.Execute (HTTP, TCP_Value, Timeout => 10.0);
                  begin
                     pragma Assert (Client.Status (Reply) = 200);
                     pragma Assert
                       (Client.Negotiated_Protocol (Reply) =
                          Flyology.HTTP.HTTP_2_Protocol);
                     pragma Assert
                       (Flyology.Bytes.To_Byte_String
                          (Client.Read_All (Reply)) = "same routes");
                  end;
               end;
            end if;
            Dual_Stack_Gate.Release;
         exception
            when others =>
               Dual_Stack_Gate.Release;
               raise;
         end;
         Phase := Mixed_Shutdown;
         Client.Shutdown (HTTP, Timeout => 5.0);
      end;

      declare
         HTTP : aliased Client.Client (Capacity => 1);
         Request : Client.Request;
      begin
         Phase := Pooled_Configure;
         Client.Configure
           (HTTP,
            Flyology.HTTP.Parse_Origin
              ("https://localhost:" & Decimal (Natural (Address.Port))),
            Client.Require_HTTP_3,
            HTTP_3_Certificate_DER => Fixtures.Server_Certificate);
         Client.Set_Method (Request, Flyology.HTTP.To_Method ("POST"));
         Client.Set_Target (Request, "/hello/Ada");
         Client.Set_Body (Request, "payload");
         --  Cross the concurrent and former lifetime stream tables, then the
         --  initial 512 KiB connection receive window, on one pooled
         --  connection. This exercises MAX_DATA and MAX_STREAMS credit return
         --  together through the user-facing client and server APIs.
         for Exchange in 1 .. 8_000 loop
            Phase := Pooled_Exchange;
            Exchange_Number := Exchange;
            declare
               Reply : Client.Response :=
                 Client.Execute (HTTP, Request, Timeout => 10.0);
            begin
               pragma Assert (Client.Status (Reply) = 200);
               pragma Assert
                 (Client.Negotiated_Protocol (Reply) =
                    Flyology.HTTP.HTTP_3_Protocol);
               pragma Assert
                 (Flyology.Bytes.To_Byte_String (Client.Read_All (Reply)) =
                    "hello Ada");
            end;
         end loop;
         Exchange_Number := 0;
         Phase := Pooled_Shutdown;
         Client.Shutdown (HTTP, Timeout => 5.0);
      end;

      Phase := Raw_Handshake;
      Fixtures.Initialize_Client (Transport);
      Sockets.Create_Socket
        (Socket, Raw_Address.Family, Sockets.Socket_Datagram);
      Sockets.Connect_Socket (Socket, Raw_Address);
      Raw_Epoch := Ada.Real_Time.Clock;
      QUIC.Start_Client (Transport, Flight, QUIC_Status, Raw_Now);
      pragma Assert (QUIC_Status = QUIC.Succeeded);
      QUIC_IO.Send (Socket, Flight, Timeout => 10.0);

      --  A listener whose connection registry is momentarily full discards a
      --  QUIC Initial without answering it. The transport now owns that
      --  retransmission, so the loop drives its probe timeout rather than
      --  resending the last flight itself, and a discarded datagram costs a
      --  probe interval instead of the whole exchange.
      for Attempt in 1 .. 16 loop
         exit when QUIC.Is_Connected (Transport);
         Attempt_Number := Attempt;
         begin
            QUIC_IO.Receive
              (Socket, Transport, Flight, QUIC_Status,
               Now => Raw_Now, Timeout => Raw_Receive_Timeout);
            pragma Assert
              (QUIC_Status in QUIC.Succeeded | QUIC.Waiting_For_More);
            QUIC_IO.Send (Socket, Flight, Timeout => 10.0);
         exception
            when Flyology.IO.Timeout_Error =>
               Recover_Raw_Handshake;
         end;
      end loop;
      Attempt_Number := 0;
      pragma Assert (QUIC.Is_Connected (Transport));

      Phase := Raw_Start;
      H3.Initialize (Session, H3.Client);
      declare
         Control : QUIC.Datagram;
      begin
         H3.Start
           (Session, Transport, Now => 1_000,
            Packet => Control, Status => H3_Status);
         pragma Assert (H3_Status = H3.Succeeded);
         QUIC_IO.Send (Socket, Control, Timeout => 10.0);
      end;

      declare
         Headers : H3.Header_Block;
         Stream : QUIC.Stream_ID;
         Packet : QUIC.Datagram;
      begin
         Phase := Raw_Request;
         H3.Append (Headers, H3.Make_Field (":method", "POST"));
         H3.Append (Headers, H3.Make_Field (":scheme", "https"));
         H3.Append (Headers, H3.Make_Field (":path", "/hello/Ada"));
         H3.Append (Headers, H3.Make_Field (":authority", "localhost"));
         H3.Append (Headers, H3.Make_Field ("content-length", "7"));
         H3.Open_Request (Session, Transport, Stream, H3_Status);
         pragma Assert (H3_Status = H3.Succeeded);
         H3.Send_Headers
           (Session, Transport, Stream, Headers, Fin => False,
            Now => 2_000, Packet => Packet, Status => H3_Status);
         pragma Assert (H3_Status = H3.Succeeded);
         QUIC_IO.Send (Socket, Packet, Timeout => 10.0);
         declare
            Payload : constant Ada.Streams.Stream_Element_Array :=
              (1 => Character'Pos ('p'), 2 => Character'Pos ('a'),
               3 => Character'Pos ('y'), 4 => Character'Pos ('l'),
               5 => Character'Pos ('o'), 6 => Character'Pos ('a'),
               7 => Character'Pos ('d'));
         begin
            H3.Send_Data
              (Session, Transport, Stream, Payload, Fin => True,
               Now => 2_001, Packet => Packet, Status => H3_Status);
            pragma Assert (H3_Status = H3.Succeeded);
            QUIC_IO.Send (Socket, Packet, Timeout => 10.0);
         end;
      end;

      declare
         Event : H3.Event;
         Status_Seen : Boolean := False;
         Middleware_Seen : Boolean := False;
         Alt_Svc_Seen : Boolean := False;
         Ended : Boolean := False;
         Payload : Unbounded_String;
      begin
         Phase := Raw_Response;
         for Attempt in 1 .. 16 loop
            Attempt_Number := Attempt;
            --  The server drives application-space probe timeouts, so a
            --  discarded response datagram is retransmitted by the peer.
            --  Spend the attempt budget waiting for that rather than
            --  abandoning the exchange on the first quiet interval. Sixteen
            --  one-second probes stay inside the server's connection age.
            begin
               QUIC_IO.Receive
                 (Socket, Transport, Flight, QUIC_Status, Timeout => 1.0);
               pragma Assert
                 (QUIC_Status in QUIC.Succeeded | QUIC.Waiting_For_More);
               QUIC_IO.Send (Socket, Flight, Timeout => 10.0);
            exception
               when Flyology.IO.Timeout_Error =>
                  null;
            end;
            loop
               H3.Poll (Session, Transport, Event, H3_Status);
               exit when H3_Status = H3.No_Event;
               pragma Assert (H3_Status = H3.Succeeded);
               if Event.Kind = H3.Headers_Received then
                  for Index in 1 .. H3.Header_Count (Event.Headers) loop
                     declare
                        Field : constant H3.Header_Field :=
                          H3.Field_At (Event.Headers, Index);
                     begin
                        if H3.Field_Name (Field) = ":status"
                          and then H3.Field_Value (Field) = "200"
                        then
                           Status_Seen := True;
                        elsif H3.Field_Name (Field) = "x-middleware"
                          and then H3.Field_Value (Field) = "visited"
                        then
                           Middleware_Seen := True;
                        elsif H3.Field_Name (Field) = "alt-svc" then
                           Alt_Svc_Seen := True;
                        end if;
                     end;
                  end loop;
               elsif Event.Kind = H3.Data_Received then
                  for Index in 1 .. Event.Data_Length loop
                     Append
                       (Payload,
                        Character'Val
                          (Event.Data
                             (Ada.Streams.Stream_Element_Offset (Index))));
                  end loop;
               elsif Event.Kind = H3.Stream_Ended then
                  Ended := True;
               end if;
            end loop;
            exit when Ended;
         end loop;
         Attempt_Number := 0;
         pragma Assert (Status_Seen);
         pragma Assert (Middleware_Seen);
         pragma Assert (not Alt_Svc_Seen);
         pragma Assert (To_String (Payload) = "hello Ada");
         pragma Assert (Ended);
      end;
      Phase := Raw_Close;
      Sockets.Close_Socket (Socket);
      exception
         when Error : others =>
            Outcome.Fail
              (Failure_Context & ": " &
               Ada.Exceptions.Exception_Information (Error));
            if Sockets.Is_Open (Socket) then
               Sockets.Close_Socket (Socket);
            end if;
            raise;
      end Run_Client;

      procedure Await_Server (Endpoint : Sockets.Endpoint) is
         Socket : Sockets.Socket_Type;
      begin
         for Attempt in 1 .. 100 loop
            begin
               Sockets.Create_Socket (Socket, Sockets.IPv4);
               Sockets.Connect_Socket (Socket, Endpoint);
               Sockets.Close_Socket (Socket);
               return;
            exception
               when Sockets.Socket_Error | Flyology.IO.Device_Error =>
                  if Sockets.Is_Open (Socket) then
                     Sockets.Close_Socket (Socket);
                  end if;
                  if Attempt = 100 then
                     raise;
                  end if;
                  delay 0.01;
            end;
         end loop;
      end Await_Server;
   begin
      Await_Server (Address);
      Await_Server (HTTP_Address);
      declare
         HTTP : aliased Client.Client (Capacity => 1);
         Request : Client.Request;
      begin
         Client.Configure
           (HTTP,
            Flyology.HTTP.Parse_Origin
              ("http://localhost:" &
               Decimal (Natural (HTTP_Address.Port))));
         Client.Set_Target (Request, "/discover?source=cleartext");
         declare
            Reply : Client.Response :=
              Client.Execute (HTTP, Request, Timeout => 10.0);
         begin
            pragma Assert (Client.Status (Reply) = 308);
            pragma Assert
              (Client.Negotiated_Protocol (Reply) =
                 Flyology.HTTP.HTTP_1_1_Protocol);
            pragma Assert
              (Client.Header (Reply, "Location") =
                 "https://localhost:" & Decimal (Natural (Address.Port)) &
                 "/discover?source=cleartext");
            pragma Assert
              (Flyology.Bytes.To_Byte_String (Client.Read_All (Reply)) = "");
         end;
         Client.Shutdown (HTTP);
      end;
      declare
         task First_Client;
         task Second_Client;

         task body First_Client is
         begin
            Run_Client (Address);
         exception
            when Error : others =>
               Outcome.Fail (Ada.Exceptions.Exception_Information (Error));
         end First_Client;

         task body Second_Client is
         begin
            Run_Client (IPv6_Address);
         exception
            when Error : others =>
               Outcome.Fail (Ada.Exceptions.Exception_Information (Error));
         end Second_Client;
      begin
         null;
      end;

      Stop.Request;
   exception
      when others =>
         Stop.Request;
         raise;
   end;

   --  Exercise the alternative cleartext policy independently of redirect.
   --  The same registered route observes Plain_HTTP, and direct cleartext
   --  responses do not advertise a secure HTTP/3 alternative.
   declare
      Stop : aliased Flyology.Cancellation.Token;
      task type Server_Task_Type;
      for Server_Task_Type'Storage_Size use 16 * 1_024 * 1_024;
      Server_Task : Server_Task_Type;

      task body Server_Task_Type is
      begin
         begin
            Routes.Serve
              (State,
               HTTP_Endpoint => HTTP_Address,
               HTTPS_Endpoint => Address,
               HTTPS_Origin => Flyology.HTTP.Parse_Origin
                 ("https://localhost:" & Decimal (Natural (Address.Port))),
               TLS_Backend => Server_Backend,
               Certificate_DER => Fixtures.Server_Certificate,
               Private_Key => Fixtures.Server_Private_Key,
               Cleartext => Routing.Serve_Cleartext,
               Cleartext_Capacity => 1,
               TCP_Capacity => 1,
               HTTP_3_Capacity => 1,
               Timeout => 10.0,
               Handshake_Timeout => 10.0,
               Max_Connection_Age => 20.0,
               Drain_Timeout => 10.0,
               Token => Stop'Access);
         exception
            when Error : others =>
               Outcome.Fail (Ada.Exceptions.Exception_Information (Error));
               Stop.Request;
         end;
      end Server_Task_Type;

      procedure Await_Cleartext is
         Socket : Sockets.Socket_Type;
      begin
         for Attempt in 1 .. 100 loop
            begin
               Sockets.Create_Socket (Socket, Sockets.IPv4);
               Sockets.Connect_Socket (Socket, HTTP_Address);
               Sockets.Close_Socket (Socket);
               return;
            exception
               when Sockets.Socket_Error | Flyology.IO.Device_Error =>
                  if Sockets.Is_Open (Socket) then
                     Sockets.Close_Socket (Socket);
                  end if;
                  if Attempt = 100 then
                     raise;
                  end if;
                  delay 0.01;
            end;
         end loop;
      end Await_Cleartext;
   begin
      Await_Cleartext;
      declare
         HTTP : aliased Client.Client (Capacity => 1);
         Request : Client.Request;
      begin
         Client.Configure
           (HTTP,
            Flyology.HTTP.Parse_Origin
              ("http://localhost:" &
               Decimal (Natural (HTTP_Address.Port))));
         Client.Set_Target (Request, "/discover");
         declare
            Reply : Client.Response :=
              Client.Execute (HTTP, Request, Timeout => 10.0);
         begin
            pragma Assert (Client.Status (Reply) = 200);
            pragma Assert (Client.Header (Reply, "Alt-Svc") = "");
            pragma Assert
              (Flyology.Bytes.To_Byte_String (Client.Read_All (Reply)) =
                 "clear routes");
         end;
         Client.Shutdown (HTTP);
      end;
      Stop.Request;
   exception
      when others =>
         Stop.Request;
         raise;
   end;

   pragma Assert (Outcome.Passed, Outcome.Message);
end HTTP3_Server_Integration;
