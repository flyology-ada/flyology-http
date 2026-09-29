with Ada.Calendar;
with Ada.Streams;
with Ada.Strings.Fixed;
with GNAT.Sockets;
with Flyology;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.IO.Sockets;
with H2_Wire;
with Repro_Support;

--  H2-4.  Cancelling a client stream whose request field section is still
--  fragmented leaves Continuation_Slot pinned to a stream the output pump
--  will never serve again, so the field section is never terminated.  RFC
--  9113 4.3: "Field blocks MUST be transmitted as a contiguous sequence of
--  frames, with no interleaved frames of any other type or from any other
--  stream."  RFC 9113 6.10 on END_HEADERS: "If the END_HEADERS flag is not
--  set, this frame MUST be followed by another CONTINUATION frame.  A
--  receiver MUST treat the receipt of any other type of frame or a frame on
--  a different stream as a connection error (Section 5.4.1) of type
--  PROTOCOL_ERROR."
--
--  Thirty concurrent exchanges each carry a 16000-octet field, so every
--  request head needs a CONTINUATION (the shape tests/http2_client_
--  integration.adb calls the "continuation" scenario).  The peer stops
--  reading, so the deadlines expire while sections are in flight.  The spike
--  asserts the wire never carries an unterminated field section.
procedure Repro_H2_4 is
   use Ada.Streams;
   use Repro_Support;
   use H2_Wire;
   package Client renames Flyology.HTTP.Client;
   package Sockets renames Flyology.IO.Sockets;

   function Decimal (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   Listener : Sockets.Socket_Type;
   Address  : Sockets.Endpoint;

   --  Cap the accepted socket's receive buffer so the client's output pump
   --  actually parks on Need_Write while a field section is in flight.  On
   --  loopback the kernel otherwise absorbs every byte this spike can send.
   procedure Shrink_Receive_Buffer (Socket : Sockets.Socket_Type) is
      Native : constant GNAT.Sockets.Socket_Type :=
        GNAT.Sockets.To_Ada (Integer (Sockets.Native_Descriptor (Socket)));
   begin
      GNAT.Sockets.Set_Socket_Option
        (Native, GNAT.Sockets.Socket_Level,
         (GNAT.Sockets.Receive_Buffer, 2_048));
   exception
      when others =>
         Note ("  (could not shrink the peer receive buffer)");
   end Shrink_Receive_Buffer;

   Capture_Limit : constant := 2 * 1_024 * 1_024;
   type Capture_Array is array (1 .. Capture_Limit) of Stream_Element;
   type Capture_Access is access Capture_Array;
   Capture : constant Capture_Access := new Capture_Array'(others => 0);
   Captured : Natural := 0;

   Dangling_Section : Boolean := False;
   Interleaved      : Boolean := False;
   Unfinished       : Boolean := False;
begin
   Note ("H2-4: cancelling a stream mid field section");
   Address := Listen_Loopback (Listener);
   Shrink_Receive_Buffer (Listener);

   declare
      Origin : constant String :=
        "http://127.0.0.1:" & Decimal (Natural (Address.Port));
      Session : aliased Client.Client (Capacity => 1);

      task Peer_Task is
         pragma Task_Info (Flyology.Native_Task);
      end Peer_Task;

      task body Peer_Task is
         Socket  : Sockets.Socket_Type;
         Where   : Sockets.Endpoint;
         Opening : Stream_Element_Array (1 .. Preface'Length);
         Chunk   : Stream_Element_Array (1 .. 16_384);
         Last    : Stream_Element_Offset;
      begin
         Sockets.Accept_Connection
           (Listener, Socket, Where, Timeout => 15.0);
         Shrink_Receive_Buffer (Socket);
         Sockets.Receive_Exactly (Socket, Opening, Timeout => 10.0);
         Send_Frame (Socket, Settings_Frame, 0, 0, Empty);
         --  Drain slowly so the client's output pump parks on Need_Write
         --  while field sections are in flight and the per-exchange
         --  deadlines expire.  A peer that reads as fast as loopback allows
         --  never lets the pump stop between two fragments.
         declare
            use type Ada.Calendar.Time;
            Slow : Stream_Element_Array (1 .. 2_048);
            Deadline : constant Ada.Calendar.Time :=
              Ada.Calendar.Clock + 8.0;
         begin
            while Ada.Calendar.Clock < Deadline loop
               Sockets.Receive (Socket, Slow, Last, Timeout => 1.0);
               exit when Last < Slow'First;
               for Offset in Slow'First .. Last loop
                  if Captured < Capture_Limit then
                     Captured := Captured + 1;
                     Capture (Captured) := Slow (Offset);
                  end if;
               end loop;
               delay 0.020;
            end loop;
         exception
            when others => null;
         end;
         --  Then drain whatever remains as fast as possible.
         begin
            loop
               Sockets.Receive (Socket, Chunk, Last, Timeout => 20.0);
               exit when Last < Chunk'First;
               for Offset in Chunk'First .. Last loop
                  if Captured < Capture_Limit then
                     Captured := Captured + 1;
                     Capture (Captured) := Chunk (Offset);
                  end if;
               end loop;
            end loop;
         exception
            when others => null;
         end;
         Sockets.Close_Socket (Socket);
      exception
         when others => null;
      end Peer_Task;
   begin
      Client.Configure
        (Session, Flyology.HTTP.Parse_Origin (Origin),
         Client.HTTP_2_Prior_Knowledge);
      declare
         task type Requester is
            pragma Task_Info (Flyology.Native_Task);
         end Requester;

         task body Requester is
            Ask : aliased Client.Request;
         begin
            --  A 15900-octet target plus a 16000-octet field puts the
            --  encoded head above the 16384-octet maximum frame size, so it
            --  needs a HEADERS fragment and a CONTINUATION.
            Client.Set_Target (Ask, "/pinned/" & (1 .. 15_900 => 'p'));
            Client.Add_Header (Ask, "x-large", (1 .. 16_000 => 'x'));
            declare
               Reply : Client.Response :=
                 Client.Execute (Session, Ask, Timeout => 3.0);
               pragma Unreferenced (Reply);
            begin
               null;
            end;
         exception
            when others => null;
         end Requester;

         Workers : array (1 .. 30) of Requester;
         pragma Unreferenced (Workers);
      begin
         null;
      end;
      --  Let the slow peer finish draining before the connection closes, so
      --  the capture shows everything the pump was still willing to emit.
      delay 6.0;
      --  One more request on the same pooled connection.  Its field section
      --  is what a peer sees arriving after the abandoned one.
      declare
         Ask : aliased Client.Request;
      begin
         Client.Set_Target (Ask, "/after-cancel");
         declare
            Reply : Client.Response :=
              Client.Execute (Session, Ask, Timeout => 3.0);
            pragma Unreferenced (Reply);
         begin
            null;
         end;
      exception
         when others => null;
      end;
      delay 4.0;
      begin
         Client.Shutdown (Session, Timeout => 5.0);
      exception
         when others => null;
      end;
   end;

   --  Analyse what the peer actually received.  Two passes: the first
   --  counts frames, the second traces only the tail plus any anomaly.
   declare
      Total_Frames : Natural := 0;

      procedure Scan (Trace_From : Natural) is
         Cursor  : Natural := 1;
         Expecting : Boolean := False;
         Section_Stream : Natural := 0;
         Seen : Natural := 0;
      begin
         Interleaved := False;
         Unfinished := False;
         --  The peer already consumed the connection preface with a separate
         --  exact read, so the capture starts at the client's first frame.
         while Cursor + 8 <= Captured loop
            declare
               Length : constant Natural :=
                 Natural (Capture (Cursor)) * 65_536 +
                 Natural (Capture (Cursor + 1)) * 256 +
                 Natural (Capture (Cursor + 2));
               Kind   : constant Stream_Element := Capture (Cursor + 3);
               Flags  : constant Stream_Element := Capture (Cursor + 4);
               Stream : constant Natural :=
                 Natural (Capture (Cursor + 5) and 16#7F#) * 16#100_0000# +
                 Natural (Capture (Cursor + 6)) * 16#1_0000# +
                 Natural (Capture (Cursor + 7)) * 16#100# +
                 Natural (Capture (Cursor + 8));
               Ends   : constant Boolean := (Flags and End_Headers_Flag) /= 0;
            begin
               exit when Cursor + 8 + Length > Captured;
               Seen := Seen + 1;
               if Seen >= Trace_From then
                  Note
                    ("  -> " & Frame_Name (Kind) & " stream" &
                     Natural'Image (Stream) & " length" &
                     Natural'Image (Length) &
                     (if Kind in Headers_Frame | Continuation_Frame
                      then (if Ends then " END_HEADERS"
                            else " (no END_HEADERS)")
                      else ""));
               end if;
               if Expecting then
                  if Kind /= Continuation_Frame
                    or else Stream /= Section_Stream
                  then
                     Interleaved := True;
                     Note
                       ("  !! " & Frame_Name (Kind) & " on stream" &
                        Natural'Image (Stream) &
                        " interrupts the unterminated field section of" &
                        " stream" & Natural'Image (Section_Stream));
                     Expecting := False;
                  elsif Ends then
                     Expecting := False;
                  end if;
               elsif Kind = Headers_Frame and then not Ends then
                  Expecting := True;
                  Section_Stream := Stream;
               end if;
               Cursor := Cursor + 9 + Length;
            end;
         end loop;
         Total_Frames := Seen;
         if Cursor + 8 <= Captured then
            Note ("  -> trailing incomplete frame at the end of the capture");
         end if;
         if Expecting then
            Unfinished := True;
            if Trace_From <= Seen then
               Note
                 ("  !! the capture ends inside the field section of stream" &
                  Natural'Image (Section_Stream) &
                  ": its CONTINUATION was never emitted");
            end if;
         end if;
      end Scan;
   begin
      Scan (Trace_From => Natural'Last);
      Scan (Trace_From => (if Total_Frames > 8 then Total_Frames - 8 else 1));
      Dangling_Section := Interleaved or else Unfinished;
      Note ("  captured" & Natural'Image (Captured) & " octets in" &
            Natural'Image (Total_Frames) & " complete frames");
   end;

   Check
     (not Dangling_Section,
      "a cancelled request never leaves its field section unterminated " &
      "on the wire");

   Sockets.Close_Socket (Listener);
   Finish;
end Repro_H2_4;
