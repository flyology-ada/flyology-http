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

--  H3-QPACK-1: the HTTP/3 server returns no per-stream receive credit while a
--  request body is arriving.  Return_Request_Credit is called only from the
--  Stream_Ended branch of Process_Event, so a request whose body exceeds the
--  initial max_stream_data_bidi_remote (16,384) can never finish arriving.
--
--  This program asserts the CORRECT behaviour: a client that uploads 20,000
--  bytes in 1,024-byte DATA frames to a routed HTTP/3 server can send the
--  whole body and receive the response.
procedure Repro_H3_QPACK_1 is
   package App renames Flyology.HTTP.Server.Applications;
   package H3 renames Flyology.HTTP.HTTP_3;
   package QUIC renames Flyology.QUIC.Connections;
   package QUIC_IO renames Flyology.QUIC.Connections.IO;
   package Sockets renames Flyology.IO.Sockets;
   package Fixtures renames Flyology.QUIC.Test_Connections;

   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type H3.Event_Kind;
   use type H3.Operation_Status;
   use type QUIC.Operation_Status;

   Body_Length : constant := 20_000;
   Chunk       : constant := 1_024;
   Upload_Budget : constant Duration := 12.0;

   type Context is limited null record;

   procedure Handle (Application : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (Application);
   begin
      X.Text (200, "received" & Natural'Image (X.Content'Length));
   end Handle;

   package Engine is new Flyology.HTTP.Server.HTTP_3 (Context, Handle);

   --  The connection state retains this token, so it must live no deeper
   --  than the instance that allocates that state.
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

   Payload : constant Ada.Streams.Stream_Element_Array
     (1 .. Body_Length) := (others => Character'Pos ('a'));
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
            Timeout => 20.0,
            Handshake_Timeout => 10.0,
            Max_Connection_Age => 25.0,
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
      Stream    : QUIC.Stream_ID;
      Headers   : H3.Header_Block;
      Deadline  : Ada.Real_Time.Time;
      Sent      : Ada.Streams.Stream_Element_Offset := 0;
      Blocked   : Natural := 0;
      Saw_Status : Boolean := False;
      Reported  : Boolean := False;

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
      Repro_Support.Check
        (Status = QUIC.Succeeded, "client Initial is built");
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
         Repro_Support.Check
           (H3_Status = H3.Succeeded, "client control stream starts");
         QUIC_IO.Send (Socket, Packet, 2.0);

         --  Absorb the server's SETTINGS before sending a request.
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

         H3.Open_Request (Session, Transport, Stream, H3_Status);
         Repro_Support.Check
           (H3_Status = H3.Succeeded, "request stream opens");

         H3.Append (Headers, H3.Make_Field (":method", "POST"));
         H3.Append (Headers, H3.Make_Field (":scheme", "https"));
         H3.Append (Headers, H3.Make_Field (":path", "/upload"));
         H3.Append (Headers, H3.Make_Field (":authority", "localhost"));
         H3.Append
           (Headers, H3.Make_Field ("content-length", "20000"));
         H3.Send_Headers
           (Session, Transport, Stream, Headers, Fin => False,
            Now => Now, Packet => Packet, Status => H3_Status);
         Repro_Support.Check
           (H3_Status = H3.Succeeded, "request HEADERS are sent");
         if H3_Status = H3.Succeeded then
            QUIC_IO.Send (Socket, Packet, 2.0);
         end if;

         --  Upload the body.  A conformant sender stops at the peer's
         --  advertised max_stream_data and waits for MAX_STREAM_DATA.
         Deadline :=
           Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Upload_Budget);
         while Sent < Body_Length
           and then Ada.Real_Time.Clock < Deadline
         loop
            declare
               Last : constant Ada.Streams.Stream_Element_Offset :=
                 Ada.Streams.Stream_Element_Offset'Min
                   (Sent + Chunk, Body_Length);
            begin
               H3.Send_Data
                 (Session, Transport, Stream,
                  Payload (Sent + 1 .. Last),
                  Fin => Last = Body_Length,
                  Now => Now, Packet => Packet, Status => H3_Status);
               if H3_Status = H3.Succeeded then
                  QUIC_IO.Send (Socket, Packet, 2.0);
                  Sent := Last;
               elsif H3_Status = H3.Transport_Blocked then
                  if Blocked = 0 then
                     Repro_Support.Note
                       ("first Transport_Blocked after" &
                          Ada.Streams.Stream_Element_Offset'Image (Sent) &
                          " body bytes");
                  end if;
                  Blocked := Blocked + 1;
                  Pump (0.25);
               else
                  if not Reported then
                     Repro_Support.Note
                       ("unexpected Send_Data status " &
                          H3.Operation_Status'Image (H3_Status));
                     Reported := True;
                  end if;
                  exit;
               end if;
            end;
         end loop;

         Repro_Support.Note
           ("body bytes accepted by the transport:" &
              Ada.Streams.Stream_Element_Offset'Image (Sent) &
              "; Transport_Blocked retries:" & Natural'Image (Blocked));
         Repro_Support.Check
           (Sent = Body_Length,
            "the whole 20,000-byte request body reaches the server within" &
              Duration'Image (Upload_Budget) & " s");

         --  Whether or not the body completed, give the server a window to
         --  answer.  A server that granted credit answers 200.
         Deadline := Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (6.0);
         while not Saw_Status and then Ada.Real_Time.Clock < Deadline loop
            H3.Poll (Session, Transport, Event, H3_Status);
            if H3_Status = H3.Succeeded
              and then Event.Kind = H3.Headers_Received
            then
               for Index in 1 .. H3.Header_Count (Event.Headers) loop
                  declare
                     Field : constant H3.Header_Field :=
                       H3.Field_At (Event.Headers, Index);
                  begin
                     if H3.Field_Name (Field) = ":status" then
                        Repro_Support.Note
                          ("response :status = " & H3.Field_Value (Field));
                        Saw_Status := H3.Field_Value (Field) = "200";
                     end if;
                  end;
               end loop;
            elsif H3_Status = H3.No_Event then
               Pump (0.25);
            elsif H3_Status /= H3.Succeeded then
               Repro_Support.Note
                 ("poll status " & H3.Operation_Status'Image (H3_Status));
               exit;
            end if;
         end loop;
         Repro_Support.Check
           (Saw_Status, "the server answers 200 for the buffered upload");
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
end Repro_H3_QPACK_1;
