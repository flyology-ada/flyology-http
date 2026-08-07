procedure Flyology.HTTP.QPACK_Field_Section_Policy.Smoke is
   use type Ada.Streams.Stream_Element_Array;

   Request : Header_Block;
   Wire    : Encode_Result;
   Parsed  : Decode_Result;
begin
   Request.Count := 5;
   Request.Fields (1) := Make_Field (":method", "GET");
   Request.Fields (2) := Make_Field (":scheme", "https");
   Request.Fields (3) := Make_Field (":path", "/");
   Request.Fields (4) := Make_Field (":authority", "example.com");
   Request.Fields (5) := Make_Field ("x-test", "ok");

   Wire := Encode (Request);
   pragma Assert (Wire.Status = Encoded);
   pragma Assert
     (Wire.Data (1 .. 5) = (16#00#, 16#00#, 16#D1#, 16#D7#, 16#C1#));
   Parsed := Decode (Wire.Data (1 .. Ada.Streams.Stream_Element_Offset (Wire.Length)));
   pragma Assert (Parsed.Status = Decoded and then Parsed.Block.Count = 5);
   pragma Assert
     (Field_Name (Parsed.Block.Fields (1)) = ":method"
      and then Field_Value (Parsed.Block.Fields (1)) = "GET");
   pragma Assert
     (Field_Name (Parsed.Block.Fields (4)) = ":authority"
      and then Field_Value (Parsed.Block.Fields (4)) = "example.com");
   pragma Assert
     (Field_Name (Parsed.Block.Fields (5)) = "x-test"
      and then Field_Value (Parsed.Block.Fields (5)) = "ok");

   Parsed :=
     Decode
       ((16#00#, 16#00#, 16#51#, 16#0B#,
         16#2F#, 16#69#, 16#6E#, 16#64#, 16#65#, 16#78#,
         16#2E#, 16#68#, 16#74#, 16#6D#, 16#6C#));
   pragma Assert
     (Parsed.Status = Decoded
      and then Parsed.Block.Count = 1
      and then Field_Name (Parsed.Block.Fields (1)) = ":path"
      and then Field_Value (Parsed.Block.Fields (1)) = "/index.html");

   pragma Assert (Decode ((16#01#, 16#00#)).Status = Unsupported_Dynamic);
   pragma Assert (Decode ((16#00#, 16#00#, 16#80#)).Status = Unsupported_Dynamic);
   pragma Assert
     (Decode ((16#00#, 16#00#, 16#50#, 16#80#)).Status =
        Unsupported_Huffman);
   pragma Assert
     (Decode ((16#00#, 16#00#, 16#FF#, 16#24#)).Status =
        Invalid_Static_Index);
end Flyology.HTTP.QPACK_Field_Section_Policy.Smoke;
