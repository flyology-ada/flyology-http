with Ada.Finalization;
with Ada.Streams;
with System;

--  OpenSSL-backed cryptographic primitives used by the Ada QUIC engine.
--  OpenSSL supplies cryptography only; protocol state and wire handling remain
--  in Ada.
private package Flyology.QUIC.Crypto_OpenSSL is
   use type Ada.Streams.Stream_Element_Array;

   subtype SHA256_Secret is Ada.Streams.Stream_Element_Array (1 .. 32);
   subtype AES_128_Key is Ada.Streams.Stream_Element_Array (1 .. 16);
   subtype AES_GCM_IV is Ada.Streams.Stream_Element_Array (1 .. 12);
   subtype Header_Sample is Ada.Streams.Stream_Element_Array (1 .. 16);
   subtype Header_Mask is Ada.Streams.Stream_Element_Array (1 .. 5);
   subtype SHA256_Digest is Ada.Streams.Stream_Element_Array (1 .. 32);
   subtype X25519_Private_Key is Ada.Streams.Stream_Element_Array (1 .. 32);
   subtype X25519_Public_Key is Ada.Streams.Stream_Element_Array (1 .. 32);
   subtype X25519_Shared_Secret is Ada.Streams.Stream_Element_Array (1 .. 32);

   --  QUIC v1 Initial secrets and traffic keys. Initial secrets are derived
   --  from the public Destination Connection ID; later encryption levels use
   --  separate owning, zeroizing key containers.
   type Initial_Keys is record
      Client_Secret : SHA256_Secret;
      Client_Key    : AES_128_Key;
      Client_IV     : AES_GCM_IV;
      Client_HP     : AES_128_Key;
      Server_Secret : SHA256_Secret;
      Server_Key    : AES_128_Key;
      Server_IV     : AES_GCM_IV;
      Server_HP     : AES_128_Key;
   end record;

   Crypto_Error : exception;
   type Provider is limited private;

   procedure Initialize_Provider
     (Item              : in out Provider;
      Library_Directory : String := "");

   function Is_Available (Item : Provider) return Boolean;

   procedure Derive_V1_Initial
     (Item                       : Provider;
      Destination_Connection_ID : Ada.Streams.Stream_Element_Array;
      Keys                       : out Initial_Keys)
   with Pre => Destination_Connection_ID'Length <= 20;

   procedure Protect
     (Item       : Provider;
      Key        : AES_128_Key;
      Nonce      : AES_GCM_IV;
      Header     : Ada.Streams.Stream_Element_Array;
      Plaintext  : Ada.Streams.Stream_Element_Array;
      Ciphertext : out Ada.Streams.Stream_Element_Array)
   with Pre => Ciphertext'Length = Plaintext'Length + 16;

   procedure Unprotect
     (Item          : Provider;
      Key           : AES_128_Key;
      Nonce         : AES_GCM_IV;
      Header        : Ada.Streams.Stream_Element_Array;
      Ciphertext    : Ada.Streams.Stream_Element_Array;
      Plaintext     : out Ada.Streams.Stream_Element_Array;
      Authenticated : out Boolean)
   with
     Pre =>
       Ciphertext'Length >= 16
       and then Plaintext'Length = Ciphertext'Length - 16,
     Post =>
       Authenticated
       or else Plaintext = (Plaintext'Range => 0);

   procedure Make_Header_Mask
     (Item   : Provider;
      Key    : AES_128_Key;
      Sample : Header_Sample;
      Mask   : out Header_Mask);

   procedure Random_Bytes
     (Item   : Provider;
      Output : out Ada.Streams.Stream_Element_Array);

   procedure SHA256
     (Item   : Provider;
      Data   : Ada.Streams.Stream_Element_Array;
      Digest : out SHA256_Digest);

   procedure HMAC_SHA256
     (Item   : Provider;
      Key    : Ada.Streams.Stream_Element_Array;
      Data   : Ada.Streams.Stream_Element_Array;
      Digest : out SHA256_Digest);

   procedure X25519_Public
     (Item        : Provider;
      Private_Key : X25519_Private_Key;
      Public_Key  : out X25519_Public_Key);

   procedure X25519_Shared
     (Item            : Provider;
      Private_Key     : X25519_Private_Key;
      Peer_Public_Key : X25519_Public_Key;
      Shared_Secret   : out X25519_Shared_Secret);

   procedure Generate_X25519
     (Item        : Provider;
      Private_Key : out X25519_Private_Key;
      Public_Key  : out X25519_Public_Key);
private
   type Provider is new Ada.Finalization.Limited_Controlled with record
      Handle : System.Address := System.Null_Address;
   end record;

   overriding procedure Finalize (Item : in out Provider);
end Flyology.QUIC.Crypto_OpenSSL;
