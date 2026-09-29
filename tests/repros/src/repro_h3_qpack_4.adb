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

--  H3-QPACK-4: the server leaks one HTTP/3 send slot per cancelled response.
--  Build_Request_Cancellation marks Item.Sending (Slot).Cancelled but clears
--  the slot only for the client role (http_3_connection.adb:669-676), and
--  Release_Message decrements Send_Count only when Local_Role = Client
--  (:133-145).  Send_Count therefore grows by one per cancellation until
--  Add_Send returns Stream_Capacity_Exceeded at Max_Streams = 32.
--
--  A handler that leaves a streaming response open reaches this through
--  server-http_3.adb:1585-1590 -> X.Mark_Failed -> H3.Cancel_Request.
--
--  This program asserts the CORRECT behaviour: a connection survives more
--  cancelled responses than its send-slot table has entries.
procedure Repro_H3_QPACK_4 is
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

   Attempts : constant := 40;

   type Context is limited null record;

   --  Begin a streaming response and return without ending it.  The driver
   --  classifies this as Streaming_Response and calls Mark_Failed, which is
   --  the ordinary cancellation path.
   procedure Handle (Application : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (Application);
   begin
      X.Begin_Stream (200, "text/plain");
      X.Write_Chunk ("partial");
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
            Max_Connection_Age => 50.0,
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
      Answered  : Natural := 0;
      Stopped_At : Natural := 0;

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

         for Attempt in 1 .. Attempts loop
            declare
               Stream : QUIC.Stream_ID;
               Block  : H3.Header_Block;
               Done   : Boolean := False;
            begin
               H3.Open_Request (Session, Transport, Stream, H3_Status);
               if H3_Status /= H3.Succeeded then
                  Repro_Support.Note
                    ("attempt" & Natural'Image (Attempt) &
                       " Open_Request: " &
                       H3.Operation_Status'Image (H3_Status));
                  Stopped_At := Attempt;
                  exit;
               end if;
               H3.Append (Block, H3.Make_Field (":method", "GET"));
               H3.Append (Block, H3.Make_Field (":scheme", "https"));
               H3.Append (Block, H3.Make_Field (":path", "/stream"));
               H3.Append (Block, H3.Make_Field (":authority", "localhost"));
               H3.Send_Headers
                 (Session, Transport, Stream, Block, Fin => True,
                  Now => Now, Packet => Packet, Status => H3_Status);
               if H3_Status /= H3.Succeeded then
                  Repro_Support.Note
                    ("attempt" & Natural'Image (Attempt) &
                       " Send_Headers: " &
                       H3.Operation_Status'Image (H3_Status));
                  Stopped_At := Attempt;
                  exit;
               end if;
               QUIC_IO.Send (Socket, Packet, 2.0);

               Deadline :=
                 Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (3.0);
               while not Done and then Ada.Real_Time.Clock < Deadline loop
                  H3.Poll (Session, Transport, Event, H3_Status);
                  if H3_Status = H3.Succeeded then
                     if Event.Stream = Stream
                       and then Event.Kind = H3.Headers_Received
                     then
                        Answered := Answered + 1;
                        Done := True;
                     end if;
                  elsif H3_Status = H3.No_Event then
                     if QUIC.State (Transport) /= QUIC.Connected then
                        exit;
                     end if;
                     Pump (0.25);
                  else
                     Repro_Support.Note
                       ("attempt" & Natural'Image (Attempt) & " poll: " &
                          H3.Operation_Status'Image (H3_Status));
                     exit;
                  end if;
               end loop;
               if not Done then
                  Stopped_At := Attempt;
                  exit;
               end if;
            end;
         end loop;

         Repro_Support.Note
           ("responses received:" & Natural'Image (Answered) &
              " of" & Natural'Image (Attempts) &
              (if Stopped_At = 0 then ""
               else "; first unanswered attempt" &
                 Natural'Image (Stopped_At)) &
              "; transport state " &
              QUIC.Connection_State'Image (QUIC.State (Transport)));
         Repro_Support.Check
           (Answered = Attempts,
            "every one of" & Natural'Image (Attempts) &
              " cancelled responses still reaches the client");
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
end Repro_H3_QPACK_4;
