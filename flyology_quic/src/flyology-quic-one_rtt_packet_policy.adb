package body Flyology.QUIC.One_RTT_Packet_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;

   function Parse
     (Data               : Ada.Streams.Stream_Element_Array;
      Destination_Length : Long_Header_Policy.V1_Connection_ID_Length)
      return Parse_Result
   is
      Result : Parse_Result;
      Number_Offset : constant Natural := 1 + Destination_Length;
   begin
      if Data'Length > 65_535 then
         Result.Status := Packet_Too_Large;
         return Result;
      elsif Data'Length < 1 then
         return Result;
      end if;

      Result.First_Byte := Data (Data'First);
      if (Result.First_Byte and 16#80#) /= 0 then
         Result.Status := Not_Short_Header;
         return Result;
      elsif (Result.First_Byte and 16#40#) = 0 then
         Result.Status := Invalid_Fixed_Bit;
         return Result;
      elsif Natural (Data'Length) < Number_Offset then
         return Result;
      end if;

      Result.Destination.Length := Destination_Length;
      for Index in 1 .. Destination_Length loop
         Result.Destination.Data
           (Ada.Streams.Stream_Element_Offset (Index)) :=
             Data
               (Data'First + Ada.Streams.Stream_Element_Offset (Index));
      end loop;
      Result.Packet_Number_Offset := Number_Offset;
      Result.Protected_Length := Natural (Data'Length) - Number_Offset;
      if Result.Protected_Length < 20 then
         Result.Status := Insufficient_Protected_Payload;
         return Result;
      end if;

      Result.Consumed := Natural (Data'Length);
      Result.Status := Parsed;
      return Result;
   end Parse;
end Flyology.QUIC.One_RTT_Packet_Policy;
