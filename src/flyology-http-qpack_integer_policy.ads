with Ada.Streams;

--  Internal, proved QPACK prefixed-integer codec.
--
--  QPACK uses the HPACK-style integer representation whose prefix shares the
--  first octet with representation flags. This is distinct from QUIC varints.
private package Flyology.HTTP.QPACK_Integer_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;

   Max_Input_Length : constant := 65_535;
   Max_Value        : constant := 65_535;

   subtype Prefix_Size is Positive range 1 .. 8;
   subtype Value_Type is Natural range 0 .. Max_Value;

   function Prefix_Mask (Bits : Prefix_Size) return Ada.Streams.Stream_Element is
     (case Bits is
         when 1 => 16#01#,
         when 2 => 16#03#,
         when 3 => 16#07#,
         when 4 => 16#0F#,
         when 5 => 16#1F#,
         when 6 => 16#3F#,
         when 7 => 16#7F#,
         when 8 => 16#FF#)
   with Global => null;

   type Decode_Status is (Decoded, Truncated, Value_Too_Large);

   type Decode_Result is record
      Status   : Decode_Status := Truncated;
      Value    : Value_Type := 0;
      Consumed : Natural range 0 .. 4 := 0;
   end record;

   function Decode
     (Data : Ada.Streams.Stream_Element_Array;
      Bits : Prefix_Size) return Decode_Result
   with
     Global => null,
     Pre => Data'Length <= Max_Input_Length,
     Post =>
       (if Decode'Result.Status = Decoded then
           Decode'Result.Consumed in 1 .. 4
           and then Decode'Result.Consumed <= Data'Length);

   type Encode_Result is record
      Data   : Ada.Streams.Stream_Element_Array (1 .. 4) := (others => 0);
      Length : Natural range 1 .. 4 := 1;
   end record;

   function Encode
     (Value     : Value_Type;
      Bits      : Prefix_Size;
      High_Bits : Ada.Streams.Stream_Element) return Encode_Result
   with
     Global => null,
     Pre => (High_Bits and Prefix_Mask (Bits)) = 0,
     Post => Encode'Result.Length in 1 .. 4;
end Flyology.HTTP.QPACK_Integer_Policy;
