with Ada.Streams;

--  Internal, bounded QPACK field-section codec.
--
--  This initial profile uses the RFC 9204 static table and literal fields. A
--  zero Required Insert Count deliberately excludes dynamic-table references.
--  Huffman strings are identified separately so a caller can report the
--  required QPACK decompression error until Huffman decoding is enabled.
private package Flyology.HTTP.QPACK_Field_Section_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element_Offset;

   Max_Name_Length    : constant := 256;
   Max_Value_Length   : constant := 16 * 1_024;
   Max_Fields         : constant := 32;
   Max_Encoded_Length : constant := 65_535;
   --  Encoded field sections are immediately wrapped in a bounded HTTP/3
   --  frame.  Decoding retains the full protocol bound, but send results only
   --  need room for the largest useful single-datagram field section.
   Max_Encode_Length  : constant := 1_109;

   subtype Name_Length is Natural range 0 .. Max_Name_Length;
   subtype Value_Length is Natural range 0 .. Max_Value_Length;
   subtype Field_Count is Natural range 0 .. Max_Fields;

   type Header_Field is record
      Name_Size  : Name_Length := 0;
      Name       : String (1 .. Max_Name_Length) :=
        (others => Character'Val (0));
      Value_Size : Value_Length := 0;
      Value      : String (1 .. Max_Value_Length) :=
        (others => Character'Val (0));
   end record;

   function Make_Field (Name, Value : String) return Header_Field
   with
     Global => null,
     Pre => Name'Length in 1 .. Max_Name_Length
       and then Value'Length <= Max_Value_Length,
     Post => Make_Field'Result.Name_Size = Name'Length
       and then Make_Field'Result.Value_Size = Value'Length;

   function Field_Name (Item : Header_Field) return String
   with Global => null,
        Post => Field_Name'Result'Length = Item.Name_Size;

   function Field_Value (Item : Header_Field) return String
   with Global => null,
        Post => Field_Value'Result'Length = Item.Value_Size;

   type Header_Field_Array is
     array (Positive range 1 .. Max_Fields) of Header_Field;

   type Header_Block is record
      Count  : Field_Count := 0;
      Fields : Header_Field_Array;
   end record;

   Max_Field_Section_Size : constant :=
     Max_Fields * (Max_Name_Length + Max_Value_Length + 32);
   subtype Field_Section_Size_Type is Natural range
     0 .. Max_Field_Section_Size;

   function Field_Section_Size
     (Block : Header_Block) return Field_Section_Size_Type
   with Global => null;

   type Decode_Status is
     (Decoded,
      Truncated,
      Invalid_Prefix,
      Unsupported_Dynamic,
      Invalid_Huffman,
      Invalid_Static_Index,
      Too_Many_Fields,
      Field_Too_Large);

   type Decode_Result is record
      Status   : Decode_Status := Truncated;
      Block    : Header_Block;
      Consumed : Natural range 0 .. Max_Encoded_Length := 0;
   end record;

   subtype Decode_Length is Natural range 0 .. Max_Encoded_Length;

   procedure Decode_Into
     (Data     : Ada.Streams.Stream_Element_Array;
      Block    : in out Header_Block;
      Status   : out Decode_Status;
      Consumed : out Decode_Length)
   with
     Global => null,
     Pre => Data'Length <= Max_Encoded_Length,
     Post =>
       (if Status = Decoded then Consumed = Data'Length else Consumed = 0);

   function Decode
     (Data : Ada.Streams.Stream_Element_Array) return Decode_Result
   with
     Global => null,
     Pre => Data'Length <= Max_Encoded_Length;

   type Encode_Status is (Encoded, Section_Too_Large);

   type Encode_Result is record
      Status : Encode_Status := Encoded;
      Data   : Ada.Streams.Stream_Element_Array (1 .. Max_Encode_Length) :=
        (others => 0);
      Length : Natural range 0 .. Max_Encode_Length := 0;
   end record;

   function Encode (Block : Header_Block) return Encode_Result
   with
     Global => null,
     Post =>
       (if Encode'Result.Status = Encoded then Encode'Result.Length >= 2);
end Flyology.HTTP.QPACK_Field_Section_Policy;
