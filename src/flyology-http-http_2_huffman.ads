with Ada.Streams;

--  Decodes the fixed HPACK Huffman code from RFC 7541 Appendix B.
private package Flyology.HTTP.HTTP_2_Huffman is

   --  Decode Value and reject EOS symbols, invalid codes, invalid padding, or
   --  output exceeding Maximum.
   function Decode
     (Value   : Ada.Streams.Stream_Element_Array;
      Maximum : Natural) return String;

end Flyology.HTTP.HTTP_2_Huffman;
