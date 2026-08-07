with Flyology.QUIC.Varint_Policy;
with Interfaces;

package body Flyology.QUIC.Handshake_Packet_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element_Offset;
   use type Flyology.QUIC.Long_Header_Policy.Packet_Kind;
   use type Flyology.QUIC.Long_Header_Policy.Parse_Status;
   use type Flyology.QUIC.Varint_Policy.Decode_Status;
   use type Interfaces.Unsigned_64;

   function Parse
     (Data : Ada.Streams.Stream_Element_Array) return Parse_Result
   is
      function Has_Length (Length : Datagram_Offset) return Boolean is
        (Data'Length > 65_535
         or else Length <= Natural (Data'Length));

      Result        : Parse_Result;
      Length_Result : Varint_Policy.Decode_Result;
   begin
      Result.Header := Long_Header_Policy.Parse (Data);
      if Result.Header.Status = Long_Header_Policy.Truncated then
         return Result;
      elsif Result.Header.Status /= Long_Header_Policy.Parsed then
         Result.Status := Invalid_Long_Header;
         return Result;
      elsif Result.Header.Version /= Long_Header_Policy.Version_1
        or else Result.Header.Kind /= Long_Header_Policy.Handshake
      then
         Result.Status := Not_V1_Handshake;
         return Result;
      end if;

      Result.Length_Offset := Result.Header.Consumed;
      if Result.Length_Offset >= Datagram_Offset'Last
        or else not Has_Length (Result.Length_Offset + 1)
      then
         return Result;
      end if;

      Length_Result :=
        Varint_Policy.Decode
          (Data
             (Data'First
                + Ada.Streams.Stream_Element_Offset (Result.Length_Offset)
              .. Data'Last));
      if Length_Result.Status /= Varint_Policy.Decoded then
         return Result;
      end if;
      Result.Length_Bytes := Length_Result.Consumed;

      if Result.Length_Offset >
        Datagram_Offset'Last - Length_Result.Consumed
      then
         Result.Status := Packet_Length_Too_Large;
         return Result;
      end if;
      Result.Packet_Number_Offset :=
        Result.Length_Offset + Length_Result.Consumed;

      if Length_Result.Value > Interfaces.Unsigned_64 (Datagram_Offset'Last)
      then
         Result.Status := Packet_Length_Too_Large;
         return Result;
      end if;
      Result.Protected_Length := Natural (Length_Result.Value);
      if Result.Protected_Length < 20 then
         Result.Status := Insufficient_Protected_Payload;
         return Result;
      elsif Result.Protected_Length >
        Datagram_Offset'Last - Result.Packet_Number_Offset
      then
         Result.Status := Packet_Length_Too_Large;
         return Result;
      end if;

      Result.Consumed :=
        Result.Packet_Number_Offset + Result.Protected_Length;
      if not Has_Length (Result.Consumed) then
         Result.Consumed := 0;
         return Result;
      end if;

      Result.Status := Parsed;
      return Result;
   end Parse;
end Flyology.QUIC.Handshake_Packet_Policy;
