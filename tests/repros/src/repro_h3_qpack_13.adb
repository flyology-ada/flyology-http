with Ada.Streams;
with Flyology.HTTP;
with Flyology.HTTP.HTTP_3;
with Flyology.QUIC.Connections;
with Flyology.QUIC.Test_Connections;
with Repro_Support;

--  H3-QPACK-13: a malformed response on a request stream whose identifier is
--  above 4092 is re-reported for as long as the peer leaves the stream open.
--
--  On Header_Error the client role sets Finished, emits a Stream_Reset event
--  and returns without consuming the offending bytes
--  (http_3_connection.adb:426-440; Consumed is set only on the Consumed
--  status).  The client then cancels, and Abandon_Message records a
--  tombstone only when ID / 4 <= Message_Ordinal'Last = 1023
--  (:148-160, .ads:18), and calls QUIC.Release_Stream only when the stream is
--  complete or was reset by the peer (:172-179).  For a higher identifier on
--  a stream the peer keeps open, the next Poll finds Is_Released_Message
--  false (:105-113), Find_Or_Open opens a fresh slot for the same ID
--  (:355, :179-223), the same bytes are parsed again and the same event is
--  emitted again.
--
--  This program asserts the CORRECT behaviour: one malformed response
--  produces one stream failure, whatever the stream identifier.
procedure Repro_H3_QPACK_13 is
   package H3 renames Flyology.HTTP.HTTP_3;
   package QUIC renames Flyology.QUIC.Connections;
   package Fixtures renames Flyology.QUIC.Test_Connections;

   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Array;
   use type Ada.Streams.Stream_Element_Offset;
   use type H3.Event_Kind;
   use type H3.Operation_Status;
   use type QUIC.Connection_State;
   use type QUIC.Send_Status;
   use type QUIC.Stream_ID;

   --  Message_Ordinal'Last is 1023, so the 1,025th request stream (ID 4096)
   --  is the first one with no tombstone slot.
   Warmup : constant := 1_024;

   Client_Transport, Server_Transport : QUIC.Connection;
   Client_H3, Server_H3 : H3.Session;
   Packet : QUIC.Datagram;
   Sent   : QUIC.Send_Status;
   Status : H3.Operation_Status;
   Event  : H3.Event;
   Stamp  : QUIC.Timestamp := 1_000;

   function Tick return QUIC.Timestamp is
   begin
      Stamp := Stamp + 1_000;
      return Stamp;
   end Tick;

   procedure Acknowledge
     (From : in out QUIC.Connection; To : in out QUIC.Connection)
   is
      ACK : QUIC.Datagram;
   begin
      QUIC.Build_ACK_Datagram
        (From, ACK_Delay => 0, Now => Tick, Packet => ACK, Status => Sent);
      if Sent = QUIC.Sent then
         Fixtures.Deliver (ACK, To);
      end if;
   end Acknowledge;

   --  Both directions refresh connection, stream and stream-count credit.
   procedure Refresh_Credit (Streams : QUIC.Stream_Offset) is
      Grant : QUIC.Datagram;
   begin
      QUIC.Build_Receive_Credit_Datagram
        (Server_Transport, Connection_Window => 524_288,
         Direction => QUIC.Bidirectional, Maximum_Streams => Streams,
         Now => Tick, Packet => Grant, Status => Sent);
      if Sent = QUIC.Sent then
         Fixtures.Deliver (Grant, Client_Transport);
      end if;
      QUIC.Build_Receive_Credit_Datagram
        (Client_Transport, Connection_Window => 524_288,
         Direction => QUIC.Bidirectional, Maximum_Streams => Streams,
         Now => Tick, Packet => Grant, Status => Sent);
      if Sent = QUIC.Sent then
         Fixtures.Deliver (Grant, Server_Transport);
      end if;
   end Refresh_Credit;

   procedure Drain (Item : in out H3.Session; On : in out QUIC.Connection) is
   begin
      loop
         H3.Poll (Item, On, Event, Status);
         exit when Status /= H3.Succeeded;
      end loop;
   end Drain;

   --  One complete, well-formed exchange, so the stream retires normally and
   --  the next identifier advances.
   procedure Exchange (Stream : out QUIC.Stream_ID; OK : out Boolean) is
      Request_Block, Response_Block : H3.Header_Block;
   begin
      OK := False;
      Stream := 0;
      H3.Open_Request (Client_H3, Client_Transport, Stream, Status);
      if Status /= H3.Succeeded then
         Repro_Support.Note
           ("Open_Request: " & H3.Operation_Status'Image (Status));
         return;
      end if;
      H3.Append (Request_Block, H3.Make_Field (":method", "GET"));
      H3.Append (Request_Block, H3.Make_Field (":scheme", "https"));
      H3.Append (Request_Block, H3.Make_Field (":path", "/x"));
      H3.Append (Request_Block, H3.Make_Field (":authority", "h"));
      H3.Send_Headers
        (Client_H3, Client_Transport, Stream, Request_Block, Fin => True,
         Now => Tick, Packet => Packet, Status => Status);
      if Status /= H3.Succeeded then
         Repro_Support.Note
           ("Send_Headers: " & H3.Operation_Status'Image (Status));
         return;
      end if;
      Fixtures.Deliver (Packet, Server_Transport);
      Drain (Server_H3, Server_Transport);
      Acknowledge (Server_Transport, Client_Transport);

      H3.Append (Response_Block, H3.Make_Field (":status", "200"));
      H3.Send_Headers
        (Server_H3, Server_Transport, Stream, Response_Block, Fin => True,
         Now => Tick, Packet => Packet, Status => Status);
      if Status /= H3.Succeeded then
         Repro_Support.Note
           ("response Send_Headers: " & H3.Operation_Status'Image (Status) &
              "; server transport " &
              QUIC.Connection_State'Image (QUIC.State (Server_Transport)) &
              "; client transport " &
              QUIC.Connection_State'Image (QUIC.State (Client_Transport)));
         return;
      end if;
      Fixtures.Deliver (Packet, Client_Transport);
      H3.Release_Request (Server_H3, Server_Transport, Stream, Status);
      if Status /= H3.Succeeded then
         Repro_Support.Note
           ("Release_Request: " & H3.Operation_Status'Image (Status));
         return;
      end if;
      Drain (Client_H3, Client_Transport);
      Acknowledge (Client_Transport, Server_Transport);
      OK := True;
   end Exchange;

   --  QPACK prefixed integer (RFC 9204 section 4.1.1 / RFC 7541 section
   --  5.1): a value below 2**N - 1 fits the prefix, otherwise the prefix is
   --  all ones and the remainder follows in seven-bit continuation groups.
   function Prefixed
     (Pattern     : Ada.Streams.Stream_Element;
      Prefix_Bits : Positive;
      Value       : Natural) return Ada.Streams.Stream_Element_Array
   is
      Limit : constant Natural := 2 ** Prefix_Bits - 1;
   begin
      if Value < Limit then
         return (1 => Pattern or Ada.Streams.Stream_Element (Value));
      end if;
      declare
         Rest   : Natural := Value - Limit;
         Buffer : Ada.Streams.Stream_Element_Array (1 .. 6);
         Last   : Ada.Streams.Stream_Element_Offset := 1;
      begin
         Buffer (1) := Pattern or Ada.Streams.Stream_Element (Limit);
         while Rest >= 128 loop
            Last := Last + 1;
            Buffer (Last) :=
              Ada.Streams.Stream_Element (Rest mod 128 + 128);
            Rest := Rest / 128;
         end loop;
         Last := Last + 1;
         Buffer (Last) := Ada.Streams.Stream_Element (Rest);
         return Buffer (1 .. Last);
      end;
   end Prefixed;

   function To_Bytes (Text : String) return Ada.Streams.Stream_Element_Array
   is
      Result : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Text'Length));
      Cursor : Ada.Streams.Stream_Element_Offset := 1;
   begin
      for Index in Text'Range loop
         Result (Cursor) :=
           Ada.Streams.Stream_Element (Character'Pos (Text (Index)));
         Cursor := Cursor + 1;
      end loop;
      return Result;
   end To_Bytes;

   --  QPACK "Literal Field Line with Literal Name" (RFC 9204 section 4.5.6):
   --  001NHxxx with a three-bit name-length prefix and the Huffman bit at
   --  0x08 clear, the name octets, then Hxxxxxxx with a seven-bit
   --  value-length prefix and the value octets.
   function Literal_Line
     (Name, Value : String) return Ada.Streams.Stream_Element_Array is
     (Prefixed (2#0010_0000#, 3, Name'Length) & To_Bytes (Name) &
      Prefixed (16#00#, 7, Value'Length) & To_Bytes (Value));


   --  Ask for one response, have the peer answer with a malformed field
   --  section and leave the stream open, then poll eight times and count how
   --  often the same failure is reported.
   procedure Malformed_Probe
     (Stream : out QUIC.Stream_ID; Resets : out Natural)
   is
      Request_Block : H3.Header_Block;
      Section : constant Ada.Streams.Stream_Element_Array :=
        (16#00#, 16#00#) & Literal_Line (":status", "200") &
        --  An uppercase field name: RFC 9114 section 4.2 requires lowercase
        --  field names on the wire.
        Literal_Line ("X-Bad", "v");
      Frame : Ada.Streams.Stream_Element_Array (1 .. Section'Length + 2);
   begin
      Resets := 0;
      H3.Open_Request (Client_H3, Client_Transport, Stream, Status);
      if Status /= H3.Succeeded then
         Repro_Support.Note
           ("probe Open_Request: " & H3.Operation_Status'Image (Status));
         return;
      end if;
      H3.Append (Request_Block, H3.Make_Field (":method", "GET"));
      H3.Append (Request_Block, H3.Make_Field (":scheme", "https"));
      H3.Append (Request_Block, H3.Make_Field (":path", "/x"));
      H3.Append (Request_Block, H3.Make_Field (":authority", "h"));
      H3.Send_Headers
        (Client_H3, Client_Transport, Stream, Request_Block, Fin => True,
         Now => Tick, Packet => Packet, Status => Status);
      Fixtures.Deliver (Packet, Server_Transport);
      Drain (Server_H3, Server_Transport);

      Frame (1) := 16#01#;
      Frame (2) := Ada.Streams.Stream_Element (Section'Length);
      Frame (3 .. Frame'Last) := Section;
      QUIC.Build_Stream_Datagram
        (Server_Transport, Stream, Offset => 0, Fin => False,
         Data => Frame, Now => Tick, Packet => Packet, Status => Sent);
      if Sent /= QUIC.Sent then
         Repro_Support.Note
           ("probe Build_Stream_Datagram: " & QUIC.Send_Status'Image (Sent));
         return;
      end if;
      Fixtures.Deliver (Packet, Client_Transport);

      --  Poll the way the composable client pump does: take the event,
      --  cancel the exchange, keep polling.
      for Attempt in 1 .. 8 loop
         H3.Poll (Client_H3, Client_Transport, Event, Status);
         if Status = H3.Succeeded
           and then Event.Kind = H3.Stream_Reset
           and then Event.Stream = Stream
         then
            Resets := Resets + 1;
            H3.Cancel_Request
              (Client_H3, Client_Transport, Stream,
               H3.Malformed_Message, Tick, Packet, Status);
            if Status = H3.Succeeded then
               Fixtures.Deliver (Packet, Server_Transport);
            end if;
         end if;
      end loop;
   end Malformed_Probe;

   Last_Stream : QUIC.Stream_ID := 0;
   Warmed      : Natural := 0;
   OK          : Boolean;
begin
   Fixtures.Connect (Client_Transport, Server_Transport);
   H3.Initialize (Client_H3, H3.Client);
   H3.Initialize (Server_H3, H3.Server);
   H3.Start (Client_H3, Client_Transport, Tick, Packet, Status);
   Fixtures.Deliver (Packet, Server_Transport);
   H3.Start (Server_H3, Server_Transport, Tick, Packet, Status);
   Fixtures.Deliver (Packet, Client_Transport);
   Drain (Server_H3, Server_Transport);
   Drain (Client_H3, Client_Transport);
   Repro_Support.Check
     (H3.Has_Peer_Settings (Client_H3), "the sessions exchange SETTINGS");

   --  Control: the same malformed response on a low stream identifier,
   --  which the tombstone table does cover.
   declare
      Control_Stream : QUIC.Stream_ID;
      Control_Resets : Natural;
   begin
      Refresh_Credit (64);
      Malformed_Probe (Control_Stream, Control_Resets);
      Repro_Support.Note
        ("control stream id" & QUIC.Stream_ID'Image (Control_Stream) &
           " reported the failure" & Natural'Image (Control_Resets) &
           " times in 8 polls");
      Repro_Support.Check
        (Control_Resets = 1,
         "inside the tombstone table one malformed response is reported " &
           "once");
   end;

   --  Retire enough well-formed exchanges to pass identifier 4092.
   for Index in 1 .. Warmup loop
      Refresh_Credit (QUIC.Stream_Offset (64 + Index));
      Exchange (Last_Stream, OK);
      exit when not OK;
      Warmed := Index;
   end loop;
   Repro_Support.Note
     ("completed" & Natural'Image (Warmed) & " warm-up exchanges; last " &
        "stream id" & QUIC.Stream_ID'Image (Last_Stream));
   Repro_Support.Check
     (Warmed = Warmup, "the connection retires 1,024 request streams");

   if Warmed = Warmup then
      declare
         Stream : QUIC.Stream_ID;
         Resets : Natural;
      begin
         Refresh_Credit (QUIC.Stream_Offset (64 + Warmup + 8));
         Malformed_Probe (Stream, Resets);
         Repro_Support.Note
           ("offending stream id" & QUIC.Stream_ID'Image (Stream) &
              "; the tombstone table covers ids up to 4092");
         Repro_Support.Check
           (Stream > 4_092,
            "the offending stream identifier is past the tombstone table");
         Repro_Support.Note
           ("Stream_Reset events emitted for the same malformed response:" &
              Natural'Image (Resets) & " in 8 polls");
         Repro_Support.Check
           (Resets <= 1,
            "one malformed response produces one stream failure, whatever " &
              "the stream identifier");
      end;
   end if;

   Repro_Support.Finish;
end Repro_H3_QPACK_13;
