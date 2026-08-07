procedure Flyology.QUIC.Packet_Number_Policy.Smoke is
begin
   pragma Assert
     (Select_Length (16#AC5C02#, True, 16#ABE8B3#) = 2);
   pragma Assert
     (Select_Length (16#ACE8FE#, True, 16#ABE8B3#) = 3);
   pragma Assert (Select_Length (0, False, 0) = 1);

   --  Four bytes represent at most 2**31 contiguous unacknowledged numbers.
   pragma Assert (Is_Representable (2**31 - 1, False, 0));
   pragma Assert (Select_Length (2**31 - 1, False, 0) = 4);
   pragma Assert (not Is_Representable (2**31, False, 0));
   pragma Assert (Is_Representable (2**31, True, 0));
   pragma Assert (not Is_Representable (2**31 + 1, True, 0));

   pragma Assert (Reconstruct (16#A82F30EA#, 16#9B32#, 2) = 16#A82F9B32#);
   pragma Assert (Reconstruct (16#01F0#, 16#10#, 1) = 16#0210#);
   pragma Assert (Reconstruct (16#01FF#, 16#F0#, 1) = 16#01F0#);
   pragma Assert (Reconstruct (16#00FF#, 16#80#, 1) = 16#0180#);
   pragma Assert (Reconstruct_From_Expected (0, 2, 4) = 2);
end Flyology.QUIC.Packet_Number_Policy.Smoke;
