with Ada.Streams;
with Flyology.QUIC.Long_Header_Policy;
with Interfaces;

--  Internal, proved QUIC v1 Initial packet envelope policy.
--
--  Offsets are zero-based from the first element of the supplied datagram.
--  The parser locates the token, Length field, protected packet number, and
--  end of one Initial packet without interpreting protected header bits.
--  A protected length below 20 cannot provide the 16-byte header-protection
--  sample that begins four bytes after the packet-number field.
private package Flyology.QUIC.Initial_Packet_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Interfaces.Unsigned_32;
   use type Long_Header_Policy.Packet_Kind;
   use type Long_Header_Policy.Parse_Status;

   subtype Datagram_Offset is Natural range 0 .. 65_535;
   subtype Varint_Bytes is Natural range 0 .. 8;

   type Parse_Status is
     (Parsed,
      Truncated,
      Not_V1_Initial,
      Invalid_Long_Header,
      Token_Length_Too_Large,
      Packet_Length_Too_Large,
      Insufficient_Protected_Payload);

   type Parse_Result is record
      Status               : Parse_Status := Truncated;
      Header               : Long_Header_Policy.Parse_Result;
      Token_Length_Bytes   : Varint_Bytes := 0;
      Token_Offset         : Datagram_Offset := 0;
      Token_Length         : Datagram_Offset := 0;
      Length_Offset        : Datagram_Offset := 0;
      Length_Bytes         : Varint_Bytes := 0;
      Packet_Number_Offset : Datagram_Offset := 0;
      Protected_Length     : Datagram_Offset := 0;
      Consumed             : Datagram_Offset := 0;
   end record;

   function Parse
     (Data : Ada.Streams.Stream_Element_Array) return Parse_Result
   with
     Global => null,
     Post =>
       (if Parse'Result.Status = Parsed then
           Parse'Result.Header.Status = Long_Header_Policy.Parsed
           and then Parse'Result.Header.Kind = Long_Header_Policy.Initial
           and then
             Parse'Result.Header.Version = Long_Header_Policy.Version_1
           and then Parse'Result.Token_Length_Bytes in 1 | 2 | 4 | 8
           and then Parse'Result.Length_Bytes in 1 | 2 | 4 | 8
           and then Parse'Result.Token_Offset =
             Parse'Result.Header.Consumed
             + Parse'Result.Token_Length_Bytes
           and then Parse'Result.Length_Offset =
             Parse'Result.Token_Offset + Parse'Result.Token_Length
           and then Parse'Result.Packet_Number_Offset =
             Parse'Result.Length_Offset + Parse'Result.Length_Bytes
           and then Parse'Result.Protected_Length >= 20
           and then Parse'Result.Consumed =
             Parse'Result.Packet_Number_Offset
             + Parse'Result.Protected_Length
           and then
             (Data'Length > 65_535
              or else Parse'Result.Consumed <= Natural (Data'Length)));
end Flyology.QUIC.Initial_Packet_Policy;
