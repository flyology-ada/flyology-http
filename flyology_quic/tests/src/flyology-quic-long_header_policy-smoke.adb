procedure Flyology.QUIC.Long_Header_Policy.Smoke is
   use type Ada.Streams.Stream_Element_Array;
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;

   Empty_ID : constant Connection_ID := (Data => (others => 0), Length => 0);
   Client_Destination : constant Connection_ID :=
     (Data =>
        (1 => 16#83#, 2 => 16#94#, 3 => 16#C8#, 4 => 16#F0#,
         5 => 16#3E#, 6 => 16#51#, 7 => 16#57#, 8 => 16#08#,
         others => 0),
      Length => 8);

   procedure Check_Client_Initial is
      Prefix : constant Encoded_Prefix :=
        Encode_Protected_V1_Prefix
          (Initial, 4, Client_Destination, Empty_ID);
      --  The unprotected prefix from RFC 9001 Appendix A.2.
      Wire : constant Ada.Streams.Stream_Element_Array (1 .. 15) :=
        (16#C3#, 0, 0, 0, 1, 8,
         16#83#, 16#94#, 16#C8#, 16#F0#,
         16#3E#, 16#51#, 16#57#, 16#08#, 0);
      Result : constant Parse_Result := Parse (Wire);
   begin
      pragma Assert (Prefix.Length = Wire'Length);
      pragma Assert
        (Prefix.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Prefix.Length)) = Wire);
      pragma Assert (Result.Status = Parsed);
      pragma Assert (Result.Kind = Initial);
      pragma Assert (Result.Version = Version_1);
      pragma Assert (Result.Consumed = Wire'Length);
      pragma Assert (Result.Destination.Length = 8);
      pragma Assert (Result.Destination.Data (1 .. 8) = Wire (7 .. 14));
      pragma Assert (Result.Source.Length = 0);
   end Check_Client_Initial;

   procedure Check_Server_Initial is
      --  The unprotected prefix from RFC 9001 Appendix A.3.
      Wire : constant Ada.Streams.Stream_Element_Array (1 .. 15) :=
        (16#CF#, 0, 0, 0, 1, 0, 8,
         16#F0#, 16#67#, 16#A5#, 16#50#,
         16#2A#, 16#42#, 16#62#, 16#B5#);
      Result : constant Parse_Result := Parse (Wire);
   begin
      pragma Assert (Result.Status = Parsed and then Result.Kind = Initial);
      pragma Assert (Result.Destination.Length = 0);
      pragma Assert (Result.Source.Length = 8);
      pragma Assert (Result.Source.Data (1 .. 8) = Wire (8 .. 15));
   end Check_Server_Initial;

   procedure Check_Arbitrary_Lower_Bound is
      Wire : constant Ada.Streams.Stream_Element_Array (-7 .. 7) :=
        (16#C3#, 0, 0, 0, 1, 8,
         16#83#, 16#94#, 16#C8#, 16#F0#,
         16#3E#, 16#51#, 16#57#, 16#08#, 0);
      Result : constant Parse_Result := Parse (Wire);
   begin
      pragma Assert (Result.Status = Parsed and then Result.Kind = Initial);
      pragma Assert (Result.Consumed = Wire'Length);
      pragma Assert (Result.Destination.Length = 8);
      pragma Assert (Result.Destination.Data (1 .. 8) = Wire (-1 .. 6));
   end Check_Arbitrary_Lower_Bound;

   procedure Check_Truncation is
      Complete : constant Ada.Streams.Stream_Element_Array (1 .. 11) :=
        (16#C0#, 0, 0, 0, 1, 2, 16#AA#, 16#BB#, 2, 16#CC#, 16#DD#);
   begin
      pragma Assert (Parse ((1 .. 0 => 0)).Status = Truncated);
      for Last in
        Complete'First ..
          Ada.Streams.Stream_Element_Offset'Pred (Complete'Last)
      loop
         pragma Assert (Parse (Complete (Complete'First .. Last)).Status = Truncated);
      end loop;
      pragma Assert (Parse (Complete).Status = Parsed);
   end Check_Truncation;

   procedure Check_Boundaries is
      Twenty : Connection_ID := (Data => (others => 0), Length => 20);
      Prefix : Encoded_Prefix;
      Result : Parse_Result;
      Version_Negotiation : Ada.Streams.Stream_Element_Array (1 .. 49) :=
        (others => 0);
      Unknown : Ada.Streams.Stream_Element_Array (1 .. 49) := (others => 0);
   begin
      for Index in 1 .. 20 loop
         Twenty.Data (Ada.Streams.Stream_Element_Offset (Index)) :=
           Ada.Streams.Stream_Element (Index);
      end loop;
      Prefix := Encode_Protected_V1_Prefix (Handshake, 1, Twenty, Twenty);
      pragma Assert (Prefix.Length = 47 and then Prefix.Data (1) = 16#E0#);
      Result :=
        Parse
          (Prefix.Data
             (1 .. Ada.Streams.Stream_Element_Offset (Prefix.Length)));
      pragma Assert (Result.Status = Parsed and then Result.Kind = Handshake);
      pragma Assert (Result.Destination.Length = 20);
      pragma Assert (Result.Source.Length = 20);

      Version_Negotiation (1) := 16#80#;
      Version_Negotiation (6) := 21;
      Version_Negotiation (28) := 21;
      Result := Parse (Version_Negotiation);
      pragma Assert
        (Result.Status = Parsed
         and then Result.Kind = Long_Header_Policy.Version_Negotiation
         and then Result.Destination.Length = 21
         and then Result.Source.Length = 21);

      Unknown (1) := 16#80#;
      Unknown (5) := 2;
      Unknown (6) := 21;
      Unknown (28) := 21;
      Result := Parse (Unknown);
      pragma Assert
        (Result.Status = Parsed
         and then Result.Kind = Unsupported_Version
         and then Result.Version = 2);
   end Check_Boundaries;
begin
   Check_Client_Initial;
   Check_Server_Initial;
   Check_Arbitrary_Lower_Bound;
   Check_Truncation;
   Check_Boundaries;

   pragma Assert (Parse ((1 => 16#40#)).Status = Not_Long_Header);
   pragma Assert
     (Parse ((16#80#, 0, 0, 0, 1)).Status = Invalid_V1_Fixed_Bit);
   pragma Assert
     (Parse ((16#C0#, 0, 0, 0, 1, 21)).Status =
        Invalid_V1_Connection_ID_Length);
   pragma Assert
     (Parse ((16#C0#, 0, 0, 0, 1, 0, 21)).Status =
        Invalid_V1_Connection_ID_Length);

   declare
      Result : Parse_Result;
   begin
      Result := Parse ((16#D0#, 0, 0, 0, 1, 0, 0));
      pragma Assert (Result.Status = Parsed and then Result.Kind = Zero_RTT);
      Result := Parse ((16#E0#, 0, 0, 0, 1, 0, 0));
      pragma Assert (Result.Status = Parsed and then Result.Kind = Handshake);
      Result := Parse ((16#F0#, 0, 0, 0, 1, 0, 0));
      pragma Assert (Result.Status = Parsed and then Result.Kind = Retry);
   end;
end Flyology.QUIC.Long_Header_Policy.Smoke;
