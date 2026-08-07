package body Flyology.QUIC.TLS_Extension_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;

   Supported_Groups          : constant := 16#000A#;
   Signature_Algorithms      : constant := 16#000D#;
   ALPN_Extension            : constant := 16#0010#;
   Supported_Versions        : constant := 16#002B#;
   Key_Share                 : constant := 16#0033#;
   QUIC_Transport_Parameters : constant := 16#0039#;
   X25519                    : constant := 16#001D#;

   function Parse
     (Data    : Ada.Streams.Stream_Element_Array;
      Context : Extension_Context) return Parse_Result
   is
      subtype Cursor is Extension_Offset;
      subtype Seen_Index is Positive range 1 .. 128;
      type Seen_Array is array (Seen_Index) of Natural range 0 .. 65_535;

      Data_Length : constant Cursor := Cursor (Data'Length);
      Position    : Cursor := 0;
      Result      : Parse_Result;
      Seen        : Seen_Array := (others => 0);

      function Byte_At (Offset : Cursor) return Natural
      with
        Pre => Offset < Data_Length,
        Post => Byte_At'Result <= 255;

      function Byte_At (Offset : Cursor) return Natural is
        (Natural
           (Data
              (Data'First + Ada.Streams.Stream_Element_Offset (Offset))));

      procedure Read_U16
        (Cursor_Pos : in out Cursor;
         Value   : out Natural;
         Success : out Boolean)
      with
        Pre => Cursor_Pos <= Data_Length,
        Post =>
          (if Success then
              Cursor_Pos = Cursor_Pos'Old + 2
              and then Cursor_Pos <= Data_Length
              and then Value <= 65_535
           else Cursor_Pos = Cursor_Pos'Old and then Value = 0);

      procedure Read_U16
        (Cursor_Pos : in out Cursor;
         Value   : out Natural;
         Success : out Boolean)
      is
      begin
         Value := 0;
         Success := False;
         if Data_Length - Cursor_Pos < 2 then
            return;
         end if;
         Value :=
           Byte_At (Cursor_Pos) * 256 + Byte_At (Cursor_Pos + 1);
         Cursor_Pos := Cursor_Pos + 2;
         Success := True;
      end Read_U16;

      function Was_Seen (Extension_Type : Natural) return Boolean
      with
        Pre => Result.Count < 128,
        Global => (Input => (Seen, Result));

      function Was_Seen (Extension_Type : Natural) return Boolean is
      begin
         for Index in Seen_Index range 1 .. Result.Count loop
            if Seen (Index) = Extension_Type then
               return True;
            end if;
         end loop;
         return False;
      end Was_Seen;

      procedure Parse_Client_Versions
        (Value_Start  : Cursor;
         Value_Length : Cursor;
         Valid        : out Boolean)
      with
        Pre =>
          Value_Start <= Data_Length
          and then Value_Length <= Data_Length - Value_Start;

      procedure Parse_Client_Versions
        (Value_Start  : Cursor;
         Value_Length : Cursor;
         Valid        : out Boolean)
      is
         List_Length : Natural;
         Cursor_Pos  : Cursor;
      begin
         Valid := False;
         if Value_Length < 3 then
            return;
         end if;
         List_Length := Byte_At (Value_Start);
         if List_Length < 2
           or else List_Length mod 2 /= 0
           or else Value_Length /= 1 + List_Length
         then
            return;
         end if;
         Cursor_Pos := Value_Start + 1;
         while Cursor_Pos < Value_Start + Value_Length loop
            pragma Loop_Invariant (Cursor_Pos < Data_Length);
            pragma Loop_Invariant
              ((Cursor_Pos - Value_Start - 1) mod 2 = 0);
            pragma Loop_Variant
              (Decreases => Value_Start + Value_Length - Cursor_Pos);
            if Byte_At (Cursor_Pos) = 3
              and then Byte_At (Cursor_Pos + 1) = 4
            then
               Result.Has_Supported_TLS_1_3 := True;
            end if;
            Cursor_Pos := Cursor_Pos + 2;
         end loop;
         Valid := Result.Has_Supported_TLS_1_3;
      end Parse_Client_Versions;

      procedure Parse_Client_Key_Shares
        (Value_Start  : Cursor;
         Value_Length : Cursor;
         Valid        : out Boolean)
      with
        Pre =>
          Value_Start <= Data_Length
          and then Value_Length <= Data_Length - Value_Start;

      procedure Parse_Client_Key_Shares
        (Value_Start  : Cursor;
         Value_Length : Cursor;
         Valid        : out Boolean)
      is
         Cursor_Pos  : Cursor := Value_Start;
         List_Length : Natural;
         Group       : Natural;
         Key_Length  : Natural;
         Success     : Boolean;
         Entry_Start : Cursor;
      begin
         Valid := False;
         Read_U16 (Cursor_Pos, List_Length, Success);
         if not Success or else List_Length /= Value_Length - 2 then
            return;
         end if;
         while Cursor_Pos < Value_Start + Value_Length loop
            pragma Loop_Invariant
              (Cursor_Pos <= Value_Start + Value_Length
               and then Cursor_Pos <= Data_Length);
            pragma Loop_Variant
              (Decreases => Value_Start + Value_Length - Cursor_Pos);
            Entry_Start := Cursor_Pos;
            Read_U16 (Cursor_Pos, Group, Success);
            if not Success then
               return;
            end if;
            Read_U16 (Cursor_Pos, Key_Length, Success);
            if not Success
              or else Key_Length >
                Value_Start + Value_Length - Cursor_Pos
            then
               return;
            end if;
            if Group = X25519 and then Key_Length = 32 then
               Result.Has_X25519_Key_Share := True;
               Result.Key_Share_Offset := Cursor_Pos;
            end if;
            Cursor_Pos := Cursor_Pos + Key_Length;
            pragma Assert (Cursor_Pos > Entry_Start);
         end loop;
         Valid := Result.Has_X25519_Key_Share;
      end Parse_Client_Key_Shares;

      procedure Parse_ALPN
        (Value_Start  : Cursor;
         Value_Length : Cursor;
         Valid        : out Boolean)
      with
        Pre =>
          Value_Start <= Data_Length
          and then Value_Length <= Data_Length - Value_Start;

      procedure Parse_ALPN
        (Value_Start  : Cursor;
         Value_Length : Cursor;
         Valid        : out Boolean)
      is
         Cursor_Pos  : Cursor := Value_Start;
         List_Length : Natural;
         Name_Length : Natural;
         Success     : Boolean;
      begin
         Valid := False;
         Read_U16 (Cursor_Pos, List_Length, Success);
         if not Success or else List_Length /= Value_Length - 2 then
            return;
         end if;
         while Cursor_Pos < Value_Start + Value_Length loop
            pragma Loop_Invariant
              (Cursor_Pos <= Value_Start + Value_Length
               and then Cursor_Pos <= Data_Length);
            pragma Loop_Variant
              (Decreases => Value_Start + Value_Length - Cursor_Pos);
            Name_Length := Byte_At (Cursor_Pos);
            Cursor_Pos := Cursor_Pos + 1;
            if Name_Length = 0
              or else Name_Length >
                Value_Start + Value_Length - Cursor_Pos
            then
               return;
            end if;
            if not Result.Has_ALPN then
               Result.Has_ALPN := True;
               Result.ALPN_Protocol_Offset := Cursor_Pos;
               Result.ALPN_Protocol_Length := Name_Length;
            end if;
            Cursor_Pos := Cursor_Pos + Name_Length;
         end loop;
         Valid := Result.Has_ALPN;
      end Parse_ALPN;

      procedure Parse_Signatures
        (Value_Start  : Cursor;
         Value_Length : Cursor;
         Valid        : out Boolean)
      with
        Pre =>
          Value_Start <= Data_Length
          and then Value_Length <= Data_Length - Value_Start;

      procedure Parse_Signatures
        (Value_Start  : Cursor;
         Value_Length : Cursor;
         Valid        : out Boolean)
      is
         Cursor_Pos : Cursor := Value_Start;
         List_Length : Natural;
         Algorithm   : Natural;
         Success     : Boolean;
      begin
         Valid := False;
         Read_U16 (Cursor_Pos, List_Length, Success);
         if not Success
           or else List_Length < 2
           or else List_Length mod 2 /= 0
           or else List_Length /= Value_Length - 2
         then
            return;
         end if;
         while Cursor_Pos < Value_Start + Value_Length loop
            pragma Loop_Invariant
              (Cursor_Pos <= Value_Start + Value_Length
               and then Cursor_Pos <= Data_Length);
            pragma Loop_Variant
              (Decreases => Value_Start + Value_Length - Cursor_Pos);
            Read_U16 (Cursor_Pos, Algorithm, Success);
            if not Success then
               return;
            end if;
            if Algorithm in 16#0403# | 16#0804# | 16#0807# then
               Result.Has_Compatible_Signature := True;
            end if;
         end loop;
         Valid := Result.Has_Compatible_Signature;
      end Parse_Signatures;

      Extension_Start : Cursor;
      Extension_Type  : Natural;
      Length_Value    : Natural;
      Value_Start     : Cursor;
      Value_Length    : Cursor;
      Success         : Boolean;
      Valid           : Boolean;
   begin
      Result.Status := Parsed;
      while Position < Data_Length loop
         pragma Loop_Invariant (Position <= Data_Length);
         pragma Loop_Invariant (Result.Count <= 128);
         pragma Loop_Variant (Decreases => Data_Length - Position);
         if Result.Count = 128 then
            Result.Status := Too_Many_Extensions;
            return Result;
         end if;
         Extension_Start := Position;
         Read_U16 (Position, Extension_Type, Success);
         if not Success then
            Result.Status := Truncated;
            return Result;
         end if;
         Read_U16 (Position, Length_Value, Success);
         if not Success or else Length_Value > Data_Length - Position then
            Result.Status := Truncated;
            return Result;
         end if;
         Value_Start := Position;
         Value_Length := Cursor (Length_Value);
         Position := Position + Value_Length;
         pragma Assert (Position > Extension_Start);

         if Was_Seen (Extension_Type) then
            Result.Status := Duplicate_Extension;
            return Result;
         end if;
         Result.Count := Result.Count + 1;
         Seen (Result.Count) := Extension_Type;

         case Extension_Type is
            when Supported_Versions =>
               if Context = Encrypted_Extensions then
                  Result.Status := Extension_Not_Allowed;
                  return Result;
               elsif Context = Client_Hello then
                  Parse_Client_Versions
                    (Value_Start, Value_Length, Valid);
                  if not Valid then
                     Result.Status := Invalid_Extension_Value;
                     return Result;
                  end if;
               elsif Value_Length /= 2
                 or else Byte_At (Value_Start) /= 3
                 or else Byte_At (Value_Start + 1) /= 4
               then
                  Result.Status := Invalid_Extension_Value;
                  return Result;
               else
                  Result.Has_Supported_TLS_1_3 := True;
               end if;

            when Key_Share =>
               if Context = Encrypted_Extensions then
                  Result.Status := Extension_Not_Allowed;
                  return Result;
               elsif Context = Client_Hello then
                  Parse_Client_Key_Shares
                    (Value_Start, Value_Length, Valid);
                  if not Valid then
                     Result.Status := Invalid_Extension_Value;
                     return Result;
                  end if;
               elsif Value_Length /= 36
                 or else Byte_At (Value_Start) /= 0
                 or else Byte_At (Value_Start + 1) /= X25519
                 or else Byte_At (Value_Start + 2) /= 0
                 or else Byte_At (Value_Start + 3) /= 32
               then
                  Result.Status := Invalid_Extension_Value;
                  return Result;
               else
                  Result.Has_X25519_Key_Share := True;
                  Result.Key_Share_Offset := Value_Start + 4;
               end if;

            when ALPN_Extension =>
               if Context = Server_Hello then
                  Result.Status := Extension_Not_Allowed;
                  return Result;
               end if;
               Parse_ALPN (Value_Start, Value_Length, Valid);
               if not Valid
                 or else
                   (Context = Encrypted_Extensions
                    and then Value_Length /= 3 + Result.ALPN_Protocol_Length)
               then
                  Result.Status := Invalid_Extension_Value;
                  return Result;
               end if;

            when Signature_Algorithms =>
               if Context /= Client_Hello then
                  Result.Status := Extension_Not_Allowed;
                  return Result;
               end if;
               Parse_Signatures (Value_Start, Value_Length, Valid);
               if not Valid then
                  Result.Status := Invalid_Extension_Value;
                  return Result;
               end if;

            when QUIC_Transport_Parameters =>
               if Context = Server_Hello then
                  Result.Status := Extension_Not_Allowed;
                  return Result;
               end if;
               Result.Has_Transport_Parameters := True;
               Result.Transport_Parameters_Offset := Value_Start;
               Result.Transport_Parameters_Length := Value_Length;

            when others =>
               null;
         end case;
      end loop;

      if Result.Has_Supported_TLS_1_3 /=
           (Context /= Encrypted_Extensions)
        or else Result.Has_X25519_Key_Share /=
          (Context /= Encrypted_Extensions)
        or else Result.Has_Compatible_Signature /= (Context = Client_Hello)
        or else Result.Has_ALPN /= (Context /= Server_Hello)
        or else Result.Has_Transport_Parameters /= (Context /= Server_Hello)
      then
         Result.Status := Missing_Required_Extension;
      end if;
      return Result;
   end Parse;

   procedure Append_U16
     (Result   : in out Encode_Result;
      Position : in out Natural;
      Value    : Natural;
      Success  : in out Boolean)
   with
     Pre => Position <= Max_Encoded_Extensions and then Value <= 65_535,
     Post => Position >= Position'Old and then Position <= Max_Encoded_Extensions;

   procedure Append_U16
     (Result   : in out Encode_Result;
      Position : in out Natural;
      Value    : Natural;
      Success  : in out Boolean)
   is
   begin
      if not Success then
         return;
      elsif Max_Encoded_Extensions - Position < 2 then
         Success := False;
         return;
      end if;
      Result.Data (Ada.Streams.Stream_Element_Offset (Position + 1)) :=
        Ada.Streams.Stream_Element (Value / 256);
      Result.Data (Ada.Streams.Stream_Element_Offset (Position + 2)) :=
        Ada.Streams.Stream_Element (Value mod 256);
      Position := Position + 2;
   end Append_U16;

   procedure Append_Bytes
     (Result   : in out Encode_Result;
      Position : in out Natural;
      Data     : Ada.Streams.Stream_Element_Array;
      Success  : in out Boolean)
   with
     Pre => Position <= Max_Encoded_Extensions
       and then Data'Length <= Max_Encoded_Extensions,
     Post => Position >= Position'Old and then Position <= Max_Encoded_Extensions;

   procedure Append_Bytes
     (Result   : in out Encode_Result;
      Position : in out Natural;
      Data     : Ada.Streams.Stream_Element_Array;
      Success  : in out Boolean)
   is
   begin
      if not Success then
         return;
      elsif Natural (Data'Length) > Max_Encoded_Extensions - Position then
         Success := False;
         return;
      end if;
      if Data'Length > 0 then
         for Offset in Natural range 0 .. Natural (Data'Length) - 1 loop
            pragma Loop_Invariant
              (Offset < Natural (Data'Length)
               and then Offset < Max_Encoded_Extensions - Position);
            Result.Data
              (Ada.Streams.Stream_Element_Offset (Position + Offset + 1)) :=
                Data
                  (Data'First + Ada.Streams.Stream_Element_Offset (Offset));
         end loop;
      end if;
      Position := Position + Natural (Data'Length);
   end Append_Bytes;

   function Encode_Client_Hello
     (Key                  : X25519_Public_Key;
      ALPN                 : Ada.Streams.Stream_Element_Array;
      Transport_Parameters : Ada.Streams.Stream_Element_Array)
      return Encode_Result
   is
      Result   : Encode_Result;
      Position : Natural := 0;
      Success  : Boolean := True;
   begin
      --  supported_versions: one TLS 1.3 version.
      Append_U16 (Result, Position, Supported_Versions, Success);
      Append_U16 (Result, Position, 3, Success);
      Append_Bytes (Result, Position, (2, 3, 4), Success);

      --  supported_groups: X25519.
      Append_U16 (Result, Position, Supported_Groups, Success);
      Append_U16 (Result, Position, 4, Success);
      Append_Bytes (Result, Position, (0, 2, 0, X25519), Success);

      --  CertificateVerify algorithms: Ed25519, ECDSA P-256, RSA-PSS.
      Append_U16 (Result, Position, Signature_Algorithms, Success);
      Append_U16 (Result, Position, 8, Success);
      Append_Bytes
        (Result, Position,
         (0, 6, 16#08#, 16#07#, 16#04#, 16#03#, 16#08#, 16#04#),
         Success);

      --  key_share: one X25519 share.
      Append_U16 (Result, Position, Key_Share, Success);
      Append_U16 (Result, Position, 38, Success);
      Append_Bytes
        (Result, Position, (0, 36, 0, X25519, 0, 32), Success);
      Append_Bytes (Result, Position, Key, Success);

      --  ALPN protocol list with one application protocol.
      Append_U16 (Result, Position, ALPN_Extension, Success);
      Append_U16 (Result, Position, 3 + Natural (ALPN'Length), Success);
      Append_U16 (Result, Position, 1 + Natural (ALPN'Length), Success);
      Append_Bytes
        (Result, Position,
         (1 => Ada.Streams.Stream_Element (ALPN'Length)), Success);
      Append_Bytes (Result, Position, ALPN, Success);

      Append_U16 (Result, Position, QUIC_Transport_Parameters, Success);
      Append_U16
        (Result, Position, Natural (Transport_Parameters'Length), Success);
      Append_Bytes (Result, Position, Transport_Parameters, Success);

      Result.Status := (if Success then Encoded else Input_Too_Large);
      Result.Length := (if Success then Position else 0);
      return Result;
   end Encode_Client_Hello;

   function Encode_Server_Hello
     (Key : X25519_Public_Key) return Encode_Result
   is
      Result   : Encode_Result;
      Position : Natural := 0;
      Success  : Boolean := True;
   begin
      Append_U16 (Result, Position, Supported_Versions, Success);
      Append_U16 (Result, Position, 2, Success);
      Append_Bytes (Result, Position, (3, 4), Success);
      Append_U16 (Result, Position, Key_Share, Success);
      Append_U16 (Result, Position, 36, Success);
      Append_Bytes (Result, Position, (0, X25519, 0, 32), Success);
      Append_Bytes (Result, Position, Key, Success);
      Result.Status := (if Success then Encoded else Input_Too_Large);
      Result.Length := (if Success then Position else 0);
      return Result;
   end Encode_Server_Hello;

   function Encode_Encrypted_Extensions
     (ALPN                 : Ada.Streams.Stream_Element_Array;
      Transport_Parameters : Ada.Streams.Stream_Element_Array)
      return Encode_Result
   is
      Result   : Encode_Result;
      Position : Natural := 0;
      Success  : Boolean := True;
   begin
      Append_U16 (Result, Position, ALPN_Extension, Success);
      Append_U16 (Result, Position, 3 + Natural (ALPN'Length), Success);
      Append_U16 (Result, Position, 1 + Natural (ALPN'Length), Success);
      Append_Bytes
        (Result, Position,
         (1 => Ada.Streams.Stream_Element (ALPN'Length)), Success);
      Append_Bytes (Result, Position, ALPN, Success);
      Append_U16 (Result, Position, QUIC_Transport_Parameters, Success);
      Append_U16
        (Result, Position, Natural (Transport_Parameters'Length), Success);
      Append_Bytes (Result, Position, Transport_Parameters, Success);
      Result.Status := (if Success then Encoded else Input_Too_Large);
      Result.Length := (if Success then Position else 0);
      return Result;
   end Encode_Encrypted_Extensions;
end Flyology.QUIC.TLS_Extension_Policy;
