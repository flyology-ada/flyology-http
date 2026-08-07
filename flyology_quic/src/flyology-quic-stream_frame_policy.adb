package body Flyology.QUIC.Stream_Frame_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Varint_Policy.Decode_Status;
   use type Varint_Policy.Value_Type;

   function Parse
     (Data : Ada.Streams.Stream_Element_Array) return Parse_Result
   is
      Data_Length : constant Frame_Offset := Frame_Offset (Data'Length);

      procedure Read_Varint
        (Position : in out Frame_Offset;
         Value    : out Varint_Policy.Value_Type;
         Success  : out Boolean)
      with
        Pre => Position <= Data_Length,
        Post =>
          (if Success then
              Position - Position'Old in 1 | 2 | 4 | 8
              and then Position <= Data_Length
           else
              Position = Position'Old and then Value = 0);

      procedure Read_Varint
        (Position : in out Frame_Offset;
         Value    : out Varint_Policy.Value_Type;
         Success  : out Boolean)
      is
         Decoded : Varint_Policy.Decode_Result;
      begin
         Value := 0;
         Success := False;
         if Position = Data_Length then
            return;
         end if;
         Decoded :=
           Varint_Policy.Decode
             (Data
                (Data'First + Ada.Streams.Stream_Element_Offset (Position)
                   .. Data'Last));
         if Decoded.Status /= Varint_Policy.Decoded then
            return;
         end if;
         pragma Assert
           (Frame_Offset (Decoded.Consumed) <= Data_Length - Position);
         Value := Decoded.Value;
         Position := Position + Frame_Offset (Decoded.Consumed);
         Success := True;
      end Read_Varint;

      Result : Parse_Result;
      Position : Frame_Offset := 0;
      Success : Boolean;
      Length_Value : Varint_Policy.Value_Type;
   begin
      Read_Varint (Position, Result.Frame_Type, Success);
      if not Success then
         return Result;
      elsif Result.Frame_Type not in 16#08# .. 16#0F# then
         Result.Status := Not_Stream_Frame;
         return Result;
      end if;

      Result.Fin := (Result.Frame_Type and 1) /= 0;
      Read_Varint (Position, Result.Stream_ID, Success);
      if not Success then
         return Result;
      end if;
      if (Result.Frame_Type and 4) /= 0 then
         Read_Varint (Position, Result.Stream_Offset, Success);
         if not Success then
            return Result;
         end if;
      end if;

      if (Result.Frame_Type and 2) /= 0 then
         Read_Varint (Position, Length_Value, Success);
         if not Success
           or else Length_Value > Varint_Policy.Value_Type (Frame_Offset'Last)
         then
            return Result;
         end if;
         Result.Data_Length := Frame_Offset (Length_Value);
         if Result.Data_Length > Data_Length - Position then
            Result.Data_Length := 0;
            return Result;
         end if;
      else
         Result.Data_Length := Data_Length - Position;
      end if;

      if Varint_Policy.Value_Type (Result.Data_Length) >
        Varint_Policy.Value_Type'Last - Result.Stream_Offset
      then
         Result.Status := Stream_Range_Too_Large;
         Result.Data_Length := 0;
         return Result;
      end if;
      Result.Data_Offset := Position;
      Result.Consumed := Position + Result.Data_Length;
      Result.Status := Parsed;
      return Result;
   end Parse;

   function Encode
     (Stream_ID : Varint_Policy.Value_Type;
      Offset    : Varint_Policy.Value_Type;
      Fin       : Boolean;
      Data      : Ada.Streams.Stream_Element_Array) return Encode_Result
   is
      Result : Encode_Result;
      Data_Length : constant Natural := Natural (Data'Length);
      Encoded_ID : constant Varint_Policy.Encoded_Value :=
        Varint_Policy.Encode (Stream_ID);
      Encoded_Offset : constant Varint_Policy.Encoded_Value :=
        Varint_Policy.Encode (Offset);
      Encoded_Length : constant Varint_Policy.Encoded_Value :=
        Varint_Policy.Encode (Varint_Policy.Value_Type (Data_Length));
      Position : Frame_Offset := 1;
   begin
      if Offset > Varint_Policy.Value_Type'Last
        - Varint_Policy.Value_Type (Data_Length)
      then
         return Result;
      end if;

      Result.Data (1) :=
        16#0A#
        + (if Offset > 0 then 4 else 0)
        + (if Fin then 1 else 0);
      for Index in 1 .. Encoded_ID.Length loop
         Result.Data
           (Position + Ada.Streams.Stream_Element_Offset (Index)) :=
             Encoded_ID.Data (Ada.Streams.Stream_Element_Offset (Index));
      end loop;
      Position := Position + Frame_Offset (Encoded_ID.Length);
      if Offset > 0 then
         for Index in 1 .. Encoded_Offset.Length loop
            Result.Data
              (Position + Ada.Streams.Stream_Element_Offset (Index)) :=
                Encoded_Offset.Data
                  (Ada.Streams.Stream_Element_Offset (Index));
         end loop;
         Position := Position + Frame_Offset (Encoded_Offset.Length);
      end if;
      for Index in 1 .. Encoded_Length.Length loop
         Result.Data
           (Position + Ada.Streams.Stream_Element_Offset (Index)) :=
             Encoded_Length.Data
               (Ada.Streams.Stream_Element_Offset (Index));
      end loop;
      Position := Position + Frame_Offset (Encoded_Length.Length);
      if Data_Length > 0 then
         for Index in 0 .. Data_Length - 1 loop
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
end Flyology.QUIC.Stream_Frame_Policy;
