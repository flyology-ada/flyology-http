procedure Flyology.QUIC.ACK_Range_Policy.Smoke is
   use type Ada.Streams.Stream_Element_Offset;
   Data : constant Ada.Streams.Stream_Element_Array :=
     (16#02#, 16#32#, 16#00#, 16#02#, 16#0A#,
      16#04#, 16#05#, 16#09#, 16#02#);
   Frame  : constant Initial_Frame_Policy.Parse_Result :=
     Initial_Frame_Policy.Parse_Next (Data, 0);
   Result : Decode_Result;
begin
   pragma Assert
     (Frame.Status = Initial_Frame_Policy.Parsed
      and then Frame.ACK_Range_Count = 2);
   Result := Decode (Data, Frame);
   pragma Assert
     (Result.Status = Decoded and then Result.Count = 3
      and then Result.Ranges (1) = (Smallest => 40, Largest => 50)
      and then Result.Ranges (2) = (Smallest => 29, Largest => 34)
      and then Result.Ranges (3) = (Smallest => 16, Largest => 18));
   pragma Assert
     (Acknowledges (Result, 50)
      and then Acknowledges (Result, 30)
      and then Acknowledges (Result, 16)
      and then not Acknowledges (Result, 39)
      and then not Acknowledges (Result, 15));

   declare
      Truncated_Data : constant Ada.Streams.Stream_Element_Array :=
        Data (Data'First .. Data'Last - 1);
   begin
      pragma Assert
        (Decode (Truncated_Data, Frame).Status = Truncated);
   end;

   declare
      Invalid_Data : Ada.Streams.Stream_Element_Array := Data;
   begin
      Invalid_Data (Invalid_Data'Last) := 16#13#;
      pragma Assert
        (Decode (Invalid_Data, Frame).Status = Invalid_Range);
   end;

   declare
      Too_Many : Initial_Frame_Policy.Parse_Result := Frame;
   begin
      Too_Many.ACK_Range_Count := Max_Ranges;
      pragma Assert (Decode (Data, Too_Many).Status = Too_Many_Ranges);
   end;
end Flyology.QUIC.ACK_Range_Policy.Smoke;
