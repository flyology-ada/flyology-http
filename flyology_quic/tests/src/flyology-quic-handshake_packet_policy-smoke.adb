procedure Flyology.QUIC.Handshake_Packet_Policy.Smoke is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;

   procedure Check_Envelope_And_Coalescing is
      Wire : Ada.Streams.Stream_Element_Array (-10 .. 30) := (others => 0);
      Result : Parse_Result;
   begin
      Wire (-10 .. 3) :=
        (16#E0#, 0, 0, 0, 1,
         4, 16#83#, 16#94#, 16#C8#, 16#F0#,
         2, 16#01#, 16#02#,
         20);
      Result := Parse (Wire);
      pragma Assert (Result.Status = Parsed);
      pragma Assert (Result.Header.Kind = Long_Header_Policy.Handshake);
      pragma Assert (Result.Length_Offset = 13);
      pragma Assert (Result.Length_Bytes = 1);
      pragma Assert (Result.Packet_Number_Offset = 14);
      pragma Assert (Result.Protected_Length = 20);
      pragma Assert (Result.Consumed = 34);
      pragma Assert
        (Wire
           (Wire'First
              + Ada.Streams.Stream_Element_Offset (Result.Consumed)) = 0);
   end Check_Envelope_And_Coalescing;

   procedure Check_Truncation is
      Complete : Ada.Streams.Stream_Element_Array (1 .. 28) := (others => 0);
   begin
      Complete (1 .. 8) := (16#E0#, 0, 0, 0, 1, 0, 0, 20);
      for Last in
        Complete'First ..
          Ada.Streams.Stream_Element_Offset'Pred (Complete'Last)
      loop
         pragma Assert
           (Parse (Complete (Complete'First .. Last)).Status = Truncated);
      end loop;
      pragma Assert (Parse (Complete).Status = Parsed);
   end Check_Truncation;

   procedure Check_Rejections is
      Packet_Too_Large : constant Ada.Streams.Stream_Element_Array :=
        (16#E0#, 0, 0, 0, 1, 0, 0, 16#80#, 1, 0, 0);
   begin
      pragma Assert
        (Parse ((16#C0#, 0, 0, 0, 1, 0, 0)).Status =
           Not_V1_Handshake);
      pragma Assert
        (Parse ((16#80#, 0, 0, 0, 1)).Status = Invalid_Long_Header);
      pragma Assert
        (Parse (Packet_Too_Large).Status = Packet_Length_Too_Large);
      pragma Assert
        (Parse ((16#E0#, 0, 0, 0, 1, 0, 0, 19)).Status =
           Insufficient_Protected_Payload);
   end Check_Rejections;

   procedure Check_Wide_Length is
      Wire : Ada.Streams.Stream_Element_Array (1 .. 29) := (others => 0);
      Result : Parse_Result;
   begin
      Wire (1 .. 9) :=
        (16#E0#, 0, 0, 0, 1, 0, 0, 16#40#, 20);
      Result := Parse (Wire);
      pragma Assert (Result.Status = Parsed);
      pragma Assert (Result.Length_Bytes = 2);
      pragma Assert (Result.Packet_Number_Offset = 9);
      pragma Assert (Result.Consumed = Wire'Length);
   end Check_Wide_Length;
begin
   Check_Envelope_And_Coalescing;
   Check_Truncation;
   Check_Rejections;
   Check_Wide_Length;
end Flyology.QUIC.Handshake_Packet_Policy.Smoke;
