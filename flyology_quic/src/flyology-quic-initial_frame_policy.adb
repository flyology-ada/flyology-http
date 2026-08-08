package body Flyology.QUIC.Initial_Frame_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element;
   use type Varint_Policy.Decode_Status;
   use type Varint_Policy.Value_Type;

   function Encode_Transport_Close
     (Error_Code : Varint_Policy.Value_Type;
      Frame_Type : Varint_Policy.Value_Type)
      return Transport_Close_Encode_Result
   is
      Encoded_Error : constant Varint_Policy.Encoded_Value :=
        Varint_Policy.Encode (Error_Code);
      Encoded_Frame : constant Varint_Policy.Encoded_Value :=
        Varint_Policy.Encode (Frame_Type);
      Result : Transport_Close_Encode_Result;
      Cursor : Natural range 1 .. Max_Transport_Close_Length + 1 := 1;

      procedure Append (Value : Varint_Policy.Encoded_Value)
      with
        Pre => Cursor + Value.Length - 1 <= Max_Transport_Close_Length,
        Post => Cursor = Cursor'Old + Value.Length;

      procedure Append (Value : Varint_Policy.Encoded_Value) is
      begin
         Result.Data
           (Ada.Streams.Stream_Element_Offset (Cursor)
              .. Ada.Streams.Stream_Element_Offset
                   (Cursor + Value.Length - 1)) :=
             Value.Data
               (1 .. Ada.Streams.Stream_Element_Offset (Value.Length));
         Cursor := Cursor + Value.Length;
      end Append;
   begin
      Result.Data (1) := 16#1C#;
      Cursor := 2;
      Append (Encoded_Error);
      Append (Encoded_Frame);
      Result.Data (Ada.Streams.Stream_Element_Offset (Cursor)) := 0;
      Result.Length := Cursor;
      return Result;
   end Encode_Transport_Close;

   function Parse_Next
     (Data   : Ada.Streams.Stream_Element_Array;
      Cursor : Frame_Offset) return Parse_Result
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
              Position = Position'Old
              and then Value = 0);

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

      Result           : Parse_Result;
      Position         : Frame_Offset := Cursor;
      Success          : Boolean;
      Range_Count      : Varint_Policy.Value_Type;
      Remaining_Ranges : Frame_Offset;
      Smallest         : Varint_Policy.Value_Type;
      Gap              : Varint_Policy.Value_Type;
      ACK_Range        : Varint_Policy.Value_Type;
      Next_Largest     : Varint_Policy.Value_Type;
      Length_Value     : Varint_Policy.Value_Type;
   begin
      Result.Start_Offset := Cursor;
      if Cursor = Data_Length then
         return Result;
      end if;

      Read_Varint (Position, Result.Frame_Type, Success);
      if not Success then
         Result.Status := Truncated;
         return Result;
      end if;
      pragma Assert (Position > Cursor);
      Result.Frame_Type_Bytes := Varint_Bytes (Position - Cursor);

      case Result.Frame_Type is
         when 16#00# =>
            Result.Kind := Padding;
            while Position < Data_Length
              and then
                Data
                  (Data'First
                   + Ada.Streams.Stream_Element_Offset (Position)) = 0
            loop
               pragma Loop_Invariant
                 (Position > Cursor and then Position <= Data_Length);
               pragma Loop_Variant (Decreases => Data_Length - Position);
               Position := Position + 1;
            end loop;
            Result.Padding_Length := Position - Cursor;

         when 16#01# =>
            Result.Kind := Ping;

         when 16#02# | 16#03# =>
            Result.Kind := Acknowledgment;
            Read_Varint
              (Position, Result.Largest_Acknowledged, Success);
            if not Success then
               Result.Status := Truncated;
               return Result;
            end if;
            Read_Varint (Position, Result.ACK_Delay, Success);
            if not Success then
               Result.Status := Truncated;
               return Result;
            end if;
            Read_Varint (Position, Range_Count, Success);
            if not Success then
               Result.Status := Truncated;
               return Result;
            end if;
            Read_Varint (Position, Result.First_ACK_Range, Success);
            if not Success then
               Result.Status := Truncated;
               return Result;
            elsif Result.First_ACK_Range > Result.Largest_Acknowledged then
               Result.Status := Invalid_ACK_Range;
               return Result;
            elsif Range_Count >
              Varint_Policy.Value_Type (Frame_Offset'Last)
            then
               Result.Status := Truncated;
               return Result;
            end if;

            Result.ACK_Range_Count := Frame_Offset (Range_Count);
            if Result.ACK_Range_Count > (Data_Length - Position) / 2 then
               Result.Status := Truncated;
               Result.ACK_Range_Count := 0;
               return Result;
            end if;
            Result.ACK_Ranges_Offset := Position;
            Remaining_Ranges := Result.ACK_Range_Count;
            Smallest :=
              Result.Largest_Acknowledged - Result.First_ACK_Range;
            while Remaining_Ranges > 0 loop
               pragma Loop_Invariant
                 (Position > Cursor and then Position <= Data_Length);
               pragma Loop_Variant (Decreases => Remaining_Ranges);
               Read_Varint (Position, Gap, Success);
               if not Success then
                  Result.Status := Truncated;
                  return Result;
               end if;
               Read_Varint (Position, ACK_Range, Success);
               if not Success then
                  Result.Status := Truncated;
                  return Result;
               elsif Smallest < 2 or else Gap > Smallest - 2 then
                  Result.Status := Invalid_ACK_Range;
                  return Result;
               end if;
               Next_Largest := Smallest - Gap - 2;
               if ACK_Range > Next_Largest then
                  Result.Status := Invalid_ACK_Range;
                  return Result;
               end if;
               Smallest := Next_Largest - ACK_Range;
               Remaining_Ranges := Remaining_Ranges - 1;
            end loop;

            if Result.Frame_Type = 16#03# then
               Read_Varint (Position, Result.ECT0_Count, Success);
               if not Success then
                  Result.Status := Truncated;
                  return Result;
               end if;
               Read_Varint (Position, Result.ECT1_Count, Success);
               if not Success then
                  Result.Status := Truncated;
                  return Result;
               end if;
               Read_Varint (Position, Result.ECN_CE_Count, Success);
               if not Success then
                  Result.Status := Truncated;
                  return Result;
               end if;
            end if;

         when 16#06# =>
            Result.Kind := Crypto;
            Read_Varint (Position, Result.Crypto_Offset, Success);
            if not Success then
               Result.Status := Truncated;
               return Result;
            end if;
            Read_Varint (Position, Length_Value, Success);
            if not Success then
               Result.Status := Truncated;
               return Result;
            elsif Length_Value >
              Varint_Policy.Value_Type'Last - Result.Crypto_Offset
            then
               Result.Status := Frame_Value_Too_Large;
               return Result;
            elsif Length_Value >
              Varint_Policy.Value_Type (Frame_Offset'Last)
            then
               Result.Status := Truncated;
               return Result;
            end if;
            Result.Crypto_Length := Frame_Offset (Length_Value);
            if Result.Crypto_Length > Data_Length - Position then
               Result.Status := Truncated;
               Result.Crypto_Length := 0;
               return Result;
            end if;
            Result.Crypto_Data_Offset := Position;
            Position := Position + Result.Crypto_Length;

         when 16#1C# =>
            Result.Kind := Transport_Close;
            Read_Varint
              (Position, Result.Close_Error_Code, Success);
            if not Success then
               Result.Status := Truncated;
               return Result;
            end if;
            Read_Varint
              (Position, Result.Close_Frame_Type, Success);
            if not Success then
               Result.Status := Truncated;
               return Result;
            end if;
            Read_Varint (Position, Length_Value, Success);
            if not Success then
               Result.Status := Truncated;
               return Result;
            elsif Length_Value >
              Varint_Policy.Value_Type (Frame_Offset'Last)
            then
               Result.Status := Truncated;
               return Result;
            end if;
            Result.Close_Reason_Length := Frame_Offset (Length_Value);
            if Result.Close_Reason_Length > Data_Length - Position then
               Result.Status := Truncated;
               Result.Close_Reason_Length := 0;
               return Result;
            end if;
            Result.Close_Reason_Offset := Position;
            Position := Position + Result.Close_Reason_Length;

         when others =>
            Result.Status := Frame_Type_Not_Allowed;
            return Result;
      end case;

      pragma Assert (Position > Cursor);
      Result.Consumed := Position - Cursor;
      Result.Status := Parsed;
      return Result;
   end Parse_Next;
end Flyology.QUIC.Initial_Frame_Policy;
