procedure Flyology.QUIC.Protection_Policy.Smoke is
   use type Ada.Streams.Stream_Element_Array;

   IV : constant Nonce :=
     (16#FA#, 16#04#, 16#4B#, 16#2F#, 16#42#, 16#A3#,
      16#FD#, 16#3B#, 16#46#, 16#FB#, 16#25#, 16#5C#);
begin
   pragma Assert
     (Make_Nonce (IV, 2) =
        Nonce'
          (16#FA#, 16#04#, 16#4B#, 16#2F#, 16#42#, 16#A3#,
           16#FD#, 16#3B#, 16#46#, 16#FB#, 16#25#, 16#5E#));

   declare
      First  : Ada.Streams.Stream_Element := 16#C3#;
      Number : Ada.Streams.Stream_Element_Array := (0, 0, 0, 2);
      Mask   : constant Header_Mask :=
        (16#43#, 16#7B#, 16#9A#, 16#EC#, 16#36#);
   begin
      Apply_Header_Protection (First, Number, True, Mask);
      pragma Assert (First = 16#C0#);
      pragma Assert (Number = (16#7B#, 16#9A#, 16#EC#, 16#34#));
      Apply_Header_Protection (First, Number, True, Mask);
      pragma Assert (First = 16#C3#);
      pragma Assert (Number = (0, 0, 0, 2));
   end;

   declare
      Client : constant Unprotected_Long_Header :=
        Remove_Long_Header_Protection
          (16#C0#,
           (16#7B#, 16#9A#, 16#EC#, 16#34#),
           (16#43#, 16#7B#, 16#9A#, 16#EC#, 16#36#));
      Server : constant Unprotected_Long_Header :=
        Remove_Long_Header_Protection
          (16#CF#,
           (16#C0#, 16#D9#, 16#5A#, 16#48#),
           (16#2E#, 16#C0#, 16#D8#, 16#35#, 16#6A#));
   begin
      --  RFC 9001 Appendices A.2 and A.3 receive-side results.
      pragma Assert (Client.First_Byte = 16#C3#);
      pragma Assert (Client.Number_Length = 4);
      pragma Assert (Client.Encoded_Number = (0, 0, 0, 2));
      pragma Assert (Client.Truncated_Number = 2);

      pragma Assert (Server.First_Byte = 16#C1#);
      pragma Assert (Server.Number_Length = 2);
      pragma Assert (Server.Encoded_Number (1 .. 2) = (0, 1));
      pragma Assert (Server.Encoded_Number (3 .. 4) = (0, 0));
      pragma Assert (Server.Truncated_Number = 1);
   end;

   declare
      Short : constant Unprotected_Long_Header :=
        Remove_Short_Header_Protection
          (16#5D#,
           (16#AB#, 16#AA#, 16#AA#, 16#AA#),
           (16#1C#, 16#AA#, 16#BB#, 16#CC#, 16#DD#));
   begin
      pragma Assert (Short.First_Byte = 16#41#);
      pragma Assert (Short.Number_Length = 2);
      pragma Assert (Short.Encoded_Number (1 .. 2) = (1, 16#11#));
      pragma Assert (Short.Truncated_Number = 16#0111#);
   end;
end Flyology.QUIC.Protection_Policy.Smoke;
