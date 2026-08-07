with Interfaces.C;
with Interfaces.C.Strings;

package body Flyology.QUIC.Crypto_OpenSSL is
   package C renames Interfaces.C;
   package CS renames Interfaces.C.Strings;

   use type C.int;
   use type System.Address;

   Error_Capacity : constant := 1_024;
   subtype Error_Buffer is C.char_array (0 .. C.size_t (Error_Capacity - 1));

   function C_Create
     (Directory  : CS.chars_ptr;
      Error      : System.Address;
      Error_Size : C.size_t) return System.Address;
   pragma Import (C, C_Create, "flyology_quic_openssl_create");

   procedure C_Release (Handle : System.Address);
   pragma Import (C, C_Release, "flyology_quic_openssl_release");

   function C_Initial_Keys
     (Handle        : System.Address;
      Connection_ID : System.Address;
      ID_Length     : C.size_t;
      Client_Secret : System.Address;
      Client_Key    : System.Address;
      Client_IV     : System.Address;
      Client_HP     : System.Address;
      Server_Secret : System.Address;
      Server_Key    : System.Address;
      Server_IV     : System.Address;
      Server_HP     : System.Address;
      Error         : System.Address;
      Error_Size    : C.size_t) return C.int;
   pragma Import
     (C, C_Initial_Keys, "flyology_quic_openssl_initial_keys");

   function C_Protect
     (Handle            : System.Address;
      Key               : System.Address;
      Nonce             : System.Address;
      Header            : System.Address;
      Header_Length     : C.size_t;
      Plaintext         : System.Address;
      Plaintext_Length  : C.size_t;
      Ciphertext        : System.Address;
      Ciphertext_Length : C.size_t;
      Error             : System.Address;
      Error_Size        : C.size_t) return C.int;
   pragma Import (C, C_Protect, "flyology_quic_openssl_protect");

   function C_Unprotect
     (Handle            : System.Address;
      Key               : System.Address;
      Nonce             : System.Address;
      Header            : System.Address;
      Header_Length     : C.size_t;
      Ciphertext        : System.Address;
      Ciphertext_Length : C.size_t;
      Plaintext         : System.Address;
      Plaintext_Length  : C.size_t;
      Error             : System.Address;
      Error_Size        : C.size_t) return C.int;
   pragma Import (C, C_Unprotect, "flyology_quic_openssl_unprotect");

   function C_Header_Mask
     (Handle     : System.Address;
      Key        : System.Address;
      Sample     : System.Address;
      Mask       : System.Address;
      Error      : System.Address;
      Error_Size : C.size_t) return C.int;
   pragma Import
     (C, C_Header_Mask, "flyology_quic_openssl_header_mask");

   function C_Random
     (Handle        : System.Address;
      Output        : System.Address;
      Output_Length : C.size_t;
      Error         : System.Address;
      Error_Size    : C.size_t) return C.int;
   pragma Import (C, C_Random, "flyology_quic_openssl_random");

   function C_SHA256
     (Handle      : System.Address;
      Data        : System.Address;
      Data_Length : C.size_t;
      Digest      : System.Address;
      Error       : System.Address;
      Error_Size  : C.size_t) return C.int;
   pragma Import (C, C_SHA256, "flyology_quic_openssl_sha256");

   function C_HMAC_SHA256
     (Handle      : System.Address;
      Key         : System.Address;
      Key_Length  : C.size_t;
      Data        : System.Address;
      Data_Length : C.size_t;
      Digest      : System.Address;
      Error       : System.Address;
      Error_Size  : C.size_t) return C.int;
   pragma Import
     (C, C_HMAC_SHA256, "flyology_quic_openssl_hmac_sha256");

   function C_X25519_Public
     (Handle      : System.Address;
      Private_Key : System.Address;
      Public_Key  : System.Address;
      Error       : System.Address;
      Error_Size  : C.size_t) return C.int;
   pragma Import
     (C, C_X25519_Public, "flyology_quic_openssl_x25519_public");

   function C_X25519_Shared
     (Handle          : System.Address;
      Private_Key     : System.Address;
      Peer_Public_Key : System.Address;
      Shared_Secret   : System.Address;
      Error           : System.Address;
      Error_Size      : C.size_t) return C.int;
   pragma Import
     (C, C_X25519_Shared, "flyology_quic_openssl_x25519_shared");

   function C_Ed25519_Public
     (Handle      : System.Address;
      Private_Key : System.Address;
      Public_Key  : System.Address;
      Error       : System.Address;
      Error_Size  : C.size_t) return C.int;
   pragma Import
     (C, C_Ed25519_Public, "flyology_quic_openssl_ed25519_public");

   function C_Ed25519_Sign
     (Handle         : System.Address;
      Private_Key    : System.Address;
      Message        : System.Address;
      Message_Length : C.size_t;
      Signature      : System.Address;
      Error          : System.Address;
      Error_Size     : C.size_t) return C.int;
   pragma Import
     (C, C_Ed25519_Sign, "flyology_quic_openssl_ed25519_sign");

   function C_Ed25519_Verify
     (Handle         : System.Address;
      Public_Key     : System.Address;
      Message        : System.Address;
      Message_Length : C.size_t;
      Signature      : System.Address;
      Error          : System.Address;
      Error_Size     : C.size_t) return C.int;
   pragma Import
     (C, C_Ed25519_Verify, "flyology_quic_openssl_ed25519_verify");

   function C_Ed25519_Verify_Certificate
     (Handle             : System.Address;
      Certificate        : System.Address;
      Certificate_Length : C.size_t;
      Message            : System.Address;
      Message_Length     : C.size_t;
      Signature          : System.Address;
      Error              : System.Address;
      Error_Size         : C.size_t) return C.int;
   pragma Import
     (C, C_Ed25519_Verify_Certificate,
      "flyology_quic_openssl_ed25519_verify_certificate");

   function Image (Buffer : Error_Buffer) return String is
     (C.To_Ada (Buffer, Trim_Nul => True));

   function Contains_Nul (Value : String) return Boolean is
   begin
      for Element of Value loop
         if Element = Character'Val (0) then
            return True;
         end if;
      end loop;
      return False;
   end Contains_Nul;

   procedure Initialize_Provider
     (Item              : in out Provider;
      Library_Directory : String := "")
   is
      Directory : CS.chars_ptr := CS.Null_Ptr;
      Error     : aliased Error_Buffer := (others => C.nul);
   begin
      if Item.Handle /= System.Null_Address then
         raise Program_Error with
           "QUIC crypto provider is already initialized";
      elsif Contains_Nul (Library_Directory) then
         raise Program_Error with
           "OpenSSL library path contains an embedded NUL";
      end if;

      Directory := CS.New_String (Library_Directory);
      Item.Handle :=
        C_Create
          (Directory, Error (Error'First)'Address, C.size_t (Error'Length));
      CS.Free (Directory);
      if Item.Handle = System.Null_Address then
         raise Crypto_Error with "OpenSSL: " & Image (Error);
      end if;
   exception
      when others =>
         CS.Free (Directory);
         raise;
   end Initialize_Provider;

   function Is_Available (Item : Provider) return Boolean is
     (Item.Handle /= System.Null_Address);

   procedure Derive_V1_Initial
     (Item                       : Provider;
      Destination_Connection_ID : Ada.Streams.Stream_Element_Array;
      Keys                       : out Initial_Keys)
   is
      Result : aliased Initial_Keys :=
        (Client_Secret | Client_Key | Client_IV | Client_HP |
         Server_Secret | Server_Key | Server_IV | Server_HP => (others => 0));
      Error  : aliased Error_Buffer := (others => C.nul);
      Status : C.int;
   begin
      if Item.Handle = System.Null_Address then
         raise Crypto_Error with "OpenSSL QUIC crypto provider is unavailable";
      end if;
      Status :=
        C_Initial_Keys
          (Item.Handle,
           (if Destination_Connection_ID'Length = 0
            then System.Null_Address
            else Destination_Connection_ID
              (Destination_Connection_ID'First)'Address),
           C.size_t (Destination_Connection_ID'Length),
           Result.Client_Secret (Result.Client_Secret'First)'Address,
           Result.Client_Key (Result.Client_Key'First)'Address,
           Result.Client_IV (Result.Client_IV'First)'Address,
           Result.Client_HP (Result.Client_HP'First)'Address,
           Result.Server_Secret (Result.Server_Secret'First)'Address,
           Result.Server_Key (Result.Server_Key'First)'Address,
           Result.Server_IV (Result.Server_IV'First)'Address,
           Result.Server_HP (Result.Server_HP'First)'Address,
           Error (Error'First)'Address, C.size_t (Error'Length));
      if Status /= 0 then
         raise Crypto_Error with "OpenSSL: " & Image (Error);
      end if;
      Keys := Result;
   end Derive_V1_Initial;

   procedure Protect
     (Item       : Provider;
      Key        : AES_128_Key;
      Nonce      : AES_GCM_IV;
      Header     : Ada.Streams.Stream_Element_Array;
      Plaintext  : Ada.Streams.Stream_Element_Array;
      Ciphertext : out Ada.Streams.Stream_Element_Array)
   is
      Error  : aliased Error_Buffer := (others => C.nul);
      Status : C.int;
   begin
      if Item.Handle = System.Null_Address then
         raise Crypto_Error with "OpenSSL QUIC crypto provider is unavailable";
      end if;
      Status :=
        C_Protect
          (Item.Handle, Key (Key'First)'Address, Nonce (Nonce'First)'Address,
           (if Header'Length = 0 then System.Null_Address
            else Header (Header'First)'Address),
           C.size_t (Header'Length),
           (if Plaintext'Length = 0 then System.Null_Address
            else Plaintext (Plaintext'First)'Address),
           C.size_t (Plaintext'Length), Ciphertext (Ciphertext'First)'Address,
           C.size_t (Ciphertext'Length), Error (Error'First)'Address,
           C.size_t (Error'Length));
      if Status /= 0 then
         Ciphertext := (others => 0);
         raise Crypto_Error with "OpenSSL: " & Image (Error);
      end if;
   end Protect;

   procedure Unprotect
     (Item          : Provider;
      Key           : AES_128_Key;
      Nonce         : AES_GCM_IV;
      Header        : Ada.Streams.Stream_Element_Array;
      Ciphertext    : Ada.Streams.Stream_Element_Array;
      Plaintext     : out Ada.Streams.Stream_Element_Array;
      Authenticated : out Boolean)
   is
      Error  : aliased Error_Buffer := (others => C.nul);
      Status : C.int;
   begin
      Plaintext := (others => 0);
      if Item.Handle = System.Null_Address then
         raise Crypto_Error with "OpenSSL QUIC crypto provider is unavailable";
      end if;
      Status :=
        C_Unprotect
          (Item.Handle, Key (Key'First)'Address, Nonce (Nonce'First)'Address,
           (if Header'Length = 0 then System.Null_Address
            else Header (Header'First)'Address),
           C.size_t (Header'Length), Ciphertext (Ciphertext'First)'Address,
           C.size_t (Ciphertext'Length),
           (if Plaintext'Length = 0 then System.Null_Address
            else Plaintext (Plaintext'First)'Address),
           C.size_t (Plaintext'Length), Error (Error'First)'Address,
           C.size_t (Error'Length));
      if Status = 0 then
         Authenticated := True;
      elsif Status = 1 then
         Authenticated := False;
      else
         raise Crypto_Error with "OpenSSL: " & Image (Error);
      end if;
   end Unprotect;

   procedure Make_Header_Mask
     (Item   : Provider;
      Key    : AES_128_Key;
      Sample : Header_Sample;
      Mask   : out Header_Mask)
   is
      Error  : aliased Error_Buffer := (others => C.nul);
      Status : C.int;
   begin
      if Item.Handle = System.Null_Address then
         raise Crypto_Error with "OpenSSL QUIC crypto provider is unavailable";
      end if;
      Status :=
        C_Header_Mask
          (Item.Handle, Key (Key'First)'Address, Sample (Sample'First)'Address,
           Mask (Mask'First)'Address, Error (Error'First)'Address,
           C.size_t (Error'Length));
      if Status /= 0 then
         Mask := (others => 0);
         raise Crypto_Error with "OpenSSL: " & Image (Error);
      end if;
   end Make_Header_Mask;

   procedure Random_Bytes
     (Item   : Provider;
      Output : out Ada.Streams.Stream_Element_Array)
   is
      Error  : aliased Error_Buffer := (others => C.nul);
      Status : C.int;
   begin
      Output := (others => 0);
      if Item.Handle = System.Null_Address then
         raise Crypto_Error with "OpenSSL QUIC crypto provider is unavailable";
      end if;
      Status :=
        C_Random
          (Item.Handle,
           (if Output'Length = 0 then System.Null_Address
            else Output (Output'First)'Address),
           C.size_t (Output'Length), Error (Error'First)'Address,
           C.size_t (Error'Length));
      if Status /= 0 then
         Output := (others => 0);
         raise Crypto_Error with "OpenSSL: " & Image (Error);
      end if;
   end Random_Bytes;

   procedure SHA256
     (Item   : Provider;
      Data   : Ada.Streams.Stream_Element_Array;
      Digest : out SHA256_Digest)
   is
      Error  : aliased Error_Buffer := (others => C.nul);
      Status : C.int;
   begin
      Digest := (others => 0);
      if Item.Handle = System.Null_Address then
         raise Crypto_Error with "OpenSSL QUIC crypto provider is unavailable";
      end if;
      Status :=
        C_SHA256
          (Item.Handle,
           (if Data'Length = 0 then System.Null_Address
            else Data (Data'First)'Address),
           C.size_t (Data'Length), Digest (Digest'First)'Address,
           Error (Error'First)'Address, C.size_t (Error'Length));
      if Status /= 0 then
         Digest := (others => 0);
         raise Crypto_Error with "OpenSSL: " & Image (Error);
      end if;
   end SHA256;

   procedure HMAC_SHA256
     (Item   : Provider;
      Key    : Ada.Streams.Stream_Element_Array;
      Data   : Ada.Streams.Stream_Element_Array;
      Digest : out SHA256_Digest)
   is
      Error  : aliased Error_Buffer := (others => C.nul);
      Status : C.int;
   begin
      Digest := (others => 0);
      if Item.Handle = System.Null_Address then
         raise Crypto_Error with "OpenSSL QUIC crypto provider is unavailable";
      end if;
      Status :=
        C_HMAC_SHA256
          (Item.Handle,
           (if Key'Length = 0 then System.Null_Address
            else Key (Key'First)'Address),
           C.size_t (Key'Length),
           (if Data'Length = 0 then System.Null_Address
            else Data (Data'First)'Address),
           C.size_t (Data'Length), Digest (Digest'First)'Address,
           Error (Error'First)'Address, C.size_t (Error'Length));
      if Status /= 0 then
         Digest := (others => 0);
         raise Crypto_Error with "OpenSSL: " & Image (Error);
      end if;
   end HMAC_SHA256;

   procedure X25519_Public
     (Item        : Provider;
      Private_Key : X25519_Private_Key;
      Public_Key  : out X25519_Public_Key)
   is
      Error  : aliased Error_Buffer := (others => C.nul);
      Status : C.int;
   begin
      Public_Key := (others => 0);
      if Item.Handle = System.Null_Address then
         raise Crypto_Error with "OpenSSL QUIC crypto provider is unavailable";
      end if;
      Status :=
        C_X25519_Public
          (Item.Handle, Private_Key (Private_Key'First)'Address,
           Public_Key (Public_Key'First)'Address, Error (Error'First)'Address,
           C.size_t (Error'Length));
      if Status /= 0 then
         Public_Key := (others => 0);
         raise Crypto_Error with "OpenSSL: " & Image (Error);
      end if;
   end X25519_Public;

   procedure X25519_Shared
     (Item            : Provider;
      Private_Key     : X25519_Private_Key;
      Peer_Public_Key : X25519_Public_Key;
      Shared_Secret   : out X25519_Shared_Secret)
   is
      Error  : aliased Error_Buffer := (others => C.nul);
      Status : C.int;
   begin
      Shared_Secret := (others => 0);
      if Item.Handle = System.Null_Address then
         raise Crypto_Error with "OpenSSL QUIC crypto provider is unavailable";
      end if;
      Status :=
        C_X25519_Shared
          (Item.Handle, Private_Key (Private_Key'First)'Address,
           Peer_Public_Key (Peer_Public_Key'First)'Address,
           Shared_Secret (Shared_Secret'First)'Address,
           Error (Error'First)'Address, C.size_t (Error'Length));
      if Status /= 0 then
         Shared_Secret := (others => 0);
         raise Crypto_Error with "OpenSSL: " & Image (Error);
      end if;
   end X25519_Shared;

   procedure Generate_X25519
     (Item        : Provider;
      Private_Key : out X25519_Private_Key;
      Public_Key  : out X25519_Public_Key)
   is
   begin
      Private_Key := (others => 0);
      Public_Key := (others => 0);
      Random_Bytes (Item, Private_Key);
      X25519_Public (Item, Private_Key, Public_Key);
   exception
      when others =>
         Private_Key := (others => 0);
         Public_Key := (others => 0);
         raise;
   end Generate_X25519;

   procedure Ed25519_Public
     (Item        : Provider;
      Private_Key : Ed25519_Private_Key;
      Public_Key  : out Ed25519_Public_Key)
   is
      Error  : aliased Error_Buffer := (others => C.nul);
      Status : C.int;
   begin
      Public_Key := (others => 0);
      if Item.Handle = System.Null_Address then
         raise Crypto_Error with "OpenSSL QUIC crypto provider is unavailable";
      end if;
      Status :=
        C_Ed25519_Public
          (Item.Handle, Private_Key (Private_Key'First)'Address,
           Public_Key (Public_Key'First)'Address, Error (Error'First)'Address,
           C.size_t (Error'Length));
      if Status /= 0 then
         Public_Key := (others => 0);
         raise Crypto_Error with "OpenSSL: " & Image (Error);
      end if;
   end Ed25519_Public;

   procedure Ed25519_Sign
     (Item        : Provider;
      Private_Key : Ed25519_Private_Key;
      Message     : Ada.Streams.Stream_Element_Array;
      Signature   : out Ed25519_Signature)
   is
      Error  : aliased Error_Buffer := (others => C.nul);
      Status : C.int;
   begin
      Signature := (others => 0);
      if Item.Handle = System.Null_Address then
         raise Crypto_Error with "OpenSSL QUIC crypto provider is unavailable";
      end if;
      Status :=
        C_Ed25519_Sign
          (Item.Handle, Private_Key (Private_Key'First)'Address,
           (if Message'Length = 0 then System.Null_Address
            else Message (Message'First)'Address),
           C.size_t (Message'Length), Signature (Signature'First)'Address,
           Error (Error'First)'Address, C.size_t (Error'Length));
      if Status /= 0 then
         Signature := (others => 0);
         raise Crypto_Error with "OpenSSL: " & Image (Error);
      end if;
   end Ed25519_Sign;

   procedure Ed25519_Verify
     (Item       : Provider;
      Public_Key : Ed25519_Public_Key;
      Message    : Ada.Streams.Stream_Element_Array;
      Signature  : Ed25519_Signature;
      Verified   : out Boolean)
   is
      Error  : aliased Error_Buffer := (others => C.nul);
      Status : C.int;
   begin
      Verified := False;
      if Item.Handle = System.Null_Address then
         raise Crypto_Error with "OpenSSL QUIC crypto provider is unavailable";
      end if;
      Status :=
        C_Ed25519_Verify
          (Item.Handle, Public_Key (Public_Key'First)'Address,
           (if Message'Length = 0 then System.Null_Address
            else Message (Message'First)'Address),
           C.size_t (Message'Length), Signature (Signature'First)'Address,
           Error (Error'First)'Address, C.size_t (Error'Length));
      if Status = 0 then
         Verified := True;
      elsif Status /= 1 then
         raise Crypto_Error with "OpenSSL: " & Image (Error);
      end if;
   end Ed25519_Verify;

   procedure Ed25519_Verify_Certificate
     (Item            : Provider;
      Certificate_DER : Ada.Streams.Stream_Element_Array;
      Message         : Ada.Streams.Stream_Element_Array;
      Signature       : Ed25519_Signature;
      Verified        : out Boolean)
   is
      Error  : aliased Error_Buffer := (others => C.nul);
      Status : C.int;
   begin
      Verified := False;
      if Item.Handle = System.Null_Address then
         raise Crypto_Error with "OpenSSL QUIC crypto provider is unavailable";
      end if;
      Status :=
        C_Ed25519_Verify_Certificate
          (Item.Handle, Certificate_DER (Certificate_DER'First)'Address,
           C.size_t (Certificate_DER'Length),
           (if Message'Length = 0 then System.Null_Address
            else Message (Message'First)'Address),
           C.size_t (Message'Length), Signature (Signature'First)'Address,
           Error (Error'First)'Address, C.size_t (Error'Length));
      if Status = 0 then
         Verified := True;
      elsif Status /= 1 then
         raise Crypto_Error with "OpenSSL: " & Image (Error);
      end if;
   end Ed25519_Verify_Certificate;

   overriding procedure Finalize (Item : in out Provider) is
   begin
      if Item.Handle /= System.Null_Address then
         C_Release (Item.Handle);
         Item.Handle := System.Null_Address;
      end if;
   end Finalize;
end Flyology.QUIC.Crypto_OpenSSL;
