--  H3-QPACK-12.  Two QPACK inputs that RFC 9204 permits are rejected.
--
--  (a) stream_receive_policy.adb:169-174 rejects every byte on the peer's
--      QPACK encoder stream, on the reasoning that a zero
--      SETTINGS_QPACK_MAX_TABLE_CAPACITY "prohibits every encoder
--      instruction in this profile".  RFC 9204 section 4.3.1 says "An
--      encoder informs the decoder of a change to the dynamic table capacity
--      using an instruction that starts with the '001' 3-bit pattern" and
--      "The new capacity MUST be lower than or equal to the limit described
--      in Section 3.2.3."  With a limit of zero, Set Dynamic Table Capacity
--      to zero (the single octet 0x20) is the one legal capacity and is a
--      conformant no-op.
--
--  (b) qpack_field_section_policy.adb:256-262 rejects any nonzero Delta Base.
--      RFC 9204 section 4.5.1.2: "A Sign bit of 0 indicates that the Base is
--      greater than or equal to the value of the Required Insert Count; the
--      decoder adds the value of Delta Base to the Required Insert Count to
--      determine the value of the Base", with the only stated constraint
--      being "The value of Base MUST NOT be negative."  Required Insert
--      Count 0 with Sign 0 and Delta Base 1 gives Base 1, which is not
--      negative.
--
--  This program asserts the CORRECT behaviour for both.  All RFC text above
--  was fetched from rfc-editor.org during this verification.
with Ada.Streams;
with Flyology.HTTP.HTTP_3_Stream_Policy;
with Flyology.HTTP.QPACK_Field_Section_Policy;
with Repro_Support;

procedure Flyology.HTTP.HTTP_3_Stream_Receive_Policy.Repro_H3_QPACK_12
  with SPARK_Mode => Off
is
   package QPACK renames Flyology.HTTP.QPACK_Field_Section_Policy;
   package Stream_Roles renames Flyology.HTTP.HTTP_3_Stream_Policy;

   use type QPACK.Decode_Status;

   Connection : Connection_State;
   Stream     : Stream_State;
   Status     : Receive_Status;
   Headers    : QPACK.Header_Block;
   Result     : Compact_Receive_Result;
begin
   --  (a) A client-initiated unidirectional stream declaring the QPACK
   --  encoder type (0x02), then Set Dynamic Table Capacity 0 (0x20).
   Open
     (Stream, Stream_ID => 6, Local_Role => Stream_Roles.Server,
      Status => Status);
   Process_Compact (Connection, Stream, (1 => 16#02#), Headers, Result);
   Repro_Support.Note
     ("encoder-stream type octet: " & Receive_Status'Image (Result.Status) &
        ", stream kind " & Stream_Kind'Image (Kind (Stream)));
   Process_Compact (Connection, Stream, (1 => 16#20#), Headers, Result);
   Repro_Support.Note
     ("Set Dynamic Table Capacity 0: " &
        Receive_Status'Image (Result.Status));
   Repro_Support.Check
     (Result.Status /= QPACK_Encoder_Stream_Error,
      "Set Dynamic Table Capacity to zero, the only capacity the advertised " &
        "limit permits, is not an encoder-stream error");

   --  (b) Required Insert Count 0, Sign 0, Delta Base 1, then one static
   --  indexed field line (0xD1 is :method GET in the RFC 9204 Appendix A
   --  static table, as tests/flyology-http-qpack_field_section_policy-smoke
   --  pins).
   declare
      Wire : constant Ada.Streams.Stream_Element_Array :=
        (16#00#, 16#01#, 16#D1#);
      Parsed : constant QPACK.Decode_Result := QPACK.Decode (Wire);
   begin
      Repro_Support.Note
        ("Required Insert Count 0 with Delta Base 1: " &
           QPACK.Decode_Status'Image (Parsed.Status));
      Repro_Support.Check
        (Parsed.Status = QPACK.Decoded,
         "a nonzero Delta Base with Required Insert Count 0 decodes, " &
           "Base being 1 and so not negative");
   end;

   --  The control: Delta Base 0 on the same section.
   declare
      Wire : constant Ada.Streams.Stream_Element_Array :=
        (16#00#, 16#00#, 16#D1#);
   begin
      Repro_Support.Note
        ("control, Delta Base 0: " &
           QPACK.Decode_Status'Image (QPACK.Decode (Wire).Status));
   end;

   Repro_Support.Finish;
end Flyology.HTTP.HTTP_3_Stream_Receive_Policy.Repro_H3_QPACK_12;
