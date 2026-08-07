with Flyology.QUIC.Varint_Policy;
with Interfaces;

package body Flyology.QUIC.Initial_Packet_Policy
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
      subtype Datagram_Count is Natural range 0 .. 65_535;

      function Has_Length (Length : Datagram_Count) return Boolean is
        (Data'Length > 65_535
         or else Length <= Natural (Data'Length));

      function Decode_At
        (Offset : Datagram_Offset) return Varint_Policy.Decode_Result
      with
        Pre => Offset < Datagram_Offset'Last and then Has_Length (Offset + 1);

      function Decode_At
        (Offset : Datagram_Offset) return Varint_Policy.Decode_Result is
        (Varint_Policy.Decode
           (Data
              (Data'First + Ada.Streams.Stream_Element_Offset (Offset)
               .. Data'Last)));

      Result        : Parse_Result;
      Token_Result  : Varint_Policy.Decode_Result;
      Length_Result : Varint_Policy.Decode_Result;
   begin
      Result.Header := Long_Header_Policy.Parse (Data);
      if Result.Header.Status = Long_Header_Policy.Truncated then
         return Result;
      elsif Result.Header.Status /= Long_Header_Policy.Parsed then
         Result.Status := Invalid_Long_Header;
         return Result;
      elsif Result.Header.Version /= Long_Header_Policy.Version_1
        or else Result.Header.Kind /= Long_Header_Policy.Initial
      then
         Result.Status := Not_V1_Initial;
         return Result;
      end if;

      if Result.Header.Consumed >= Datagram_Offset'Last
        or else not Has_Length (Result.Header.Consumed + 1)
      then
         return Result;
      end if;

      Token_Result := Decode_At (Result.Header.Consumed);
      if Token_Result.Status /= Varint_Policy.Decoded then
         return Result;
      end if;
      Result.Token_Length_Bytes := Token_Result.Consumed;
      Result.Token_Offset := Result.Header.Consumed + Token_Result.Consumed;

      if Token_Result.Value > Interfaces.Unsigned_64 (Datagram_Offset'Last)
        or else
          Natural (Token_Result.Value) >
            Datagram_Offset'Last - Result.Token_Offset
      then
         Result.Status := Token_Length_Too_Large;
         return Result;
      end if;
      Result.Token_Length := Natural (Token_Result.Value);
      Result.Length_Offset := Result.Token_Offset + Result.Token_Length;

      if Result.Length_Offset >= Datagram_Offset'Last then
         Result.Status := Token_Length_Too_Large;
         return Result;
      elsif not Has_Length (Result.Length_Offset + 1) then
         return Result;
      end if;

      Length_Result := Decode_At (Result.Length_Offset);
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
end Flyology.QUIC.Initial_Packet_Policy;
