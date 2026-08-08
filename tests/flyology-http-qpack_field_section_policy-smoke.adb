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
   pragma Assert (Field_Section_Size (Request) = 217);

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

   --  RFC 9204 Appendix B.1, Stream 0: literal field line with a static
   --  name reference. Keep this byte sequence verbatim as a published
   --  decoder oracle rather than regenerating it through our encoder.
   Parsed :=
     Decode
       ((16#00#, 16#00#, 16#51#, 16#0B#,
         16#2F#, 16#69#, 16#6E#, 16#64#, 16#65#, 16#78#,
         16#2E#, 16#68#, 16#74#, 16#6D#, 16#6C#));
   pragma Assert
     (Parsed.Status = Decoded
      and then Parsed.Block.Count = 1
      and then Parsed.Consumed = 15
      and then Field_Name (Parsed.Block.Fields (1)) = ":path"
      and then Field_Value (Parsed.Block.Fields (1)) = "/index.html");

   --  RFC 9204 Appendix B.2 is a published dynamic-table example. The
   --  bounded static-only profile must reject its nonzero Required Insert
   --  Count explicitly, rather than interpreting it as a static section.
   pragma Assert
     (Decode ((16#03#, 16#81#, 16#10#, 16#11#)).Status =
        Unsupported_Dynamic);

   pragma Assert (Decode ((16#01#, 16#00#)).Status = Unsupported_Dynamic);
   pragma Assert (Decode ((16#00#, 16#00#, 16#80#)).Status = Unsupported_Dynamic);
   Parsed :=
     Decode
       ((16#00#, 16#00#, 16#51#, 16#8C#, 16#F1#, 16#E3#,
         16#C2#, 16#E5#, 16#F2#, 16#3A#, 16#6B#, 16#A0#,
         16#AB#, 16#90#, 16#F4#, 16#FF#));
   pragma Assert
     (Parsed.Status = Decoded
      and then Field_Name (Parsed.Block.Fields (1)) = ":path"
      and then Field_Value (Parsed.Block.Fields (1)) = "www.example.com");
   pragma Assert
     (Decode ((16#00#, 16#00#, 16#50#, 16#81#, 16#00#)).Status =
        Invalid_Huffman);
   pragma Assert
     (Decode ((16#00#, 16#00#, 16#FF#, 16#24#)).Status =
        Invalid_Static_Index);
end Flyology.HTTP.QPACK_Field_Section_Policy.Smoke;
