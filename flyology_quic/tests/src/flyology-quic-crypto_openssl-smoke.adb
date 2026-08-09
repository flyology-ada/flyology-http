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
      Digest : SHA256_Digest;
      Key    : constant Ada.Streams.Stream_Element_Array (1 .. 20) :=
        (others => 16#0B#);
   begin
      --  FIPS 180-4 and RFC 4231 keep the primitive boundary independent
      --  from the TLS and QUIC key schedules which consume it.
      SHA256 (Backend, Hex (""), Digest);
      pragma Assert
        (Digest =
           Hex ("e3b0c44298fc1c149afbf4c8996fb924" &
                "27ae41e4649b934ca495991b7852b855"));
      SHA256 (Backend, Hex ("616263"), Digest);
      pragma Assert
        (Digest =
           Hex ("ba7816bf8f01cfea414140de5dae2223" &
                "b00361a396177a9cb410ff61f20015ad"));
      HMAC_SHA256 (Backend, Key, Hex ("4869205468657265"), Digest);
      pragma Assert
        (Digest =
           Hex ("b0344c61d8db38535ca8afceaf0bf12b" &
                "881dc200c9833da726e9376c2e32cff7"));
   end;

   declare
      Alice_Private : constant X25519_Private_Key :=
        X25519_Private_Key'
          (Hex ("77076d0a7318a57d3c16c17251b26645" &
                "df4c2f87ebc0992ab177fba51db92c2a"));
      Bob_Private   : constant X25519_Private_Key :=
        X25519_Private_Key'
          (Hex ("5dab087e624a8a4b79e17f8b83800ee6" &
                "6f3bb1292618b6fd1c2f8b27ff88e0eb"));
      Alice_Public  : X25519_Public_Key;
      Bob_Public    : X25519_Public_Key;
      Alice_Shared  : X25519_Shared_Secret;
      Bob_Shared    : X25519_Shared_Secret;
      Expected_Alice_Public : constant X25519_Public_Key :=
        X25519_Public_Key'
          (Hex ("8520f0098930a754748b7ddcb43ef75a0" &
                "dbf3a0d26381af4eba4a98eaa9b4e6a"));
      Expected_Bob_Public : constant X25519_Public_Key :=
        X25519_Public_Key'
          (Hex ("de9edb7d7b7dc1b4d35b61c2ece43537" &
                "3f8343c85b78674dadfc7e146f882b4f"));
      Expected_Shared : constant X25519_Shared_Secret :=
        X25519_Shared_Secret'
          (Hex ("4a5d9d5ba4ce2de1728e3bf480350f25" &
                "e07e21c947d19e3376f09b3c1e161742"));
   begin
      --  RFC 7748 verifies raw public-key derivation and both ECDH
      --  directions, including the byte ordering used on the TLS wire.
      X25519_Public (Backend, Alice_Private, Alice_Public);
      X25519_Public (Backend, Bob_Private, Bob_Public);
      pragma Assert (Alice_Public = Expected_Alice_Public);
      pragma Assert (Bob_Public = Expected_Bob_Public);
      X25519_Shared
        (Backend, Alice_Private, Bob_Public, Alice_Shared);
      X25519_Shared
        (Backend, Bob_Private, Alice_Public, Bob_Shared);
      pragma Assert
        (Alice_Shared = Expected_Shared and then Bob_Shared = Expected_Shared);

      declare
         Rejected : Boolean := False;
         Invalid_Shared : X25519_Shared_Secret;
      begin
         begin
            X25519_Shared
              (Backend, Alice_Private, (others => 0), Invalid_Shared);
         exception
            when Crypto_Error =>
               Rejected := True;
         end;
         pragma Assert (Rejected);
      end;
   end;

   declare
      Alice_Private : X25519_Private_Key;
      Alice_Public  : X25519_Public_Key;
      Bob_Private   : X25519_Private_Key;
      Bob_Public    : X25519_Public_Key;
      Alice_Shared  : X25519_Shared_Secret;
      Bob_Shared    : X25519_Shared_Secret;
   begin
      Generate_X25519 (Backend, Alice_Private, Alice_Public);
      Generate_X25519 (Backend, Bob_Private, Bob_Public);
      X25519_Shared
        (Backend, Alice_Private, Bob_Public, Alice_Shared);
      X25519_Shared
        (Backend, Bob_Private, Alice_Public, Bob_Shared);
      pragma Assert (Alice_Shared = Bob_Shared);
   end;

   declare
      Private_Key : constant Ed25519_Private_Key :=
        Ed25519_Private_Key'
          (Hex ("9d61b19deffd5a60ba844af492ec2cc4" &
                "4449c5697b326919703bac031cae7f60"));
      Expected_Public : constant Ed25519_Public_Key :=
        Ed25519_Public_Key'
          (Hex ("d75a980182b10ab7d54bfed3c964073a" &
                "0ee172f3daa62325af021a68f707511a"));
      Expected_Signature : constant Ed25519_Signature :=
        Ed25519_Signature'
          (Hex ("e5564300c360ac729086e2cc806e828a" &
                "84877f1eb8e5d974d873e06522490155" &
                "5fb8821590a33bacc61e39701cf9b46b" &
                "d25bf5f0595bbe24655141438e7a100b"));
      Public_Key : Ed25519_Public_Key;
      Signature  : Ed25519_Signature;
      Verified   : Boolean;
   begin
      --  RFC 8032 section 7.1, test 1 fixes public-key derivation and the
      --  deterministic signature encoding for an empty message.
      Ed25519_Public (Backend, Private_Key, Public_Key);
      Ed25519_Sign (Backend, Private_Key, Hex (""), Signature);
      pragma Assert (Public_Key = Expected_Public);
      pragma Assert (Signature = Expected_Signature);
      Ed25519_Verify
        (Backend, Public_Key, Hex (""), Signature, Verified);
      pragma Assert (Verified);
      Signature (Signature'Last) := Signature (Signature'Last) xor 1;
      Ed25519_Verify
        (Backend, Public_Key, Hex (""), Signature, Verified);
      pragma Assert (not Verified);
   end;

   declare
      Private_Key : constant Ed25519_Private_Key :=
        Ed25519_Private_Key'
          (Hex ("f491306c81165ffd97822f3ef58de891" &
                "8779314457f5501e42d3f68504cd3aa8"));
      Certificate : constant Ada.Streams.Stream_Element_Array :=
        Hex
          ("3082013c3081efa0030201020214434e3e3873a520217edf913fba03f4" &
           "ea17411e64300506032b657030143112301006035504030c096c6f6361" &
           "6c686f7374301e170d3236303830373230323830385a170d3336303830" &
           "343230323830385a30143112301006035504030c096c6f63616c686f73" &
           "74302a300506032b65700321006380a1de85cdd187a3134d096ff12e8b" &
           "1e47aa4c94cff3c4144bad3ee5f81eaea3533051301d0603551d0e0416" &
           "0414d3dd952a2ff44a35af38d9249d71a454ced348ce301f0603551d23" &
           "041830168014d3dd952a2ff44a35af38d9249d71a454ced348ce300f060" &
           "3551d130101ff040530030101ff300506032b657003410024075a33b818" &
           "be62a4f328b79bd8f79febe7d3710fb44ba7a7b2d8e12bc3d1e4056d5" &
           "c20fba04e183430175b62ed1a107eb518dfaacf11045fa0e5a6feba2c0f");
      Message   : constant Ada.Streams.Stream_Element_Array := Hex ("71756963");
      Signature : Ed25519_Signature;
      Verified  : Boolean;
   begin
      --  The fixed DER fixture binds the raw seed above to an X.509
      --  SubjectPublicKeyInfo. This exercises only key extraction and
      --  signature verification; trust and hostname policy remain in Ada.
      Ed25519_Sign (Backend, Private_Key, Message, Signature);
      Ed25519_Verify_Certificate
        (Backend, Certificate, Message, Signature, Verified);
      pragma Assert (Verified);
      Signature (Signature'First) := Signature (Signature'First) xor 1;
      Ed25519_Verify_Certificate
        (Backend, Certificate, Message, Signature, Verified);
      pragma Assert (not Verified);
      Ed25519_Verify_Certificate
        (Backend, Hex ("3000"), Message, Signature, Verified);
      pragma Assert (not Verified);
   end;

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
      Unprotect
        (Backend, Keys.Client_Key, Nonce, Header, Ciphertext, Decoded,
         Authenticated);
      pragma Assert (Authenticated and then Decoded = Plaintext);

      Make_Header_Mask (Backend, Keys.Client_HP, Sample, Mask);
      pragma Assert (Mask = Hex ("437b9aec36"));
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
