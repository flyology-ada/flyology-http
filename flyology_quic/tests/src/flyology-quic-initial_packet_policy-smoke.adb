procedure Flyology.QUIC.Initial_Packet_Policy.Smoke is
   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Streams.Stream_Element;

   procedure Put_Client_Prefix
     (Wire : in out Ada.Streams.Stream_Element_Array)
   is
   begin
      Wire (Wire'First .. Wire'First + 17) :=
        (16#C3#, 0, 0, 0, 1, 8,
         16#83#, 16#94#, 16#C8#, 16#F0#,
         16#3E#, 16#51#, 16#57#, 16#08#, 0,
         0, 16#44#, 16#9E#);
   end Put_Client_Prefix;

   procedure Check_RFC_Client_Initial is
      Wire : Ada.Streams.Stream_Element_Array (1 .. 1_200) := (others => 0);
      Result : Parse_Result;
   begin
      --  Header through Length from RFC 9001 Appendix A.2.
      Put_Client_Prefix (Wire);
      pragma Assert (Parse (Wire (1 .. 16)).Status = Truncated);
      pragma Assert (Parse (Wire (1 .. 17)).Status = Truncated);
      pragma Assert (Parse (Wire (1 .. 18)).Status = Truncated);
      Result := Parse (Wire);
      pragma Assert (Result.Status = Parsed);
      pragma Assert (Result.Header.Kind = Long_Header_Policy.Initial);
      pragma Assert (Result.Token_Offset = 16);
      pragma Assert (Result.Token_Length = 0);
      pragma Assert (Result.Length_Offset = 16);
      pragma Assert (Result.Length_Bytes = 2);
      pragma Assert (Result.Packet_Number_Offset = 18);
      pragma Assert (Result.Protected_Length = 1_182);
      pragma Assert (Result.Consumed = 1_200);
   end Check_RFC_Client_Initial;

   procedure Check_RFC_Server_Initial is
      Wire : Ada.Streams.Stream_Element_Array (1 .. 135) := (others => 0);
      Result : Parse_Result;
   begin
      --  Header through Length from RFC 9001 Appendix A.3.
      Wire (1 .. 18) :=
        (16#CF#, 0, 0, 0, 1, 0, 8,
         16#F0#, 16#67#, 16#A5#, 16#50#,
         16#2A#, 16#42#, 16#62#, 16#B5#,
         0, 16#40#, 16#75#);
      Result := Parse (Wire);
      pragma Assert (Result.Status = Parsed);
      pragma Assert (Result.Token_Offset = 16);
      pragma Assert (Result.Packet_Number_Offset = 18);
      pragma Assert (Result.Protected_Length = 117);
      pragma Assert (Result.Consumed = 135);
   end Check_RFC_Server_Initial;

   procedure Check_Token_And_Coalescing is
      Wire : Ada.Streams.Stream_Element_Array (-10 .. 30) := (others => 0);
      Result : Parse_Result;
   begin
      Wire (-10 .. 2) :=
        (16#C0#, 0, 0, 0, 1, 1, 16#AA#, 1, 16#BB#,
         3, 16#10#, 16#20#, 16#30#);
      Wire (3) := 20;
      Result := Parse (Wire);
      pragma Assert (Result.Status = Parsed);
      pragma Assert (Result.Token_Offset = 10);
      pragma Assert (Result.Token_Length = 3);
      pragma Assert (Result.Length_Offset = 13);
      pragma Assert (Result.Packet_Number_Offset = 14);
      pragma Assert (Result.Consumed = 34);
      pragma Assert
        (Wire
           (Wire'First
            + Ada.Streams.Stream_Element_Offset (Result.Token_Offset)) =
           16#10#);
      pragma Assert
        (Wire
           (Wire'First
            + Ada.Streams.Stream_Element_Offset (Result.Consumed)) = 0);
   end Check_Token_And_Coalescing;

   procedure Check_Truncation is
      Complete : Ada.Streams.Stream_Element_Array (1 .. 29) := (others => 0);
   begin
      Complete (1 .. 9) := (16#C0#, 0, 0, 0, 1, 0, 0, 0, 20);
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
      Token_Too_Large : constant Ada.Streams.Stream_Element_Array :=
        (16#C0#, 0, 0, 0, 1, 0, 0, 16#80#, 1, 0, 0);
      Packet_Too_Large : constant Ada.Streams.Stream_Element_Array :=
        (16#C0#, 0, 0, 0, 1, 0, 0, 0, 16#80#, 1, 0, 0);
   begin
      pragma Assert
        (Parse ((16#E0#, 0, 0, 0, 1, 0, 0)).Status = Not_V1_Initial);
      pragma Assert
        (Parse ((16#80#, 0, 0, 0, 1)).Status = Invalid_Long_Header);
      pragma Assert
        (Parse (Token_Too_Large).Status = Token_Length_Too_Large);
      pragma Assert
        (Parse (Packet_Too_Large).Status = Packet_Length_Too_Large);
      pragma Assert
        (Parse ((16#C0#, 0, 0, 0, 1, 0, 0, 0, 19)).Status =
           Insufficient_Protected_Payload);
   end Check_Rejections;

   procedure Check_Wide_Varints is
      Wire : Ada.Streams.Stream_Element_Array (1 .. 31) := (others => 0);
      Result : Parse_Result;
   begin
      Wire (1 .. 11) :=
        (16#C0#, 0, 0, 0, 1, 0, 0,
         16#40#, 0, 16#40#, 20);
      Result := Parse (Wire);
      pragma Assert (Result.Status = Parsed);
      pragma Assert (Result.Token_Length_Bytes = 2);
      pragma Assert (Result.Length_Bytes = 2);
      pragma Assert (Result.Packet_Number_Offset = 11);
      pragma Assert (Result.Consumed = Wire'Length);
   end Check_Wide_Varints;
begin
   Check_RFC_Client_Initial;
   Check_RFC_Server_Initial;
   Check_Token_And_Coalescing;
   Check_Truncation;
   Check_Rejections;
   Check_Wide_Varints;
end Flyology.QUIC.Initial_Packet_Policy.Smoke;
