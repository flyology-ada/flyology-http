package body Flyology.QUIC.TLS_Handshake_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element_Offset;
   use type TLS_Extension_Policy.Encode_Status;
   use type TLS_Extension_Policy.Parse_Status;

   function Parse
     (Data : Ada.Streams.Stream_Element_Array) return Parse_Result
   is
      subtype Cursor is Handshake_Offset;

      Data_Length : constant Cursor := Cursor (Data'Length);
      Result      : Parse_Result;
      Position    : Cursor;
      Message_End : Cursor;
      Body_Length : Natural;
      Vector_Length : Natural;
      Found_AES_128_GCM_SHA256 : Boolean := False;
      Session_Length : Natural;

      function Byte_At (Offset : Cursor) return Natural
      with
        Pre => Offset < Data_Length,
        Post => Byte_At'Result <= 255;

      function Byte_At (Offset : Cursor) return Natural is
        (Natural
           (Data
              (Data'First + Ada.Streams.Stream_Element_Offset (Offset))));

      procedure Read_U16
        (Value   : out Natural;
         Success : out Boolean)
      with
        Pre => Position <= Message_End and then Message_End <= Data_Length,
        Post =>
          (if Success then
              Position = Position'Old + 2
              and then Position <= Message_End
              and then Value <= 65_535
           else Position = Position'Old and then Value = 0);

      procedure Read_U16
        (Value   : out Natural;
         Success : out Boolean)
      is
      begin
         Value := 0;
         Success := False;
         if Message_End - Position < 2 then
            return;
         end if;
         Value := Byte_At (Position) * 256 + Byte_At (Position + 1);
         Position := Position + 2;
         Success := True;
      end Read_U16;

      procedure Parse_Extensions
        (Context : TLS_Extension_Policy.Extension_Context;
         Success : out Boolean)
      with
        Pre =>
          Position <= Message_End
          and then Message_End <= Data_Length,
        Post =>
          (if Success then
              Position = Message_End
              and then Result.Extensions.Status = TLS_Extension_Policy.Parsed);

      procedure Parse_Extensions
        (Context : TLS_Extension_Policy.Extension_Context;
         Success : out Boolean)
      is
         Length_Value : Natural;
         Read_OK      : Boolean;
      begin
         Success := False;
         Read_U16 (Length_Value, Read_OK);
         if not Read_OK or else Length_Value /= Message_End - Position then
            return;
         end if;
         Result.Extensions_Offset := Position;
         Result.Extensions_Length := Handshake_Offset (Length_Value);
         if Length_Value = 0 then
            Result.Extensions :=
              TLS_Extension_Policy.Parse ((1 .. 0 => 0), Context);
         else
            Result.Extensions :=
              TLS_Extension_Policy.Parse
                (Data
                   (Data'First
                      + Ada.Streams.Stream_Element_Offset (Position)
                    .. Data'First
                      + Ada.Streams.Stream_Element_Offset (Message_End - 1)),
                 Context);
         end if;
         if Result.Extensions.Status /= TLS_Extension_Policy.Parsed then
            return;
         end if;
         Position := Message_End;
         Success := True;
      end Parse_Extensions;

      Success : Boolean;
      Entry_Start : Cursor;
   begin
      if Data_Length < 4 then
         return Result;
      end if;
      Body_Length :=
        Byte_At (1) * 65_536 + Byte_At (2) * 256 + Byte_At (3);
      if Body_Length > Data_Length - 4 then
         return Result;
      elsif Body_Length > Handshake_Offset'Last - 4 then
         Result.Status := Invalid_Handshake;
         return Result;
      end if;
      Message_End := Cursor (4 + Body_Length);
      Result.Consumed := Message_End;
      Position := 4;

      case Byte_At (0) is
         when 1 =>
            Result.Kind := Client_Hello;
         when 2 =>
            Result.Kind := Server_Hello;
         when 8 =>
            Result.Kind := Encrypted_Extensions;
         when others =>
            Result.Status := Unsupported_Message;
            return Result;
      end case;

      if Result.Kind = Encrypted_Extensions then
         Parse_Extensions
           (TLS_Extension_Policy.Encrypted_Extensions, Success);
         if not Success then
            Result.Status :=
              (if Result.Extensions.Status /= TLS_Extension_Policy.Parsed
               then Invalid_Extensions else Invalid_Handshake);
            return Result;
         end if;
         Result.Status := Parsed;
         return Result;
      end if;

      --  Both hello messages retain TLS 1.2's legacy_version and random.
      if Message_End - Position < 35
        or else Byte_At (Position) /= 3
        or else Byte_At (Position + 1) /= 3
      then
         Result.Status := Invalid_Handshake;
         return Result;
      end if;
      Position := Position + 2;
      Result.Random_Offset := Position;
      Position := Position + 32;
      Session_Length := Byte_At (Position);
      Position := Position + 1;
      if Session_Length > 32
        or else Session_Length > Message_End - Position
      then
         Result.Status := Invalid_Handshake;
         return Result;
      end if;
      Result.Session_ID_Length := Session_Length;
      Result.Session_ID_Offset := Position;
      Position := Position + Result.Session_ID_Length;

      if Result.Kind = Client_Hello then
         Read_U16 (Vector_Length, Success);
         if not Success
           or else Vector_Length < 2
           or else Vector_Length mod 2 /= 0
           or else Vector_Length > Message_End - Position
         then
            Result.Status := Invalid_Handshake;
            return Result;
         end if;
         Entry_Start := Position;
         while Position < Entry_Start + Vector_Length loop
            pragma Loop_Invariant
              (Position <= Entry_Start + Vector_Length
               and then Position <= Message_End);
            pragma Loop_Invariant
              (Entry_Start + Vector_Length <= Message_End);
            pragma Loop_Invariant
              (Position + 1 < Entry_Start + Vector_Length);
            pragma Loop_Invariant
              ((Position - Entry_Start) mod 2 = 0);
            pragma Loop_Variant
              (Decreases => Entry_Start + Vector_Length - Position);
            if Byte_At (Position) = 16#13#
              and then Byte_At (Position + 1) = 16#01#
            then
               Found_AES_128_GCM_SHA256 := True;
            end if;
            Position := Position + 2;
         end loop;
         if not Found_AES_128_GCM_SHA256
           or else Message_End - Position < 2
           or else Byte_At (Position) /= 1
           or else Byte_At (Position + 1) /= 0
         then
            Result.Status := Invalid_Handshake;
            return Result;
         end if;
         Position := Position + 2;
         Parse_Extensions (TLS_Extension_Policy.Client_Hello, Success);
      else
         if Message_End - Position < 3
           or else Byte_At (Position) /= 16#13#
           or else Byte_At (Position + 1) /= 16#01#
           or else Byte_At (Position + 2) /= 0
         then
            Result.Status := Invalid_Handshake;
            return Result;
         end if;
         Position := Position + 3;
         Parse_Extensions (TLS_Extension_Policy.Server_Hello, Success);
      end if;

      if not Success then
         Result.Status :=
           (if Result.Extensions.Status /= TLS_Extension_Policy.Parsed
            then Invalid_Extensions else Invalid_Handshake);
         return Result;
      end if;
      Result.Status := Parsed;
      return Result;
   end Parse;

   procedure Append_Byte
     (Result   : in out Encode_Result;
      Position : in out Natural;
      Value    : Ada.Streams.Stream_Element;
      Success  : in out Boolean)
   with
     Pre => Position <= Max_Encoded_Handshake,
     Post => Position >= Position'Old and then Position <= Max_Encoded_Handshake;

   procedure Append_Byte
     (Result   : in out Encode_Result;
      Position : in out Natural;
      Value    : Ada.Streams.Stream_Element;
      Success  : in out Boolean)
   is
   begin
      if not Success then
         return;
      elsif Position = Max_Encoded_Handshake then
         Success := False;
         return;
      end if;
      Position := Position + 1;
      Result.Data (Ada.Streams.Stream_Element_Offset (Position)) := Value;
   end Append_Byte;

   procedure Append_U16
     (Result   : in out Encode_Result;
      Position : in out Natural;
      Value    : Natural;
      Success  : in out Boolean)
   with
     Pre => Position <= Max_Encoded_Handshake and then Value <= 65_535,
     Post => Position >= Position'Old and then Position <= Max_Encoded_Handshake;

   procedure Append_U16
     (Result   : in out Encode_Result;
      Position : in out Natural;
      Value    : Natural;
      Success  : in out Boolean)
   is
   begin
      Append_Byte
        (Result, Position, Ada.Streams.Stream_Element (Value / 256), Success);
      Append_Byte
        (Result, Position, Ada.Streams.Stream_Element (Value mod 256), Success);
   end Append_U16;

   procedure Append_Bytes
     (Result   : in out Encode_Result;
      Position : in out Natural;
      Data     : Ada.Streams.Stream_Element_Array;
      Success  : in out Boolean)
   with
     Pre => Position <= Max_Encoded_Handshake
       and then Data'Length <= Max_Encoded_Handshake,
     Post => Position >= Position'Old and then Position <= Max_Encoded_Handshake;

   procedure Append_Bytes
     (Result   : in out Encode_Result;
      Position : in out Natural;
      Data     : Ada.Streams.Stream_Element_Array;
      Success  : in out Boolean)
   is
   begin
      if not Success then
         return;
      elsif Natural (Data'Length) > Max_Encoded_Handshake - Position then
         Success := False;
         return;
      end if;
      if Data'Length > 0 then
         for Offset in Natural range 0 .. Natural (Data'Length) - 1 loop
            pragma Loop_Invariant
              (Offset < Natural (Data'Length)
               and then Offset < Max_Encoded_Handshake - Position);
            Result.Data
              (Ada.Streams.Stream_Element_Offset (Position + Offset + 1)) :=
                Data
                  (Data'First + Ada.Streams.Stream_Element_Offset (Offset));
         end loop;
      end if;
      Position := Position + Natural (Data'Length);
   end Append_Bytes;

   procedure Finish_Message
     (Result   : in out Encode_Result;
      Position : Natural;
      Success  : Boolean)
   with Pre => Position in 4 .. Max_Encoded_Handshake;

   procedure Finish_Message
     (Result   : in out Encode_Result;
      Position : Natural;
      Success  : Boolean)
   is
      Body_Length : constant Natural := Position - 4;
   begin
      if Success then
         Result.Data (2) :=
           Ada.Streams.Stream_Element (Body_Length / 65_536);
         Result.Data (3) :=
           Ada.Streams.Stream_Element ((Body_Length / 256) mod 256);
         Result.Data (4) := Ada.Streams.Stream_Element (Body_Length mod 256);
         Result.Status := Encoded;
         Result.Length := Position;
      end if;
   end Finish_Message;

   function Encode_Client_Hello
     (Random               : Hello_Random;
      Key                  : TLS_Extension_Policy.X25519_Public_Key;
      ALPN                 : Ada.Streams.Stream_Element_Array;
      Transport_Parameters : Ada.Streams.Stream_Element_Array)
      return Encode_Result
   is
      Extensions : constant TLS_Extension_Policy.Encode_Result :=
        TLS_Extension_Policy.Encode_Client_Hello
          (Key, ALPN, Transport_Parameters);
      Result   : Encode_Result;
      Position : Natural := 4;
      Success  : Boolean :=
        Extensions.Status = TLS_Extension_Policy.Encoded;
   begin
      Result.Data (1) := 1;
      Append_Bytes (Result, Position, (3, 3), Success);
      Append_Bytes (Result, Position, Random, Success);
      Append_Byte (Result, Position, 0, Success);
      Append_U16 (Result, Position, 2, Success);
      Append_Bytes (Result, Position, (16#13#, 16#01#), Success);
      Append_Bytes (Result, Position, (1, 0), Success);
      Append_U16 (Result, Position, Extensions.Length, Success);
      Append_Bytes
        (Result, Position,
         Extensions.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Extensions.Length)),
         Success);
      Finish_Message (Result, Position, Success);
      return Result;
   end Encode_Client_Hello;

   function Encode_Server_Hello
     (Random  : Hello_Random;
      Session : Session_ID;
      Key     : TLS_Extension_Policy.X25519_Public_Key) return Encode_Result
   is
      Extensions : constant TLS_Extension_Policy.Encode_Result :=
        TLS_Extension_Policy.Encode_Server_Hello (Key);
      Result   : Encode_Result;
      Position : Natural := 4;
      Success  : Boolean :=
        Extensions.Status = TLS_Extension_Policy.Encoded;
   begin
      Result.Data (1) := 2;
      Append_Bytes (Result, Position, (3, 3), Success);
      Append_Bytes (Result, Position, Random, Success);
      Append_Byte
        (Result, Position, Ada.Streams.Stream_Element (Session.Length), Success);
      if Session.Length > 0 then
         Append_Bytes
           (Result, Position,
            Session.Data
              (1 .. Ada.Streams.Stream_Element_Offset (Session.Length)),
            Success);
      end if;
      Append_Bytes (Result, Position, (16#13#, 16#01#, 0), Success);
      Append_U16 (Result, Position, Extensions.Length, Success);
      Append_Bytes
        (Result, Position,
         Extensions.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Extensions.Length)),
         Success);
      Finish_Message (Result, Position, Success);
      return Result;
   end Encode_Server_Hello;

   function Encode_Encrypted_Extensions
     (ALPN                 : Ada.Streams.Stream_Element_Array;
      Transport_Parameters : Ada.Streams.Stream_Element_Array)
      return Encode_Result
   is
      Extensions : constant TLS_Extension_Policy.Encode_Result :=
        TLS_Extension_Policy.Encode_Encrypted_Extensions
          (ALPN, Transport_Parameters);
      Result   : Encode_Result;
      Position : Natural := 4;
      Success  : Boolean :=
        Extensions.Status = TLS_Extension_Policy.Encoded;
   begin
      Result.Data (1) := 8;
      Append_U16 (Result, Position, Extensions.Length, Success);
      Append_Bytes
        (Result, Position,
         Extensions.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Extensions.Length)),
         Success);
      Finish_Message (Result, Position, Success);
      return Result;
   end Encode_Encrypted_Extensions;
end Flyology.QUIC.TLS_Handshake_Policy;
