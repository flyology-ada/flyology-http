procedure Flyology.QUIC.Crypto_OpenSSL.Smoke is
   use type Ada.Streams.Stream_Element;
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

   Backend : Provider;
   Keys    : Initial_Keys;
begin
   Initialize_Provider (Backend);
   pragma Assert (Is_Available (Backend));
   Derive_V1_Initial (Backend, Hex ("8394c8f03e515708"), Keys);

   --  RFC 9001 Appendix A.1 verifies both directions of the v1 Initial key
   --  schedule independently of the implementation.
   pragma Assert
     (Keys.Client_Secret =
        Hex ("c00cf151ca5be075ed0ebfb5c80323c4" &
             "2d6b7db67881289af4008f1f6c357aea"));
   pragma Assert
     (Keys.Client_Key = Hex ("1f369613dd76d5467730efcbe3b1a22d"));
   pragma Assert (Keys.Client_IV = Hex ("fa044b2f42a3fd3b46fb255c"));
   pragma Assert
     (Keys.Client_HP = Hex ("9f50449e04a0e810283a1e9933adedd2"));
   pragma Assert
     (Keys.Server_Secret =
        Hex ("3c199828fd139efd216c155ad844cc81" &
             "fb82fa8d7446fa7d78be803acdda951b"));
   pragma Assert
     (Keys.Server_Key = Hex ("cf3a5331653c364c88f0f379b6067e37"));
   pragma Assert (Keys.Server_IV = Hex ("0ac1493ca1905853b0bba03e"));
   pragma Assert
     (Keys.Server_HP = Hex ("c206b8d9b9f0f37644430b490eeaa314"));

   declare
      Crypto_Frame : constant Ada.Streams.Stream_Element_Array :=
        Hex
          ("060040f1010000ed0303ebf8fa56f129" &
           "39b9584a3896472ec40bb863cfd3e868" &
           "04fe3a47f06a2b69484c000004130113" &
           "02010000c000000010000e00000b6578" &
           "616d706c652e636f6dff01000100000a" &
           "00080006001d00170018001000070005" &
           "04616c706e0005000501000000000033" &
           "00260024001d00209370b2c9caa47fba" &
           "baf4559fedba753de171fa71f50f1ce1" &
           "5d43e994ec74d748002b000302030400" &
           "0d0010000e0403050306030203080408" &
           "050806002d00020101001c0002400100" &
           "3900320408ffffffffffffffff050480" &
           "00ffff07048000ffff08011001048000" &
           "75300901100f088394c8f03e51570806" &
           "048000ffff");
      Header : constant Ada.Streams.Stream_Element_Array :=
        Hex ("c300000001088394c8f03e5157080000449e00000002");
      Plaintext  : Ada.Streams.Stream_Element_Array (1 .. 1_162) :=
        (others => 0);
      Ciphertext : Ada.Streams.Stream_Element_Array (1 .. 1_178);
      Decoded    : Ada.Streams.Stream_Element_Array (Plaintext'Range);
      Tampered   : Ada.Streams.Stream_Element_Array (Ciphertext'Range);
      Authenticated : Boolean;
      Nonce      : AES_GCM_IV := Keys.Client_IV;
      Sample     : Header_Sample;
      Mask       : Header_Mask;
      Protected_Header : Ada.Streams.Stream_Element_Array (Header'Range) :=
        Header;
   begin
      Plaintext (1 .. Crypto_Frame'Length) := Crypto_Frame;
      Nonce (Nonce'Last) := Nonce (Nonce'Last) xor 2;
      Protect
        (Backend, Keys.Client_Key, Nonce, Header, Plaintext, Ciphertext);

      Sample := Ciphertext (1 .. 16);
      pragma Assert (Sample = Hex ("d1b1c98dd7689fb8ec11d242b123dc9b"));
      pragma Assert
        (Ciphertext (Ciphertext'Last - 15 .. Ciphertext'Last) =
           Hex ("e221af44860018ab0856972e194cd934"));

      Unprotect
        (Backend, Keys.Client_Key, Nonce, Header, Ciphertext, Decoded,
         Authenticated);
      pragma Assert (Authenticated and then Decoded = Plaintext);
      Tampered := Ciphertext;
      Tampered (Tampered'Last) := Tampered (Tampered'Last) xor 1;
      Unprotect
        (Backend, Keys.Client_Key, Nonce, Header, Tampered, Decoded,
         Authenticated);
      pragma Assert (not Authenticated);
      pragma Assert (Decoded = (Decoded'Range => 0));

      Make_Header_Mask (Backend, Keys.Client_HP, Sample, Mask);
      pragma Assert (Mask = Hex ("437b9aec36"));
      Protected_Header (Protected_Header'First) :=
        Protected_Header (Protected_Header'First) xor (Mask (1) and 16#0F#);
      for Offset in Ada.Streams.Stream_Element_Offset range 0 .. 3 loop
         Protected_Header (Protected_Header'Last - 3 + Offset) :=
           Protected_Header (Protected_Header'Last - 3 + Offset)
             xor Mask (Offset + 2);
      end loop;
      pragma Assert
        (Protected_Header =
           Hex ("c000000001088394c8f03e5157080000449e7b9aec34"));
   end;
end Flyology.QUIC.Crypto_OpenSSL.Smoke;
