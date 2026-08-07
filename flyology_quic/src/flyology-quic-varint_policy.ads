with Ada.Streams;
with Interfaces;

--  Internal, proved QUIC variable-length integer encoding policy.
--
--  The wire representation follows RFC 9000 Section 16. Decode accepts every
--  permitted width, including values encoded in more bytes than necessary;
--  Encode always selects the shortest representation.
private package Flyology.QUIC.Varint_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Interfaces.Unsigned_64;

   subtype Value_Type is Interfaces.Unsigned_64 range 0 .. 2**62 - 1;
   subtype Encoded_Length is Positive range 1 .. 8;

   type Encoded_Value is record
      Data   : Ada.Streams.Stream_Element_Array (1 .. 8) := (others => 0);
      Length : Encoded_Length := 1;
   end record;

   type Decode_Status is (Decoded, Truncated);

   type Decode_Result is record
      Status   : Decode_Status := Truncated;
      Value    : Value_Type := 0;
      Consumed : Natural range 0 .. 8 := 0;
   end record;

   function Required_Length (Value : Value_Type) return Encoded_Length
   with
     Global => null,
     Post => Required_Length'Result in 1 | 2 | 4 | 8;

   function Encode (Value : Value_Type) return Encoded_Value
   with
     Global => null,
     Post =>
       Encode'Result.Length = Required_Length (Value)
       and then Encode'Result.Length in 1 | 2 | 4 | 8;

   function Decode
     (Data : Ada.Streams.Stream_Element_Array) return Decode_Result
   with
     Global => null,
     Post =>
       (if Decode'Result.Status = Decoded then
           Decode'Result.Consumed in 1 | 2 | 4 | 8
           and then
             (case Decode'Result.Consumed is
                 when 1 => Data'Length >= 1,
                 when 2 => Data'Length >= 2,
                 when 4 => Data'Length >= 4,
                 when 8 => Data'Length >= 8,
                 when others => False)
        else
           Decode'Result.Consumed = 0
           and then Decode'Result.Value = 0);
end Flyology.QUIC.Varint_Policy;
