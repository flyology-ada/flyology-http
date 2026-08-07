with Flyology.QUIC.Initial_Frame_Policy;

procedure Flyology.QUIC.Crypto_Frame_Policy.Smoke is
   use type Ada.Streams.Stream_Element_Array;
   use type Ada.Streams.Stream_Element_Offset;
   use type Initial_Frame_Policy.Frame_Kind;
   use type Initial_Frame_Policy.Parse_Status;
   use type Varint_Policy.Value_Type;

   Small : constant Encode_Result :=
     Encode (0, (16#01#, 16#02#, 16#03#));
begin
   pragma Assert
     (Small.Status = Encoded
      and then Small.Length = 6
      and then Small.Data (1 .. 6) =
        (16#06#, 0, 3, 16#01#, 16#02#, 16#03#));
   declare
      Parsed : constant Initial_Frame_Policy.Parse_Result :=
        Initial_Frame_Policy.Parse_Next
          (Small.Data
             (1 .. Ada.Streams.Stream_Element_Offset (Small.Length)),
           0);
   begin
      pragma Assert
        (Parsed.Status = Initial_Frame_Policy.Parsed
         and then Parsed.Kind = Initial_Frame_Policy.Crypto
         and then Parsed.Crypto_Offset = 0
         and then Parsed.Crypto_Length = 3
         and then Parsed.Crypto_Data_Offset = 3);
   end;

   declare
      Data : constant Ada.Streams.Stream_Element_Array (1 .. 64) :=
        (others => 16#A5#);
      Wide : constant Encode_Result := Encode (64, Data);
      Parsed : constant Initial_Frame_Policy.Parse_Result :=
        Initial_Frame_Policy.Parse_Next
          (Wide.Data
             (1 .. Ada.Streams.Stream_Element_Offset (Wide.Length)),
           0);
   begin
      pragma Assert
        (Wide.Status = Encoded
         and then Wide.Length = 69
         and then Wide.Data (1 .. 5) =
           (16#06#, 16#40#, 16#40#, 16#40#, 16#40#)
         and then Parsed.Status = Initial_Frame_Policy.Parsed
         and then Parsed.Crypto_Offset = 64
         and then Parsed.Crypto_Length = 64);
   end;

   declare
      Rejected : constant Encode_Result :=
        Encode
          (Varint_Policy.Value_Type'Last,
           Ada.Streams.Stream_Element_Array'(1 => 1));
   begin
      pragma Assert
        (Rejected.Status = Stream_Offset_Too_Large
         and then Rejected.Length = 0
         and then Rejected.Data = (Rejected.Data'Range => 0));
   end;
end Flyology.QUIC.Crypto_Frame_Policy.Smoke;
