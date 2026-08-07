with Ada.Streams;
with Interfaces;

--  Internal, proved QUIC long-header invariant framing policy.
--
--  Parsing retains the version-independent fields defined by RFC 8999 and
--  applies the QUIC v1 fixed-bit and 20-byte connection-ID limits from
--  RFC 9000. Version Negotiation and unknown versions retain connection IDs
--  up to the invariant one-byte wire limit without interpreting type bits.
private package Flyology.QUIC.Long_Header_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Interfaces.Unsigned_32;

   Version_1 : constant Interfaces.Unsigned_32 := 1;

   subtype Connection_ID_Length is Natural range 0 .. 255;
   subtype V1_Connection_ID_Length is Connection_ID_Length range 0 .. 20;
   subtype Connection_ID_Index is
     Ada.Streams.Stream_Element_Offset range 1 .. 255;

   type Connection_ID is record
      Data   : Ada.Streams.Stream_Element_Array (Connection_ID_Index) :=
        (others => 0);
      Length : Connection_ID_Length := 0;
   end record;

   type Packet_Kind is
     (Initial,
      Zero_RTT,
      Handshake,
      Retry,
      Version_Negotiation,
      Unsupported_Version);

   subtype Protected_V1_Kind is Packet_Kind range Initial .. Handshake;
   subtype Packet_Number_Length is Positive range 1 .. 4;

   type Parse_Status is
     (Parsed,
      Truncated,
      Not_Long_Header,
      Invalid_V1_Fixed_Bit,
      Invalid_V1_Connection_ID_Length);

   subtype Parsed_Prefix_Length is Natural range 7 .. 517;

   type Parse_Result is record
      Status      : Parse_Status := Truncated;
      Kind        : Packet_Kind := Unsupported_Version;
      First_Byte  : Ada.Streams.Stream_Element := 0;
      Version     : Interfaces.Unsigned_32 := 0;
      Destination : Connection_ID;
      Source      : Connection_ID;
      Consumed    : Natural range 0 .. 517 := 0;
   end record;

   function Parse
     (Data : Ada.Streams.Stream_Element_Array) return Parse_Result
   with
     Global => null,
     Post =>
       (if Parse'Result.Status = Parsed then
           Parse'Result.Consumed in Parsed_Prefix_Length
           and then
             (Data'Length > 517
              or else
                Parse'Result.Consumed <= Natural (Data'Length))
           and then Parse'Result.Consumed =
             7
             + Parse'Result.Destination.Length
             + Parse'Result.Source.Length
           and then
             (if Parse'Result.Version = Version_1 then
                 Parse'Result.Destination.Length <= 20
                 and then Parse'Result.Source.Length <= 20));

   subtype Encoded_Prefix_Length is Natural range 7 .. 47;

   type Encoded_Prefix is record
      Data   : Ada.Streams.Stream_Element_Array (1 .. 47) := (others => 0);
      Length : Encoded_Prefix_Length := 7;
   end record;

   function Encode_Protected_V1_Prefix
     (Kind          : Protected_V1_Kind;
      Number_Length : Packet_Number_Length;
      Destination   : Connection_ID;
      Source        : Connection_ID) return Encoded_Prefix
   with
     Global => null,
     Pre =>
       Destination.Length <= V1_Connection_ID_Length'Last
       and then Source.Length <= V1_Connection_ID_Length'Last,
     Post =>
       Encode_Protected_V1_Prefix'Result.Length =
         7 + Destination.Length + Source.Length;
end Flyology.QUIC.Long_Header_Policy;
