with Ada.Streams;
with Interfaces;

--  Proved QUIC variable-length integer encoding policy.
--
--  The wire representation follows RFC 9000 Section 16. Decode accepts every
--  permitted width, including values encoded in more bytes than necessary;
--  Encode always selects the shortest representation.
package Flyology.QUIC.Varint_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Interfaces.Unsigned_64;

   --  Integer range representable by the QUIC wire format.
   subtype Value_Type is Interfaces.Unsigned_64 range 0 .. 2**62 - 1;

   --  Permitted encoded widths, in octets.
   subtype Encoded_Length is Positive range 1 .. 8;

   --  A shortest-form encoded value in a fixed-capacity buffer.
   --  @field Data Encoded octets; only the prefix selected by Length is used
   --  @field Length Number of encoded octets in Data
   type Encoded_Value is record
      Data   : Ada.Streams.Stream_Element_Array (1 .. 8) := (others => 0);
      Length : Encoded_Length := 1;
   end record;

   --  Outcome of decoding a variable-length integer.
   --  @enum Decoded A complete value was decoded
   --  @enum Truncated The input does not contain the width selected by its
   --     first two bits
   type Decode_Status is (Decoded, Truncated);

   --  Result of decoding one integer from the start of an octet array.
   --  @field Status Whether a complete integer was available
   --  @field Value Decoded integer, or zero when Status is Truncated
   --  @field Consumed Number of input octets consumed, or zero on truncation
   type Decode_Result is record
      Status   : Decode_Status := Truncated;
      Value    : Value_Type := 0;
      Consumed : Natural range 0 .. 8 := 0;
   end record;

   --  Return the shortest permitted wire width for a value.
   --  @param Value Integer to size
   --  @return One, two, four, or eight octets
   function Required_Length (Value : Value_Type) return Encoded_Length
   with
     Global => null,
     Post => Required_Length'Result in 1 | 2 | 4 | 8;

   --  Encode a value using its shortest permitted wire width.
   --  @param Value Integer to encode
   --  @return Fixed-capacity buffer and the length of its encoded prefix
   function Encode (Value : Value_Type) return Encoded_Value
   with
     Global => null,
     Post =>
       Encode'Result.Length = Required_Length (Value)
       and then Encode'Result.Length in 1 | 2 | 4 | 8;

   --  Decode one integer from the start of an octet array.
   --  @param Data Input whose first two bits select the encoded width
   --  @return Decoded value and consumed width, or Truncated with no bytes
   --     consumed
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
