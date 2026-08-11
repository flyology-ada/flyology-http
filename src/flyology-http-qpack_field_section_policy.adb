with Flyology.HTTP.Header_Huffman_Policy;
with Flyology.HTTP.QPACK_Integer_Policy;
with Flyology.HTTP.QPACK_Static_Table;

package body Flyology.HTTP.QPACK_Field_Section_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element;
   use type QPACK_Integer_Policy.Decode_Status;
   use type Header_Huffman_Policy.Decode_Status;

   function Make_Field (Name, Value : String) return Header_Field is
      Result : Header_Field;
   begin
      Result.Name_Size := Name'Length;
      for Offset in 0 .. Name'Length - 1 loop
         Result.Name (Offset + 1) := Name (Name'First + Offset);
      end loop;
      Result.Value_Size := Value'Length;
      if Value'Length > 0 then
         for Offset in 0 .. Value'Length - 1 loop
            Result.Value (Offset + 1) := Value (Value'First + Offset);
         end loop;
      end if;
      return Result;
   end Make_Field;

   function Field_Name (Item : Header_Field) return String is
     (Item.Name (1 .. Item.Name_Size));

   function Field_Value (Item : Header_Field) return String is
     (if Item.Value_Size = 0 then "" else Item.Value (1 .. Item.Value_Size));

   function Field_Section_Size
     (Block : Header_Block) return Field_Section_Size_Type
   is
      Result : Field_Section_Size_Type := 0;
   begin
      for Index in 1 .. Block.Count loop
         pragma Loop_Invariant
           (Result <=
              (Index - 1) *
                (Max_Name_Length + Max_Value_Length + 32));
         Result := Result
           + Block.Fields (Index).Name_Size
           + Block.Fields (Index).Value_Size
           + 32;
      end loop;
      return Result;
   end Field_Section_Size;

   procedure Decode_Into
     (Data     : Ada.Streams.Stream_Element_Array;
      Block    : in out Header_Block;
      Status   : out Decode_Status;
      Consumed : out Decode_Length)
   is
      Data_Length : constant Natural := Natural (Data'Length);
      subtype Cursor is Natural range 0 .. Data_Length;
      Position    : Cursor := 0;

      function Byte_At (Offset : Natural) return Ada.Streams.Stream_Element
      with Pre => Offset < Data_Length;

      function Byte_At (Offset : Natural) return Ada.Streams.Stream_Element is
        (Data (Data'First + Ada.Streams.Stream_Element_Offset (Offset)));

      procedure Read_Integer
        (Bits    : QPACK_Integer_Policy.Prefix_Size;
         Value   : out QPACK_Integer_Policy.Value_Type;
         Success : out Boolean)
      with
        Pre => Position <= Data_Length,
        Post =>
          (if Success then
              Position > Position'Old
                and then Position <= Data_Length
                and then Position - Position'Old <= 4
           else Position = Position'Old and then Value = 0);

      procedure Read_Integer
        (Bits    : QPACK_Integer_Policy.Prefix_Size;
         Value   : out QPACK_Integer_Policy.Value_Type;
         Success : out Boolean)
      is
         Parsed : QPACK_Integer_Policy.Decode_Result;
      begin
         Value := 0;
         Success := False;
         if Position = Data_Length then
            return;
         end if;
         declare
            Available : constant Natural :=
              Natural'Min (4, Data_Length - Position);
            First_Index : constant Ada.Streams.Stream_Element_Offset :=
              Data'First + Ada.Streams.Stream_Element_Offset (Position);
            Last_Index : constant Ada.Streams.Stream_Element_Offset :=
              First_Index + Ada.Streams.Stream_Element_Offset (Available - 1);
         begin
            pragma Assert (Available in 1 .. 4);
            pragma Assert (Last_Index <= Data'Last);
            Parsed :=
              QPACK_Integer_Policy.Decode
                (Data (First_Index .. Last_Index), Bits);
         end;
         if Parsed.Status /= QPACK_Integer_Policy.Decoded then
            return;
         end if;
         pragma Assert (Parsed.Consumed <= Data_Length - Position);
         pragma Assert (Position + Parsed.Consumed <= Data_Length);
         Position := Position + Parsed.Consumed;
         Value := Parsed.Value;
         Success := True;
      end Read_Integer;

      procedure Append_Field (Item : Header_Field; Success : out Boolean)
      with
        Post =>
          (if Success then Block.Count = Block.Count'Old + 1
           else Block.Count = Block.Count'Old);

      procedure Append_Field (Item : Header_Field; Success : out Boolean) is
      begin
         Success := False;
         if Block.Count = Max_Fields then
            return;
         end if;
         Block.Count := Block.Count + 1;
         Block.Fields (Block.Count) := Item;
         Success := True;
      end Append_Field;

      procedure Read_String
        (Target     : out String;
         Length     : out Natural;
         Status     : out Decode_Status;
         Prefix_Bits : QPACK_Integer_Policy.Prefix_Size := 7;
         Huffman_Bit : Ada.Streams.Stream_Element := 16#80#)
      with
        Pre => Target'First = 1
          and then Target'Length <= Max_Value_Length,
        Post =>
          (if Status = Decoded then
              Length <= Target'Length
              and then Position > Position'Old
              and then Position <= Data_Length
           else Length = 0);

      procedure Read_String
        (Target      : out String;
         Length      : out Natural;
         Status      : out Decode_Status;
         Prefix_Bits : QPACK_Integer_Policy.Prefix_Size := 7;
         Huffman_Bit : Ada.Streams.Stream_Element := 16#80#)
      is
         Encoded_Length : QPACK_Integer_Policy.Value_Type;
         Success        : Boolean;
         First_Position : constant Natural := Position;
         Huffman        : Boolean;
      begin
         Target := (others => Character'Val (0));
         Length := 0;
         Status := Truncated;
         if Position = Data_Length then
            return;
         end if;
         Huffman := (Byte_At (Position) and Huffman_Bit) /= 0;
         Read_Integer (Prefix_Bits, Encoded_Length, Success);
         if not Success then
            Position := First_Position;
            return;
         elsif Natural (Encoded_Length) > Data_Length - Position then
            Position := First_Position;
            return;
         end if;
         if Huffman then
            declare
               Parsed : Header_Huffman_Policy.Decode_Result;
            begin
               if Encoded_Length = 0 then
                  Parsed := Header_Huffman_Policy.Decode
                    (Ada.Streams.Stream_Element_Array'(1 .. 0 => 0),
                     Header_Huffman_Policy.Output_Length (Target'Length));
               else
                  Parsed := Header_Huffman_Policy.Decode
                    (Data
                       (Data'First
                          + Ada.Streams.Stream_Element_Offset (Position)
                        .. Data'First
                             + Ada.Streams.Stream_Element_Offset
                                 (Position + Natural (Encoded_Length) - 1)),
                     Header_Huffman_Policy.Output_Length (Target'Length));
               end if;
               if Parsed.Status = Header_Huffman_Policy.Output_Too_Large then
                  Status := Field_Too_Large;
                  return;
               elsif Parsed.Status /= Header_Huffman_Policy.Decoded then
                  Status := Invalid_Huffman;
                  return;
               end if;
               Length := Parsed.Length;
               for Offset in 1 .. Length loop
                  Target (Offset) := Parsed.Data (Offset);
               end loop;
            end;
         else
            if Encoded_Length >
              QPACK_Integer_Policy.Value_Type (Target'Length)
            then
               Status := Field_Too_Large;
               return;
            end if;
            Length := Natural (Encoded_Length);
            if Length > 0 then
               for Offset in 0 .. Length - 1 loop
                  Target (Offset + 1) :=
                    Character'Val (Byte_At (Position + Offset));
               end loop;
            end if;
         end if;
         pragma Assert (Natural (Encoded_Length) <= Data_Length - Position);
         pragma Assert
           (Position + Natural (Encoded_Length) <= Data_Length);
         Position := Position + Natural (Encoded_Length);
         Status := Decoded;
      end Read_String;

      Required_Insert_Count : QPACK_Integer_Policy.Value_Type;
      Delta_Base            : QPACK_Integer_Policy.Value_Type;
      Index                 : QPACK_Integer_Policy.Value_Type;
      Success               : Boolean;
      Item                  : Header_Field;
      String_Status         : Decode_Status;
      Octet                 : Ada.Streams.Stream_Element;
   begin
      Block.Count := 0;
      Status := Truncated;
      Consumed := 0;
      Read_Integer (8, Required_Insert_Count, Success);
      if not Success then
         return;
      elsif Required_Insert_Count /= 0 then
         Status := Unsupported_Dynamic;
         return;
      elsif Position = Data_Length then
         return;
      elsif (Byte_At (Position) and 16#80#) /= 0 then
         Status := Invalid_Prefix;
         return;
      end if;
      Read_Integer (7, Delta_Base, Success);
      if not Success then
         return;
      elsif Delta_Base /= 0 then
         Status := Invalid_Prefix;
         return;
      end if;

      while Position < Data_Length loop
         pragma Loop_Variant (Decreases => Data_Length - Position);
         Octet := Byte_At (Position);
         Item := (others => <>);

         if (Octet and 16#80#) /= 0 then
            if (Octet and 16#40#) = 0 then
               Status := Unsupported_Dynamic;
               return;
            end if;
            Read_Integer (6, Index, Success);
            if not Success then
               return;
            elsif Index > QPACK_Integer_Policy.Value_Type
                (QPACK_Static_Table.Static_Index'Last)
            then
               Status := Invalid_Static_Index;
               return;
            end if;
            Item :=
              Make_Field
                (QPACK_Static_Table.Name
                   (QPACK_Static_Table.Static_Index (Index)),
                 QPACK_Static_Table.Value
                   (QPACK_Static_Table.Static_Index (Index)));

         elsif (Octet and 16#C0#) = 16#40# then
            if (Octet and 16#10#) = 0 then
               Status := Unsupported_Dynamic;
               return;
            end if;
            Read_Integer (4, Index, Success);
            if not Success then
               return;
            elsif Index > QPACK_Integer_Policy.Value_Type
                (QPACK_Static_Table.Static_Index'Last)
            then
               Status := Invalid_Static_Index;
               return;
            end if;
            declare
               Static_Name : constant String :=
                 QPACK_Static_Table.Name
                   (QPACK_Static_Table.Static_Index (Index));
            begin
               Item.Name_Size := Static_Name'Length;
               for Offset in 0 .. Static_Name'Length - 1 loop
                  Item.Name (Offset + 1) :=
                    Static_Name (Static_Name'First + Offset);
               end loop;
            end;
            Read_String (Item.Value, Item.Value_Size, String_Status);
            if String_Status /= Decoded then
               Status := String_Status;
               return;
            end if;

         elsif (Octet and 16#E0#) = 16#20# then
            Read_String
              (Item.Name,
               Item.Name_Size,
               String_Status,
               Prefix_Bits => 3,
               Huffman_Bit => 16#08#);
            if String_Status /= Decoded then
               Status := String_Status;
               return;
            elsif Item.Name_Size = 0 then
               Status := Field_Too_Large;
               return;
            end if;
            Read_String (Item.Value, Item.Value_Size, String_Status);
            if String_Status /= Decoded then
               Status := String_Status;
               return;
            end if;

         else
            Status := Unsupported_Dynamic;
            return;
         end if;

         Append_Field (Item, Success);
         if not Success then
            Status := Too_Many_Fields;
            return;
         end if;
      end loop;

      pragma Assert (Position = Data_Length);
      Status := Decoded;
      Consumed := Data_Length;
      pragma Assert
        (Status = Decoded and then Consumed = Data_Length);
   end Decode_Into;

   function Decode
     (Data : Ada.Streams.Stream_Element_Array) return Decode_Result
   is
      Result : Decode_Result;
   begin
      Decode_Into (Data, Result.Block, Result.Status, Result.Consumed);
      return Result;
   end Decode;

   function Encode (Block : Header_Block) return Encode_Result is
      subtype Output_Cursor is Natural range 2 .. Max_Encode_Length;
      Result   : Encode_Result;
      Position : Output_Cursor := 2;
      Failed   : Boolean := False;

      procedure Append_Byte (Value : Ada.Streams.Stream_Element)
      with Post => Position >= Position'Old;

      procedure Append_Byte (Value : Ada.Streams.Stream_Element) is
      begin
         if Position = Max_Encode_Length then
            Failed := True;
         else
            Position := Position + 1;
            Result.Data (Ada.Streams.Stream_Element_Offset (Position)) :=
              Value;
         end if;
      end Append_Byte;

      procedure Append_Integer
        (Value     : QPACK_Integer_Policy.Value_Type;
         Bits      : QPACK_Integer_Policy.Prefix_Size;
         High_Bits : Ada.Streams.Stream_Element)
      with
        Pre =>
          (High_Bits and QPACK_Integer_Policy.Prefix_Mask (Bits)) = 0,
        Post => Position >= Position'Old;

      procedure Append_Integer
        (Value     : QPACK_Integer_Policy.Value_Type;
         Bits      : QPACK_Integer_Policy.Prefix_Size;
         High_Bits : Ada.Streams.Stream_Element)
      is
         Encoded_Value : constant QPACK_Integer_Policy.Encode_Result :=
           QPACK_Integer_Policy.Encode (Value, Bits, High_Bits);
      begin
         if Encoded_Value.Length > Max_Encode_Length - Position then
            Failed := True;
            return;
         end if;
         for Offset in 1 .. Encoded_Value.Length loop
            Append_Byte
              (Encoded_Value.Data
                 (Ada.Streams.Stream_Element_Offset (Offset)));
         end loop;
      end Append_Integer;

      procedure Append_String (Value : String)
      with
        Pre => Value'Length <= QPACK_Integer_Policy.Max_Value;

      procedure Append_String (Value : String) is
      begin
         Append_Integer (Value'Length, 7, 0);
         if not Failed and then Value'Length > 0 then
            if Value'Length > Max_Encode_Length - Position then
               Failed := True;
               return;
            end if;
            for Offset in 0 .. Value'Length - 1 loop
               Append_Byte
                 (Ada.Streams.Stream_Element
                    (Character'Pos (Value (Value'First + Offset))));
            end loop;
         end if;
      end Append_String;

      Exact : QPACK_Static_Table.Lookup_Result;
      Named : QPACK_Static_Table.Lookup_Result;
   begin
      Result.Data (1) := 0;
      Result.Data (2) := 0;
      for Field_Number in 1 .. Block.Count loop
         declare
            Item       : Header_Field renames Block.Fields (Field_Number);
            Name_Text  : constant String := Field_Name (Item);
            Value_Text : constant String := Field_Value (Item);
         begin
            QPACK_Static_Table.Find
              (Name_Text, Value_Text, Exact, Named);
            if Exact.Found then
               pragma Assert
                 ((Ada.Streams.Stream_Element'(16#C0#)
                    and QPACK_Integer_Policy.Prefix_Mask (6)) = 0);
               Append_Integer
                 (QPACK_Integer_Policy.Value_Type (Exact.Index), 6, 16#C0#);
            else
               if Named.Found then
                  pragma Assert
                    ((Ada.Streams.Stream_Element'(16#50#)
                       and QPACK_Integer_Policy.Prefix_Mask (4)) = 0);
                  Append_Integer
                    (QPACK_Integer_Policy.Value_Type (Named.Index), 4, 16#50#);
               else
                  pragma Assert (Name_Text'Length <= Max_Name_Length);
                  pragma Assert
                    ((Ada.Streams.Stream_Element'(16#20#)
                       and QPACK_Integer_Policy.Prefix_Mask (3)) = 0);
                  Append_Integer
                    (QPACK_Integer_Policy.Value_Type (Name_Text'Length),
                     3,
                     16#20#);
                  if not Failed then
                     if Name_Text'Length > Max_Encode_Length - Position then
                        Failed := True;
                     else
                        for Offset in 0 .. Name_Text'Length - 1 loop
                           Append_Byte
                             (Ada.Streams.Stream_Element
                                (Character'Pos
                                   (Name_Text (Name_Text'First + Offset))));
                        end loop;
                     end if;
                  end if;
               end if;
               if not Failed then
                  Append_String (Value_Text);
               end if;
            end if;
         end;
         exit when Failed;
      end loop;

      Result.Length := Position;
      if Failed then
         Result.Status := Section_Too_Large;
      end if;
      return Result;
   end Encode;
end Flyology.HTTP.QPACK_Field_Section_Policy;
