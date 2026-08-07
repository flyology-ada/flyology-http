procedure Flyology.QUIC.TLS_Extension_Policy.Smoke is
   use type Ada.Streams.Stream_Element_Array;
   use type Ada.Streams.Stream_Element_Offset;

   function Nibble (Value : Character) return Natural is
     (case Value is
         when '0' .. '9' => Character'Pos (Value) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (Value) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (Value) - Character'Pos ('A') + 10,
         when others => raise Constraint_Error);

   function Hex (Value : String) return Ada.Streams.Stream_Element_Array is
      Result : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Value'Length / 2));
      Source : Positive := Value'First;
   begin
      pragma Assert (Value'Length mod 2 = 0);
      for Element of Result loop
         Element :=
           Ada.Streams.Stream_Element
             (16 * Nibble (Value (Source)) + Nibble (Value (Source + 1)));
         Source := Source + 2;
      end loop;
      return Result;
   end Hex;

   procedure Check_Status
     (Wire     : Ada.Streams.Stream_Element_Array;
      Context  : Extension_Context;
      Expected : Parse_Status)
   is
      Result : constant Parse_Result := Parse (Wire, Context);
   begin
      pragma Assert
        (Result.Status = Expected,
         "expected " & Expected'Image & ", got " & Result.Status'Image);
   end Check_Status;

   RFC_Client_Extensions : constant Ada.Streams.Stream_Element_Array :=
     Hex
       ("00000010000e00000b6578616d706c65" &
        "2e636f6dff01000100000a0008000600" &
        "1d0017001800100007000504616c706e" &
        "00050005010000000000330026002400" &
        "1d00209370b2c9caa47fbabaf4559fed" &
        "ba753de171fa71f50f1ce15d43e994ec" &
        "74d748002b0003020304000d0010000e" &
        "0403050306030203080408050806002d" &
        "00020101001c00024001003900320408" &
        "ffffffffffffffff05048000ffff0704" &
        "8000ffff080110010480007530090110" &
        "0f088394c8f03e51570806048000ffff");

   RFC_Server_Extensions : constant Ada.Streams.Stream_Element_Array :=
     Hex
       ("00330024001d00209d3c940d89690b84" &
        "d08a60993c144eca684d1081287c834d" &
        "5311bcf32bb9da1a002b00020304");

   Key : constant X25519_Public_Key :=
     Hex
       ("9370b2c9caa47fbabaf4559fedba753d" &
        "e171fa71f50f1ce15d43e994ec74d748");
   H3 : constant Ada.Streams.Stream_Element_Array := Hex ("6833");
   Client_TP : constant Ada.Streams.Stream_Element_Array := Hex ("0f00");
   Server_TP : constant Ada.Streams.Stream_Element_Array := Hex ("00000f00");
begin
   declare
      Result : constant Parse_Result :=
        Parse (RFC_Client_Extensions, Client_Hello);
   begin
      pragma Assert
        (Result.Status = Parsed and then Result.Count = 11,
         "RFC client extensions: " & Result.Status'Image
         & " count" & Result.Count'Image);
      pragma Assert
        (Result.Has_Supported_TLS_1_3
         and then Result.Has_X25519_Key_Share
         and then Result.Has_Compatible_Signature
         and then Result.Has_ALPN
         and then Result.ALPN_Protocol_Length = 4
         and then
           RFC_Client_Extensions
             (Ada.Streams.Stream_Element_Offset (1)
                + Ada.Streams.Stream_Element_Offset
                    (Result.ALPN_Protocol_Offset)
              .. Ada.Streams.Stream_Element_Offset
                   (Result.ALPN_Protocol_Offset
                    + Result.ALPN_Protocol_Length)) = Hex ("616c706e")
         and then Result.Has_Transport_Parameters
         and then Result.Transport_Parameters_Length = 50);
   end;

   declare
      Result : constant Parse_Result :=
        Parse (RFC_Server_Extensions, Server_Hello);
   begin
      pragma Assert
        (Result.Status = Parsed
         and then Result.Count = 2
         and then Result.Has_Supported_TLS_1_3
         and then Result.Has_X25519_Key_Share
         and then not Result.Has_ALPN
         and then not Result.Has_Transport_Parameters
         and then
           RFC_Server_Extensions
             (Ada.Streams.Stream_Element_Offset (1)
                + Ada.Streams.Stream_Element_Offset (Result.Key_Share_Offset)
              .. Ada.Streams.Stream_Element_Offset
                   (Result.Key_Share_Offset + 32)) =
             Hex
               ("9d3c940d89690b84d08a60993c144eca" &
                "684d1081287c834d5311bcf32bb9da1a"));
   end;

   declare
      Encoded : constant Encode_Result :=
        Encode_Client_Hello (Key, H3, Client_TP);
      Parsed_Result : constant Parse_Result :=
        Parse
          (Encoded.Data
             (1 .. Ada.Streams.Stream_Element_Offset (Encoded.Length)),
           Client_Hello);
   begin
      pragma Assert
        (Encoded.Status = TLS_Extension_Policy.Encoded
         and then Parsed_Result.Status = Parsed
         and then Parsed_Result.Count = 6
         and then Parsed_Result.ALPN_Protocol_Length = 2
         and then Parsed_Result.Transport_Parameters_Length = 2);
   end;

   declare
      Encoded : constant Encode_Result := Encode_Server_Hello (Key);
   begin
      pragma Assert
        (Encoded.Status = TLS_Extension_Policy.Encoded
         and then
           Parse
             (Encoded.Data
                (1 .. Ada.Streams.Stream_Element_Offset (Encoded.Length)),
              Server_Hello).Status = Parsed);
   end;

   declare
      Encoded : constant Encode_Result :=
        Encode_Encrypted_Extensions (H3, Server_TP);
      Parsed_Result : constant Parse_Result :=
        Parse
          (Encoded.Data
             (1 .. Ada.Streams.Stream_Element_Offset (Encoded.Length)),
           Encrypted_Extensions);
   begin
      pragma Assert
        (Encoded.Status = TLS_Extension_Policy.Encoded
         and then Parsed_Result.Status = Parsed
         and then Parsed_Result.Count = 2
         and then Parsed_Result.Transport_Parameters_Length = 4);
   end;

   Check_Status ((1 => 0), Client_Hello, Truncated);
   Check_Status (Hex ("002b0003020304"), Client_Hello,
                 Missing_Required_Extension);
   Check_Status (Hex ("002b00020304002b00020304"), Server_Hello,
                 Duplicate_Extension);
   Check_Status (Hex ("00390000"), Server_Hello, Extension_Not_Allowed);
   Check_Status (Hex ("002b00020304"), Encrypted_Extensions,
                 Extension_Not_Allowed);
   Check_Status (Hex ("002b0003020303"), Client_Hello,
                 Invalid_Extension_Value);
   Check_Status (Hex ("00330004001d0000"), Client_Hello,
                 Invalid_Extension_Value);
   Check_Status (Hex ("00100003000100"), Encrypted_Extensions,
                 Invalid_Extension_Value);
end Flyology.QUIC.TLS_Extension_Policy.Smoke;
