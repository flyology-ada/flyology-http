procedure Flyology.QUIC.TLS_Key_Schedule.Smoke is
   use type Ada.Streams.Stream_Element_Array;

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

   Provider   : Crypto_OpenSSL.Provider;
   Handshake  : Handshake_Secrets;
   Shared     : constant Shared_Secret :=
     Shared_Secret'
       (Hex ("8bd4054fb55b9d63fdfbacf9f04b9f0d" &
             "35e6d63f537563efd46272900f89492d"));
   Transcript : constant Transcript_Hash :=
     Transcript_Hash'
       (Hex ("860c06edc07858ee8e78f0e7428c58ed" &
             "d6b43f2ca3e6e95f02ed063cf0e1cad8"));
begin
   Crypto_OpenSSL.Initialize_Provider (Provider);
   Derive_Handshake (Provider, Shared, Transcript, Handshake);

   --  RFC 8448 Section 3 checks the no-PSK TLS 1.3 schedule from the
   --  X25519 result through handshake traffic, Finished, and master secrets.
   pragma Assert
     (Handshake.Handshake =
        Hex ("1dc826e93606aa6fdc0aadc12f741b01" &
             "046aa6b99f691ed221a9f0ca043fbeac"));
   pragma Assert
     (Handshake.Client_Traffic =
        Hex ("b3eddb126e067f35a780b3abf45e2d8f" &
             "3b1a950738f52e9600746a0e27a55a21"));
   pragma Assert
     (Handshake.Server_Traffic =
        Hex ("b67b7d690cc16c4e75e54213cb2d37b4" &
             "e9c912bcded9105d42befd59d391ad38"));
   pragma Assert
     (Handshake.Client_Finished =
        Hex ("b80ad01015fb2f0bd65ff7d4da5d6bf8" &
             "3f84821d1f87fdc7d3c75b5a7b42d9c4"));
   pragma Assert
     (Handshake.Server_Finished =
        Hex ("008d3b66f816ea559f96b537e885c31f" &
             "c068bf492c652f01f288a1d8cdc19fc8"));
   pragma Assert
     (Handshake.Master =
        Hex ("18df06843d13a08bf2a449844c5f8a47" &
             "8001bc4d4c627984d5a41da8d0402919"));

   declare
      Key : Crypto_OpenSSL.AES_128_Key;
      IV  : Crypto_OpenSSL.AES_GCM_IV;
   begin
      HKDF_Expand_Label
        (Provider, Handshake.Server_Traffic, "key", Hex (""), Key);
      HKDF_Expand_Label
        (Provider, Handshake.Server_Traffic, "iv", Hex (""), IV);
      pragma Assert (Key = Hex ("3fce516009c21727d0f2e4e86ee403bc"));
      pragma Assert (IV = Hex ("5d313eb2671276ee13000b30"));
   end;

   declare
      Transcript_Before_Server_Finished : constant Transcript_Hash :=
        Transcript_Hash'
          (Hex ("edb7725fa7a3473b031ec8ef65a24854" &
                "93900138a2b91291407d7951a06110ed"));
      Verify_Data : Secret;
   begin
      Finished_Verify_Data
        (Provider, Handshake.Server_Finished,
         Transcript_Before_Server_Finished, Verify_Data);
      pragma Assert
        (Verify_Data =
           Hex ("9b9b141d906337fbd2cbdce71df4deda" &
                "4ab42c309572cb7fffee5454b78f0718"));
   end;

   declare
      Server_Transcript : constant Transcript_Hash :=
        Transcript_Hash'
          (Hex ("9608102a0f1ccc6db6250b7b7e417b1a" &
                "000eaada3daae4777a7686c9ff83df13"));
      Application : Application_Secrets;
   begin
      Derive_Application
        (Provider, Handshake, Server_Transcript, Application);
      pragma Assert
        (Application.Client_Traffic =
           Hex ("9e40646ce79a7f9dc05af8889bce6552" &
                "875afa0b06df0087f792ebb7c17504a5"));
      pragma Assert
        (Application.Server_Traffic =
           Hex ("a11af9f05531f856ad47116b45a95032" &
                "8204b4f44bfb6b3a4b4f1f3fcb631643"));
      pragma Assert
        (Application.Exporter =
           Hex ("fe22f881176eda18eb8f44529e6792c5" &
                "0c9a3f89452f68d8ae311b4309d3cf50"));
      Clear (Application);
   end;

   declare
      Client_Transcript : constant Transcript_Hash :=
        Transcript_Hash'
          (Hex ("209145a96ee8e2a122ff810047cc9526" &
                "84658d6049e86429426db87c54ad143d"));
      Resumption : Secret;
   begin
      Derive_Resumption
        (Provider, Handshake, Client_Transcript, Resumption);
      pragma Assert
        (Resumption =
           Hex ("7df235f2031d2a051287d02b0241b0bf" &
                "daf86cc856231f2d5aba46c434ec196c"));
      Clear (Resumption);
   end;

   declare
      Initial_Traffic : constant Secret :=
        Secret'
          (Hex ("c00cf151ca5be075ed0ebfb5c80323c4" &
                "2d6b7db67881289af4008f1f6c357aea"));
      Keys : QUIC_Traffic_Keys;
   begin
      --  RFC 9001 Appendix A.1 validates QUIC's distinct key labels.
      Derive_QUIC_Keys (Provider, Initial_Traffic, Keys);
      pragma Assert (Keys.Key = Hex ("1f369613dd76d5467730efcbe3b1a22d"));
      pragma Assert (Keys.IV = Hex ("fa044b2f42a3fd3b46fb255c"));
      pragma Assert (Keys.HP = Hex ("9f50449e04a0e810283a1e9933adedd2"));
      Clear (Keys);
   end;

   Clear (Handshake);
   pragma Assert
     (Handshake = (Handshake_Secrets'(others => (others => 0))));
end Flyology.QUIC.TLS_Key_Schedule.Smoke;
