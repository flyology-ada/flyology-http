--  H3-QPACK-2.  HTTP/3 frames are consumed whole: HTTP_3_Frame_Policy.Parse
--  reports Truncated with Consumed = 0 until the entire payload is
--  contiguous, and http_3_connection.adb calls QUIC.Consume only when
--  Result.Consumed > 0.  The QUIC reassembly window is a compile-time 16,384
--  bytes (Flyology.QUIC.Stream_Reassembly_Policy.Max_Stream_Data, enforced by
--  the Reassembly_State type invariant Highest - Base <= Max_Stream_Data), so
--  the longest contiguous prefix any stream can ever present is 16,384 bytes.
--  A DATA frame whose declared length exceeds that prefix therefore never
--  becomes complete, nothing is consumed, the base never advances, and no
--  further bytes can arrive.
--
--  This program asserts the CORRECT behaviour: presented with the largest
--  contiguous prefix the transport can ever hold, the receive policy makes
--  forward progress (consumes something) instead of asking for more data that
--  can never arrive.  Part B covers the second half of the finding, the
--  65,535-byte parser ceiling that RFC 9114 section 7.1 does not impose.
with Ada.Streams;
with Flyology.HTTP.HTTP_3_Frame_Policy;
with Flyology.HTTP.HTTP_3_Stream_Policy;
with Flyology.HTTP.QPACK_Field_Section_Policy;
with Repro_Support;

procedure Flyology.HTTP.HTTP_3_Stream_Receive_Policy.Repro_H3_QPACK_2
  with SPARK_Mode => Off
is
   package Frames renames Flyology.HTTP.HTTP_3_Frame_Policy;
   package QPACK renames Flyology.HTTP.QPACK_Field_Section_Policy;
   package Stream_Roles renames Flyology.HTTP.HTTP_3_Stream_Policy;

   use type Ada.Streams.Stream_Element_Offset;
   use type QPACK.Encode_Status;
   use type Frames.Parse_Status;

   --  Flyology.QUIC.Stream_Reassembly_Policy.Max_Stream_Data.  That package
   --  is a private child of Flyology.QUIC and cannot be named from here, so
   --  the value is restated and checked against the transport default in the
   --  note below.
   Window : constant := 16_384;

   --  A body larger than the window, declared in one DATA frame the way
   --  quic-go 0.54.1 writes one (http3/response_writer.go:177-180 builds a
   --  single dataFrame per Write) and the way aioquic's send_data does.
   Declared_Body : constant := 20_000;

   Connection : Connection_State;
   Stream     : Stream_State;
   Status     : Receive_Status;
   Headers    : QPACK.Header_Block;
   Result     : Compact_Receive_Result;

   Section : QPACK.Header_Block;
   Wire    : QPACK.Encode_Result;
begin
   Repro_Support.Note
     ("QUIC reassembly window =" & Integer'Image (Window) &
      " bytes; declared DATA frame length =" &
      Integer'Image (Declared_Body));

   Section.Count := 5;
   Section.Fields (1) := QPACK.Make_Field (":method", "POST");
   Section.Fields (2) := QPACK.Make_Field (":scheme", "https");
   Section.Fields (3) := QPACK.Make_Field (":path", "/upload");
   Section.Fields (4) := QPACK.Make_Field (":authority", "localhost");
   Section.Fields (5) := QPACK.Make_Field ("content-length", "20000");
   Wire := QPACK.Encode (Section);
   Repro_Support.Check
     (Wire.Status = QPACK.Encoded, "the request field section encodes");

   Open
     (Stream, Stream_ID => 0, Local_Role => Stream_Roles.Server,
      Status => Status);
   Repro_Support.Check
     (Status = Consumed, "the request stream opens");

   --  Step 1: the HEADERS frame, which fits and is consumed normally.  After
   --  this the QUIC reassembly base has advanced, so the window is free to
   --  hold a fresh 16,384 contiguous bytes.
   declare
      Frame : constant Frames.Encode_Result :=
        Frames.Encode
          (Frames.Headers_Frame,
           Wire.Data (1 .. Ada.Streams.Stream_Element_Offset (Wire.Length)));
   begin
      Process_Compact
        (Connection, Stream,
         Frame.Data (1 .. Ada.Streams.Stream_Element_Offset (Frame.Length)),
         Headers, Result);
      Repro_Support.Check
        (Result.Status = Consumed
           and then Result.Event = Headers_Received
           and then Result.Consumed = Frame.Length,
         "the HEADERS frame is consumed");
   end;

   --  Step 2: the whole window, filled with the DATA frame envelope for a
   --  20,000-byte payload followed by as much payload as fits.  This is the
   --  most the transport can ever present for this frame.
   declare
      --  DATA (type 0x00) with a four-byte QUIC varint length of 20,000
      --  (0x4E20 with the 0b10 prefix): 00 80 00 4E 20.
      Envelope : constant Ada.Streams.Stream_Element_Array :=
        (16#00#, 16#80#, 16#00#, 16#4E#, 16#20#);
      Buffer : Ada.Streams.Stream_Element_Array (1 .. Window) :=
        (others => Character'Pos ('a'));
   begin
      Buffer (1 .. Envelope'Length) := Envelope;
      Repro_Support.Note
        ("largest contiguous DATA payload prefix the window can hold =" &
           Ada.Streams.Stream_Element_Offset'Image
             (Window - Envelope'Length) & " bytes");
      Process_Compact (Connection, Stream, Buffer, Headers, Result);
      Repro_Support.Note
        ("Process_Compact status " & Receive_Status'Image (Result.Status) &
           ", consumed" & Input_Offset'Image (Result.Consumed));
      Repro_Support.Check
        (Result.Consumed > 0,
         "a DATA frame larger than the reassembly window makes progress " &
           "instead of stalling forever");
   end;

   --  Part B: the parser's own 65,535-byte frame-length ceiling.  RFC 9114
   --  section 7.1 describes Length as "a variable-length integer that
   --  describes the length in bytes of the Frame Payload" and imposes no
   --  maximum, so a 65,536-byte DATA frame is legal on the wire.
   declare
      Fresh_Connection : Connection_State;
      Fresh_Stream     : Stream_State;
      Fresh_Status     : Receive_Status;
      Fresh_Headers    : QPACK.Header_Block;
      Fresh_Result     : Compact_Receive_Result;
      --  DATA with a four-byte varint length of 65,536 (0x10000).
      Oversize : constant Ada.Streams.Stream_Element_Array :=
        (16#00#, 16#80#, 16#01#, 16#00#, 16#00#);
      Parsed : constant Frames.Parse_Result := Frames.Parse (Oversize);
   begin
      Repro_Support.Note
        ("Frame_Policy.Parse of a 65,536-byte DATA length: " &
           Frames.Parse_Status'Image (Parsed.Status));
      Open
        (Fresh_Stream, Stream_ID => 4, Local_Role => Stream_Roles.Server,
         Status => Fresh_Status);
      declare
         Frame : constant Frames.Encode_Result :=
           Frames.Encode
             (Frames.Headers_Frame,
              Wire.Data
                (1 .. Ada.Streams.Stream_Element_Offset (Wire.Length)));
      begin
         Process_Compact
           (Fresh_Connection, Fresh_Stream,
            Frame.Data
              (1 .. Ada.Streams.Stream_Element_Offset (Frame.Length)),
            Fresh_Headers, Fresh_Result);
      end;
      Process_Compact
        (Fresh_Connection, Fresh_Stream, Oversize, Fresh_Headers,
         Fresh_Result);
      Repro_Support.Note
        ("Process_Compact of the 65,536-byte DATA envelope: " &
           Receive_Status'Image (Fresh_Result.Status));
      Repro_Support.Check
        (Fresh_Result.Status /= Frame_Error,
         "a DATA frame length above 65,535 is not a connection error, " &
           "RFC 9114 section 7.1 setting no maximum");
   end;

   Repro_Support.Finish;
end Flyology.HTTP.HTTP_3_Stream_Receive_Policy.Repro_H3_QPACK_2;
