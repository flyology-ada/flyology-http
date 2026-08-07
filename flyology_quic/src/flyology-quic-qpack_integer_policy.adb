package body Flyology.QUIC.QPACK_Integer_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;

   function Prefix_Mask (Bits : Prefix_Size) return Ada.Streams.Stream_Element
   is
     (case Bits is
         when 1 => 16#01#,
         when 2 => 16#03#,
         when 3 => 16#07#,
         when 4 => 16#0F#,
         when 5 => 16#1F#,
         when 6 => 16#3F#,
         when 7 => 16#7F#,
         when 8 => 16#FF#);

   function Decode
     (Data : Ada.Streams.Stream_Element_Array;
      Bits : Prefix_Size) return Decode_Result
   is
      Result     : Decode_Result;
      Mask       : constant Natural := Natural (Prefix_Mask (Bits));
      Value      : Natural;
      Position   : Natural range 0 .. 4 := 1;
      Multiplier : Natural range 1 .. 16_384 := 1;
      Octet      : Natural;
      Low        : Natural;
   begin
      if Data'Length = 0 then
         return Result;
      end if;
      Value := Natural (Data (Data'First)) mod (Mask + 1);
      if Value < Mask then
         Result.Status := Decoded;
         Result.Value := Value;
         Result.Consumed := 1;
         return Result;
      end if;

      loop
         pragma Loop_Invariant (Position in 1 .. 3);
         pragma Loop_Invariant (Value <= Max_Value);
         pragma Loop_Invariant (Multiplier in 1 .. 16_384);
         pragma Loop_Variant (Decreases => 4 - Position);
         if Position >= Data'Length then
            return Result;
         end if;
         Octet :=
           Natural
             (Data
                (Data'First + Ada.Streams.Stream_Element_Offset (Position)));
         Low := Octet mod 128;
         if Low > (Max_Value - Value) / Multiplier then
            Result.Status := Value_Too_Large;
            return Result;
         end if;
         pragma Assert (Low * Multiplier <= Max_Value - Value);
         Value := Value + Low * Multiplier;
         Position := Position + 1;
         if Octet < 128 then
            Result.Status := Decoded;
            Result.Value := Value;
            Result.Consumed := Position;
            return Result;
         elsif Position = 4 or else Multiplier > 128 then
            Result.Status := Value_Too_Large;
            return Result;
         end if;
         Multiplier := Multiplier * 128;
      end loop;
   end Decode;

   function Encode
     (Value     : Value_Type;
      Bits      : Prefix_Size;
      High_Bits : Ada.Streams.Stream_Element) return Encode_Result
   is
      Result    : Encode_Result;
      Mask      : constant Natural := Natural (Prefix_Mask (Bits));
      Remaining : Natural := Value;
      Position  : Natural range 1 .. 4 := 1;
   begin
      if Remaining < Mask then
         Result.Data (1) := High_Bits + Ada.Streams.Stream_Element (Remaining);
         return Result;
      end if;

      Result.Data (1) := High_Bits + Ada.Streams.Stream_Element (Mask);
      Remaining := Remaining - Mask;
      if Remaining >= 128 then
         Result.Data (Ada.Streams.Stream_Element_Offset (Position + 1)) :=
           Ada.Streams.Stream_Element (Remaining mod 128 + 128);
         Remaining := Remaining / 128;
         Position := Position + 1;
      end if;
      if Remaining >= 128 then
         Result.Data (Ada.Streams.Stream_Element_Offset (Position + 1)) :=
           Ada.Streams.Stream_Element (Remaining mod 128 + 128);
         Remaining := Remaining / 128;
         Position := Position + 1;
      end if;
      pragma Assert (Remaining < 128);
      Result.Data (Ada.Streams.Stream_Element_Offset (Position + 1)) :=
        Ada.Streams.Stream_Element (Remaining);
      Result.Length := Position + 1;
      return Result;
   end Encode;
end Flyology.QUIC.QPACK_Integer_Policy;
