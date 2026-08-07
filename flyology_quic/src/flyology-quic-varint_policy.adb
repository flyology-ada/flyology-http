package body Flyology.QUIC.Varint_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;

   function Required_Length (Value : Value_Type) return Encoded_Length is
     (if Value <= 63 then 1
      elsif Value <= 16_383 then 2
      elsif Value <= 1_073_741_823 then 4
      else 8);

   function Encode (Value : Value_Type) return Encoded_Value is
      Result : Encoded_Value;
   begin
      Result.Length := Required_Length (Value);
      case Result.Length is
         when 1 =>
            Result.Data (1) := Ada.Streams.Stream_Element (Value);
         when 2 =>
            Result.Data (1) :=
              16#40# + Ada.Streams.Stream_Element (Value / 2**8);
            Result.Data (2) := Ada.Streams.Stream_Element (Value mod 2**8);
         when 4 =>
            Result.Data (1) :=
              16#80# + Ada.Streams.Stream_Element (Value / 2**24);
            Result.Data (2) :=
              Ada.Streams.Stream_Element ((Value / 2**16) mod 2**8);
            Result.Data (3) :=
              Ada.Streams.Stream_Element ((Value / 2**8) mod 2**8);
            Result.Data (4) := Ada.Streams.Stream_Element (Value mod 2**8);
         when 8 =>
            Result.Data (1) :=
              16#C0# + Ada.Streams.Stream_Element (Value / 2**56);
            Result.Data (2) :=
              Ada.Streams.Stream_Element ((Value / 2**48) mod 2**8);
            Result.Data (3) :=
              Ada.Streams.Stream_Element ((Value / 2**40) mod 2**8);
            Result.Data (4) :=
              Ada.Streams.Stream_Element ((Value / 2**32) mod 2**8);
            Result.Data (5) :=
              Ada.Streams.Stream_Element ((Value / 2**24) mod 2**8);
            Result.Data (6) :=
              Ada.Streams.Stream_Element ((Value / 2**16) mod 2**8);
            Result.Data (7) :=
              Ada.Streams.Stream_Element ((Value / 2**8) mod 2**8);
            Result.Data (8) := Ada.Streams.Stream_Element (Value mod 2**8);
         when others =>
            raise Program_Error;
      end case;
      return Result;
   end Encode;

   function Decode
     (Data : Ada.Streams.Stream_Element_Array) return Decode_Result
   is
      subtype Byte_Offset is Natural range 0 .. 7;

      function Byte_At (Offset : Byte_Offset) return Interfaces.Unsigned_64
      with
        Pre =>
          (case Offset is
              when 0 => Data'Length >= 1,
              when 1 => Data'Length >= 2,
              when 2 => Data'Length >= 3,
              when 3 => Data'Length >= 4,
              when 4 => Data'Length >= 5,
              when 5 => Data'Length >= 6,
              when 6 => Data'Length >= 7,
              when 7 => Data'Length >= 8),
        Post => Byte_At'Result <= 255;

      function Byte_At (Offset : Byte_Offset) return Interfaces.Unsigned_64 is
        (Interfaces.Unsigned_64
           (Data
              (Data'First + Ada.Streams.Stream_Element_Offset (Offset))));

      First  : Interfaces.Unsigned_64;
      Length : Encoded_Length;
      Value  : Interfaces.Unsigned_64;
   begin
      if Data'Length = 0 then
         return (Status => Truncated, Value => 0, Consumed => 0);
      end if;

      First := Byte_At (0);
      Length :=
        (if First < 16#40# then 1
         elsif First < 16#80# then 2
         elsif First < 16#C0# then 4
         else 8);
      if (case Length is
             when 1 => Data'Length < 1,
             when 2 => Data'Length < 2,
             when 4 => Data'Length < 4,
             when 8 => Data'Length < 8,
             when others => True)
      then
         return (Status => Truncated, Value => 0, Consumed => 0);
      end if;

      Value := First mod 16#40#;
      case Length is
         when 1 =>
            null;
         when 2 =>
            Value := Value * 2**8 + Byte_At (1);
         when 4 =>
            Value :=
              ((Value * 2**8 + Byte_At (1)) * 2**8 + Byte_At (2))
              * 2**8 + Byte_At (3);
         when 8 =>
            Value :=
              ((((((Value * 2**8 + Byte_At (1)) * 2**8 + Byte_At (2))
                    * 2**8 + Byte_At (3)) * 2**8 + Byte_At (4))
                  * 2**8 + Byte_At (5)) * 2**8 + Byte_At (6))
                * 2**8 + Byte_At (7);
         when others =>
            raise Program_Error;
      end case;
      return
        (Status => Decoded, Value => Value_Type (Value), Consumed => Length);
   end Decode;
end Flyology.QUIC.Varint_Policy;
