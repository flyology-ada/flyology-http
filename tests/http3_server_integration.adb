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
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
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

   type Unknown_String_Source
     (Data : not null access constant String)
   is limited new Client.Request_Body_Source with record
      Cursor : Natural := 1;
   end record;

   overriding function Declared_Length
     (Item : Unknown_String_Source) return Client.Body_Length is
     (Client.Unknown_Length);

   overriding procedure Read
     (Item     : in out Unknown_String_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
      Count : constant Natural := Natural'Min
        (Natural (Data'Length), Item.Data'Length - Item.Cursor + 1);
   begin
      Last := Data'First - 1;
      if Count > 0 then
         for Offset in 0 .. Count - 1 loop
            Data (Data'First + Ada.Streams.Stream_Element_Offset (Offset)) :=
              Ada.Streams.Stream_Element
                (Character'Pos (Item.Data (Item.Cursor + Offset)));
         end loop;
         Last := Data'First + Ada.Streams.Stream_Element_Offset (Count - 1);
      end if;
      Item.Cursor := Item.Cursor + Count;
      Finished := Item.Cursor > Item.Data'Length;
   end Read;

   type Sparse_Five_GiB_Source is
     limited new Client.Request_Body_Source with null record;

   overriding function Declared_Length
     (Item : Sparse_Five_GiB_Source) return Client.Body_Length is
     (Client.Known_Length (5 * 1_024 * 1_024 * 1_024));

   overriding procedure Read
     (Item     : in out Sparse_Five_GiB_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token) is
   begin
      pragma Unreferenced (Item, Timeout, Token);
      Data := (others => 0);
      Last := Data'First - 1;
      Finished := True;
   end Read;

   Source_Failure : exception;
   type Adversarial_Kind is
     (Zero_Progress, Overrun, Source_Exception, Cancelled_Source,
      Expired_Source, Early_Final_Source);
   type Adversarial_Source (Kind : Adversarial_Kind) is limited new
     Client.Request_Body_Source with record
      Reads : Natural := 0;
   end record;

   overriding function Declared_Length
     (Item : Adversarial_Source) return Client.Body_Length is
     (case Item.Kind is
         when Zero_Progress | Source_Exception => Client.Unknown_Length,
         when Overrun | Cancelled_Source | Expired_Source =>
           Client.Known_Length (1),
         when Early_Final_Source =>
           Client.Known_Length (64 * 1_024 * 1_024 * 1_024));

   overriding procedure Read
     (Item     : in out Adversarial_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token) is
   begin
      Item.Reads := Item.Reads + 1;
      Last := Data'First - 1;
      Finished := False;
      case Item.Kind is
         when Zero_Progress =>
            null;
         when Overrun =>
            Data (Data'First .. Data'First + 1) := (others => 1);
            Last := Data'First + 1;
            Finished := True;
         when Source_Exception =>
            raise Source_Failure;
         when Cancelled_Source =>
            pragma Assert (Token /= null);
            Token.Request;
            Data (Data'First) := 1;
            Last := Data'First;
            Finished := True;
         when Expired_Source =>
            pragma Assert (Timeout >= 0.0);
            delay 0.02;
            Data (Data'First) := 1;
            Last := Data'First;
            Finished := True;
         when Early_Final_Source =>
            Data := (others => 1);
            Last := Data'Last;
      end case;
   end Read;

   type Context is limited null record;
   package Routing is new Flyology.HTTP.Server.Routing (Context);

   Routes : aliased Routing.Router
     (Capacity => 9, Slashes => Routing.Strict_Slashes);
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
      pragma Assert (X.Request_Authority /= "");
      if X.Request_Header_Count ("x-repeat") > 0 then
         pragma Assert (X.Request_Header_Count = 2);
         pragma Assert (X.Request_Header_Count ("x-repeat") = 2);
         pragma Assert (X.Request_Header_Name (1) = "x-repeat");
         pragma Assert (X.Request_Header ("x-repeat", 2) = "two");
      end if;
      pragma Assert (X.Parameter ("name") = "Ada");
      pragma Assert
        (Flyology.HTTP.Server.Content (X.Request_Value) = "payload");
      if X.Request_Header_Count ("x-repeat") > 0 then
         pragma Assert (X.Request_Trailer_Count = 2);
         pragma Assert
           (X.Request_Trailer_Name (1) = "x-amz-checksum-sha256");
         pragma Assert
           (X.Request_Trailer ("x-amz-trailer-signature") = "signature");
      end if;
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
              Flyology.HTTP.HTTP_2_Protocol |
              Flyology.HTTP.HTTP_3_Protocol);
         pragma Assert (X.Request_Scheme = Flyology.HTTP.Secure_HTTPS);
         X.Text (200, "same routes");
      end if;
   end Discover;

   procedure Early
     (Application : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (Application);
   begin
      X.Text (409, "upload stopped");
   end Early;

   procedure Fixed
     (Application : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (Application);
      Value : constant String := "fixed";
   begin
      X.Begin_Stream (200, "text/plain", Content_Length => Value'Length);
      for Item of Value loop
         X.Write_Chunk (String'(1 => Item));
      end loop;
      X.End_Stream;
   end Fixed;

   procedure Fixed_Zero
     (Application : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (Application);
   begin
      X.Begin_Stream
        (200, "application/octet-stream", Content_Length => 0);
      X.End_Stream;
   end Fixed_Zero;

   procedure Fixed_Head
     (Application : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (Application);
   begin
      X.Begin_Stream
        (200, "application/octet-stream",
         Content_Length => 5 * 1_024 * 1_024 * 1_024 + 9);
      X.End_Stream;
   end Fixed_Head;

   procedure Fixed_Overrun
     (Application : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (Application);
   begin
      X.Begin_Stream (200, "text/plain", Content_Length => 1);
      X.Write_Chunk ("xx");
   end Fixed_Overrun;

   procedure Fixed_Underrun
     (Application : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (Application);
   begin
      X.Begin_Stream (200, "text/plain", Content_Length => 2);
      X.Write_Chunk ("x");
      X.End_Stream;
   end Fixed_Underrun;

   procedure Fixed_Exception
     (Application : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (Application);
   begin
      X.Begin_Stream (200, "text/plain", Content_Length => 2);
      raise Constraint_Error with "fixed source failure";
   end Fixed_Exception;
begin
   Routes.Add_Middleware (Observe'Access);
   Routes.Post
     ("/hello/{name}", Hello'Access, Name => "hello",
      Policy =>
        (Routing.Default_Route_Policy with delta
           Body_Handling => App.Buffer_Body,
           Max_Body      => 6 * 1_024 * 1_024 * 1_024));
   Routes.Get ("/discover", Discover'Access, Name => "discover");
   Routes.Get ("/fixed", Fixed'Access, Name => "fixed");
   Routes.Get ("/fixed-zero", Fixed_Zero'Access, Name => "fixed.zero");
   Routes.Get ("/fixed-head", Fixed_Head'Access, Name => "fixed.head");
   Routes.Get
     ("/fixed-overrun", Fixed_Overrun'Access, Name => "fixed.overrun");
   Routes.Get
     ("/fixed-underrun", Fixed_Underrun'Access, Name => "fixed.underrun");
   Routes.Get
     ("/fixed-exception", Fixed_Exception'Access, Name => "fixed.exception");
   Routes.Post
     ("/early", Early'Access, Name => "early",
      Policy =>
        (Routing.Default_Route_Policy with delta
           Body_Handling => App.Reject_Body,
           Max_Body => 64 * 1_024 * 1_024 * 1_024));

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
               --  The 8,000-exchange loop below isolates bounded stack,
               --  stream-credit, and slot reuse on one connection. Total-age
               --  rotation has separate deterministic pool-policy coverage.
               Max_Connection_Age => -1.0,
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
            Mixed_H3_Multiplex,
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

         procedure Send_Raw_Get
           (Path   : String;
            Stream : out QUIC.Stream_ID)
         is
            Headers : H3.Header_Block;
            Packet  : QUIC.Datagram;
         begin
            H3.Append (Headers, H3.Make_Field (":method", "GET"));
            H3.Append (Headers, H3.Make_Field (":scheme", "https"));
            H3.Append (Headers, H3.Make_Field (":path", Path));
            H3.Append
              (Headers, H3.Make_Field (":authority", "localhost"));
            H3.Open_Request (Session, Transport, Stream, H3_Status);
            pragma Assert (H3_Status = H3.Succeeded);
            H3.Send_Headers
              (Session, Transport, Stream, Headers, Fin => True,
               Now => Raw_Now, Packet => Packet, Status => H3_Status);
            pragma Assert (H3_Status = H3.Succeeded);
            QUIC_IO.Send (Socket, Packet, Timeout => 10.0);
         end Send_Raw_Get;

         procedure Await_Raw_Reset (Stream : QUIC.Stream_ID) is
            Event : H3.Event;
            Seen  : Boolean := False;
         begin
            for Attempt in 1 .. 16 loop
               begin
                  QUIC_IO.Receive
                    (Socket, Transport, Flight, QUIC_Status, Timeout => 1.0);
                  pragma Assert
                    (QUIC_Status in QUIC.Succeeded | QUIC.Waiting_For_More);
                  QUIC_IO.Send (Socket, Flight, Timeout => 10.0);
               exception
                  when Flyology.IO.Timeout_Error => null;
               end;
               loop
                  H3.Poll (Session, Transport, Event, H3_Status);
                  exit when H3_Status = H3.No_Event;
                  pragma Assert (H3_Status = H3.Succeeded);
                  if Event.Stream = Stream and then Event.Kind = H3.Stream_Reset
                  then
                     Seen := True;
                  end if;
               end loop;
               exit when Seen;
            end loop;
            pragma Assert (Seen);
         end Await_Raw_Reset;

         procedure Await_Raw_Fixed (Stream : QUIC.Stream_ID) is
            Event  : H3.Event;
            Ended  : Boolean := False;
            Length : Boolean := False;
            Payload : Unbounded_String;
         begin
            for Attempt in 1 .. 16 loop
               begin
                  QUIC_IO.Receive
                    (Socket, Transport, Flight, QUIC_Status, Timeout => 1.0);
                  pragma Assert
                    (QUIC_Status in QUIC.Succeeded | QUIC.Waiting_For_More);
                  QUIC_IO.Send (Socket, Flight, Timeout => 10.0);
               exception
                  when Flyology.IO.Timeout_Error => null;
               end;
               loop
                  H3.Poll (Session, Transport, Event, H3_Status);
                  exit when H3_Status = H3.No_Event;
                  pragma Assert (H3_Status = H3.Succeeded);
                  if Event.Stream = Stream
                    and then Event.Kind = H3.Headers_Received
                  then
                     for Index in 1 .. H3.Header_Count (Event.Headers) loop
                        declare
                           Field : constant H3.Header_Field :=
                             H3.Field_At (Event.Headers, Index);
                        begin
                           Length := Length or else
                             (H3.Field_Name (Field) = "content-length"
                              and then H3.Field_Value (Field) = "5");
                        end;
                     end loop;
                  elsif Event.Stream = Stream
                    and then Event.Kind = H3.Data_Received
                  then
                     for Index in 1 .. Event.Data_Length loop
                        Append
                          (Payload,
                           Character'Val
                             (Event.Data
                                (Ada.Streams.Stream_Element_Offset (Index))));
                     end loop;
                  elsif Event.Stream = Stream
                    and then Event.Kind = H3.Stream_Ended
                  then
                     Ended := True;
                  end if;
               end loop;
               exit when Ended;
            end loop;
            pragma Assert (Length);
            pragma Assert (To_String (Payload) = "fixed");
            pragma Assert (Ended);
         end Await_Raw_Fixed;
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
               Payload : aliased constant String := "payload";
               Source : Unknown_String_Source (Payload'Access);
            begin
               Client.Set_Method
                 (H3_Value, Flyology.HTTP.To_Method ("POST"));
               Client.Set_Target (H3_Value, "/hello/Ada");
               Client.Add_Header (H3_Value, "x-repeat", "one");
               Client.Add_Header (H3_Value, "x-repeat", "two");
               Client.Add_Trailer
                 (H3_Value, "x-amz-checksum-sha256", "checksum");
               Client.Add_Trailer
                 (H3_Value, "x-amz-trailer-signature", "signature");
               declare
                  Reply : Client.Response :=
                    Client.Execute
                      (HTTP, H3_Value, Source, Timeout => 10.0);
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
               Phase := Mixed_H3_Multiplex;
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
                          Flyology.HTTP.HTTP_3_Protocol);
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
         Pooled_Reply : Client.Response;
         Pooled_Body  : Flyology.Bytes.Unbounded_Bytes;

         procedure Check_Pooled_Exchange is
            Expected : constant String := "hello Ada";
         begin
            Client.Execute
              (HTTP, Request, Pooled_Reply, Timeout => 10.0);
            Client.Read_All (Pooled_Reply, Pooled_Body);
            pragma Assert (Client.Status (Pooled_Reply) = 200);
            pragma Assert
              (Client.Negotiated_Protocol (Pooled_Reply) =
                 Flyology.HTTP.HTTP_3_Protocol);
            pragma Assert
              (Flyology.Bytes.Length (Pooled_Body) = Expected'Length);
            for Index in Expected'Range loop
               pragma Assert
                 (Flyology.Bytes.Element (Pooled_Body, Index) =
                    Ada.Streams.Stream_Element
                      (Character'Pos (Expected (Index))));
            end loop;
         end Check_Pooled_Exchange;
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
         declare
            Fixed_Request : Client.Request;
         begin
            Client.Set_Target (Fixed_Request, "/fixed");
            declare
               Reply : Client.Response :=
                 Client.Execute (HTTP, Fixed_Request, Timeout => 10.0);
            begin
               pragma Assert
                 (Client.Header (Reply, "content-length") = "5");
               pragma Assert
                 (Client.Header (Reply, "transfer-encoding") = "");
               pragma Assert
                 (Flyology.Bytes.To_Byte_String (Client.Read_All (Reply)) =
                    "fixed");
            end;
         end;
         declare
            Zero_Request : Client.Request;
         begin
            Client.Set_Target (Zero_Request, "/fixed-zero");
            declare
               Reply : Client.Response :=
                 Client.Execute (HTTP, Zero_Request, Timeout => 10.0);
            begin
               pragma Assert
                 (Client.Header (Reply, "content-length") = "0");
               pragma Assert
                 (Flyology.Bytes.Length (Client.Read_All (Reply)) = 0);
            end;
         end;
         declare
            Head_Request : Client.Request;
         begin
            Client.Set_Target (Head_Request, "/fixed-head");
            Client.Set_Method
              (Head_Request, Flyology.HTTP.To_Method ("HEAD"));
            declare
               Reply : Client.Response :=
                 Client.Execute (HTTP, Head_Request, Timeout => 10.0);
            begin
               pragma Assert
                 (Client.Header (Reply, "content-length") = "5368709129");
               pragma Assert
                 (Flyology.Bytes.Length (Client.Read_All (Reply)) = 0);
            end;
         end;
         --  Validate 64-bit Content-Length framing and premature-EOF cleanup
         --  without retaining or transmitting a multi-gigabyte payload.
         declare
            Sparse_Request : Client.Request;
            Source         : Sparse_Five_GiB_Source;
            Raised         : Boolean := False;
         begin
            Client.Set_Method
              (Sparse_Request, Flyology.HTTP.To_Method ("POST"));
            Client.Set_Target (Sparse_Request, "/hello/Ada");
            begin
               declare
                  Unexpected : Client.Response :=
                    Client.Execute
                      (HTTP, Sparse_Request, Source, Timeout => 10.0);
                  pragma Unreferenced (Unexpected);
               begin
                  null;
               end;
            exception
               when Client.Request_Body_Error => Raised := True;
            end;
            pragma Assert (Raised);
         end;
         --  Cover the borrowed-source contract on a live H3 stream after
         --  allocation. A successful retained exchange after each failure
         --  proves either safe reuse or safe replacement of the lease.
         for Kind in Zero_Progress .. Expired_Source loop
            declare
               Fault_Request : Client.Request;
               Source        : Adversarial_Source (Kind);
               Cancel        : aliased Flyology.Cancellation.Token;
               Raised        : Boolean := False;
            begin
               Client.Set_Method
                 (Fault_Request, Flyology.HTTP.To_Method ("POST"));
               Client.Set_Target (Fault_Request, "/hello/Ada");
               begin
                  declare
                     Unexpected : Client.Response := Client.Execute
                       (HTTP, Fault_Request, Source,
                        Timeout =>
                          (if Kind = Expired_Source then 0.005 else 10.0),
                        Token =>
                          (if Kind = Cancelled_Source
                           then Cancel'Access else null));
                     pragma Unreferenced (Unexpected);
                  begin
                     null;
                  end;
               exception
                  when Client.Request_Body_Error =>
                     Raised := Kind in Zero_Progress | Overrun;
                  when Source_Failure =>
                     Raised := Kind = Source_Exception;
                  when Flyology.Cancellation.Operation_Cancelled =>
                     Raised := Kind = Cancelled_Source;
                  when Flyology.IO.Timeout_Error =>
                     Raised := Kind = Expired_Source;
               end;
               pragma Assert (Raised);
               declare
                  Reply : Client.Response :=
                    Client.Execute (HTTP, Request, Timeout => 10.0);
               begin
                  pragma Assert (Client.Status (Reply) = 200);
                  pragma Assert
                    (Flyology.Bytes.To_Byte_String (Client.Read_All (Reply)) =
                       "hello Ada");
               end;
            end;
         end loop;

         --  A final response can arrive while an effectively unbounded source
         --  is flow-control blocked. Stop pulling promptly; the incomplete H3
         --  upload closes only that transport before the next pooled exchange.
         declare
            Early_Request : Client.Request;
            Source        : Adversarial_Source (Early_Final_Source);
         begin
            Client.Set_Method
              (Early_Request, Flyology.HTTP.To_Method ("POST"));
            Client.Set_Target (Early_Request, "/early");
            declare
               Reply : Client.Response := Client.Execute
                 (HTTP, Early_Request, Source, Timeout => 10.0);
            begin
               pragma Assert (Client.Status (Reply) = 413);
               pragma Assert (Source.Reads > 0 and then Source.Reads < 1_024);
               declare
                  Rejection : constant Flyology.Bytes.Unbounded_Bytes :=
                    Client.Read_All (Reply);
                  pragma Unreferenced (Rejection);
               begin
                  null;
               end;
            end;
         end;
         declare
            Reply : Client.Response :=
              Client.Execute (HTTP, Request, Timeout => 10.0);
         begin
            pragma Assert (Client.Status (Reply) = 200);
            pragma Assert
              (Flyology.Bytes.To_Byte_String (Client.Read_All (Reply)) =
                 "hello Ada");
         end;
         --  Cross the concurrent and former lifetime stream tables, then the
         --  initial 512 KiB connection receive window, on one pooled
         --  connection. This exercises MAX_DATA and MAX_STREAMS credit return
         --  together through the user-facing client and server APIs.
         for Exchange in 1 .. 8_000 loop
            Phase := Pooled_Exchange;
            Exchange_Number := Exchange;
            Check_Pooled_Exchange;
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
      for Failure in 1 .. 3 loop
         declare
            Failed_Stream : QUIC.Stream_ID;
            Reuse_Stream  : QUIC.Stream_ID;
         begin
            Send_Raw_Get
              ((if Failure = 1 then "/fixed-overrun"
                elsif Failure = 2 then "/fixed-underrun"
                else "/fixed-exception"),
               Failed_Stream);
            Await_Raw_Reset (Failed_Stream);
            Send_Raw_Get ("/fixed", Reuse_Stream);
            Await_Raw_Fixed (Reuse_Stream);
         end;
      end loop;
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
         --  Keep less than the runtime's 2 MiB default so a transaction-sized
         --  QUIC stream-table copy cannot silently return to the owner stack.
         --  The raw-protocol oracle itself retains about 1.3 MiB in its
         --  deepest path, so this bound still leaves measured test overhead.
         task type Client_Task (Use_IPv6 : Boolean);
         for Client_Task'Storage_Size use 7 * 256 * 1_024;
         First_Client  : Client_Task (False);
         Second_Client : Client_Task (True);

         task body Client_Task is
         begin
            Run_Client
              ((if Use_IPv6 then IPv6_Address else Address));
         exception
            when Error : others =>
               Outcome.Fail (Ada.Exceptions.Exception_Information (Error));
         end Client_Task;
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
