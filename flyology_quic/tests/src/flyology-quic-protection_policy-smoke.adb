procedure Flyology.QUIC.Protection_Policy.Smoke is
   use type Ada.Streams.Stream_Element;
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
end Flyology.QUIC.Protection_Policy.Smoke;
