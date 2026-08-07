package body Flyology.QUIC.Crypto_Frame_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element_Offset;
   use type Varint_Policy.Value_Type;

   function Encode
     (Offset : Varint_Policy.Value_Type;
      Data   : Ada.Streams.Stream_Element_Array) return Encode_Result
   is
      Result : Encode_Result;
      Data_Length : constant Natural := Natural (Data'Length);
      Encoded_Offset : constant Varint_Policy.Encoded_Value :=
        Varint_Policy.Encode (Offset);
      Encoded_Length : constant Varint_Policy.Encoded_Value :=
        Varint_Policy.Encode (Varint_Policy.Value_Type (Data_Length));
      Position : Ada.Streams.Stream_Element_Offset range 1 .. 17 := 1;
   begin
      if Offset > Varint_Policy.Value_Type'Last
        - Varint_Policy.Value_Type (Data_Length)
      then
         return Result;
      end if;

      Result.Data (1) := 16#06#;
      for Index in 1 .. Encoded_Offset.Length loop
         pragma Loop_Invariant (Position = 1);
         Result.Data
           (Position + Ada.Streams.Stream_Element_Offset (Index)) :=
           Encoded_Offset.Data (Ada.Streams.Stream_Element_Offset (Index));
      end loop;
      Position :=
        Position
          + Ada.Streams.Stream_Element_Offset (Encoded_Offset.Length);

      for Index in 1 .. Encoded_Length.Length loop
         pragma Loop_Invariant (Position in 2 .. 9);
         Result.Data
           (Position + Ada.Streams.Stream_Element_Offset (Index)) :=
           Encoded_Length.Data (Ada.Streams.Stream_Element_Offset (Index));
      end loop;
      Position :=
        Position
          + Ada.Streams.Stream_Element_Offset (Encoded_Length.Length);

      if Data_Length > 0 then
         for Index in 0 .. Data_Length - 1 loop
            pragma Loop_Invariant (Position in 3 .. 17);
            pragma Loop_Invariant
              (Position + Ada.Streams.Stream_Element_Offset (Index) + 1 <=
                 Max_Frame_Length);
            Result.Data
              (Position + Ada.Streams.Stream_Element_Offset (Index) + 1) :=
              Data
                (Data'First + Ada.Streams.Stream_Element_Offset (Index));
         end loop;
      end if;
      Result.Length := Natural (Position) + Data_Length;
      Result.Status := Encoded;
      return Result;
   end Encode;
end Flyology.QUIC.Crypto_Frame_Policy;
