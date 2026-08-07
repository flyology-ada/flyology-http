package body Flyology.QUIC.Transport_Parameter_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element;
   use type Varint_Policy.Decode_Status;
   use type Varint_Policy.Value_Type;

   Original_Destination_Connection_ID : constant := 16#00#;
   Max_Idle_Timeout                   : constant := 16#01#;
   Stateless_Reset_Token              : constant := 16#02#;
   Max_UDP_Payload_Size               : constant := 16#03#;
   Initial_Max_Data                   : constant := 16#04#;
   Initial_Max_Stream_Data_Bidi_Local : constant := 16#05#;
   Initial_Max_Stream_Data_Bidi_Remote : constant := 16#06#;
   Initial_Max_Stream_Data_Uni        : constant := 16#07#;
   Initial_Max_Streams_Bidi           : constant := 16#08#;
   Initial_Max_Streams_Uni            : constant := 16#09#;
   ACK_Delay_Exponent                 : constant := 16#0A#;
   Max_ACK_Delay                      : constant := 16#0B#;
   Disable_Active_Migration           : constant := 16#0C#;
   Preferred_Address                 : constant := 16#0D#;
   Active_Connection_ID_Limit         : constant := 16#0E#;
   Initial_Source_Connection_ID       : constant := 16#0F#;
   Retry_Source_Connection_ID         : constant := 16#10#;

   function Decode
     (Data        : Ada.Streams.Stream_Element_Array;
      Sender_Role : Endpoint_Role) return Decode_Result
   is
      subtype Cursor_Type is Natural range 0 .. 65_535;
      subtype Seen_Index is Positive range 1 .. Max_Transport_Parameters;
      type Seen_Array is array (Seen_Index) of Varint_Policy.Value_Type;

      Data_Length : constant Cursor_Type := Cursor_Type (Data'Length);
      Seen        : Seen_Array := (others => 0);
      Position    : Cursor_Type := 0;
      Result      : Decode_Result;

      procedure Read_Varint
        (Cursor  : in out Cursor_Type;
         Value   : out Varint_Policy.Value_Type;
         Success : out Boolean)
      with
        Pre => Cursor <= Data_Length,
        Post =>
          (if Success then
              Cursor - Cursor'Old in 1 | 2 | 4 | 8
              and then Cursor <= Data_Length
           else
              Cursor = Cursor'Old and then Value = 0);

      procedure Read_Varint
        (Cursor  : in out Cursor_Type;
         Value   : out Varint_Policy.Value_Type;
         Success : out Boolean)
      is
         Decoded_Value : Varint_Policy.Decode_Result;
      begin
         Value := 0;
         Success := False;
         if Cursor = Data_Length then
            return;
         end if;
         Decoded_Value :=
           Varint_Policy.Decode
             (Data
                (Data'First + Ada.Streams.Stream_Element_Offset (Cursor)
                 .. Data'Last));
         if Decoded_Value.Status /= Varint_Policy.Decoded then
            return;
         end if;
         pragma Assert
           (Cursor_Type (Decoded_Value.Consumed) <= Data_Length - Cursor);
         Cursor := Cursor + Cursor_Type (Decoded_Value.Consumed);
         Value := Decoded_Value.Value;
         Success := True;
      end Read_Varint;

      function Already_Seen
        (Identifier : Varint_Policy.Value_Type) return Boolean
      with
        Pre => Result.Count < Max_Transport_Parameters,
        Global => (Input => (Seen, Result));

      function Already_Seen
        (Identifier : Varint_Policy.Value_Type) return Boolean
      is
      begin
         for Index in Seen_Index range 1 .. Result.Count loop
            pragma Loop_Invariant (Index <= Result.Count);
            if Seen (Index) = Identifier then
               return True;
            end if;
         end loop;
         return False;
      end Already_Seen;

      procedure Decode_Integer
        (Value_Start  : Cursor_Type;
         Value_Length : Cursor_Type;
         Value        : out Varint_Policy.Value_Type;
         Success      : out Boolean)
      with
        Pre =>
          Value_Start <= Data_Length
          and then Value_Length <= Data_Length - Value_Start,
        Post => (if not Success then Value = 0);

      procedure Decode_Integer
        (Value_Start  : Cursor_Type;
         Value_Length : Cursor_Type;
         Value        : out Varint_Policy.Value_Type;
         Success      : out Boolean)
      is
         Decoded_Value : Varint_Policy.Decode_Result;
      begin
         Value := 0;
         Success := False;
         if Value_Length = 0 then
            return;
         end if;
         Decoded_Value :=
           Varint_Policy.Decode
             (Data
                (Data'First
                   + Ada.Streams.Stream_Element_Offset (Value_Start)
                 .. Data'First
                   + Ada.Streams.Stream_Element_Offset
                       (Value_Start + Value_Length - 1)));
         if Decoded_Value.Status /= Varint_Policy.Decoded
           or else Decoded_Value.Consumed /= Value_Length
         then
            return;
         end if;
         Value := Decoded_Value.Value;
         Success := True;
      end Decode_Integer;

      procedure Copy_Connection_ID
        (Value_Start  : Cursor_Type;
         Value_Length : Connection_ID_Length;
         Target       : out Connection_ID_Parameter)
      with
        Pre =>
          Value_Start <= Data_Length
          and then Cursor_Type (Value_Length) <= Data_Length - Value_Start,
        Post => Target.Present and then Target.Length = Value_Length;

      procedure Copy_Connection_ID
        (Value_Start  : Cursor_Type;
         Value_Length : Connection_ID_Length;
         Target       : out Connection_ID_Parameter)
      is
      begin
         Target := (Present => True, Data => (others => 0), Length => Value_Length);
         for Offset in Natural range 0 .. Natural (Value_Length) - 1 loop
            pragma Loop_Invariant (Target.Present);
            pragma Loop_Invariant (Target.Length = Value_Length);
            Target.Data
              (1 + Ada.Streams.Stream_Element_Offset (Offset)) :=
                Data
                  (Data'First
                   + Ada.Streams.Stream_Element_Offset (Value_Start + Offset));
         end loop;
      end Copy_Connection_ID;

      Identifier     : Varint_Policy.Value_Type;
      Length_Value   : Varint_Policy.Value_Type;
      Value          : Varint_Policy.Value_Type;
      Value_Start    : Cursor_Type;
      Value_Length   : Cursor_Type;
      Parameter_Start : Cursor_Type;
      Success        : Boolean;
      CID_Length     : Connection_ID_Length;
      Preferred_CID_Length : Natural range 0 .. 255;
   begin
      Result.Status := Decoded;
      while Position < Data_Length loop
         pragma Loop_Invariant (Position <= Data_Length);
         pragma Loop_Invariant (Result.Count <= Max_Transport_Parameters);
         pragma Loop_Variant (Decreases => Data_Length - Position);

         if Result.Count = Max_Transport_Parameters then
            Result.Status := Too_Many_Parameters;
            return Result;
         end if;
         Parameter_Start := Position;
         Read_Varint (Position, Identifier, Success);
         if not Success then
            Result.Status := Truncated;
            return Result;
         end if;
         Read_Varint (Position, Length_Value, Success);
         if not Success
           or else Length_Value > Varint_Policy.Value_Type (Data_Length - Position)
         then
            Result.Status := Truncated;
            return Result;
         end if;
         Value_Length := Cursor_Type (Length_Value);
         Value_Start := Position;
         Position := Position + Value_Length;
         pragma Assert (Position > Parameter_Start);

         if Already_Seen (Identifier) then
            Result.Status := Duplicate_Parameter;
            return Result;
         end if;
         Result.Count := Result.Count + 1;
         Seen (Result.Count) := Identifier;

         if Sender_Role = Client
           and then Identifier in
             Original_Destination_Connection_ID
             | Stateless_Reset_Token
             | Preferred_Address
             | Retry_Source_Connection_ID
         then
            Result.Status := Forbidden_Parameter;
            return Result;
         end if;

         case Identifier is
            when Original_Destination_Connection_ID =>
               if Value_Length > Connection_ID_Length'Last then
                  Result.Status := Invalid_Parameter_Value;
                  return Result;
               end if;
               CID_Length := Connection_ID_Length (Value_Length);
               Copy_Connection_ID
                 (Value_Start, CID_Length,
                  Result.Parameters.Original_Destination_Connection_ID);

            when Stateless_Reset_Token =>
               if Value_Length /= 16 then
                  Result.Status := Invalid_Parameter_Value;
                  return Result;
               end if;
               Result.Parameters.Stateless_Reset_Token.Present := True;
               for Offset in Natural range 0 .. 15 loop
                  Result.Parameters.Stateless_Reset_Token.Data
                    (1 + Ada.Streams.Stream_Element_Offset (Offset)) :=
                      Data
                        (Data'First
                         + Ada.Streams.Stream_Element_Offset
                             (Value_Start + Offset));
               end loop;

            when Disable_Active_Migration =>
               if Value_Length /= 0 then
                  Result.Status := Invalid_Parameter_Value;
                  return Result;
               end if;
               Result.Parameters.Disable_Active_Migration := True;

            when Preferred_Address =>
               if Value_Length < 41 or else Value_Length > 61 then
                  Result.Status := Invalid_Parameter_Value;
                  return Result;
               end if;
               Preferred_CID_Length :=
                 Natural
                   (Data
                      (Data'First
                       + Ada.Streams.Stream_Element_Offset
                           (Value_Start + 24)));
               if Preferred_CID_Length > 20
                 or else Value_Length /= 41 + Preferred_CID_Length
               then
                  Result.Status := Invalid_Parameter_Value;
                  return Result;
               end if;
               Result.Parameters.Preferred_Address_Received := True;

            when Initial_Source_Connection_ID | Retry_Source_Connection_ID =>
               if Value_Length > Connection_ID_Length'Last then
                  Result.Status := Invalid_Parameter_Value;
                  return Result;
               end if;
               CID_Length := Connection_ID_Length (Value_Length);
               if Identifier = Initial_Source_Connection_ID then
                  Copy_Connection_ID
                    (Value_Start, CID_Length,
                     Result.Parameters.Initial_Source_Connection_ID);
               else
                  Copy_Connection_ID
                    (Value_Start, CID_Length,
                     Result.Parameters.Retry_Source_Connection_ID);
               end if;

            when Max_Idle_Timeout
               | Max_UDP_Payload_Size
               | Initial_Max_Data
               | Initial_Max_Stream_Data_Bidi_Local
               | Initial_Max_Stream_Data_Bidi_Remote
               | Initial_Max_Stream_Data_Uni
               | Initial_Max_Streams_Bidi
               | Initial_Max_Streams_Uni
               | ACK_Delay_Exponent
               | Max_ACK_Delay
               | Active_Connection_ID_Limit =>
               Decode_Integer (Value_Start, Value_Length, Value, Success);
               if not Success then
                  Result.Status := Invalid_Parameter_Value;
                  return Result;
               end if;
               if (Identifier = Max_UDP_Payload_Size and then Value < 1_200)
                 or else
                   (Identifier in Initial_Max_Streams_Bidi
                                  | Initial_Max_Streams_Uni
                    and then Value > 2**60)
                 or else
                   (Identifier = ACK_Delay_Exponent and then Value > 20)
                 or else (Identifier = Max_ACK_Delay and then Value >= 2**14)
                 or else
                   (Identifier = Active_Connection_ID_Limit and then Value < 2)
               then
                  Result.Status := Invalid_Parameter_Value;
                  return Result;
               end if;

               case Identifier is
                  when Max_Idle_Timeout =>
                     Result.Parameters.Max_Idle_Timeout := (True, Value);
                  when Max_UDP_Payload_Size =>
                     Result.Parameters.Max_UDP_Payload_Size := (True, Value);
                  when Initial_Max_Data =>
                     Result.Parameters.Initial_Max_Data := (True, Value);
                  when Initial_Max_Stream_Data_Bidi_Local =>
                     Result.Parameters.Initial_Max_Stream_Data_Bidi_Local :=
                       (True, Value);
                  when Initial_Max_Stream_Data_Bidi_Remote =>
                     Result.Parameters.Initial_Max_Stream_Data_Bidi_Remote :=
                       (True, Value);
                  when Initial_Max_Stream_Data_Uni =>
                     Result.Parameters.Initial_Max_Stream_Data_Uni :=
                       (True, Value);
                  when Initial_Max_Streams_Bidi =>
                     Result.Parameters.Initial_Max_Streams_Bidi :=
                       (True, Value);
                  when Initial_Max_Streams_Uni =>
                     Result.Parameters.Initial_Max_Streams_Uni :=
                       (True, Value);
                  when ACK_Delay_Exponent =>
                     Result.Parameters.ACK_Delay_Exponent := (True, Value);
                  when Max_ACK_Delay =>
                     Result.Parameters.Max_ACK_Delay := (True, Value);
                  when Active_Connection_ID_Limit =>
                     Result.Parameters.Active_Connection_ID_Limit :=
                       (True, Value);
                  when others =>
                     raise Program_Error;
               end case;

            when others =>
               null;
         end case;
      end loop;

      if not Result.Parameters.Initial_Source_Connection_ID.Present
        or else
          (Sender_Role = Server
           and then
             not Result.Parameters.Original_Destination_Connection_ID.Present)
      then
         Result.Status := Missing_Mandatory_Parameter;
      end if;
      return Result;
   end Decode;

   function Encode
     (Parameters  : Transport_Parameters;
      Sender_Role : Endpoint_Role) return Encode_Result
   is
      Result   : Encode_Result;
      Position : Natural range 0 .. Max_Encoded_Length := 0;
      Success  : Boolean := True;

      procedure Append_Bytes (Data : Ada.Streams.Stream_Element_Array)
      with
        Pre => Data'Length <= Max_Encoded_Length,
        Post => Position >= Position'Old and then Position <= Max_Encoded_Length;

      procedure Append_Bytes (Data : Ada.Streams.Stream_Element_Array) is
      begin
         if not Success then
            return;
         elsif Natural (Data'Length) > Max_Encoded_Length - Position then
            Success := False;
            return;
         end if;
         if Data'Length > 0 then
            for Offset in Natural range 0 .. Natural (Data'Length) - 1 loop
               pragma Loop_Invariant (Position <= Max_Encoded_Length);
               pragma Loop_Invariant
                 (Offset < Natural (Data'Length)
                  and then
                    Offset < Max_Encoded_Length - Position);
               Result.Data
                 (Ada.Streams.Stream_Element_Offset (Position + Offset + 1)) :=
                   Data
                     (Data'First
                      + Ada.Streams.Stream_Element_Offset (Offset));
            end loop;
         end if;
         Position := Position + Natural (Data'Length);
      end Append_Bytes;

      procedure Append_Varint (Value : Varint_Policy.Value_Type);

      procedure Append_Varint (Value : Varint_Policy.Value_Type) is
         Encoded_Value : constant Varint_Policy.Encoded_Value :=
           Varint_Policy.Encode (Value);
      begin
         Append_Bytes
           (Encoded_Value.Data
              (1 .. Ada.Streams.Stream_Element_Offset
                      (Encoded_Value.Length)));
      end Append_Varint;

      procedure Append_Integer
        (Identifier : Varint_Policy.Value_Type;
         Parameter  : Integer_Parameter);

      procedure Append_Integer
        (Identifier : Varint_Policy.Value_Type;
         Parameter  : Integer_Parameter)
      is
         Encoded_Value : constant Varint_Policy.Encoded_Value :=
           Varint_Policy.Encode (Parameter.Value);
      begin
         if not Parameter.Present or else not Success then
            return;
         end if;
         Append_Varint (Identifier);
         Append_Varint (Varint_Policy.Value_Type (Encoded_Value.Length));
         Append_Bytes
           (Encoded_Value.Data
              (1 .. Ada.Streams.Stream_Element_Offset
                      (Encoded_Value.Length)));
      end Append_Integer;

      procedure Append_Connection_ID
        (Identifier : Varint_Policy.Value_Type;
         Parameter  : Connection_ID_Parameter);

      procedure Append_Connection_ID
        (Identifier : Varint_Policy.Value_Type;
         Parameter  : Connection_ID_Parameter)
      is
      begin
         if not Parameter.Present or else not Success then
            return;
         end if;
         Append_Varint (Identifier);
         Append_Varint (Varint_Policy.Value_Type (Parameter.Length));
         if Parameter.Length > 0 then
            Append_Bytes
              (Parameter.Data
                 (1 .. Connection_ID_Index (Parameter.Length)));
         end if;
      end Append_Connection_ID;
   begin
      if not Parameters.Initial_Source_Connection_ID.Present
        or else
          (Sender_Role = Server
           and then
             not Parameters.Original_Destination_Connection_ID.Present)
        or else
          (Sender_Role = Client
           and then
             (Parameters.Original_Destination_Connection_ID.Present
              or else Parameters.Stateless_Reset_Token.Present
              or else Parameters.Preferred_Address_Received
              or else Parameters.Retry_Source_Connection_ID.Present))
        or else
          (Parameters.Max_UDP_Payload_Size.Present
           and then Parameters.Max_UDP_Payload_Size.Value < 1_200)
        or else
          (Parameters.Initial_Max_Streams_Bidi.Present
           and then Parameters.Initial_Max_Streams_Bidi.Value > 2**60)
        or else
          (Parameters.Initial_Max_Streams_Uni.Present
           and then Parameters.Initial_Max_Streams_Uni.Value > 2**60)
        or else
          (Parameters.ACK_Delay_Exponent.Present
           and then Parameters.ACK_Delay_Exponent.Value > 20)
        or else
          (Parameters.Max_ACK_Delay.Present
           and then Parameters.Max_ACK_Delay.Value >= 2**14)
        or else
          (Parameters.Active_Connection_ID_Limit.Present
           and then Parameters.Active_Connection_ID_Limit.Value < 2)
        or else Parameters.Preferred_Address_Received
      then
         return Result;
      end if;

      Append_Connection_ID
        (Original_Destination_Connection_ID,
         Parameters.Original_Destination_Connection_ID);
      Append_Integer (Max_Idle_Timeout, Parameters.Max_Idle_Timeout);
      if Parameters.Stateless_Reset_Token.Present then
         Append_Varint (Stateless_Reset_Token);
         Append_Varint (16);
         Append_Bytes (Parameters.Stateless_Reset_Token.Data);
      end if;
      Append_Integer (Max_UDP_Payload_Size, Parameters.Max_UDP_Payload_Size);
      Append_Integer (Initial_Max_Data, Parameters.Initial_Max_Data);
      Append_Integer
        (Initial_Max_Stream_Data_Bidi_Local,
         Parameters.Initial_Max_Stream_Data_Bidi_Local);
      Append_Integer
        (Initial_Max_Stream_Data_Bidi_Remote,
         Parameters.Initial_Max_Stream_Data_Bidi_Remote);
      Append_Integer
        (Initial_Max_Stream_Data_Uni,
         Parameters.Initial_Max_Stream_Data_Uni);
      Append_Integer
        (Initial_Max_Streams_Bidi, Parameters.Initial_Max_Streams_Bidi);
      Append_Integer
        (Initial_Max_Streams_Uni, Parameters.Initial_Max_Streams_Uni);
      Append_Integer (ACK_Delay_Exponent, Parameters.ACK_Delay_Exponent);
      Append_Integer (Max_ACK_Delay, Parameters.Max_ACK_Delay);
      if Parameters.Disable_Active_Migration and then Success then
         Append_Varint (Disable_Active_Migration);
         Append_Varint (0);
      end if;
      Append_Integer
        (Active_Connection_ID_Limit,
         Parameters.Active_Connection_ID_Limit);
      Append_Connection_ID
        (Initial_Source_Connection_ID,
         Parameters.Initial_Source_Connection_ID);
      Append_Connection_ID
        (Retry_Source_Connection_ID,
         Parameters.Retry_Source_Connection_ID);

      if not Success then
         Result.Status := Encoded_Parameters_Too_Large;
         Result.Length := 0;
      else
         Result.Status := Encoded;
         Result.Length := Encoded_Length (Position);
      end if;
      return Result;
   end Encode;
end Flyology.QUIC.Transport_Parameter_Policy;
