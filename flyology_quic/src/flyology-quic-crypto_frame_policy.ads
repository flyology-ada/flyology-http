with Ada.Streams;
with Flyology.QUIC.Varint_Policy;

--  Internal, proved encoder for QUIC CRYPTO frames.
--
--  The bounded result is suitable at Initial and Handshake encryption levels.
--  Stream offset plus data length is restricted to the QUIC varint domain.
private package Flyology.QUIC.Crypto_Frame_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   Max_Frame_Length : constant := 65_535;
   Max_Data_Length  : constant := Max_Frame_Length - 17;

   type Encode_Status is (Encoded, Stream_Offset_Too_Large);

   subtype Encoded_Length is Natural range 0 .. Max_Frame_Length;

   type Encode_Result is record
      Status : Encode_Status := Stream_Offset_Too_Large;
      Data   : Ada.Streams.Stream_Element_Array (1 .. Max_Frame_Length) :=
        (others => 0);
      Length : Encoded_Length := 0;
   end record;

   function Encode
     (Offset : Varint_Policy.Value_Type;
      Data   : Ada.Streams.Stream_Element_Array) return Encode_Result
   with
     Global => null,
     Pre => Data'Length <= Max_Data_Length,
     Post =>
       (if Encode'Result.Status = Encoded then
           Encode'Result.Length =
             1
             + Varint_Policy.Required_Length (Offset)
             + Varint_Policy.Required_Length
                 (Varint_Policy.Value_Type (Data'Length))
             + Natural (Data'Length));
end Flyology.QUIC.Crypto_Frame_Policy;
