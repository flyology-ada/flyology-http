package body Flyology.QUIC.ACK_Range_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element_Offset;
   use type Initial_Frame_Policy.Frame_Kind;
   use type Initial_Frame_Policy.Parse_Status;
   use type Varint_Policy.Decode_Status;
   use type Varint_Policy.Value_Type;

   function Decode
     (Data  : Ada.Streams.Stream_Element_Array;
      Frame : Initial_Frame_Policy.Parse_Result) return Decode_Result
   is
      Data_Length : constant Initial_Frame_Policy.Frame_Offset :=
        Initial_Frame_Policy.Frame_Offset (Data'Length);
      Position : Initial_Frame_Policy.Frame_Offset :=
        Frame.ACK_Ranges_Offset;
      Result   : Decode_Result;
      Smallest : Varint_Policy.Value_Type;
      Gap      : Varint_Policy.Value_Type;
      Length   : Varint_Policy.Value_Type;
      Largest  : Varint_Policy.Value_Type;
      Parsed   : Varint_Policy.Decode_Result;

      procedure Read
        (Value   : out Varint_Policy.Value_Type;
         Success : out Boolean)
      with
        Pre => Position <= Data_Length,
        Post =>
          (if Success then
              Position > Position'Old and then Position <= Data_Length
           else Position = Position'Old and then Value = 0);

      procedure Read
        (Value   : out Varint_Policy.Value_Type;
         Success : out Boolean)
      is
      begin
         Value := 0;
         Success := False;
         if Position = Data_Length then
            return;
         end if;
         Parsed :=
           Varint_Policy.Decode
             (Data
                (Data'First + Ada.Streams.Stream_Element_Offset (Position)
                   .. Data'Last));
         if Parsed.Status /= Varint_Policy.Decoded then
            return;
         end if;
         pragma Assert
           (Initial_Frame_Policy.Frame_Offset (Parsed.Consumed) <=
              Data_Length - Position);
         Position :=
           Position + Initial_Frame_Policy.Frame_Offset (Parsed.Consumed);
         Value := Parsed.Value;
         Success := True;
      end Read;

      Success : Boolean;
   begin
      if Frame.ACK_Range_Count >= Max_Ranges then
         Result.Status := Too_Many_Ranges;
         return Result;
      elsif Frame.ACK_Ranges_Offset > Data_Length
        or else Frame.First_ACK_Range > Frame.Largest_Acknowledged
      then
         Result.Status := Invalid_Range;
         return Result;
      end if;

      Result.Count := Natural (Frame.ACK_Range_Count) + 1;
      Smallest := Frame.Largest_Acknowledged - Frame.First_ACK_Range;
      Result.Ranges (1) :=
        (Smallest => Smallest, Largest => Frame.Largest_Acknowledged);

      if Result.Count > 1 then
         for Index in 2 .. Result.Count loop
            pragma Loop_Invariant (Position <= Data_Length);
            pragma Loop_Invariant
              (for all Prior in 1 .. Index - 1 =>
                 Result.Ranges (Prior).Smallest <=
                   Result.Ranges (Prior).Largest);
            Read (Gap, Success);
            if not Success then
               Result.Status := Truncated;
               Result.Count := 0;
               return Result;
            end if;
            Read (Length, Success);
            if not Success then
               Result.Status := Truncated;
               Result.Count := 0;
               return Result;
            elsif Smallest < 2 or else Gap > Smallest - 2 then
               Result.Status := Invalid_Range;
               Result.Count := 0;
               return Result;
            end if;
            Largest := Smallest - Gap - 2;
            if Length > Largest then
               Result.Status := Invalid_Range;
               Result.Count := 0;
               return Result;
            end if;
            Smallest := Largest - Length;
            Result.Ranges (Index) :=
              (Smallest => Smallest, Largest => Largest);
         end loop;
      end if;
      pragma Assert
        (for all Index in 1 .. Result.Count =>
           Result.Ranges (Index).Smallest <= Result.Ranges (Index).Largest);
      Result.Status := Decoded;
      return Result;
   end Decode;

   function Acknowledges
     (Item   : Decode_Result;
      Number : Varint_Policy.Value_Type) return Boolean
   is
   begin
      for Index in 1 .. Item.Count loop
         if Number >= Item.Ranges (Index).Smallest
           and then Number <= Item.Ranges (Index).Largest
         then
            return True;
         end if;
      end loop;
      return False;
   end Acknowledges;
end Flyology.QUIC.ACK_Range_Policy;
