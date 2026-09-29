--  H3-QPACK-8.  The client's receive credit is connection-wide but its
--  admission test is stream-local.  Build_HTTP_3_Receive_Credit
--  (client.adb:2532-2551) calls QUIC.Build_Receive_Credit_Datagram, whose
--  body raises EVERY tracked stream's limit to that stream's own
--  Consumed_Offset + Window (application_space.adb:849-866, :879-895), while
--  HTTP_3_Receive_Credit_Due (client.adb:2517-2530) decides when to do so
--  from the pumping owner's own consumed length.  A stream's QUIC-level
--  Consumed_Offset advances whenever Poll decodes its DATA into this
--  package's 65,535-byte ring (http_3_connection.adb:418-421,
--  http_3_client_connection.adb:411-423), whether or not that stream's owner
--  has read a byte.  The ring overflow at :414-416 is a hard
--  Stream.Phase := Failed, not backpressure.
--
--  The peer here is a raw in-process HTTP/3 server session that interleaves
--  two responses, because this repository's own server dispatches one
--  request at a time per connection and so never produces the interleaving
--  the finding needs.  The client side is the real
--  HTTP_3_Client_Connection.Session driven exactly as client.adb drives it:
--  publish every event, read only stream A, grant credit on A's progress.
--
--  This program asserts the CORRECT behaviour: stream B, whose owner has not
--  read, is flow-controlled rather than failed.
with Ada.Streams;
with Flyology.HTTP.Headers;
with Flyology.HTTP.HTTP_3;
with Flyology.QUIC.Connections;
with Flyology.QUIC.Test_Connections;
with Repro_Support;

procedure Flyology.HTTP.HTTP_3_Client_Connection.Repro_H3_QPACK_8
  with SPARK_Mode => Off
is
   package H3 renames Flyology.HTTP.HTTP_3;
   package QUIC renames Flyology.QUIC.Connections;
   package Fixtures renames Flyology.QUIC.Test_Connections;

   use type Ada.Streams.Stream_Element_Offset;
   use type H3.Event_Kind;
   use type H3.Operation_Status;
   use type QUIC.Stream_Offset;
   use type QUIC.Stream_ID;
   use type QUIC.Send_Status;

   Chunk : constant := 1_024;

   Client_Transport, Server_Transport : QUIC.Connection;
   Client_H3, Server_H3 : H3.Session;
   Client  : Session;
   Packet  : QUIC.Datagram;
   Credit  : QUIC.Datagram;
   Sent    : QUIC.Send_Status;
   Status  : H3.Operation_Status;
   Event   : H3.Event;

   Stream_A, Stream_B : QUIC.Stream_ID;
   Handle_A, Handle_B : Stream_Handle;
   Accepted  : Boolean;
   Published : Boolean;

   Read_A : Natural := 0;
   Sent_A : Natural := 0;
   Sent_B : Natural := 0;
   Last_Stream_Credit : QUIC.Stream_Offset := 0;
   Stalled : Natural := 0;
   Stamp : QUIC.Timestamp := 1_000;

   Payload : constant Ada.Streams.Stream_Element_Array (1 .. Chunk) :=
     (others => Character'Pos ('a'));

   function Tick return QUIC.Timestamp is
   begin
      Stamp := Stamp + 1_000;
      return Stamp;
   end Tick;

   --  Drain every complete event the client can decode, publishing each one
   --  into the real client session, and read only stream A.
   procedure Drain_Client is
   begin
      loop
         H3.Poll (Client_H3, Client_Transport, Event, Status);
         exit when Status /= H3.Succeeded;
         Publish (Client, Event, Published);
      end loop;
      declare
         Buffer   : Ada.Streams.Stream_Element_Array (1 .. 4_096);
         Last     : Ada.Streams.Stream_Element_Offset;
         Finished : Boolean;
         Outcome  : Body_Result;
         Trailers : Flyology.HTTP.Headers.List;
      begin
         loop
            Read
              (Client, Handle_A, Buffer, Last, Finished, Outcome, Trailers);
            exit when Outcome /= Body_Progress;
            Read_A := Read_A + Natural (Last - Buffer'First + 1);
         end loop;
      end;
   end Drain_Client;

   --  Acknowledge what the client received, so the peer's congestion
   --  window is not what limits the experiment.
   procedure Acknowledge is
      ACK : QUIC.Datagram;
   begin
      QUIC.Build_ACK_Datagram
        (Client_Transport, ACK_Delay => 0, Now => Tick,
         Packet => ACK, Status => Sent);
      if Sent = QUIC.Sent then
         Fixtures.Deliver (ACK, Server_Transport);
      end if;
   end Acknowledge;

   --  The client's own credit rule, applied to stream A's progress.
   procedure Grant_Credit_If_Due is
      Consumed : constant QUIC.Stream_Offset := QUIC.Stream_Offset (Read_A);
   begin
      if Consumed >= Last_Stream_Credit
        and then Consumed - Last_Stream_Credit >= 8_192
      then
         QUIC.Build_Receive_Credit_Datagram
           (Client_Transport,
            Connection_Window => 524_288,
            Direction => QUIC.Bidirectional,
            Maximum_Streams => 29,
            Now => Tick, Packet => Credit, Status => Sent);
         if Sent = QUIC.Sent then
            Fixtures.Deliver (Credit, Server_Transport);
            Last_Stream_Credit := Consumed;
         end if;
      end if;
   end Grant_Credit_If_Due;

   function Peek_B return Body_Result is
      Buffer   : Ada.Streams.Stream_Element_Array (1 .. 0);
      Last     : Ada.Streams.Stream_Element_Offset;
      Finished : Boolean;
      Outcome  : Body_Result;
      Trailers : Flyology.HTTP.Headers.List;
   begin
      Read (Client, Handle_B, Buffer, Last, Finished, Outcome, Trailers);
      return Outcome;
   end Peek_B;

   procedure Open_Exchange
     (Stream : out QUIC.Stream_ID; Handle : out Stream_Handle)
   is
      Block : H3.Header_Block;
   begin
      H3.Open_Request (Client_H3, Client_Transport, Stream, Status);
      Open (Client, Stream, Handle, Accepted);
      H3.Append (Block, H3.Make_Field (":method", "GET"));
      H3.Append (Block, H3.Make_Field (":scheme", "https"));
      H3.Append (Block, H3.Make_Field (":path", "/big"));
      H3.Append (Block, H3.Make_Field (":authority", "localhost"));
      H3.Send_Headers
        (Client_H3, Client_Transport, Stream, Block, Fin => True,
         Now => Tick, Packet => Packet, Status => Status);
      if Status = H3.Succeeded then
         Fixtures.Deliver (Packet, Server_Transport);
      end if;
   end Open_Exchange;

   procedure Answer_Head (Stream : QUIC.Stream_ID) is
      Block : H3.Header_Block;
   begin
      H3.Append (Block, H3.Make_Field (":status", "200"));
      H3.Append (Block, H3.Make_Field ("content-type", "text/plain"));
      H3.Send_Headers
        (Server_H3, Server_Transport, Stream, Block, Fin => False,
         Now => Tick, Packet => Packet, Status => Status);
      if Status = H3.Succeeded then
         Fixtures.Deliver (Packet, Client_Transport);
      end if;
   end Answer_Head;

   --  Send one DATA frame on Stream, reporting whether the transport took it.
   procedure Push (Stream : QUIC.Stream_ID; Moved : out Boolean) is
   begin
      H3.Send_Data
        (Server_H3, Server_Transport, Stream, Payload, Fin => False,
         Now => Tick, Packet => Packet, Status => Status);
      Moved := Status = H3.Succeeded;
      if Moved then
         Fixtures.Deliver (Packet, Client_Transport);
      end if;
   end Push;
begin
   Fixtures.Connect (Client_Transport, Server_Transport);
   H3.Initialize (Client_H3, H3.Client);
   H3.Initialize (Server_H3, H3.Server);
   H3.Start (Client_H3, Client_Transport, Tick, Packet, Status);
   Fixtures.Deliver (Packet, Server_Transport);
   H3.Start (Server_H3, Server_Transport, Tick, Packet, Status);
   Fixtures.Deliver (Packet, Client_Transport);
   H3.Poll (Server_H3, Server_Transport, Event, Status);
   H3.Poll (Client_H3, Client_Transport, Event, Status);
   Repro_Support.Check
     (H3.Has_Peer_Settings (Client_H3) and then H3.Has_Peer_Settings
        (Server_H3),
      "both HTTP/3 sessions exchange SETTINGS");

   Open_Exchange (Stream_A, Handle_A);
   Open_Exchange (Stream_B, Handle_B);
   Repro_Support.Check
     (Stream_A /= Stream_B, "two request streams are open");

   --  Consume both requests on the server side.
   loop
      H3.Poll (Server_H3, Server_Transport, Event, Status);
      exit when Status /= H3.Succeeded;
   end loop;

   Answer_Head (Stream_A);
   Answer_Head (Stream_B);
   Drain_Client;

   declare
      Fields   : Flyology.HTTP.Headers.List;
      Outcome  : Head_Result;
      Code     : Status_Code;
      Finished : Boolean;
   begin
      Poll_Head (Client, Handle_A, Outcome, Code, Fields, Finished);
      Repro_Support.Check
        (Outcome = Head_Ready, "stream A's response head is ready");
   end;
   declare
      Fields   : Flyology.HTTP.Headers.List;
      Outcome  : Head_Result;
      Code     : Status_Code;
      Finished : Boolean;
   begin
      Poll_Head (Client, Handle_B, Outcome, Code, Fields, Finished);
      Repro_Support.Check
        (Outcome = Head_Ready, "stream B's response head is ready");
   end;

   --  Interleave the two response bodies.  Stream B's owner never reads.
   for Round in 1 .. 2_000 loop
      declare
         Moved_A, Moved_B : Boolean;
      begin
         Push (Stream_A, Moved_A);
         if Moved_A then
            Sent_A := Sent_A + Chunk;
         end if;
         Push (Stream_B, Moved_B);
         if Moved_B then
            Sent_B := Sent_B + Chunk;
         end if;
         Drain_Client;
         Acknowledge;
         Grant_Credit_If_Due;
         exit when Peek_B = Body_Stream_Failed;
         if not Moved_A and then not Moved_B then
            Stalled := Stalled + 1;
            exit when Stalled > 50;
         else
            Stalled := 0;
         end if;
      end;
   end loop;

   Repro_Support.Note
     ("stream A: sent" & Natural'Image (Sent_A) & " bytes, owner read" &
        Natural'Image (Read_A) & "; consecutive stalled rounds at exit" &
        Natural'Image (Stalled));
   Repro_Support.Note
     ("stream B: sent" & Natural'Image (Sent_B) &
        " bytes, owner read none; body result " &
        Body_Result'Image (Peek_B));
   Repro_Support.Note
     ("Response_Buffer_Capacity =" &
        Integer'Image (Response_Buffer_Capacity));
   Repro_Support.Check
     (Peek_B /= Body_Stream_Failed,
      "the sibling stream whose owner had not read is flow-controlled, " &
        "not failed");

   Repro_Support.Finish;
end Flyology.HTTP.HTTP_3_Client_Connection.Repro_H3_QPACK_8;
