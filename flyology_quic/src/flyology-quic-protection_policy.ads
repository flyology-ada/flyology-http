with Ada.Streams;
with Interfaces;

private package Flyology.QUIC.Protection_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element;
   use type Interfaces.Unsigned_64;

   subtype Packet_Number is Interfaces.Unsigned_64 range 0 .. 2**62 - 1;
   subtype Nonce is Ada.Streams.Stream_Element_Array (1 .. 12);
   subtype Header_Mask is Ada.Streams.Stream_Element_Array (1 .. 5);
   subtype Packet_Number_Prefix is
     Ada.Streams.Stream_Element_Array (1 .. 4);
   subtype Packet_Number_Length is Positive range 1 .. 4;

   type Unprotected_Long_Header is record
      First_Byte       : Ada.Streams.Stream_Element := 0;
      Number_Length    : Packet_Number_Length := 1;
      Encoded_Number   : Packet_Number_Prefix := (others => 0);
      Truncated_Number : Interfaces.Unsigned_64 := 0;
   end record;

   function Make_Nonce
     (IV : Nonce; Number : Packet_Number) return Nonce;

   procedure Apply_Header_Protection
     (First_Byte            : in out Ada.Streams.Stream_Element;
      Encoded_Packet_Number : in out Ada.Streams.Stream_Element_Array;
      Long_Header           : Boolean;
      Mask                  : Header_Mask)
   with Pre => Encoded_Packet_Number'Length in 1 .. 4;

   function Remove_Long_Header_Protection
     (First_Byte            : Ada.Streams.Stream_Element;
      Protected_Number      : Packet_Number_Prefix;
      Mask                  : Header_Mask) return Unprotected_Long_Header
   with
     Global => null,
     Post =>
       Remove_Long_Header_Protection'Result.First_Byte =
         (First_Byte xor (Mask (1) and 16#0F#))
       and then Remove_Long_Header_Protection'Result.Number_Length =
         Natural
           ((Remove_Long_Header_Protection'Result.First_Byte and 16#03#) + 1)
       and then Remove_Long_Header_Protection'Result.Truncated_Number <
         2**(8 * Remove_Long_Header_Protection'Result.Number_Length);
end Flyology.QUIC.Protection_Policy;
