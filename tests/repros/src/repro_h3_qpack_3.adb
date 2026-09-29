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

--  H3-QPACK-3: a well-formed request field section with more fields than the
--  bounded QPACK profile retains (Max_Fields = 32) decodes as Too_Many_Fields,
--  which qpack_field_section_policy maps to QPACK_Decompression_Failed, which
--  the server driver hands to Close_For_H3_Error, which sends an application
--  CONNECTION_CLOSE with error 0x200.  Every other request multiplexed on the
--  connection is lost with it, and the server advertises no
--  SETTINGS_MAX_FIELD_SECTION_SIZE that would let a peer avoid the limit.
--
--  This program asserts the CORRECT behaviour: an oversized but syntactically
--  valid field section is a stream-level outcome (RFC 9114 section 4.2.2
--  offers 431), leaving the connection and its other requests usable.
--
--  The browser trigger named in the discovery entry (Chrome's cookie
--  crumbling producing more than 32 field lines) is NOT verified here; no
--  browser is driven.  Only the mechanism is.
procedure Repro_H3_QPACK_3 is
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
   use type QUIC.Connection_State;
   use type QUIC.Operation_Status;
   use type QUIC.Send_Status;
   use type QUIC.Stream_ID;
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Array;

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

   function Letter (Index : Natural) return Character is
     (Character'Val (Character'Pos ('a') + Index mod 26));

   --  A syntactically valid request field section with Field_Count field
   --  lines: four pseudo-headers and the rest ordinary fields.
   function Section
     (Field_Count : Positive) return Ada.Streams.Stream_Element_Array
   is
      Buffer : Ada.Streams.Stream_Element_Array (1 .. 4_096) :=
        (others => 0);
      Cursor : Ada.Streams.Stream_Element_Offset := 0;

      procedure Put (Data : Ada.Streams.Stream_Element_Array) is
      begin
         Buffer (Cursor + 1 .. Cursor + Data'Length) := Data;
         Cursor := Cursor + Data'Length;
      end Put;
   begin
      --  Required Insert Count 0, Delta Base 0.
      Put ((16#00#, 16#00#));
      Put (Literal_Line (":method", "GET"));
      Put (Literal_Line (":scheme", "https"));
      Put (Literal_Line (":path", "/hello"));
      Put (Literal_Line (":authority", "localhost"));
      for Index in 5 .. Field_Count loop
         Put
           (Literal_Line
              ("x-f" & Letter (Index) & Letter (Index / 26), "v"));
      end loop;
      return Buffer (1 .. Cursor);
   end Section;
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
      Send_Result : QUIC.Send_Status;
      H3_Status : H3.Operation_Status;
      Event     : H3.Event;
      Headers   : H3.Header_Block;
      Deadline  : Ada.Real_Time.Time;

      procedure Pump (Budget : Duration) is
      begin
         QUIC_IO.Receive (Socket, Transport, Flight, Status, Now, Budget);
         QUIC_IO.Send (Socket, Flight, 2.0);
      exception
         when Flyology.IO.Timeout_Error =>
            null;
      end Pump;

      --  Issue a plain GET through the session and report its :status.
      procedure Plain_Request (Code : out String; Last : out Natural) is
         Stream : QUIC.Stream_ID;
         Block  : H3.Header_Block;
      begin
         Code := (others => ' ');
         Last := 0;
         H3.Open_Request (Session, Transport, Stream, H3_Status);
         if H3_Status /= H3.Succeeded then
            Repro_Support.Note
              ("Open_Request: " & H3.Operation_Status'Image (H3_Status));
            return;
         end if;
         H3.Append (Block, H3.Make_Field (":method", "GET"));
         H3.Append (Block, H3.Make_Field (":scheme", "https"));
         H3.Append (Block, H3.Make_Field (":path", "/hello"));
         H3.Append (Block, H3.Make_Field (":authority", "localhost"));
         H3.Send_Headers
           (Session, Transport, Stream, Block, Fin => True,
            Now => Now, Packet => Packet, Status => H3_Status);
         if H3_Status /= H3.Succeeded then
            Repro_Support.Note
              ("Send_Headers: " & H3.Operation_Status'Image (H3_Status));
            return;
         end if;
         QUIC_IO.Send (Socket, Packet, 2.0);
         Deadline := Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (5.0);
         while Last = 0 and then Ada.Real_Time.Clock < Deadline loop
            H3.Poll (Session, Transport, Event, H3_Status);
            if H3_Status = H3.Succeeded
              and then Event.Kind = H3.Headers_Received
              and then Event.Stream = Stream
            then
               for Index in 1 .. H3.Header_Count (Event.Headers) loop
                  declare
                     Field : constant H3.Header_Field :=
                       H3.Field_At (Event.Headers, Index);
                  begin
                     if H3.Field_Name (Field) = ":status" then
                        Last := H3.Field_Value (Field)'Length;
                        Code (1 .. Last) := H3.Field_Value (Field);
                     end if;
                  end;
               end loop;
            elsif H3_Status = H3.No_Event then
               exit when QUIC.State (Transport) /= QUIC.Connected;
               Pump (0.25);
            elsif H3_Status /= H3.Succeeded then
               Repro_Support.Note
                 ("poll: " & H3.Operation_Status'Image (H3_Status));
               exit;
            end if;
         end loop;
      end Plain_Request;


      --  Send a hand-encoded field section as a HEADERS frame on a fresh
      --  request stream and report the :status the server answers, or 0.
      procedure Raw_Request
        (Payload : Ada.Streams.Stream_Element_Array;
         Stream  : out QUIC.Stream_ID;
         Code    : out String;
         Last    : out Natural;
         Closed  : out Boolean)
      is
         Length : constant Ada.Streams.Stream_Element_Offset :=
           Payload'Length;
         Frame  : Ada.Streams.Stream_Element_Array (1 .. Length + 3);
      begin
         Code := (others => ' ');
         Last := 0;
         Closed := False;
         H3.Open_Request (Session, Transport, Stream, H3_Status);
         if H3_Status /= H3.Succeeded then
            Repro_Support.Note
              ("raw Open_Request: " &
                 H3.Operation_Status'Image (H3_Status));
            return;
         end if;
         --  HEADERS frame (type 0x01) with a two-byte varint length.
         Frame (1) := 16#01#;
         Frame (2) := 16#40# or Ada.Streams.Stream_Element (Length / 256);
         Frame (3) := Ada.Streams.Stream_Element (Length mod 256);
         Frame (4 .. Frame'Last) := Payload;
         QUIC.Build_Stream_Datagram
           (Transport, Stream, Offset => 0, Fin => True,
            Data => Frame, Now => Now, Packet => Packet,
            Status => Send_Result);
         if Send_Result /= QUIC.Sent then
            Repro_Support.Note
              ("raw Build_Stream_Datagram: " &
                 QUIC.Send_Status'Image (Send_Result));
            return;
         end if;
         QUIC_IO.Send (Socket, Packet, 2.0);
         Deadline := Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (4.0);
         while Last = 0 and then Ada.Real_Time.Clock < Deadline loop
            H3.Poll (Session, Transport, Event, H3_Status);
            if H3_Status = H3.Succeeded
              and then Event.Kind = H3.Headers_Received
              and then Event.Stream = Stream
            then
               for Index in 1 .. H3.Header_Count (Event.Headers) loop
                  declare
                     Field : constant H3.Header_Field :=
                       H3.Field_At (Event.Headers, Index);
                  begin
                     if H3.Field_Name (Field) = ":status" then
                        Last := H3.Field_Value (Field)'Length;
                        Code (1 .. Last) := H3.Field_Value (Field);
                     end if;
                  end;
               end loop;
            elsif H3_Status = H3.No_Event then
               if QUIC.State (Transport) /= QUIC.Connected then
                  Closed := True;
                  exit;
               end if;
               Pump (0.25);
            else
               Pump (0.25);
               if QUIC.State (Transport) /= QUIC.Connected then
                  Closed := True;
                  exit;
               end if;
            end if;
         end loop;
      end Raw_Request;

      Code : String (1 .. 8);
      Last : Natural;
      Oversized_Stream : QUIC.Stream_ID;
      Saw_Stream_Reset : Boolean := False;
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

         --  The server advertises no field-section size, so a peer cannot
         --  learn the bound it is about to violate.
         Repro_Support.Check
           (H3.Peer_Settings (Session).Has_Max_Field_Size,
            "the server advertises SETTINGS_MAX_FIELD_SECTION_SIZE so a " &
              "peer can respect its field-section bound");

         --  A baseline request, to show the connection is healthy.
         Plain_Request (Code, Last);
         Repro_Support.Check
           (Last > 0 and then Code (1 .. Last) = "200",
            "the first request succeeds");

         --  A control: the same hand encoder, a section the profile can
         --  hold.  If this answers 200 the encoder is right and the only
         --  difference below is the field count.
         declare
            Control_Stream : QUIC.Stream_ID;
            Control_Closed : Boolean;
         begin
            Raw_Request
              (Section (6), Control_Stream, Code, Last, Control_Closed);
            Repro_Support.Note
              ("hand-encoded 6-field control answered '" &
                 (if Last > 0 then Code (1 .. Last) else "nothing") & "'");
            Repro_Support.Check
              (Last > 0 and then Code (1 .. Last) = "200",
               "the hand-encoded control request is well formed and " &
                 "answered, so the encoder is not the variable under test");
         end;

         --  The oversized but well-formed field section: 33 field lines.
         H3.Open_Request (Session, Transport, Oversized_Stream, H3_Status);
         Repro_Support.Check
           (H3_Status = H3.Succeeded, "the oversized request stream opens");
         declare
            Payload : constant Ada.Streams.Stream_Element_Array :=
              Section (33);
            --  HEADERS frame (type 0x01) with a one- or two-byte varint
            --  length; Payload is a few hundred bytes, so two bytes.
            Length  : constant Ada.Streams.Stream_Element_Offset :=
              Payload'Length;
            Frame   : Ada.Streams.Stream_Element_Array
              (1 .. Length + 3);
         begin
            Repro_Support.Note
              ("33-field section is" &
                 Ada.Streams.Stream_Element_Offset'Image (Length) &
                 " encoded bytes");
            Frame (1) := 16#01#;
            Frame (2) :=
              16#40# or Ada.Streams.Stream_Element (Length / 256);
            Frame (3) := Ada.Streams.Stream_Element (Length mod 256);
            Frame (4 .. Frame'Last) := Payload;
            QUIC.Build_Stream_Datagram
              (Transport, Oversized_Stream, Offset => 0, Fin => True,
               Data => Frame, Now => Now, Packet => Packet,
               Status => Send_Result);
            Repro_Support.Check
              (Send_Result = QUIC.Sent, "the oversized HEADERS frame builds");
            if Send_Result = QUIC.Sent then
               QUIC_IO.Send (Socket, Packet, 2.0);
            end if;
         end;

         --  Observe what the server does about it.  Pump for a fixed
         --  window rather than stopping at the first event, so that a
         --  CONNECTION_CLOSE arriving after a stream-level event is seen.
         Deadline := Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (3.0);
         while Ada.Real_Time.Clock < Deadline loop
            H3.Poll (Session, Transport, Event, H3_Status);
            if H3_Status = H3.Succeeded then
               Repro_Support.Note
                 ("event " & H3.Event_Kind'Image (Event.Kind) &
                    " on stream" & QUIC.Stream_ID'Image (Event.Stream));
               if Event.Kind = H3.Stream_Reset
                 and then Event.Stream = Oversized_Stream
               then
                  Saw_Stream_Reset := True;
               end if;
            elsif H3_Status = H3.No_Event then
               Pump (0.25);
            else
               Repro_Support.Note
                 ("poll after the oversized section: " &
                    H3.Operation_Status'Image (H3_Status));
               Pump (0.25);
            end if;
         end loop;
         Repro_Support.Note
           ("transport state after the oversized section: " &
              QUIC.Connection_State'Image (QUIC.State (Transport)) &
              "; stream-local reset for the offending stream: " &
              Boolean'Image (Saw_Stream_Reset));
         Repro_Support.Check
           (QUIC.State (Transport) /= QUIC.Peer_Closed,
            "the oversized field section does not close the QUIC connection");

         --  The decisive consequence: an unrelated later request.
         Plain_Request (Code, Last);
         Repro_Support.Check
           (Last > 0 and then Code (1 .. Last) = "200",
            "a later, unrelated request on the same connection still works");
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
end Repro_H3_QPACK_3;
