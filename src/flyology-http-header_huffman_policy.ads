with Ada.Streams;

--  Internal, proved decoder for the HPACK and QPACK static Huffman alphabet.
--
--  RFC 7541 and RFC 9204 use the same 257-symbol prefix code. The decoder is
--  bounded for HTTP field values and rejects EOS, malformed paths, excessive
--  output, and padding other than a prefix of the all-ones EOS code.
private package Flyology.HTTP.Header_Huffman_Policy
  with SPARK_Mode => On
is
   Max_Encoded_Length : constant := 65_535;
   Max_Output_Length  : constant := 4_096;

   subtype Output_Length is Natural range 0 .. Max_Output_Length;

   type Decode_Status is
     (Decoded,
      Invalid_Code,
      EOS_Symbol,
      Invalid_Padding,
      Output_Too_Large);

   type Decode_Result is record
      Status : Decode_Status := Invalid_Code;
      Data   : String (1 .. Max_Output_Length) :=
        (others => Character'Val (0));
      Length : Output_Length := 0;
   end record;

   function Decode
     (Value   : Ada.Streams.Stream_Element_Array;
      Maximum : Output_Length) return Decode_Result
   with
     Global => null,
     Pre => Value'Length <= Max_Encoded_Length,
     Post => Decode'Result.Length <= Maximum;
end Flyology.HTTP.Header_Huffman_Policy;
