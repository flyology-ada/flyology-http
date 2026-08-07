procedure Flyology.QUIC.TLS_Authentication_Policy.Smoke is
   use type Ada.Streams.Stream_Element_Array;
   use type Ada.Streams.Stream_Element_Offset;

   function Nibble (Value : Character) return Natural is
     (case Value is
         when '0' .. '9' => Character'Pos (Value) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (Value) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (Value) - Character'Pos ('A') + 10,
         when others => raise Constraint_Error);

   function Hex (Value : String) return Ada.Streams.Stream_Element_Array is
      Result : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Value'Length / 2));
      Source : Positive := Value'First;
   begin
      pragma Assert (Value'Length mod 2 = 0);
      for Element of Result loop
         Element :=
           Ada.Streams.Stream_Element
             (16 * Nibble (Value (Source)) + Nibble (Value (Source + 1)));
         Source := Source + 2;
      end loop;
      return Result;
   end Hex;

   Certificates : constant Ada.Streams.Stream_Element_Array :=
     Hex
       ("0b000013" &
        "00" &
        "00000f" &
        "0000030102030000" &
        "000001040001aa");
begin
   declare
      Result : constant Parse_Result := Parse (Certificates);
   begin
      pragma Assert
        (Result.Status = Parsed
         and then Result.Kind = Certificate_Message
         and then Result.Consumed = Certificates'Length
         and then Result.Context_Length = 0
         and then Result.Certificate_Total = 2
         and then Result.Certificates (1) =
           Certificate_Descriptor'(Offset => 11, Length => 3)
         and then Result.Certificates (2) =
           Certificate_Descriptor'(Offset => 19, Length => 1));
   end;

   declare
      Encoded : constant Encode_Result :=
        Encode_Certificate (Hex ("3003010203"), Hex ("0000"));
      Result  : constant Parse_Result :=
        Parse
          (Encoded.Data
             (1 .. Ada.Streams.Stream_Element_Offset (Encoded.Length)));
   begin
      pragma Assert
        (Encoded.Status = TLS_Authentication_Policy.Encoded
         and then Result.Status = Parsed
         and then Result.Certificate_Total = 1
         and then Result.Certificates (1).Length = 5);
   end;

   declare
      Encoded : constant Encode_Result :=
        Encode_Certificate_Verify (ED25519, Hex ("aabbcc"));
      Result  : constant Parse_Result :=
        Parse
          (Encoded.Data
             (1 .. Ada.Streams.Stream_Element_Offset (Encoded.Length)));
   begin
      pragma Assert
        (Encoded.Status = TLS_Authentication_Policy.Encoded
         and then Result.Status = Parsed
         and then Result.Kind = Certificate_Verify_Message
         and then Result.Scheme = ED25519
         and then Result.Signature_Length = 3
         and then
           Encoded.Data
             (Encoded.Data'First
                + Ada.Streams.Stream_Element_Offset
                    (Result.Signature_Offset)
              .. Encoded.Data'First
                + Ada.Streams.Stream_Element_Offset
                    (Result.Signature_Offset + Result.Signature_Length - 1)) =
             Hex ("aabbcc"));
   end;

   declare
      Verify  : constant Verify_Data :=
        Verify_Data'
          (Hex ("000102030405060708090a0b0c0d0e0f" &
                "101112131415161718191a1b1c1d1e1f"));
      Encoded : constant Encode_Result := Encode_Finished (Verify);
      Result  : constant Parse_Result :=
        Parse
          (Encoded.Data
             (1 .. Ada.Streams.Stream_Element_Offset (Encoded.Length)));
   begin
      pragma Assert
        (Encoded.Status = TLS_Authentication_Policy.Encoded
         and then Result.Status = Parsed
         and then Result.Kind = Finished_Message
         and then Result.Verify_Offset = 4
         and then Encoded.Length = 36);
   end;

   pragma Assert (Parse ((1 .. 0 => 0)).Status = Need_More_Data);
   pragma Assert (Parse (Hex ("0b000001")).Status = Need_More_Data);
   pragma Assert
     (Parse (Hex ("01000000")).Status = Unsupported_Message);
   pragma Assert
     (Parse (Hex ("0f00000604010002aabb")).Status =
        Unsupported_Signature);
   pragma Assert
     (Parse (Hex ("0f00000608070003aabb")).Status =
        Invalid_Authentication);
   pragma Assert
     (Parse (Hex ("1400001f" & (1 .. 62 => '0'))).Status =
        Invalid_Authentication);
   pragma Assert
     (Parse (Hex ("0b00000400000001")).Status =
        Invalid_Authentication);
   pragma Assert
     (Parse
        (Hex
           ("0b00003a00000036" &
            "000001aa0000" & "000001aa0000" & "000001aa0000" &
            "000001aa0000" & "000001aa0000" & "000001aa0000" &
            "000001aa0000" & "000001aa0000" & "000001aa0000")).Status =
        Too_Many_Certificates);
end Flyology.QUIC.TLS_Authentication_Policy.Smoke;
