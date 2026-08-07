package body Flyology.QUIC.TLS_Authentication_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element_Offset;

   function Parse
     (Data : Ada.Streams.Stream_Element_Array) return Parse_Result
   is
      subtype Cursor is Message_Offset;
      Data_Length : constant Cursor := Cursor (Data'Length);
      Result      : Parse_Result;
      Position    : Cursor := 0;
      Message_End : Cursor := 0;
      Body_Length : Natural;
      List_Length : Natural;
      Value       : Natural;
      Success     : Boolean;

      function Byte_At (Offset : Cursor) return Natural
      with
        Pre => Offset < Data_Length,
        Post => Byte_At'Result <= 255;

      function Byte_At (Offset : Cursor) return Natural is
        (Natural
           (Data
              (Data'First + Ada.Streams.Stream_Element_Offset (Offset))));

      procedure Read_U16 (Item : out Natural; OK : out Boolean)
      with
        Pre => Position <= Message_End and then Message_End <= Data_Length,
        Post =>
          Position <= Message_End
          and then
            (if OK then Position = Position'Old + 2 and then Item <= 65_535
             else Position = Position'Old and then Item = 0);

      procedure Read_U16 (Item : out Natural; OK : out Boolean) is
      begin
         Item := 0;
         OK := False;
         if Message_End - Position < 2 then
            return;
         end if;
         Item := Byte_At (Position) * 256 + Byte_At (Position + 1);
         Position := Position + 2;
         OK := True;
      end Read_U16;

      procedure Read_U24 (Item : out Natural; OK : out Boolean)
      with
        Pre => Position <= Message_End and then Message_End <= Data_Length,
        Post =>
          Position <= Message_End
          and then
            (if OK then
                Position = Position'Old + 3 and then Item <= 16_777_215
             else Position = Position'Old and then Item = 0);

      procedure Read_U24 (Item : out Natural; OK : out Boolean) is
      begin
         Item := 0;
         OK := False;
         if Message_End - Position < 3 then
            return;
         end if;
         Item :=
           Byte_At (Position) * 65_536
             + Byte_At (Position + 1) * 256
             + Byte_At (Position + 2);
         Position := Position + 3;
         OK := True;
      end Read_U24;
   begin
      if Data_Length < 4 then
         return Result;
      end if;
      Body_Length :=
        Byte_At (1) * 65_536 + Byte_At (2) * 256 + Byte_At (3);
      if Body_Length > Data_Length - 4 then
         return Result;
      elsif Body_Length > Message_Offset'Last - 4 then
         Result.Status := Invalid_Authentication;
         return Result;
      end if;
      Message_End := Cursor (4 + Body_Length);
      Result.Consumed := Message_End;
      Position := 4;

      case Byte_At (0) is
         when 11 =>
            Result.Kind := Certificate_Message;
         when 15 =>
            Result.Kind := Certificate_Verify_Message;
         when 20 =>
            Result.Kind := Finished_Message;
         when others =>
            Result.Status := Unsupported_Message;
            return Result;
      end case;

      case Result.Kind is
         when Certificate_Message =>
            if Position = Message_End then
               Result.Status := Invalid_Authentication;
               return Result;
            end if;
            Result.Context_Length := Byte_At (Position);
            Position := Position + 1;
            if Result.Context_Length > Message_End - Position then
               Result.Status := Invalid_Authentication;
               return Result;
            end if;
            Result.Context_Offset := Position;
            Position := Position + Result.Context_Length;
            Read_U24 (List_Length, Success);
            if not Success or else List_Length /= Message_End - Position then
               Result.Status := Invalid_Authentication;
               return Result;
            end if;
            while Position < Message_End loop
               pragma Loop_Invariant (Position <= Message_End);
               pragma Loop_Invariant (Result.Certificate_Total <= 8);
               pragma Loop_Variant (Decreases => Message_End - Position);
               if Result.Certificate_Total = 8 then
                  Result.Status := Too_Many_Certificates;
                  return Result;
               end if;
               Read_U24 (Value, Success);
               if not Success
                 or else Value = 0
                 or else Value > Message_End - Position
               then
                  Result.Status := Invalid_Authentication;
                  return Result;
               end if;
               Result.Certificate_Total := Result.Certificate_Total + 1;
               Result.Certificates (Result.Certificate_Total) :=
                 (Offset => Position, Length => Message_Offset (Value));
               Position := Position + Value;
               Read_U16 (Value, Success);
               if not Success or else Value > Message_End - Position then
                  Result.Status := Invalid_Authentication;
                  return Result;
               end if;
               Position := Position + Value;
            end loop;
            Result.Status := Parsed;

         when Certificate_Verify_Message =>
            Read_U16 (Value, Success);
            if not Success then
               Result.Status := Invalid_Authentication;
               return Result;
            end if;
            case Value is
               when 16#0403# =>
                  Result.Scheme := ECDSA_SECP256R1_SHA256;
               when 16#0804# =>
                  Result.Scheme := RSA_PSS_RSAE_SHA256;
               when 16#0807# =>
                  Result.Scheme := ED25519;
               when others =>
                  Result.Status := Unsupported_Signature;
                  return Result;
            end case;
            Read_U16 (Value, Success);
            if not Success
              or else Value = 0
              or else Value /= Message_End - Position
            then
               Result.Status := Invalid_Authentication;
               return Result;
            end if;
            Result.Signature_Offset := Position;
            Result.Signature_Length := Message_Offset (Value);
            Result.Status := Parsed;

         when Finished_Message =>
            if Body_Length /= 32 then
               Result.Status := Invalid_Authentication;
               return Result;
            end if;
            Result.Verify_Offset := Position;
            Result.Status := Parsed;
      end case;
      return Result;
   end Parse;

   procedure Append_Byte
     (Result   : in out Encode_Result;
      Position : in out Natural;
      Value    : Ada.Streams.Stream_Element;
      Success  : in out Boolean)
   with
     Pre => Position <= Max_Encoded_Authentication,
     Post =>
       Position >= Position'Old
       and then Position <= Max_Encoded_Authentication;

   procedure Append_Byte
     (Result   : in out Encode_Result;
      Position : in out Natural;
      Value    : Ada.Streams.Stream_Element;
      Success  : in out Boolean) is
   begin
      if not Success then
         return;
      elsif Position = Max_Encoded_Authentication then
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
     Pre => Value <= 65_535 and then Position <= Max_Encoded_Authentication,
     Post =>
       Position >= Position'Old
       and then Position <= Max_Encoded_Authentication;

   procedure Append_U16
     (Result   : in out Encode_Result;
      Position : in out Natural;
      Value    : Natural;
      Success  : in out Boolean) is
   begin
      Append_Byte
        (Result, Position, Ada.Streams.Stream_Element (Value / 256), Success);
      Append_Byte
        (Result, Position, Ada.Streams.Stream_Element (Value mod 256), Success);
   end Append_U16;

   procedure Append_U24
     (Result   : in out Encode_Result;
      Position : in out Natural;
      Value    : Natural;
      Success  : in out Boolean)
   with
     Pre => Value <= 16_777_215
       and then Position <= Max_Encoded_Authentication,
     Post =>
       Position >= Position'Old
       and then Position <= Max_Encoded_Authentication;

   procedure Append_U24
     (Result   : in out Encode_Result;
      Position : in out Natural;
      Value    : Natural;
      Success  : in out Boolean) is
   begin
      Append_Byte
        (Result, Position, Ada.Streams.Stream_Element (Value / 65_536),
         Success);
      Append_Byte
        (Result, Position,
         Ada.Streams.Stream_Element ((Value / 256) mod 256), Success);
      Append_Byte
        (Result, Position, Ada.Streams.Stream_Element (Value mod 256), Success);
   end Append_U24;

   procedure Append_Bytes
     (Result   : in out Encode_Result;
      Position : in out Natural;
      Data     : Ada.Streams.Stream_Element_Array;
      Success  : in out Boolean)
   with
     Pre => Position <= Max_Encoded_Authentication
       and then Data'Length <= Max_Encoded_Authentication,
     Post =>
       Position >= Position'Old
       and then Position <= Max_Encoded_Authentication;

   procedure Append_Bytes
     (Result   : in out Encode_Result;
      Position : in out Natural;
      Data     : Ada.Streams.Stream_Element_Array;
      Success  : in out Boolean) is
   begin
      if not Success then
         return;
      elsif Natural (Data'Length) > Max_Encoded_Authentication - Position then
         Success := False;
         return;
      end if;
      if Data'Length > 0 then
         for Offset in Natural range 0 .. Natural (Data'Length) - 1 loop
            pragma Loop_Invariant
              (Offset < Natural (Data'Length)
               and then Offset < Max_Encoded_Authentication - Position);
            Result.Data
              (Ada.Streams.Stream_Element_Offset (Position + Offset + 1)) :=
                Data (Data'First + Ada.Streams.Stream_Element_Offset (Offset));
         end loop;
      end if;
      Position := Position + Natural (Data'Length);
   end Append_Bytes;

   procedure Finish
     (Result   : in out Encode_Result;
      Position : Natural;
      Success  : Boolean)
   with Pre => Position in 4 .. Max_Encoded_Authentication;

   procedure Finish
     (Result   : in out Encode_Result;
      Position : Natural;
      Success  : Boolean) is
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
   end Finish;

   function Encode_Certificate
     (Certificate : Ada.Streams.Stream_Element_Array;
      Extensions  : Ada.Streams.Stream_Element_Array) return Encode_Result
   is
      Result   : Encode_Result;
      Position : Natural := 4;
      Success  : Boolean := True;
      Entry_Length : constant Natural :=
        3 + Natural (Certificate'Length) + 2 + Natural (Extensions'Length);
   begin
      Result.Data (1) := 11;
      Append_Byte (Result, Position, 0, Success);
      Append_U24 (Result, Position, Entry_Length, Success);
      Append_U24 (Result, Position, Natural (Certificate'Length), Success);
      Append_Bytes (Result, Position, Certificate, Success);
      Append_U16 (Result, Position, Natural (Extensions'Length), Success);
      Append_Bytes (Result, Position, Extensions, Success);
      Finish (Result, Position, Success);
      return Result;
   end Encode_Certificate;

   function Encode_Certificate_Verify
     (Scheme    : Signature_Scheme;
      Signature : Ada.Streams.Stream_Element_Array) return Encode_Result
   is
      Result   : Encode_Result;
      Position : Natural := 4;
      Success  : Boolean := True;
      Scheme_Value : constant Natural :=
        (case Scheme is
            when ECDSA_SECP256R1_SHA256 => 16#0403#,
            when RSA_PSS_RSAE_SHA256 => 16#0804#,
            when ED25519 => 16#0807#);
   begin
      Result.Data (1) := 15;
      Append_U16 (Result, Position, Scheme_Value, Success);
      Append_U16 (Result, Position, Natural (Signature'Length), Success);
      Append_Bytes (Result, Position, Signature, Success);
      Finish (Result, Position, Success);
      return Result;
   end Encode_Certificate_Verify;

   function Encode_Finished (Verify : Verify_Data) return Encode_Result is
      Result   : Encode_Result;
      Position : Natural := 4;
      Success  : Boolean := True;
   begin
      Result.Data (1) := 20;
      Append_Bytes (Result, Position, Verify, Success);
      Finish (Result, Position, Success);
      return Result;
   end Encode_Finished;
end Flyology.QUIC.TLS_Authentication_Policy;
