procedure Flyology.QUIC.Initial_Receiver.Smoke is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Packet_Number_Policy.Packet_Number;

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

   Backend : Crypto_OpenSSL.Provider;
   Keys    : Crypto_OpenSSL.Initial_Keys;
begin
   Crypto_OpenSSL.Initialize_Provider (Backend);
   Crypto_OpenSSL.Derive_V1_Initial
     (Backend, Hex ("8394c8f03e515708"), Keys);

   declare
      --  Complete RFC 9001 Appendix A.3 protected server Initial packet.
      Packet : constant Ada.Streams.Stream_Element_Array :=
        Hex
          ("cf000000010008f067a5502a4262b500" &
           "4075c0d95a482cd0991cd25b0aac406a" &
           "5816b6394100f37a1c69797554780bb3" &
           "8cc5a99f5ede4cf73c3ec2493a1839b3" &
           "dbcba3f6ea46c5b7684df3548e7ddeb9" &
           "c3bf9c73cc3f3bded74b562bfb19fb84" &
           "022f8ef4cdd93795d77d06edbb7aaf2f" &
           "58891850abbdca3d20398c276456cbc4" &
           "2158407dd074ee");
      Expected : constant Ada.Streams.Stream_Element_Array :=
        Hex
          ("02000000000600405a020000560303ee" &
           "fce7f7b37ba1d1632e96677825ddf739" &
           "88cfc79825df566dc5430b9a045a1200" &
           "130100002e00330024001d00209d3c94" &
           "0d89690b84d08a60993c144eca684d10" &
           "81287c834d5311bcf32bb9da1a002b00" &
           "020304");
      Tampered  : Ada.Streams.Stream_Element_Array (Packet'Range) := Packet;
      Plaintext : Ada.Streams.Stream_Element_Array (Packet'Range);
      Result    : Receive_Result;
   begin
      Receive
        (Backend, Keys.Server_Key, Keys.Server_IV, Keys.Server_HP, 0,
         Packet, Plaintext, Result);
      pragma Assert (Result.Status = Received);
      pragma Assert (Result.First_Byte = 16#C1#);
      pragma Assert (Result.Number_Length = 2 and then Result.Number = 1);
      pragma Assert (Result.Header_Length = 20);
      pragma Assert (Result.Plaintext_Length = Expected'Length);
      pragma Assert
        (Plaintext
           (Plaintext'First
            .. Plaintext'First + Expected'Length - 1) = Expected);

      Tampered (Tampered'Last) := Tampered (Tampered'Last) xor 1;
      Receive
        (Backend, Keys.Server_Key, Keys.Server_IV, Keys.Server_HP, 0,
         Tampered, Plaintext, Result);
      pragma Assert (Result.Status = Authentication_Failed);
      pragma Assert (Plaintext = (Plaintext'Range => 0));

      declare
         Invalid_Header : constant Ada.Streams.Stream_Element_Array :=
           Hex ("c5000000010008f067a5502a4262b50040750001");
         Protected_Header : Ada.Streams.Stream_Element_Array
           (Invalid_Header'Range) := Invalid_Header;
         Ciphertext : Ada.Streams.Stream_Element_Array
           (1 .. Expected'Length + 16);
         Invalid_Packet : Ada.Streams.Stream_Element_Array (Packet'Range);
         Sample : Crypto_OpenSSL.Header_Sample;
         Mask   : Crypto_OpenSSL.Header_Mask;
         Nonce  : Crypto_OpenSSL.AES_GCM_IV := Keys.Server_IV;
      begin
         Nonce (Nonce'Last) := Nonce (Nonce'Last) xor 1;
         Crypto_OpenSSL.Protect
           (Backend, Keys.Server_Key, Nonce, Invalid_Header, Expected,
            Ciphertext);
         Sample := Ciphertext (Ciphertext'First + 2 .. Ciphertext'First + 17);
         Crypto_OpenSSL.Make_Header_Mask
           (Backend, Keys.Server_HP, Sample, Mask);
         Protected_Header (Protected_Header'First) :=
           Protected_Header (Protected_Header'First)
             xor (Mask (Mask'First) and 16#0F#);
         Protected_Header (Protected_Header'Last - 1) :=
           Protected_Header (Protected_Header'Last - 1) xor Mask (2);
         Protected_Header (Protected_Header'Last) :=
           Protected_Header (Protected_Header'Last) xor Mask (3);
         Invalid_Packet
           (Invalid_Packet'First
            .. Invalid_Packet'First + Protected_Header'Length - 1) :=
              Protected_Header;
         Invalid_Packet
           (Invalid_Packet'First + Protected_Header'Length
            .. Invalid_Packet'Last) := Ciphertext;

         Receive
           (Backend, Keys.Server_Key, Keys.Server_IV, Keys.Server_HP, 0,
            Invalid_Packet, Plaintext, Result);
         pragma Assert (Result.Status = Invalid_Reserved_Bits);
         pragma Assert (Plaintext = (Plaintext'Range => 0));
      end;

      Receive
        (Backend, Keys.Server_Key, Keys.Server_IV, Keys.Server_HP, 65_537,
         Packet, Plaintext, Result);
      pragma Assert (Result.Status = Authentication_Failed);
      pragma Assert (Plaintext = (Plaintext'Range => 0));
   end;
end Flyology.QUIC.Initial_Receiver.Smoke;
