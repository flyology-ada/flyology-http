with Ada.Streams;
with Interfaces;

private package Flyology.QUIC.Protection_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Interfaces.Unsigned_64;

   subtype Packet_Number is Interfaces.Unsigned_64 range 0 .. 2**62 - 1;
   subtype Nonce is Ada.Streams.Stream_Element_Array (1 .. 12);
   subtype Header_Mask is Ada.Streams.Stream_Element_Array (1 .. 5);

   function Make_Nonce
     (IV : Nonce; Number : Packet_Number) return Nonce;

   procedure Apply_Header_Protection
     (First_Byte            : in out Ada.Streams.Stream_Element;
      Encoded_Packet_Number : in out Ada.Streams.Stream_Element_Array;
      Long_Header           : Boolean;
      Mask                  : Header_Mask)
   with Pre => Encoded_Packet_Number'Length in 1 .. 4;
end Flyology.QUIC.Protection_Policy;
