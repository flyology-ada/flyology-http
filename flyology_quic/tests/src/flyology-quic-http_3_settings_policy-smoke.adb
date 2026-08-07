procedure Flyology.QUIC.HTTP_3_Settings_Policy.Smoke is
   use type Ada.Streams.Stream_Element_Array;
   use type Varint_Policy.Value_Type;

   Defaults : constant Encode_Result := Encode ((others => <>));
begin
   pragma Assert
     (Defaults.Length = 4
      and then Defaults.Data (1 .. 4) = (1, 0, 7, 0));
   declare
      Parsed : constant Decode_Result := Decode (Defaults.Data (1 .. 4));
   begin
      pragma Assert
        (Parsed.Status = Decoded
         and then Parsed.Count = 2
         and then Parsed.Value.QPACK_Table_Capacity = 0
         and then Parsed.Value.QPACK_Blocked = 0
         and then not Parsed.Value.Has_Max_Field_Size);
   end;

   declare
      Values : constant Settings :=
        (QPACK_Table_Capacity => 4_096,
         QPACK_Blocked        => 16,
         Has_Max_Field_Size   => True,
         Max_Field_Size       => 65_536);
      Wire   : constant Encode_Result := Encode (Values);
      Parsed : constant Decode_Result :=
        Decode (Wire.Data (1 .. Ada.Streams.Stream_Element_Offset (Wire.Length)));
   begin
      pragma Assert
        (Parsed.Status = Decoded
         and then Parsed.Count = 3
         and then Parsed.Value = Values);
   end;

   pragma Assert
     (Decode ((16#21#, 9)).Status = Decoded);
   pragma Assert
     (Decode ((1, 0, 1, 1)).Status = Duplicate_Identifier);
   pragma Assert
     (Decode ((2, 0)).Status = Forbidden_Identifier);
   pragma Assert
     (Decode ((1 => 1)).Status = Truncated);
end Flyology.QUIC.HTTP_3_Settings_Policy.Smoke;
