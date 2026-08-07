package body Flyology.QUIC.Long_Header_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;

   function Parse
     (Data : Ada.Streams.Stream_Element_Array) return Parse_Result
   is
      subtype Parse_Offset is
        Ada.Streams.Stream_Element_Offset range 0 .. 517;
      subtype Byte_Offset is Parse_Offset range 0 .. 516;

      function Has_Length (Length : Parse_Offset) return Boolean is
        (Data'Length > 517
         or else
           Length <= Ada.Streams.Stream_Element_Offset (Data'Length));

      function Byte_At (Offset : Byte_Offset) return Ada.Streams.Stream_Element
      with
        Pre => Has_Length (Offset + 1);

      function Byte_At (Offset : Byte_Offset) return Ada.Streams.Stream_Element
      is
        (Data
           (Data'First + Ada.Streams.Stream_Element_Offset (Offset)));

      Result             : Parse_Result;
      Destination_Length : Connection_ID_Length;
      Source_Length      : Connection_ID_Length;
      Source_Length_At   : Byte_Offset range 6 .. 261;
      Total_Length       : Parse_Offset range 7 .. 517;
      First              : Ada.Streams.Stream_Element;
   begin
      if Data'Length < 1 then
         return Result;
      end if;

      First := Byte_At (0);
      Result.First_Byte := First;
      if (First and 16#80#) = 0 then
         Result.Status := Not_Long_Header;
         return Result;
      end if;

      if Data'Length < 5 then
         return Result;
      end if;

      Result.Version :=
        Interfaces.Unsigned_32 (Byte_At (1)) * 2**24
        + Interfaces.Unsigned_32 (Byte_At (2)) * 2**16
        + Interfaces.Unsigned_32 (Byte_At (3)) * 2**8
        + Interfaces.Unsigned_32 (Byte_At (4));

      if Result.Version = Version_1 and then (First and 16#40#) = 0 then
         Result.Status := Invalid_V1_Fixed_Bit;
         return Result;
      end if;

      if Data'Length < 6 then
         return Result;
      end if;

      Destination_Length := Connection_ID_Length (Byte_At (5));
      if Result.Version = Version_1 and then Destination_Length > 20 then
         Result.Status := Invalid_V1_Connection_ID_Length;
         return Result;
      end if;

      Source_Length_At :=
        6 + Ada.Streams.Stream_Element_Offset (Destination_Length);
      if not Has_Length (Source_Length_At + 1) then
         return Result;
      end if;

      Source_Length := Connection_ID_Length (Byte_At (Source_Length_At));
      if Result.Version = Version_1 and then Source_Length > 20 then
         Result.Status := Invalid_V1_Connection_ID_Length;
         return Result;
      end if;

      Total_Length :=
        7
        + Ada.Streams.Stream_Element_Offset (Destination_Length)
        + Ada.Streams.Stream_Element_Offset (Source_Length);
      if not Has_Length (Total_Length) then
         return Result;
      end if;

      Result.Destination.Length := Destination_Length;
      for Index in 1 .. Destination_Length loop
         Result.Destination.Data
           (Ada.Streams.Stream_Element_Offset (Index)) :=
             Byte_At (5 + Ada.Streams.Stream_Element_Offset (Index));
      end loop;

      Result.Source.Length := Source_Length;
      for Index in 1 .. Source_Length loop
         Result.Source.Data (Ada.Streams.Stream_Element_Offset (Index)) :=
           Byte_At
             (Source_Length_At
              + Ada.Streams.Stream_Element_Offset (Index));
      end loop;

      Result.Kind :=
        (if Result.Version = 0 then Version_Negotiation
         elsif Result.Version /= Version_1 then Unsupported_Version
         else
           (case (First and 16#30#) is
               when 16#00# => Initial,
               when 16#10# => Zero_RTT,
               when 16#20# => Handshake,
               when 16#30# => Retry,
               when others => Unsupported_Version));
      Result.Consumed := Natural (Total_Length);
      Result.Status := Parsed;
      return Result;
   end Parse;

   function Encode_Protected_V1_Prefix
     (Kind          : Protected_V1_Kind;
      Number_Length : Packet_Number_Length;
      Destination   : Connection_ID;
      Source        : Connection_ID) return Encoded_Prefix
   is
      Result : Encoded_Prefix;
   begin
      Result.Data (1) :=
        (case Kind is
            when Initial => 16#C0#,
            when Zero_RTT => 16#D0#,
            when Handshake => 16#E0#,
            when others => 16#C0#)
        + Ada.Streams.Stream_Element (Number_Length - 1);
      Result.Data (2 .. 5) := (0, 0, 0, 1);
      Result.Data (6) := Ada.Streams.Stream_Element (Destination.Length);
      for Index in 1 .. Destination.Length loop
         Result.Data
           (Ada.Streams.Stream_Element_Offset (6 + Index)) :=
             Destination.Data (Ada.Streams.Stream_Element_Offset (Index));
      end loop;
      Result.Data
        (Ada.Streams.Stream_Element_Offset (7 + Destination.Length)) :=
        Ada.Streams.Stream_Element (Source.Length);
      for Index in 1 .. Source.Length loop
         Result.Data
           (Ada.Streams.Stream_Element_Offset
              (7 + Destination.Length + Index)) :=
             Source.Data (Ada.Streams.Stream_Element_Offset (Index));
      end loop;
      Result.Length := 7 + Destination.Length + Source.Length;
      return Result;
   end Encode_Protected_V1_Prefix;
end Flyology.QUIC.Long_Header_Policy;
