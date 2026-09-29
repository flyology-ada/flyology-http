--  H3-QPACK-7.  The public HTTP/3 contract accepts field values up to 16 KiB
--  (Flyology.HTTP.HTTP_3.Max_Value_Length at http_3.ads:19-20, "Bounded
--  field-value size, including long :path values used by presigned object
--  requests", and the 0.1.1 CHANGELOG entries "QPACK field values to 16 KiB"
--  and "client request targets to 16 KiB"), but the send path caps an encoded
--  field section at Max_Encode_Length = 1_109 bytes
--  (qpack_field_section_policy.ads:21).  Encode then returns
--  Section_Too_Large, which http_3_connection.adb reports as
--  QPACK_Decompression_Failed, which the server turns into a 500 and the
--  client into Transport_Failed.
--
--  This program asserts the CORRECT behaviour: a field section whose values
--  are inside the documented 16 KiB bound encodes.
with Ada.Streams;
with Repro_Support;

procedure Flyology.HTTP.QPACK_Field_Section_Policy.Repro_H3_QPACK_7
  with SPARK_Mode => Off
is
   Block : Header_Block;
begin
   Repro_Support.Note
     ("Max_Value_Length =" & Integer'Image (Max_Value_Length) &
      ", Max_Fields =" & Integer'Image (Max_Fields) &
      ", Max_Encode_Length =" & Integer'Image (Max_Encode_Length));

   --  A single response header well inside the documented per-value bound:
   --  a 1,200-byte content-security-policy.
   Block.Count := 2;
   Block.Fields (1) := Make_Field (":status", "200");
   Block.Fields (2) :=
     Make_Field ("content-security-policy", (1 .. 1_200 => 'a'));
   declare
      Wire : constant Encode_Result := Encode (Block);
   begin
      Repro_Support.Note
        ("1,200-byte value: Encode returns " &
           Encode_Status'Image (Wire.Status) & ", length" &
           Integer'Image (Wire.Length));
      Repro_Support.Check
        (Wire.Status = Encoded,
         "a 1,200-byte field value, inside the documented 16 KiB bound, " &
           "encodes for sending");
   end;

   --  The largest value the public contract admits.
   Block.Count := 2;
   Block.Fields (1) := Make_Field (":method", "GET");
   Block.Fields (2) := Make_Field (":path", (1 .. 16 * 1_024 => 'p'));
   declare
      Wire : constant Encode_Result := Encode (Block);
   begin
      Repro_Support.Note
        ("16 KiB :path: Encode returns " &
           Encode_Status'Image (Wire.Status));
      Repro_Support.Check
        (Wire.Status = Encoded,
         "a 16 KiB :path, the exact size the contract names, encodes");
   end;

   --  Locate the actual send ceiling, for the report.
   declare
      Low  : Natural := 0;
      High : Natural := 16 * 1_024;
   begin
      while High - Low > 1 loop
         declare
            Middle : constant Natural := (Low + High) / 2;
            Probe  : Header_Block;
         begin
            Probe.Count := 2;
            Probe.Fields (1) := Make_Field (":status", "200");
            Probe.Fields (2) := Make_Field ("x-long", (1 .. Middle => 'a'));
            if Encode (Probe).Status = Encoded then
               Low := Middle;
            else
               High := Middle;
            end if;
         end;
      end loop;
      Repro_Support.Note
        ("largest sendable single x-long value:" & Integer'Image (Low) &
           " bytes");
   end;

   Repro_Support.Finish;
end Flyology.HTTP.QPACK_Field_Section_Policy.Repro_H3_QPACK_7;
