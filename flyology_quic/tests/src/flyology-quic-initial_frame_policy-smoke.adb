procedure Flyology.QUIC.Initial_Frame_Policy.Smoke is
   use type Ada.Streams.Stream_Element_Array;
   use type Varint_Policy.Value_Type;

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

   procedure Check_Status
     (Data     : Ada.Streams.Stream_Element_Array;
      Expected : Parse_Status)
   is
      Result : constant Parse_Result := Parse_Next (Data, 0);
   begin
      pragma Assert (Result.Status = Expected);
   end Check_Status;

   Server_Plaintext : constant Ada.Streams.Stream_Element_Array :=
     Hex
       ("02000000000600405a020000560303ee" &
        "fce7f7b37ba1d1632e96677825ddf739" &
        "88cfc79825df566dc5430b9a045a1200" &
        "130100002e00330024001d00209d3c94" &
        "0d89690b84d08a60993c144eca684d10" &
        "81287c834d5311bcf32bb9da1a002b00" &
        "020304");
begin
   declare
      ACK    : constant Parse_Result := Parse_Next (Server_Plaintext, 0);
      Crypto : constant Parse_Result :=
        Parse_Next (Server_Plaintext, ACK.Consumed);
      Ending : constant Parse_Result :=
        Parse_Next (Server_Plaintext, ACK.Consumed + Crypto.Consumed);
   begin
      pragma Assert (ACK.Status = Parsed and then ACK.Kind = Acknowledgment);
      pragma Assert (ACK.Frame_Type = 2 and then ACK.Consumed = 5);
      pragma Assert
        (ACK.Largest_Acknowledged = 0
         and then ACK.ACK_Delay = 0
         and then ACK.ACK_Range_Count = 0
         and then ACK.First_ACK_Range = 0);
      pragma Assert
        (Crypto.Status = Parsed and then Crypto.Kind = Initial_Frame_Policy.Crypto);
      pragma Assert
        (Crypto.Crypto_Offset = 0
         and then Crypto.Crypto_Length = 90
         and then Crypto.Crypto_Data_Offset = 9
         and then Crypto.Consumed = 94);
      pragma Assert (Ending.Status = End_Of_Input);
   end;

   declare
      Crypto_Frame : constant Ada.Streams.Stream_Element_Array :=
        Hex
          ("060040f1010000ed0303ebf8fa56f129" &
           "39b9584a3896472ec40bb863cfd3e868" &
           "04fe3a47f06a2b69484c000004130113" &
           "02010000c000000010000e00000b6578" &
           "616d706c652e636f6dff01000100000a" &
           "00080006001d00170018001000070005" &
           "04616c706e0005000501000000000033" &
           "00260024001d00209370b2c9caa47fba" &
           "baf4559fedba753de171fa71f50f1ce1" &
           "5d43e994ec74d748002b000302030400" &
           "0d0010000e0403050306030203080408" &
           "050806002d00020101001c0002400100" &
           "3900320408ffffffffffffffff050480" &
           "00ffff07048000ffff08011001048000" &
           "75300901100f088394c8f03e51570806" &
           "048000ffff");
      Client_Plaintext : Ada.Streams.Stream_Element_Array (1 .. 1_162) :=
        (others => 0);
      Crypto : Parse_Result;
      Padding : Parse_Result;
      Ending : Parse_Result;
   begin
      Client_Plaintext (1 .. Crypto_Frame'Length) := Crypto_Frame;
      Crypto := Parse_Next (Client_Plaintext, 0);
      pragma Assert
        (Crypto.Status = Parsed
         and then Crypto.Kind = Initial_Frame_Policy.Crypto
         and then Crypto.Crypto_Offset = 0
         and then Crypto.Crypto_Length = 241
         and then Crypto.Consumed = 245);
      Padding := Parse_Next (Client_Plaintext, Crypto.Consumed);
      pragma Assert
        (Padding.Status = Parsed
         and then Padding.Kind = Initial_Frame_Policy.Padding
         and then Padding.Padding_Length = 917
         and then Padding.Consumed = 917);
      Ending :=
        Parse_Next (Client_Plaintext, Crypto.Consumed + Padding.Consumed);
      pragma Assert (Ending.Status = End_Of_Input);
   end;

   Check_Status ((1 .. 0 => 0), End_Of_Input);
   Check_Status (Hex ("06"), Truncated);
   Check_Status (Hex ("060001"), Truncated);
   Check_Status (Hex ("0200000001"), Invalid_ACK_Range);
   Check_Status (Hex ("02020001000100"), Invalid_ACK_Range);
   Check_Status (Hex ("0200000100"), Truncated);
   Check_Status (Hex ("04"), Frame_Type_Not_Allowed);
   Check_Status
     (Hex ("06ffffffffffffffff0100"), Frame_Value_Too_Large);

   declare
      ACK_ECN : constant Parse_Result :=
        Parse_Next (Hex ("030a000002030405"), 0);
      Close : constant Parse_Result :=
        Parse_Next (Hex ("1c0a0603627965"), 0);
   begin
      pragma Assert
        (ACK_ECN.Status = Parsed
         and then ACK_ECN.Kind = Acknowledgment
         and then ACK_ECN.Largest_Acknowledged = 10
         and then ACK_ECN.First_ACK_Range = 2
         and then ACK_ECN.ACK_Range_Count = 0
         and then ACK_ECN.ECT0_Count = 3
         and then ACK_ECN.ECT1_Count = 4
         and then ACK_ECN.ECN_CE_Count = 5);
      pragma Assert
        (Close.Status = Parsed
         and then Close.Kind = Transport_Close
         and then Close.Close_Error_Code = 10
         and then Close.Close_Frame_Type = 6
         and then Close.Close_Reason_Length = 3
         and then Close.Consumed = 7);
   end;

   declare
      Encoded : constant Transport_Close_Encode_Result :=
        Encode_Transport_Close (16#08#, 16#06#);
      Decoded : constant Parse_Result :=
        Parse_Next
          (Encoded.Data
             (1 .. Ada.Streams.Stream_Element_Offset (Encoded.Length)),
           0);
      Wide : constant Transport_Close_Encode_Result :=
        Encode_Transport_Close (2**32, 2**16);
      Wide_Decoded : constant Parse_Result :=
        Parse_Next
          (Wide.Data
             (1 .. Ada.Streams.Stream_Element_Offset (Wide.Length)), 0);
   begin
      pragma Assert
        (Encoded.Length = 4
         and then Encoded.Data (1 .. 4) = (16#1C#, 16#08#, 16#06#, 0)
         and then Decoded.Status = Parsed
         and then Decoded.Kind = Transport_Close
         and then Decoded.Close_Error_Code = 16#08#
         and then Decoded.Close_Frame_Type = 16#06#
         and then Decoded.Close_Reason_Length = 0);
      pragma Assert
        (Wide.Length = 14
         and then Wide_Decoded.Status = Parsed
         and then Wide_Decoded.Close_Error_Code = 2**32
         and then Wide_Decoded.Close_Frame_Type = 2**16
         and then Wide_Decoded.Close_Reason_Length = 0);
   end;
end Flyology.QUIC.Initial_Frame_Policy.Smoke;
