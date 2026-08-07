procedure Flyology.HTTP.QPACK_Integer_Policy.Smoke is
   use type Ada.Streams.Stream_Element_Array;

   Small : constant Encode_Result := Encode (10, 5, 0);
   Wide  : constant Encode_Result := Encode (1_337, 5, 0);
   Index : constant Encode_Result := Encode (17, 6, 16#C0#);
begin
   pragma Assert
     (Small.Length = 1 and then Small.Data (1) = 16#0A#);
   pragma Assert
     (Wide.Length = 3
      and then Wide.Data (1 .. 3) = (16#1F#, 16#9A#, 16#0A#));
   pragma Assert
     (Index.Length = 1 and then Index.Data (1) = 16#D1#);

   pragma Assert
     (Decode (Wide.Data (1 .. 3), 5).Status = Decoded
      and then Decode (Wide.Data (1 .. 3), 5).Value = 1_337
      and then Decode (Wide.Data (1 .. 3), 5).Consumed = 3);
   pragma Assert
     (Decode (Index.Data (1 .. 1), 6).Value = 17);
   pragma Assert
     (Decode (Ada.Streams.Stream_Element_Array'(1 .. 0 => 0), 5).Status =
        Truncated);
   pragma Assert
     (Decode ((1 => 16#1F#), 5).Status = Truncated);
   pragma Assert
     (Decode ((16#1F#, 16#FF#, 16#FF#, 16#7F#), 5).Status =
        Value_Too_Large);
end Flyology.HTTP.QPACK_Integer_Policy.Smoke;
