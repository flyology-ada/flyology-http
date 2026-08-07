procedure Flyology.HTTP.Header_Huffman_Policy.Smoke is
   Result : Decode_Result;
begin
   Result :=
     Decode
       ((16#F1#, 16#E3#, 16#C2#, 16#E5#, 16#F2#, 16#3A#,
         16#6B#, 16#A0#, 16#AB#, 16#90#, 16#F4#, 16#FF#),
        Max_Output_Length);
   pragma Assert
     (Result.Status = Decoded and then Result.Length = 15
      and then Result.Data (1 .. Result.Length) = "www.example.com");

   Result := Decode (Ada.Streams.Stream_Element_Array'(1 .. 0 => 0), 0);
   pragma Assert (Result.Status = Decoded and then Result.Length = 0);

   Result := Decode ((1 => 0), Max_Output_Length);
   pragma Assert (Result.Status = Invalid_Padding);

   Result := Decode ((16#FF#, 16#FF#, 16#FF#, 16#FF#), Max_Output_Length);
   pragma Assert (Result.Status = EOS_Symbol);

   Result :=
     Decode
       ((16#F1#, 16#E3#, 16#C2#, 16#E5#, 16#F2#, 16#3A#,
         16#6B#, 16#A0#, 16#AB#, 16#90#, 16#F4#, 16#FF#),
        1);
   pragma Assert (Result.Status = Output_Too_Large);
end Flyology.HTTP.Header_Huffman_Policy.Smoke;
