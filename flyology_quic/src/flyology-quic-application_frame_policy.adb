package body Flyology.QUIC.Application_Frame_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Initial_Frame_Policy.Parse_Status;
   use type Stream_Frame_Policy.Parse_Status;
   use type Varint_Policy.Decode_Status;
   use type Varint_Policy.Value_Type;

   function Encode_Stream_Abort
     (Stream_ID         : Varint_Policy.Value_Type;
      Application_Error : Varint_Policy.Value_Type;
      Final_Size        : Varint_Policy.Value_Type)
      return Abort_Encode_Result
   is
      Encoded_ID    : constant Varint_Policy.Encoded_Value :=
        Varint_Policy.Encode (Stream_ID);
      Encoded_Error : constant Varint_Policy.Encoded_Value :=
        Varint_Policy.Encode (Application_Error);
      Encoded_Final : constant Varint_Policy.Encoded_Value :=
        Varint_Policy.Encode (Final_Size);
      Result        : Abort_Encode_Result;
      Cursor        : Natural range 1 .. Max_Abort_Length + 1 := 1;

      procedure Append (Value : Varint_Policy.Encoded_Value)
      with
        Pre => Cursor + Value.Length - 1 <= Max_Abort_Length,
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
      Result.Data (1) := 16#04#;
      Cursor := 2;
      Append (Encoded_ID);
      Append (Encoded_Error);
      Append (Encoded_Final);
      Result.Data (Ada.Streams.Stream_Element_Offset (Cursor)) := 16#05#;
      Cursor := Cursor + 1;
      Append (Encoded_ID);
      Append (Encoded_Error);
      Result.Length := Cursor - 1;
      return Result;
   end Encode_Stream_Abort;

   function Encode_Max_Streams
     (Bidirectional : Boolean;
      Maximum       : Varint_Policy.Value_Type)
      return Max_Streams_Encode_Result
   is
      Encoded : constant Varint_Policy.Encoded_Value :=
        Varint_Policy.Encode (Maximum);
      Result : Max_Streams_Encode_Result;
   begin
      Result.Data (1) := (if Bidirectional then 16#12# else 16#13#);
      Result.Data
        (2 .. Ada.Streams.Stream_Element_Offset (Encoded.Length + 1)) :=
          Encoded.Data
            (1 .. Ada.Streams.Stream_Element_Offset (Encoded.Length));
      --  One-RTT header protection needs at least three plaintext octets.
      --  PADDING is semantically neutral and retransmitted with the frame.
      Result.Length := Natural'Max (3, Encoded.Length + 1);
      return Result;
   end Encode_Max_Streams;

   function Encode_Max_Data
     (Maximum : Varint_Policy.Value_Type)
      return Max_Data_Encode_Result
   is
      Encoded : constant Varint_Policy.Encoded_Value :=
        Varint_Policy.Encode (Maximum);
      Result : Max_Data_Encode_Result;
   begin
      Result.Data (1) := 16#10#;
      Result.Data
        (2 .. Ada.Streams.Stream_Element_Offset (Encoded.Length + 1)) :=
          Encoded.Data
            (1 .. Ada.Streams.Stream_Element_Offset (Encoded.Length));
      Result.Length := Natural'Max (3, Encoded.Length + 1);
      return Result;
   end Encode_Max_Data;

   function Encode_Max_Stream_Data
     (Stream_ID : Varint_Policy.Value_Type;
      Maximum   : Varint_Policy.Value_Type)
      return Max_Stream_Data_Encode_Result
   is
      Encoded_ID : constant Varint_Policy.Encoded_Value :=
        Varint_Policy.Encode (Stream_ID);
      Encoded_Maximum : constant Varint_Policy.Encoded_Value :=
        Varint_Policy.Encode (Maximum);
      Result : Max_Stream_Data_Encode_Result;
      Cursor : Natural range 1 .. Max_Stream_Data_Length + 1 := 2;
   begin
      Result.Data (1) := 16#11#;
      Result.Data
        (Ada.Streams.Stream_Element_Offset (Cursor)
           .. Ada.Streams.Stream_Element_Offset
                (Cursor + Encoded_ID.Length - 1)) :=
          Encoded_ID.Data
            (1 .. Ada.Streams.Stream_Element_Offset (Encoded_ID.Length));
      Cursor := Cursor + Encoded_ID.Length;
      Result.Data
        (Ada.Streams.Stream_Element_Offset (Cursor)
           .. Ada.Streams.Stream_Element_Offset
                (Cursor + Encoded_Maximum.Length - 1)) :=
          Encoded_Maximum.Data
            (1 .. Ada.Streams.Stream_Element_Offset
              (Encoded_Maximum.Length));
      Cursor := Cursor + Encoded_Maximum.Length;
      Result.Length := Natural'Max (3, Cursor - 1);
      return Result;
   end Encode_Max_Stream_Data;

   function Parse_Next
     (Data   : Ada.Streams.Stream_Element_Array;
      Cursor : Frame_Offset) return Parse_Result
   is
      Data_Length : constant Frame_Offset := Frame_Offset (Data'Length);
      Result      : Parse_Result;
      Position    : Frame_Offset := Cursor;
      Success     : Boolean;

      procedure Read_Varint (Value : out Varint_Policy.Value_Type)
      with
        Pre => Position <= Data_Length,
        Post =>
          (if Success then
              Position - Position'Old in 1 | 2 | 4 | 8
              and then Position <= Data_Length
           else Position = Position'Old and Value = 0);

      procedure Read_Varint (Value : out Varint_Policy.Value_Type) is
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
         Position := Position + Frame_Offset (Decoded.Consumed);
         Value := Decoded.Value;
         Success := True;
      end Read_Varint;

      procedure Read_Length
        (Length : out Frame_Offset;
         Offset : out Frame_Offset)
      with
        Pre => Position > Cursor and then Position <= Data_Length,
        Post =>
          (if Success then
              Offset = Position
              and then Position > Cursor
              and then Length <= Data_Length - Position
           else Length = 0 and Offset = 0);

      procedure Read_Length
        (Length : out Frame_Offset;
         Offset : out Frame_Offset)
      is
         Value : Varint_Policy.Value_Type;
      begin
         Length := 0;
         Offset := 0;
         Read_Varint (Value);
         if not Success then
            return;
         elsif Value > Varint_Policy.Value_Type (Frame_Offset'Last)
           or else Frame_Offset (Value) > Data_Length - Position
         then
            Success := False;
            return;
         end if;
         Length := Frame_Offset (Value);
         Offset := Position;
      end Read_Length;

      procedure Finish
      with
        Pre => Position > Cursor and then Position <= Data_Length,
        Post => Result.Status = Parsed
          and then Result.Consumed = Position - Cursor;

      procedure Finish is
      begin
         Result.Consumed := Position - Cursor;
         Result.Status := Parsed;
      end Finish;

   begin
      if Cursor = Data_Length then
         return Result;
      end if;
      Read_Varint (Result.Frame_Type);
      if not Success then
         Result.Status := Truncated;
         return Result;
      end if;

      case Result.Frame_Type is
         when 16#00# | 16#01# | 16#02# | 16#03# | 16#06# | 16#1C# =>
            Result.Base := Initial_Frame_Policy.Parse_Next (Data, Cursor);
            case Result.Base.Status is
               when Initial_Frame_Policy.Parsed =>
                  Result.Consumed := Result.Base.Consumed;
                  Result.Kind :=
                    (case Result.Base.Kind is
                        when Initial_Frame_Policy.Padding => Padding,
                        when Initial_Frame_Policy.Ping => Ping,
                        when Initial_Frame_Policy.Acknowledgment => Acknowledgment,
                        when Initial_Frame_Policy.Crypto => Crypto,
                        when Initial_Frame_Policy.Transport_Close => Transport_Close);
                  Result.Status := Parsed;
               when Initial_Frame_Policy.Truncated =>
                  Result.Status := Truncated;
               when Initial_Frame_Policy.Invalid_ACK_Range =>
                  Result.Status := Invalid_ACK_Range;
               when Initial_Frame_Policy.Frame_Value_Too_Large =>
                  Result.Status := Frame_Value_Too_Large;
               when Initial_Frame_Policy.End_Of_Input
                  | Initial_Frame_Policy.Frame_Type_Not_Allowed =>
                  Result.Status := Unknown_Frame_Type;
            end case;
            pragma Assert
              (if Result.Status = Parsed then Result.Consumed > 0);
            return Result;

         when 16#04# =>
            Result.Kind := Reset_Stream;
            Read_Varint (Result.Stream_ID);
            if not Success then Result.Status := Truncated; return Result; end if;
            Read_Varint (Result.Application_Error);
            if not Success then Result.Status := Truncated; return Result; end if;
            Read_Varint (Result.Final_Size);
            if not Success then Result.Status := Truncated; return Result; end if;
            Finish;

         when 16#05# =>
            Result.Kind := Stop_Sending;
            Read_Varint (Result.Stream_ID);
            if not Success then Result.Status := Truncated; return Result; end if;
            Read_Varint (Result.Application_Error);
            if not Success then Result.Status := Truncated; return Result; end if;
            Finish;

         when 16#07# =>
            Result.Kind := New_Token;
            Read_Length (Result.Token_Length, Result.Token_Offset);
            if not Success then Result.Status := Truncated; return Result; end if;
            Position := Position + Result.Token_Length;
            Finish;

         when 16#08# .. 16#0F# =>
            Result.Kind := Stream;
            Result.Stream_Frame :=
              Stream_Frame_Policy.Parse
                (Data
                   (Data'First + Ada.Streams.Stream_Element_Offset (Cursor)
                      .. Data'Last));
            case Result.Stream_Frame.Status is
               when Stream_Frame_Policy.Parsed =>
                  Result.Consumed := Result.Stream_Frame.Consumed;
                  Result.Stream_ID := Result.Stream_Frame.Stream_ID;
                  pragma Assert
                    (Result.Stream_Frame.Data_Offset <= Data_Length - Cursor);
                  Result.Stream_Data_Offset :=
                    Cursor + Result.Stream_Frame.Data_Offset;
                  pragma Assert
                    (Result.Stream_Data_Offset <= Data_Length);
                  pragma Assert
                    (Result.Stream_Frame.Data_Length <=
                       Data_Length - Result.Stream_Data_Offset);
                  Result.Status := Parsed;
               when Stream_Frame_Policy.Truncated =>
                  Result.Status := Truncated;
               when Stream_Frame_Policy.Stream_Range_Too_Large =>
                  Result.Status := Frame_Value_Too_Large;
               when Stream_Frame_Policy.Not_Stream_Frame =>
                  Result.Status := Unknown_Frame_Type;
            end case;
            pragma Assert
              (if Result.Status = Parsed then Result.Consumed > 0);
            return Result;

         when 16#10# =>
            Result.Kind := Max_Data;
            Read_Varint (Result.Maximum);
            if not Success then Result.Status := Truncated; return Result; end if;
            Finish;

         when 16#11# =>
            Result.Kind := Max_Stream_Data;
            Read_Varint (Result.Stream_ID);
            if not Success then Result.Status := Truncated; return Result; end if;
            Read_Varint (Result.Maximum);
            if not Success then Result.Status := Truncated; return Result; end if;
            Finish;

         when 16#12# | 16#13# | 16#14# | 16#16# | 16#17# =>
            Result.Kind :=
              (case Result.Frame_Type is
                  when 16#12# => Max_Streams_Bidi,
                  when 16#13# => Max_Streams_Uni,
                  when 16#14# => Data_Blocked,
                  when 16#16# => Streams_Blocked_Bidi,
                  when others => Streams_Blocked_Uni);
            Read_Varint (Result.Maximum);
            if not Success then Result.Status := Truncated; return Result; end if;
            Finish;

         when 16#15# =>
            Result.Kind := Stream_Data_Blocked;
            Read_Varint (Result.Stream_ID);
            if not Success then Result.Status := Truncated; return Result; end if;
            Read_Varint (Result.Maximum);
            if not Success then Result.Status := Truncated; return Result; end if;
            Finish;

         when 16#18# =>
            Result.Kind := New_Connection_ID;
            Read_Varint (Result.Sequence);
            if not Success then Result.Status := Truncated; return Result; end if;
            Read_Varint (Result.Retire_Prior_To);
            if not Success then Result.Status := Truncated; return Result; end if;
            if Result.Retire_Prior_To > Result.Sequence then
               Result.Status := Invalid_Connection_ID;
               return Result;
            elsif Position = Data_Length then
               Result.Status := Truncated;
               return Result;
            end if;
            Result.CID_Length :=
              Connection_ID_Length'Min
                (20,
                 Natural
                   (Data
                      (Data'First
                         + Ada.Streams.Stream_Element_Offset (Position))));
            if Result.CID_Length = 0
              or else Natural
                (Data
                   (Data'First + Ada.Streams.Stream_Element_Offset (Position))) > 20
            then
               Result.Status := Invalid_Connection_ID;
               Result.CID_Length := 0;
               return Result;
            end if;
            Position := Position + 1;
            if Result.CID_Length + 16 > Natural (Data_Length - Position) then
               Result.Status := Truncated;
               Result.CID_Length := 0;
               return Result;
            end if;
            Result.CID_Offset := Position;
            Position := Position + Frame_Offset (Result.CID_Length);
            Result.Reset_Token_Offset := Position;
            Position := Position + 16;
            Finish;

         when 16#19# =>
            Result.Kind := Retire_Connection_ID;
            Read_Varint (Result.Sequence);
            if not Success then Result.Status := Truncated; return Result; end if;
            Finish;

         when 16#1A# | 16#1B# =>
            Result.Kind :=
              (if Result.Frame_Type = 16#1A# then Path_Challenge else Path_Response);
            if Data_Length - Position < 8 then
               Result.Status := Truncated;
               return Result;
            end if;
            Result.Path_Data_Offset := Position;
            Position := Position + 8;
            Finish;

         when 16#1D# =>
            Result.Kind := Application_Close;
            Read_Varint (Result.Application_Error);
            if not Success then Result.Status := Truncated; return Result; end if;
            Read_Length (Result.Reason_Length, Result.Reason_Offset);
            if not Success then Result.Status := Truncated; return Result; end if;
            Position := Position + Result.Reason_Length;
            Finish;

         when 16#1E# =>
            Result.Kind := Handshake_Done;
            Finish;

         when others =>
            Result.Status := Unknown_Frame_Type;
      end case;
      pragma Assert
        (if Result.Status = Parsed then Result.Consumed > 0);
      return Result;
   end Parse_Next;
end Flyology.QUIC.Application_Frame_Policy;
