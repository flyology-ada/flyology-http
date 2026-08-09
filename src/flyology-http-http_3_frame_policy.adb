package body Flyology.HTTP.HTTP_3_Frame_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element_Offset;
   use type Varint_Policy.Decode_Status;
   use type Varint_Policy.Value_Type;

   function Is_HTTP_2_Reserved
     (Frame_Type : Varint_Policy.Value_Type) return Boolean
   is
     (Frame_Type = Priority_Frame
      or else Frame_Type = Ping_Frame
      or else Frame_Type = Window_Update_Frame
      or else Frame_Type = Continuation_Frame);

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

      Result       : Parse_Result;
      Position     : Frame_Offset := 0;
      Length_Value : Varint_Policy.Value_Type;
      Success      : Boolean;
   begin
      Read_Varint (Position, Result.Frame_Type, Success);
      if not Success then
         return Result;
      end if;
      Read_Varint (Position, Length_Value, Success);
      if not Success then
         return Result;
      elsif Length_Value > Varint_Policy.Value_Type (Frame_Offset'Last) then
         Result.Status := Frame_Length_Too_Large;
         return Result;
      end if;

      Result.Payload_Length := Frame_Offset (Length_Value);
      if Result.Payload_Length > Data_Length - Position then
         Result.Payload_Length := 0;
         return Result;
      end if;
      Result.Payload_Offset := Position;
      Result.Consumed := Position + Result.Payload_Length;
      Result.Status := Parsed;
      return Result;
   end Parse;

   function Encode
     (Frame_Type : Varint_Policy.Value_Type;
      Payload    : Ada.Streams.Stream_Element_Array) return Encode_Result
   is
      Result         : Encode_Result;
      Payload_Length : constant Natural := Natural (Payload'Length);
      Encoded_Type   : constant Varint_Policy.Encoded_Value :=
        Varint_Policy.Encode (Frame_Type);
      Encoded_Length : constant Varint_Policy.Encoded_Value :=
        Varint_Policy.Encode (Varint_Policy.Value_Type (Payload_Length));
      Position       : Frame_Offset := 0;
   begin
      for Index in 1 .. Encoded_Type.Length loop
         Result.Data
           (Position + Ada.Streams.Stream_Element_Offset (Index)) :=
             Encoded_Type.Data (Ada.Streams.Stream_Element_Offset (Index));
      end loop;
      Position := Position + Frame_Offset (Encoded_Type.Length);
      for Index in 1 .. Encoded_Length.Length loop
         Result.Data
           (Position + Ada.Streams.Stream_Element_Offset (Index)) :=
             Encoded_Length.Data (Ada.Streams.Stream_Element_Offset (Index));
      end loop;
      Position := Position + Frame_Offset (Encoded_Length.Length);
      if Payload_Length > 0 then
         for Index in 0 .. Payload_Length - 1 loop
            pragma Loop_Invariant
              (Position + Ada.Streams.Stream_Element_Offset (Index) + 1 <=
                 Max_Encoded_Length);
            Result.Data
              (Position + Ada.Streams.Stream_Element_Offset (Index) + 1) :=
                Payload
                  (Payload'First + Ada.Streams.Stream_Element_Offset (Index));
         end loop;
      end if;
      Result.Length := Natural (Position) + Payload_Length;
      return Result;
   end Encode;
end Flyology.HTTP.HTTP_3_Frame_Policy;
