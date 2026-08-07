procedure Flyology.QUIC.TLS_Handshake_Policy.Smoke is
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

   Client : constant Ada.Streams.Stream_Element_Array :=
     Hex
       ("010000ed0303ebf8fa56f12939b9584a" &
        "3896472ec40bb863cfd3e86804fe3a47" &
        "f06a2b69484c00000413011302010000" &
        "c000000010000e00000b6578616d706c" &
        "652e636f6dff01000100000a00080006" &
        "001d0017001800100007000504616c70" &
        "6e000500050100000000003300260024" &
        "001d00209370b2c9caa47fbabaf4559f" &
        "edba753de171fa71f50f1ce15d43e994" &
        "ec74d748002b0003020304000d001000" &
        "0e0403050306030203080408050806002d" &
        "00020101001c00024001003900320408" &
        "ffffffffffffffff05048000ffff0704" &
        "8000ffff080110010480007530090110" &
        "0f088394c8f03e51570806048000ffff");

   Server : constant Ada.Streams.Stream_Element_Array :=
     Hex
       ("020000560303eefce7f7b37ba1d1632e" &
        "96677825ddf73988cfc79825df566dc5" &
        "430b9a045a1200130100002e00330024" &
        "001d00209d3c940d89690b84d08a6099" &
        "3c144eca684d1081287c834d5311bcf3" &
        "2bb9da1a002b00020304");
begin
   declare
      Result : constant Parse_Result := Parse (Client);
   begin
      pragma Assert
        (Result.Status = Parsed
         and then Result.Kind = Client_Hello
         and then Result.Consumed = Client'Length
         and then Result.Random_Offset = 6
         and then Result.Session_ID_Length = 0
         and then Result.Extensions_Length = 192
         and then Result.Extensions.Status = TLS_Extension_Policy.Parsed);
   end;

   declare
      Result : constant Parse_Result := Parse (Server);
   begin
      pragma Assert
        (Result.Status = Parsed
         and then Result.Kind = Server_Hello
         and then Result.Consumed = Server'Length
         and then Result.Random_Offset = 6
         and then Result.Extensions_Length = 46);
   end;

   declare
      Extension_Data : constant TLS_Extension_Policy.Encode_Result :=
        TLS_Extension_Policy.Encode_Encrypted_Extensions
          (Hex ("6833"), Hex ("00000f00"));
      Wire : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (6 + Extension_Data.Length)) :=
          (others => 0);
      Result : Parse_Result;
   begin
      Wire (1) := 8;
      Wire (4) := Ada.Streams.Stream_Element (2 + Extension_Data.Length);
      Wire (5) := Ada.Streams.Stream_Element (Extension_Data.Length / 256);
      Wire (6) := Ada.Streams.Stream_Element (Extension_Data.Length mod 256);
      Wire (7 .. Wire'Last) :=
        Extension_Data.Data
          (1 .. Ada.Streams.Stream_Element_Offset (Extension_Data.Length));
      Result := Parse (Wire);
      pragma Assert
        (Result.Status = Parsed
         and then Result.Kind = Encrypted_Extensions
         and then Result.Extensions.Has_Transport_Parameters);
   end;

   pragma Assert (Parse ((1 .. 0 => 0)).Status = Need_More_Data);
   pragma Assert (Parse (Hex ("01000100")).Status = Need_More_Data);
   pragma Assert (Parse (Hex ("14000000")).Status = Unsupported_Message);
   pragma Assert (Parse (Hex ("010000020304")).Status = Invalid_Handshake);
   pragma Assert
     (Parse (Hex ("080000020000")).Status = Invalid_Extensions);

   declare
      Coalesced : Ada.Streams.Stream_Element_Array (1 .. Server'Length + 4);
      Result    : Parse_Result;
   begin
      Coalesced (1 .. Server'Length) := Server;
      Coalesced (Server'Length + 1 .. Coalesced'Last) := Hex ("14000000");
      Result := Parse (Coalesced);
      pragma Assert
        (Result.Status = Parsed and then Result.Consumed = Server'Length);
   end;
end Flyology.QUIC.TLS_Handshake_Policy.Smoke;
