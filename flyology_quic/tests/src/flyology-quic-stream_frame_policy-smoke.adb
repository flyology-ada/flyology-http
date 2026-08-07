procedure Flyology.QUIC.Stream_Frame_Policy.Smoke is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Array;
   use type Varint_Policy.Value_Type;

   Data : constant Ada.Streams.Stream_Element_Array :=
     (16#48#, 16#33#);
   First : constant Encode_Result := Encode (0, 0, False, Data);
begin
   pragma Assert
     (First.Status = Encoded
      and then First.Length = 5
      and then First.Data (1 .. 5) =
        (16#0A#, 0, 2, 16#48#, 16#33#));
   declare
      Parsed : constant Parse_Result := Parse (First.Data (1 .. 5));
   begin
      pragma Assert
        (Parsed.Status = Stream_Frame_Policy.Parsed
         and then Parsed.Stream_ID = 0
         and then Parsed.Stream_Offset = 0
         and then Parsed.Data_Offset = 3
         and then Parsed.Data_Length = 2
         and then not Parsed.Fin
         and then Parsed.Consumed = Frame_Offset (First.Length));
   end;

   declare
      Wide : constant Encode_Result := Encode (65, 64, True, Data);
      Parsed : constant Parse_Result :=
        Parse
          (Wide.Data
             (1 .. Ada.Streams.Stream_Element_Offset (Wide.Length)));
   begin
      pragma Assert
        (Wide.Status = Encoded
         and then Wide.Data (1) = 16#0F#
         and then Parsed.Status = Stream_Frame_Policy.Parsed
         and then Parsed.Stream_ID = 65
         and then Parsed.Stream_Offset = 64
         and then Parsed.Data_Length = 2
         and then Parsed.Fin);
   end;

   declare
      Without_Length : constant Ada.Streams.Stream_Element_Array :=
        (16#08#, 4, 16#AA#, 16#BB#, 16#CC#);
      Parsed : constant Parse_Result := Parse (Without_Length);
   begin
      pragma Assert
        (Parsed.Status = Stream_Frame_Policy.Parsed
         and then Parsed.Stream_ID = 4
         and then Parsed.Data_Offset = 2
         and then Parsed.Data_Length = 3
         and then Parsed.Consumed = Without_Length'Length);
   end;

   pragma Assert (Parse ((1 => 16#01#)).Status = Not_Stream_Frame);
   pragma Assert (Parse ((16#0E#, 0)).Status = Truncated);
   pragma Assert (Parse ((16#0A#, 0, 3, 1, 2)).Status = Truncated);
   declare
      Rejected : constant Encode_Result :=
        Encode
          (0, Varint_Policy.Value_Type'Last, False,
           Ada.Streams.Stream_Element_Array'(1 => 1));
   begin
      pragma Assert
        (Rejected.Status = Stream_Range_Too_Large
         and then Rejected.Length = 0);
   end;
end Flyology.QUIC.Stream_Frame_Policy.Smoke;
