procedure Flyology.QUIC.HTTP_3_Frame_Policy.Smoke is
   use type Ada.Streams.Stream_Element_Array;
   use type Varint_Policy.Value_Type;

   Payload : constant Ada.Streams.Stream_Element_Array :=
     (16#48#, 16#33#);
   Frame : constant Encode_Result := Encode (Headers_Frame, Payload);
begin
   pragma Assert
     (Frame.Length = 4
      and then Frame.Data (1 .. 4) =
        (16#01#, 2, 16#48#, 16#33#));
   declare
      Decoded : constant Parse_Result := Parse (Frame.Data (1 .. 4));
   begin
      pragma Assert
        (Decoded.Status = Parsed
         and then Decoded.Frame_Type = Headers_Frame
         and then Decoded.Payload_Offset = 2
         and then Decoded.Payload_Length = 2
         and then Decoded.Consumed = 4);
   end;

   declare
      Unknown : constant Ada.Streams.Stream_Element_Array :=
        (16#40#, 16#21#, 0);
      Decoded : constant Parse_Result := Parse (Unknown);
   begin
      pragma Assert
        (Decoded.Status = Parsed
         and then Decoded.Frame_Type = 16#21#
         and then Decoded.Payload_Length = 0
         and then Decoded.Consumed = Unknown'Length);
   end;

   pragma Assert (Parse ((1 => 4)).Status = Truncated);
   pragma Assert (Parse ((4, 2, 1)).Status = Truncated);
   pragma Assert
     (Parse ((16#04#, 16#80#, 16#01#, 16#00#, 16#00#)).Status =
        Frame_Length_Too_Large);
end Flyology.QUIC.HTTP_3_Frame_Policy.Smoke;
