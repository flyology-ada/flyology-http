with Interfaces;

--  Internal, proved selection and reconstruction of QUIC packet numbers.
private package Flyology.QUIC.Packet_Number_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Interfaces.Unsigned_64;

   subtype Packet_Number is Interfaces.Unsigned_64 range 0 .. 2**62 - 1;
   type Encoded_Length is range 1 .. 4;

   function Window (Length : Encoded_Length) return Interfaces.Unsigned_64
   with
     Global => null,
     Post =>
       Window'Result =
         (case Length is
             when 1 => 2**8,
             when 2 => 2**16,
             when 3 => 2**24,
             when 4 => 2**32);

   function Is_Representable
     (Full                 : Packet_Number;
      Has_Largest_Acked    : Boolean;
      Largest_Acknowledged : Packet_Number) return Boolean
   with
     Global => null,
     Pre =>
       not Has_Largest_Acked
       or else Largest_Acknowledged < Full;

   function Select_Length
     (Full                 : Packet_Number;
      Has_Largest_Acked    : Boolean;
      Largest_Acknowledged : Packet_Number) return Encoded_Length
   with
     Global => null,
     Pre =>
       (not Has_Largest_Acked or else Largest_Acknowledged < Full)
       and then Is_Representable
         (Full, Has_Largest_Acked, Largest_Acknowledged);

   function Reconstruct
     (Largest   : Packet_Number;
      Truncated : Interfaces.Unsigned_64;
      Length    : Encoded_Length) return Packet_Number
   with
     Global => null,
     Pre =>
       Largest < Packet_Number'Last
       and then Truncated < Window (Length);
end Flyology.QUIC.Packet_Number_Policy;
