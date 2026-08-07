package body Flyology.QUIC.Packet_Number_Policy
  with SPARK_Mode => On
is
   function Window (Length : Encoded_Length) return Interfaces.Unsigned_64 is
     (case Length is
         when 1 => 2**8,
         when 2 => 2**16,
         when 3 => 2**24,
         when 4 => 2**32);

   function Is_Representable
     (Full                 : Packet_Number;
      Has_Largest_Acked    : Boolean;
      Largest_Acknowledged : Packet_Number) return Boolean
   is
     ((if Has_Largest_Acked
       then Full - Largest_Acknowledged
       else Full + 1) <= 2**31);

   function Select_Length
     (Full                 : Packet_Number;
      Has_Largest_Acked    : Boolean;
      Largest_Acknowledged : Packet_Number) return Encoded_Length
   is
      Unacknowledged : constant Interfaces.Unsigned_64 :=
        (if Has_Largest_Acked
         then Full - Largest_Acknowledged
         else Full + 1);
   begin
      if Unacknowledged <= 2**7 then
         return 1;
      elsif Unacknowledged <= 2**15 then
         return 2;
      elsif Unacknowledged <= 2**23 then
         return 3;
      else
         return 4;
      end if;
   end Select_Length;

   function Reconstruct
     (Largest   : Packet_Number;
      Truncated : Interfaces.Unsigned_64;
      Length    : Encoded_Length) return Packet_Number
   is
     (Reconstruct_From_Expected (Largest + 1, Truncated, Length));

   function Reconstruct_From_Expected
     (Expected  : Packet_Number;
      Truncated : Interfaces.Unsigned_64;
      Length    : Encoded_Length) return Packet_Number
   is
      PN_Window : constant Interfaces.Unsigned_64 := Window (Length);
      Half      : constant Interfaces.Unsigned_64 := PN_Window / 2;
      Candidate : Interfaces.Unsigned_64 :=
        (Expected / PN_Window) * PN_Window + Truncated;
   begin
      if Expected >= Half
        and then Candidate <= Expected - Half
        and then Candidate < 2**62 - PN_Window
      then
         Candidate := Candidate + PN_Window;
      elsif Candidate > Expected + Half
        and then Candidate >= PN_Window
      then
         Candidate := Candidate - PN_Window;
      end if;
      return Packet_Number (Candidate);
   end Reconstruct_From_Expected;
end Flyology.QUIC.Packet_Number_Policy;
