procedure Flyology.QUIC.Application_Frame_Policy.Smoke is
   use type Varint_Policy.Value_Type;

   function Hex (Value : String) return Ada.Streams.Stream_Element_Array is
      function Nibble (Item : Character) return Natural is
        (case Item is
            when '0' .. '9' => Character'Pos (Item) - Character'Pos ('0'),
            when 'a' .. 'f' => Character'Pos (Item) - Character'Pos ('a') + 10,
            when 'A' .. 'F' => Character'Pos (Item) - Character'Pos ('A') + 10,
            when others => raise Constraint_Error);
      Result : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Value'Length / 2));
      Source : Positive := Value'First;
   begin
      pragma Assert (Value'Length mod 2 = 0);
      for Item of Result loop
         Item := Ada.Streams.Stream_Element
           (16 * Nibble (Value (Source)) + Nibble (Value (Source + 1)));
         Source := Source + 2;
      end loop;
      return Result;
   end Hex;

   procedure Check
     (Wire     : Ada.Streams.Stream_Element_Array;
      Expected : Frame_Kind)
   is
      Parsed : constant Parse_Result := Parse_Next (Wire, 0);
   begin
      pragma Assert
        (Parsed.Status = Application_Frame_Policy.Parsed
         and then Parsed.Kind = Expected
         and then Parsed.Consumed = Wire'Length);
   end Check;

   Parsed : Parse_Result;
begin
   Check (Hex ("0000"), Padding);
   Check (Hex ("01"), Ping);
   Check (Hex ("0200000000"), Acknowledgment);
   Check (Hex ("04000a40ff"), Reset_Stream);
   Check (Hex ("05000a"), Stop_Sending);
   Check (Hex ("060001aa"), Crypto);
   Check (Hex ("0703616263"), New_Token);
   Check (Hex ("0a0003616263"), Stream);
   Check (Hex ("104064"), Max_Data);
   Check (Hex ("11004064"), Max_Stream_Data);
   Check (Hex ("1205"), Max_Streams_Bidi);
   Check (Hex ("1305"), Max_Streams_Uni);
   Check (Hex ("144064"), Data_Blocked);
   Check (Hex ("15004064"), Stream_Data_Blocked);
   Check (Hex ("1605"), Streams_Blocked_Bidi);
   Check (Hex ("1705"), Streams_Blocked_Uni);
   Check
     (Hex ("1800000401020304000102030405060708090a0b0c0d0e0f"),
      New_Connection_ID);
   Check (Hex ("1900"), Retire_Connection_ID);
   Check (Hex ("1a0001020304050607"), Path_Challenge);
   Check (Hex ("1b0001020304050607"), Path_Response);
   Check (Hex ("1c000000"), Transport_Close);
   Check (Hex ("1d0003627965"), Application_Close);
   Check (Hex ("1e"), Handshake_Done);

   Parsed := Parse_Next (Hex ("0a0003616263"), 0);
   pragma Assert
     (Parsed.Stream_ID = 0
      and then Parsed.Stream_Frame.Data_Length = 3
      and then Parsed.Stream_Data_Offset = 3);
   Parsed := Parse_Next (Hex ("1800000401020304000102030405060708090a0b0c0d0e0f"), 0);
   pragma Assert
     (Parsed.Sequence = 0 and then Parsed.Retire_Prior_To = 0
      and then Parsed.CID_Length = 4 and then Parsed.CID_Offset = 4
      and then Parsed.Reset_Token_Offset = 8);

   pragma Assert (Parse_Next ((1 .. 0 => 0), 0).Status = End_Of_Input);
   pragma Assert (Parse_Next (Hex ("10"), 0).Status = Truncated);
   pragma Assert (Parse_Next (Hex ("20"), 0).Status = Unknown_Frame_Type);
   pragma Assert
     (Parse_Next (Hex ("1800010401020304000102030405060708090a0b0c0d0e0f"), 0).Status =
        Invalid_Connection_ID);
   pragma Assert
     (Parse_Next (Hex ("18000000"), 0).Status = Invalid_Connection_ID);
end Flyology.QUIC.Application_Frame_Policy.Smoke;
