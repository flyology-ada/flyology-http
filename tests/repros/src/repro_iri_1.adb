--  IRI-1: an overlong or out-of-range UTF-8 sequence in a percent-decoded
--  special host decodes to a DIFFERENT host instead of failing.
--
--  Asserts the CORRECT behaviour.  WHATWG URL host parsing step 3 is "Let
--  domain be the result of running UTF-8 decode without BOM on the
--  percent-decoding of input"; the Encoding Standard's UTF-8 decoder turns
--  every malformed sequence into U+FFFD, and UTS #46 disallows U+FFFD, so
--  each input below must be rejected.  Flyology_IRI.IDNA.To_ASCII instead
--  hands the bytes to Ada.Strings.UTF_Encoding.Wide_Wide_Strings.Decode,
--  which classifies the lead byte by shape only.

with Ada.Exceptions;
with Flyology_IRI;
with Repro_Support;

procedure Repro_IRI_1 is
   use Flyology_IRI;
   use Repro_Support;

   function Byte (Value : Natural) return String is
     ([1 => Character'Val (Value)]);

   procedure Must_Reject (Input : String; Description : String) is
      Error : constant Parse_Error := Diagnose (Input, Web_URL_Syntax);
   begin
      if Can_Parse (Input, Web_URL_Syntax) then
         declare
            Value : constant Reference := Parse (Input, Web_URL_Syntax);
         begin
            Check (False,
                   Description & " accepted, host [" & Host (Value)
                   & "] image [" & Image (Value) & "]");
         end;
      else
         Check (True, Description & " rejected");
      end if;
      --  Can_Parse and Diagnose must agree, and the category must name the
      --  authority rather than something incidental.
      Check (Can_Parse (Input, Web_URL_Syntax) = (Error.Kind = No_Error),
             Description & ": Can_Parse and Diagnose agree");
      Note (Description & ": Diagnose = " & Error_Kind'Image (Error.Kind)
            & " at" & Natural'Image (Error.Offset));
   exception
      when E : others =>
         Check (False, Description & " raised "
                & Ada.Exceptions.Exception_Name (E));
   end Must_Reject;

begin
   Note ("overlong encodings of ASCII in a percent-decoded special host");
   Must_Reject ("http://%C1%81/", "C1 81 (overlong two-byte 'a')");
   Must_Reject ("http://%E0%81%81/", "E0 81 81 (overlong three-byte 'a')");
   Must_Reject ("http://%F0%80%81%81/", "F0 80 81 81 (overlong four-byte 'a')");
   Must_Reject ("http://%C0%AE%C0%AE/", "C0 AE C0 AE (overlong '..')");
   Must_Reject ("http://%C1%A5xample.com/", "C1 A5 then 'xample.com'");

   Note ("the same bytes unescaped, straight into the host");
   Must_Reject ("http://" & Byte (16#C1#) & Byte (16#81#) & "/",
                "raw C1 81");
   Must_Reject ("http://" & Byte (16#C1#) & Byte (16#A5#) & "xample.com/",
                "raw C1 A5 then 'xample.com'");

   Note ("a four-byte form above U+10FFFF");
   Must_Reject ("http://%F4%90%80%80.com/", "F4 90 80 80 (U+110000)");

   Note ("contrast: IRI_Syntax rejects the same bytes, so the two syntaxes"
         & " disagree on one input");
   Check (not Can_Parse ("http://" & Byte (16#C1#) & Byte (16#81#) & "/",
                         IRI_Syntax),
          "IRI_Syntax rejects raw C1 81");

   Note ("contrast: sequences the crate already rejects");
   Check (not Can_Parse ("http://%C0%80/", Web_URL_Syntax),
          "overlong NUL rejected (after decoding, by the NUL rule)");
   Check (not Can_Parse ("http://%ED%A0%80.com/", Web_URL_Syntax),
          "surrogate rejected");

   Finish;
exception
   when E : others =>
      Note ("unexpected exception: "
            & Ada.Exceptions.Exception_Information (E));
      Check (False, "spike raised");
      Finish;
end Repro_IRI_1;
