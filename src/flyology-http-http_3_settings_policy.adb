package body Flyology.HTTP.HTTP_3_Settings_Policy
  with SPARK_Mode => On
is
   use type Varint_Policy.Decode_Status;
   use type Varint_Policy.Value_Type;

   subtype Setting_Index is Positive range 1 .. Max_Setting_Count;
   type Identifier_Array is
     array (Setting_Index) of Varint_Policy.Value_Type;

   function Decode
     (Data : Ada.Streams.Stream_Element_Array) return Decode_Result
   is
      Data_Length : constant Payload_Offset := Payload_Offset (Data'Length);

      procedure Read_Varint
        (Position : in out Payload_Offset;
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
        (Position : in out Payload_Offset;
         Value    : out Varint_Policy.Value_Type;
         Success  : out Boolean)
      is
         Item : Varint_Policy.Decode_Result;
      begin
         Value := 0;
         Success := False;
         if Position = Data_Length then
            return;
         end if;
         Item :=
           Varint_Policy.Decode
             (Data
                (Data'First + Ada.Streams.Stream_Element_Offset (Position)
                   .. Data'Last));
         if Item.Status /= Varint_Policy.Decoded then
            return;
         end if;
         pragma Assert
           (Payload_Offset (Item.Consumed) <= Data_Length - Position);
         Value := Item.Value;
         Position := Position + Payload_Offset (Item.Consumed);
         Success := True;
      end Read_Varint;

      Result     : Decode_Result;
      Seen       : Identifier_Array := (others => 0);
      Position   : Payload_Offset := 0;
      Identifier : Varint_Policy.Value_Type;
      Value      : Varint_Policy.Value_Type;
      Success    : Boolean;
      Duplicate  : Boolean;
   begin
      while Position < Data_Length loop
         pragma Loop_Invariant (Position <= Data_Length);
         pragma Loop_Variant (Decreases => Data_Length - Position);

         Read_Varint (Position, Identifier, Success);
         if not Success then
            return Result;
         end if;
         Read_Varint (Position, Value, Success);
         if not Success then
            return Result;
         end if;

         Duplicate := False;
         for Index in Setting_Index loop
            pragma Loop_Invariant (not Duplicate or else Result.Count > 0);
            if Index <= Result.Count and then Seen (Index) = Identifier then
               Duplicate := True;
            end if;
         end loop;
         if Duplicate then
            Result.Status := Duplicate_Identifier;
            return Result;
         elsif Identifier in 16#02# .. 16#05# then
            Result.Status := Forbidden_Identifier;
            return Result;
         elsif Result.Count = Max_Setting_Count then
            Result.Status := Too_Many_Settings;
            return Result;
         end if;

         Result.Count := Result.Count + 1;
         Seen (Result.Count) := Identifier;
         case Identifier is
            when QPACK_Max_Table_Capacity =>
               Result.Value.QPACK_Table_Capacity := Value;
            when QPACK_Blocked_Streams =>
               Result.Value.QPACK_Blocked := Value;
            when Max_Field_Section_Size =>
               Result.Value.Has_Max_Field_Size := True;
               Result.Value.Max_Field_Size := Value;
            when others =>
               null;
         end case;
      end loop;
      Result.Status := Decoded;
      return Result;
   end Decode;

   function Encode (Value : Settings) return Encode_Result
   is
      Result   : Encode_Result;
      Position : Encoded_Length := 0;

      procedure Append (Item : Varint_Policy.Value_Type)
      with
        Pre => Position <= Max_Encoded_Length - 8,
        Post => Position - Position'Old in 1 | 2 | 4 | 8;

      procedure Append (Item : Varint_Policy.Value_Type)
      is
         Encoded : constant Varint_Policy.Encoded_Value :=
           Varint_Policy.Encode (Item);
      begin
         for Index in 1 .. Encoded.Length loop
            Result.Data
              (Ada.Streams.Stream_Element_Offset (Position + Index)) :=
                Encoded.Data (Ada.Streams.Stream_Element_Offset (Index));
         end loop;
         Position := Position + Encoded.Length;
      end Append;
   begin
      Append (QPACK_Max_Table_Capacity);
      Append (Value.QPACK_Table_Capacity);
      Append (QPACK_Blocked_Streams);
      Append (Value.QPACK_Blocked);
      if Value.Has_Max_Field_Size then
         Append (Max_Field_Section_Size);
         Append (Value.Max_Field_Size);
      end if;
      Result.Length := Position;
      return Result;
   end Encode;
end Flyology.HTTP.HTTP_3_Settings_Policy;
