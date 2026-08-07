procedure Flyology.QUIC.Varint_Policy.Smoke is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Array;

   procedure Check
     (Wire  : Ada.Streams.Stream_Element_Array;
      Value : Value_Type)
   is
      Result  : constant Decode_Result := Decode (Wire);
      Encoded : constant Encoded_Value := Encode (Value);
   begin
      pragma Assert (Result.Status = Decoded);
      pragma Assert (Result.Value = Value);
      pragma Assert (Result.Consumed = Wire'Length);
      pragma Assert
        (Encoded.Data (1 .. Ada.Streams.Stream_Element_Offset (Encoded.Length))
         = Wire);
   end Check;

   procedure Check_Roundtrip (Value : Value_Type) is
      Encoded : constant Encoded_Value := Encode (Value);
      Result  : constant Decode_Result :=
        Decode
          (Encoded.Data
             (1 .. Ada.Streams.Stream_Element_Offset (Encoded.Length)));
   begin
      pragma Assert (Result.Status = Decoded);
      pragma Assert (Result.Value = Value);
      pragma Assert (Result.Consumed = Encoded.Length);
   end Check_Roundtrip;
begin
   --  Published RFC 9000 Appendix A.1 values.
   Check ((1 => 16#25#), 37);
   Check ((16#7B#, 16#BD#), 15_293);
   Check ((16#9D#, 16#7F#, 16#3E#, 16#7D#), 494_878_333);
   Check
     ((16#C2#, 16#19#, 16#7C#, 16#5E#,
       16#FF#, 16#14#, 16#E8#, 16#8C#),
      151_288_809_941_952_652);

   Check_Roundtrip (0);
   Check_Roundtrip (63);
   Check_Roundtrip (64);
   Check_Roundtrip (16_383);
   Check_Roundtrip (16_384);
   Check_Roundtrip (1_073_741_823);
   Check_Roundtrip (1_073_741_824);
   Check_Roundtrip (Value_Type'Last);

   declare
      State : Value_Type := 16#0123_4567_89AB_CDEF#;
   begin
      for Iteration in 1 .. 10_000 loop
         State := (State * 6_364_136_223_846_793_005 + 1) mod 2**62;
         Check_Roundtrip (State);
      end loop;
   end;

   declare
      Result  : constant Decode_Result := Decode ((16#40#, 16#25#));
      Encoded : constant Encoded_Value := Encode (37);
   begin
      pragma Assert (Result.Status = Decoded and then Result.Value = 37);
      pragma Assert (Encoded.Length = 1 and then Encoded.Data (1) = 16#25#);
   end;

   pragma Assert (Decode ((1 => 16#40#)).Status = Truncated);
   pragma Assert (Decode ((16#80#, 0, 0)).Status = Truncated);
   pragma Assert (Decode ((16#C0#, 0, 0, 0, 0, 0, 0)).Status = Truncated);
   pragma Assert (Decode ((1 .. 0 => 0)).Status = Truncated);
end Flyology.QUIC.Varint_Policy.Smoke;
