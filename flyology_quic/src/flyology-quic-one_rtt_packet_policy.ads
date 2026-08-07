with Ada.Streams;
with Flyology.QUIC.Long_Header_Policy;

--  Internal, proved QUIC v1 1-RTT packet envelope policy.
--
--  The destination connection-ID length comes from connection state because
--  it is not encoded in a short header. A 1-RTT packet consumes the remainder
--  of its datagram and therefore cannot precede another coalesced packet.
private package Flyology.QUIC.One_RTT_Packet_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element;

   subtype Datagram_Offset is Natural range 0 .. 65_535;

   type Parse_Status is
     (Parsed,
      Truncated,
      Not_Short_Header,
      Invalid_Fixed_Bit,
      Packet_Too_Large,
      Insufficient_Protected_Payload);

   type Parse_Result is record
      Status               : Parse_Status := Truncated;
      First_Byte           : Ada.Streams.Stream_Element := 0;
      Destination          : Long_Header_Policy.Connection_ID;
      Packet_Number_Offset : Datagram_Offset := 0;
      Protected_Length     : Datagram_Offset := 0;
      Consumed             : Datagram_Offset := 0;
   end record;

   function Parse
     (Data               : Ada.Streams.Stream_Element_Array;
      Destination_Length : Long_Header_Policy.V1_Connection_ID_Length)
      return Parse_Result
   with
     Global => null,
     Post =>
       (if Parse'Result.Status = Parsed then
           (Parse'Result.First_Byte and 16#80#) = 0
           and then (Parse'Result.First_Byte and 16#40#) /= 0
           and then Parse'Result.Destination.Length = Destination_Length
           and then Parse'Result.Packet_Number_Offset =
             1 + Destination_Length
           and then Parse'Result.Protected_Length >= 20
           and then Parse'Result.Consumed =
             Parse'Result.Packet_Number_Offset
             + Parse'Result.Protected_Length
           and then Parse'Result.Consumed = Natural (Data'Length));
end Flyology.QUIC.One_RTT_Packet_Policy;
