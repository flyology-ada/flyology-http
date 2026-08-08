with Flyology.QUIC.Initial_Frame_Policy;

procedure Flyology.QUIC.ACK_Frame_Policy.Smoke is
   use type Ada.Streams.Stream_Element_Array;
   use type ACK_Range_Policy.ACK_Range;
   use type ACK_Range_Policy.Decode_Status;
   use type Initial_Frame_Policy.Parse_Status;

   Item        : Connection_State_Policy.Connection_State;
   Disposition : Connection_State_Policy.Receive_Disposition;
   Encoded_ACK : Encode_Result;
begin
   Connection_State_Policy.Reset (Item);
   pragma Assert (Encode (Item, 0).Status = Nothing_To_ACK);

   Connection_State_Policy.Record_Received (Item, 10, Disposition);
   Connection_State_Policy.Record_Received (Item, 9, Disposition);
   Connection_State_Policy.Record_Received (Item, 7, Disposition);
   Connection_State_Policy.Record_Received (Item, 3, Disposition);
   Encoded_ACK := Encode (Item, 5);
   pragma Assert
     (Encoded_ACK.Status = Encoded
      and then Encoded_ACK.Length = 9
      and then Encoded_ACK.Data (1 .. 9) =
        (16#02#, 16#0A#, 16#05#, 16#02#, 16#01#,
         16#00#, 16#00#, 16#02#, 16#00#));

   declare
      Frame : constant Initial_Frame_Policy.Parse_Result :=
        Initial_Frame_Policy.Parse_Next
          (Encoded_ACK.Data
             (1 .. Ada.Streams.Stream_Element_Offset (Encoded_ACK.Length)),
           0);
      Ranges : constant ACK_Range_Policy.Decode_Result :=
        ACK_Range_Policy.Decode
          (Encoded_ACK.Data
             (1 .. Ada.Streams.Stream_Element_Offset (Encoded_ACK.Length)),
           Frame);
   begin
      pragma Assert
        (Frame.Status = Initial_Frame_Policy.Parsed
         and then Ranges.Status = ACK_Range_Policy.Decoded
         and then Ranges.Count = 3
         and then Ranges.Ranges (1) = (Smallest => 9, Largest => 10)
         and then Ranges.Ranges (2) = (Smallest => 7, Largest => 7)
         and then Ranges.Ranges (3) = (Smallest => 3, Largest => 3));
   end;
end Flyology.QUIC.ACK_Frame_Policy.Smoke;
