with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.HTTP_3;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.HTTP_3;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.QUIC.Connections;
with Flyology.QUIC.Connections.IO;
with Flyology.QUIC.Test_Connections;
with Repro_Support;

--  H3-QPACK-6: Serve_Connection's event loop handles only
--  Flyology.IO.Timeout_Error (server-http_3.adb:1916-1918); every other
--  exception reaches "when others => Cleanup; raise" at :1923-1926 and is
--  swallowed by the listener worker, so the QUIC connection is freed with no
--  CONNECTION_CLOSE and the peer learns nothing.
--
--  The trigger used here is the one the discovery entry names first.  The
--  driver keeps Maximum_Request_Streams = 8 request slots
--  (server-http_3.adb:44) while the QUIC transport advertises
--  Max_Streams_Bidi = 29 (flyology-quic-connections.ads:106), so a peer that
--  opens nine request streams whose bodies are still in flight makes the
--  ninth Headers_Received raise Resource_Exhausted at :1699-1702.
--
--  This program asserts the CORRECT behaviour: the peer is told something.
--  Either the ninth request is refused on its own stream (RFC 9114 section
--  4.1.2 lets a server respond before resetting a stream) or the connection
--  is closed explicitly (RFC 9000 section 10.2: "An endpoint uses a
--  CONNECTION_CLOSE frame (Section 19.19) to signal that a connection is
--  being closed").  Silence is neither.
procedure Repro_H3_QPACK_6 is
   package App renames Flyology.HTTP.Server.Applications;
   package H3 renames Flyology.HTTP.HTTP_3;
   package QUIC renames Flyology.QUIC.Connections;
   package QUIC_IO renames Flyology.QUIC.Connections.IO;
   package Sockets renames Flyology.IO.Sockets;
   package Fixtures renames Flyology.QUIC.Test_Connections;

   use type Ada.Real_Time.Time;
   use type H3.Event_Kind;
   use type H3.Operation_Status;
   use type QUIC.Connection_State;
   use type QUIC.Operation_Status;
   use type QUIC.Stream_ID;

   Open_Streams : constant := 9;

   type Context is limited null record;

   procedure Handle (Application : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (Application);
   begin
      X.Text (200, "ok");
   end Handle;

   package Engine is new Flyology.HTTP.Server.HTTP_3 (Context, Handle);

   Stop : aliased Flyology.Cancellation.Token;

   State    : aliased Context;
   Listener : aliased Sockets.Socket_Type;
   Address  : Sockets.Endpoint;

   Epoch : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;

   function Now return QUIC.Timestamp is
      Elapsed : constant Duration :=
        Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Epoch);
   begin
      return QUIC.Timestamp (Long_Long_Integer (Elapsed * 1_000_000.0));
   end Now;
begin
   Sockets.Create_Socket (Listener, Sockets.IPv4, Sockets.Socket_Datagram);
   Sockets.Bind_Socket
     (Listener,
      Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
   Address := Sockets.Get_Socket_Name (Listener);

   declare
      task type Server_Task_Type;
      for Server_Task_Type'Storage_Size use 16 * 1_024 * 1_024;
      Server_Task : Server_Task_Type;

      task body Server_Task_Type is
      begin
         Engine.Serve_Listener
           (State, Listener,
            Fixtures.Server_Certificate, Fixtures.Server_Private_Key,
            Capacity => 1,
            Timeout => 15.0,
            Handshake_Timeout => 10.0,
            Max_Connection_Age => 30.0,
            Token => Stop'Access,
            Handshake_Idle_Timeout => 10.0);
      exception
         when Error : others =>
            Repro_Support.Note
              ("listener failed: " &
                 Ada.Exceptions.Exception_Information (Error));
            Stop.Request;
      end Server_Task_Type;

      Socket    : Sockets.Socket_Type;
      Transport : QUIC.Connection;
      Session   : H3.Session;
      Initial   : QUIC.Datagram_Batch;
      Flight    : QUIC.Datagram_Batch;
      Packet    : QUIC.Datagram;
      Status    : QUIC.Operation_Status;
      H3_Status : H3.Operation_Status;
      Event     : H3.Event;
      Deadline  : Ada.Real_Time.Time;
      Streams   : array (1 .. Open_Streams) of QUIC.Stream_ID :=
        (others => 0);
      Opened    : Natural := 0;
      Heard     : Boolean := False;

      procedure Pump (Budget : Duration) is
      begin
         QUIC_IO.Receive (Socket, Transport, Flight, Status, Now, Budget);
         QUIC_IO.Send (Socket, Flight, 2.0);
      exception
         when Flyology.IO.Timeout_Error =>
            null;
      end Pump;
   begin
      Sockets.Create_Socket (Socket, Address.Family, Sockets.Socket_Datagram);
      Sockets.Connect_Socket (Socket, Address);
      Fixtures.Initialize_Client (Transport);
      QUIC.Start_Client (Transport, Initial, Status);
      QUIC_IO.Send (Socket, Initial, 2.0);

      Deadline := Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (10.0);
      while not QUIC.Is_Connected (Transport)
        and then Ada.Real_Time.Clock < Deadline
      loop
         begin
            QUIC_IO.Receive (Socket, Transport, Flight, Status, Now, 0.25);
            exit when Status not in QUIC.Succeeded | QUIC.Waiting_For_More;
            QUIC_IO.Send (Socket, Flight, 2.0);
         exception
            when Flyology.IO.Timeout_Error =>
               QUIC_IO.Send (Socket, Initial, 2.0);
         end;
      end loop;
      Repro_Support.Check
        (QUIC.Is_Connected (Transport), "QUIC handshake completes");

      if QUIC.Is_Connected (Transport) then
         H3.Initialize (Session, H3.Client);
         H3.Start (Session, Transport, Now, Packet, H3_Status);
         QUIC_IO.Send (Socket, Packet, 2.0);
         Deadline := Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (5.0);
         while not H3.Has_Peer_Settings (Session)
           and then Ada.Real_Time.Clock < Deadline
         loop
            H3.Poll (Session, Transport, Event, H3_Status);
            if H3_Status = H3.No_Event then
               Pump (0.25);
            end if;
         end loop;
         Repro_Support.Check
           (H3.Has_Peer_Settings (Session), "server SETTINGS arrive");

         --  Nine POST streams whose bodies never arrive.  Fin is False, so
         --  no request ever reaches Stream_Ended and every slot stays
         --  occupied.  The transport permits 29 such streams.
         for Index in 1 .. Open_Streams loop
            declare
               Block : H3.Header_Block;
            begin
               H3.Open_Request
                 (Session, Transport, Streams (Index), H3_Status);
               exit when H3_Status /= H3.Succeeded;
               H3.Append (Block, H3.Make_Field (":method", "POST"));
               H3.Append (Block, H3.Make_Field (":scheme", "https"));
               H3.Append (Block, H3.Make_Field (":path", "/slow"));
               H3.Append (Block, H3.Make_Field (":authority", "localhost"));
               H3.Append (Block, H3.Make_Field ("content-length", "4"));
               H3.Send_Headers
                 (Session, Transport, Streams (Index), Block, Fin => False,
                  Now => Now, Packet => Packet, Status => H3_Status);
               exit when H3_Status /= H3.Succeeded;
               QUIC_IO.Send (Socket, Packet, 2.0);
               Opened := Index;
               Pump (0.1);
            end;
         end loop;
         Repro_Support.Check
           (Opened = Open_Streams,
            "the transport admits nine concurrent request streams");
         Repro_Support.Note
           ("opened" & Natural'Image (Opened) & " request streams");

         --  Wait for any word from the server about the ninth.
         Deadline := Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (6.0);
         while not Heard and then Ada.Real_Time.Clock < Deadline loop
            H3.Poll (Session, Transport, Event, H3_Status);
            if H3_Status = H3.Succeeded then
               Repro_Support.Note
                 ("event " & H3.Event_Kind'Image (Event.Kind) &
                    " on stream" & QUIC.Stream_ID'Image (Event.Stream));
               Heard := Event.Stream = Streams (Open_Streams);
            elsif H3_Status = H3.No_Event then
               exit when QUIC.State (Transport) /= QUIC.Connected;
               Pump (0.25);
            else
               Repro_Support.Note
                 ("poll: " & H3.Operation_Status'Image (H3_Status));
               exit when QUIC.State (Transport) /= QUIC.Connected;
               Pump (0.25);
            end if;
         end loop;

         Repro_Support.Note
           ("ninth stream answered: " & Boolean'Image (Heard) &
              "; transport state " &
              QUIC.Connection_State'Image (QUIC.State (Transport)));
         Repro_Support.Check
           (Heard or else QUIC.State (Transport) = QUIC.Peer_Closed,
            "the server either answers the ninth request or closes the " &
              "connection explicitly instead of abandoning it silently");
      end if;

      Sockets.Close_Socket (Socket);
      Stop.Request;
   exception
      when others =>
         Stop.Request;
         raise;
   end;

   Sockets.Close_Socket (Listener);
   Repro_Support.Finish;
end Repro_H3_QPACK_6;
