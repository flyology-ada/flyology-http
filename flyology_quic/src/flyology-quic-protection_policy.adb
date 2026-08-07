package body Flyology.QUIC.Protection_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;

   function Make_Nonce
     (IV : Nonce; Number : Packet_Number) return Nonce
   is
      Result : Nonce := IV;
   begin
      for Offset in Natural range 0 .. 7 loop
         Result
           (Result'Last - Ada.Streams.Stream_Element_Offset (Offset)) :=
             Result
               (Result'Last - Ada.Streams.Stream_Element_Offset (Offset))
             xor Ada.Streams.Stream_Element
               (Interfaces.Shift_Right (Number, 8 * Offset) and 16#FF#);
      end loop;
      return Result;
   end Make_Nonce;

   procedure Apply_Header_Protection
     (First_Byte            : in out Ada.Streams.Stream_Element;
      Encoded_Packet_Number : in out Ada.Streams.Stream_Element_Array;
      Long_Header           : Boolean;
      Mask                  : Header_Mask)
   is
      First : constant Ada.Streams.Stream_Element_Offset :=
        Encoded_Packet_Number'First;
   begin
      First_Byte :=
        First_Byte xor
          (Mask (Mask'First)
             and (if Long_Header then 16#0F# else 16#1F#));
      Encoded_Packet_Number (First) :=
        Encoded_Packet_Number (First) xor Mask (2);
      if Encoded_Packet_Number'Length >= 2 then
         Encoded_Packet_Number (First + 1) :=
           Encoded_Packet_Number (First + 1) xor Mask (3);
      end if;
      if Encoded_Packet_Number'Length >= 3 then
         Encoded_Packet_Number (First + 2) :=
           Encoded_Packet_Number (First + 2) xor Mask (4);
      end if;
      if Encoded_Packet_Number'Length = 4 then
         Encoded_Packet_Number (First + 3) :=
           Encoded_Packet_Number (First + 3) xor Mask (5);
      end if;
   end Apply_Header_Protection;

   function Remove_Long_Header_Protection
     (First_Byte            : Ada.Streams.Stream_Element;
      Protected_Number      : Packet_Number_Prefix;
      Mask                  : Header_Mask) return Unprotected_Long_Header
   is
      Result : Unprotected_Long_Header;
      Value  : Ada.Streams.Stream_Element;
   begin
      Result.First_Byte := First_Byte xor (Mask (1) and 16#0F#);
      Result.Number_Length :=
        Natural ((Result.First_Byte and 16#03#) + 1);
      for Index in 1 .. Result.Number_Length loop
         Value :=
           Protected_Number
             (Ada.Streams.Stream_Element_Offset (Index))
           xor Mask (Ada.Streams.Stream_Element_Offset (Index + 1));
         Result.Encoded_Number
           (Ada.Streams.Stream_Element_Offset (Index)) := Value;
         Result.Truncated_Number :=
           Result.Truncated_Number * 2**8 + Interfaces.Unsigned_64 (Value);
      end loop;
      return Result;
   end Remove_Long_Header_Protection;
end Flyology.QUIC.Protection_Policy;
