procedure Flyology.QUIC.One_RTT_Packet_Policy.Smoke is
   use type Ada.Streams.Stream_Element_Array;
   use type Ada.Streams.Stream_Element_Offset;

   procedure Check_Envelope is
      Wire : Ada.Streams.Stream_Element_Array (-5 .. 30) := (others => 0);
      Result : Parse_Result;
   begin
      Wire (-5) := 16#43#;
      Wire (-4 .. 3) :=
        (16#83#, 16#94#, 16#C8#, 16#F0#,
         16#3E#, 16#51#, 16#57#, 16#08#);
      Result := Parse (Wire, 8);
      pragma Assert
        (Result.Status = Parsed
         and then Result.First_Byte = 16#43#
         and then Result.Destination.Length = 8
         and then Result.Destination.Data (1 .. 8) = Wire (-4 .. 3)
         and then Result.Packet_Number_Offset = 9
         and then Result.Protected_Length = 27
         and then Result.Consumed = Wire'Length);
   end Check_Envelope;

   procedure Check_Rejections is
      Too_Large : Ada.Streams.Stream_Element_Array (1 .. 65_536) :=
        (others => 0);
   begin
      pragma Assert (Parse ((1 .. 0 => 0), 0).Status = Truncated);
      pragma Assert
        (Parse ((1 => 16#C0#), 0).Status = Not_Short_Header);
      pragma Assert
        (Parse ((1 => 16#00#), 0).Status = Invalid_Fixed_Bit);
      pragma Assert
        (Parse ((16#40#, 1, 2, 3), 4).Status = Truncated);
      pragma Assert
        (Parse ((16#40#, 1, 2, 3, 4, 0, 0, 0), 4).Status =
           Insufficient_Protected_Payload);
      Too_Large (1) := 16#40#;
      pragma Assert (Parse (Too_Large, 0).Status = Packet_Too_Large);
   end Check_Rejections;
begin
   Check_Envelope;
   Check_Rejections;
end Flyology.QUIC.One_RTT_Packet_Policy.Smoke;
