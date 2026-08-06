with Ada.Streams;

procedure Flyology.HTTP.HTTP_2_Huffman.Smoke is
   function Bytes
     (Values : Ada.Streams.Stream_Element_Array)
      return Ada.Streams.Stream_Element_Array is (Values);

   procedure Reject (Value : Ada.Streams.Stream_Element_Array) is
      Failed : Boolean := False;
   begin
      begin
         declare
            Ignored : constant String := Decode (Value, 1_024);
         begin
            pragma Unreferenced (Ignored);
         end;
      exception
         when Protocol_Error =>
            Failed := True;
      end;
      pragma Assert (Failed);
   end Reject;

begin
   --  RFC 7541 C.4.1: Huffman-coded "www.example.com".
   pragma Assert
     (Decode
        (Bytes ((16#F1#, 16#E3#, 16#C2#, 16#E5#, 16#F2#, 16#3A#,
                 16#6B#, 16#A0#, 16#AB#, 16#90#, 16#F4#, 16#FF#)),
         1_024) = "www.example.com");
   pragma Assert (Decode (Bytes ((1 .. 0 => 0)), 0) = "");

   Reject (Bytes ((1 => 16#FF#)));
   Reject (Bytes ((16#FF#, 16#FF#, 16#FF#, 16#FF#)));
   Reject (Bytes ((16#F1#, 16#E2#)));
end Flyology.HTTP.HTTP_2_Huffman.Smoke;
