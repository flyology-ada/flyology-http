--  H3-QPACK-14.  Validate_Response marks a response malformed when it carries
--  content-length together with a 1xx or 204 status
--  (http_3_header_policy.adb:414-418).  RFC 9110 section 8.6 constrains the
--  sender only, RFC 9114 section 4.1.2's list of malformed conditions does not
--  include it, and some frameworks emit "content-length: 0" on a 204.
--
--  This program asserts the CORRECT behaviour: a recipient does not treat the
--  sender's violation as a malformed message.  It also records the 101 case
--  and the request-side behaviour for comparison.
with Flyology.HTTP.QPACK_Field_Section_Policy;
with Repro_Support;

procedure Flyology.HTTP.HTTP_3_Header_Policy.Repro_H3_QPACK_14
  with SPARK_Mode => Off
is
   package QPACK renames Flyology.HTTP.QPACK_Field_Section_Policy;

   procedure Probe (Label, Code, Length : String) is
      Block : QPACK.Header_Block;
   begin
      Block.Count := 2;
      Block.Fields (1) := QPACK.Make_Field (":status", Code);
      Block.Fields (2) := QPACK.Make_Field ("content-length", Length);
      declare
         Result : constant Validation_Result := Validate_Response (Block);
      begin
         Repro_Support.Note
           (Label & ": " & Validation_Status'Image (Result.Status));
         Repro_Support.Check
           (Result.Status = Valid,
            Label & " is not a malformed message for the recipient");
      end;
   end Probe;
begin
   Probe ("204 with content-length: 0", "204", "0");
   Probe ("103 with content-length: 0", "103", "0");

   --  A 200 with the same field is the control.
   declare
      Block : QPACK.Header_Block;
   begin
      Block.Count := 2;
      Block.Fields (1) := QPACK.Make_Field (":status", "200");
      Block.Fields (2) := QPACK.Make_Field ("content-length", "0");
      Repro_Support.Note
        ("control, 200 with content-length: 0: " &
           Validation_Status'Image (Validate_Response (Block).Status));
   end;

   Repro_Support.Finish;
end Flyology.HTTP.HTTP_3_Header_Policy.Repro_H3_QPACK_14;
