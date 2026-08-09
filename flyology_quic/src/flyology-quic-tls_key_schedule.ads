with Ada.Streams;
with Flyology.QUIC.Crypto_OpenSSL;

--  Ada-owned TLS 1.3 key schedule for QUIC's mandatory SHA-256 suite.
--  Cryptographic operations are delegated to the private primitive provider;
--  labels, transcript contexts, secret transitions, and QUIC key derivation
--  remain here.
private package Flyology.QUIC.TLS_Key_Schedule is
   subtype Secret is Crypto_OpenSSL.SHA256_Digest;
   subtype Transcript_Hash is Crypto_OpenSSL.SHA256_Digest;
   subtype Shared_Secret is Crypto_OpenSSL.X25519_Shared_Secret;

   type Handshake_Secrets is record
      Handshake       : Secret := (others => 0);
      Master          : Secret := (others => 0);
      Client_Traffic  : Secret := (others => 0);
      Server_Traffic  : Secret := (others => 0);
      Client_Finished : Secret := (others => 0);
      Server_Finished : Secret := (others => 0);
   end record;

   type Application_Secrets is record
      Client_Traffic : Secret := (others => 0);
      Server_Traffic : Secret := (others => 0);
      Exporter       : Secret := (others => 0);
   end record;

   type QUIC_Traffic_Keys is record
      Traffic : Secret := (others => 0);
      Key : Crypto_OpenSSL.AES_128_Key := (others => 0);
      IV  : Crypto_OpenSSL.AES_GCM_IV := (others => 0);
      HP  : Crypto_OpenSSL.AES_128_Key := (others => 0);
   end record;

   procedure HKDF_Extract
     (Provider : Crypto_OpenSSL.Provider;
      Salt     : Ada.Streams.Stream_Element_Array;
      IKM      : Ada.Streams.Stream_Element_Array;
      Result   : out Secret);

   procedure HKDF_Expand_Label
     (Provider : Crypto_OpenSSL.Provider;
      PRK      : Secret;
      Label    : String;
      Context  : Ada.Streams.Stream_Element_Array;
      Output   : out Ada.Streams.Stream_Element_Array)
   with
     Pre => Label'Length <= 249
       and then Context'Length <= 255
       and then Output'Length in 1 .. 32;

   procedure Derive_Secret
     (Provider : Crypto_OpenSSL.Provider;
      PRK      : Secret;
      Label    : String;
      Context  : Transcript_Hash;
      Result   : out Secret)
   with Pre => Label'Length <= 249;

   procedure Derive_Handshake
     (Provider        : Crypto_OpenSSL.Provider;
      Shared          : Shared_Secret;
      Hello_Transcript : Transcript_Hash;
      Result          : out Handshake_Secrets);

   procedure Derive_Application
     (Provider          : Crypto_OpenSSL.Provider;
      Handshake         : Handshake_Secrets;
      Server_Transcript : Transcript_Hash;
      Result            : out Application_Secrets);

   procedure Derive_Resumption
     (Provider          : Crypto_OpenSSL.Provider;
      Handshake         : Handshake_Secrets;
      Client_Transcript : Transcript_Hash;
      Result            : out Secret);

   procedure Derive_QUIC_Keys
     (Provider : Crypto_OpenSSL.Provider;
      Traffic  : Secret;
      Result   : out QUIC_Traffic_Keys);

   procedure Finished_Verify_Data
     (Provider   : Crypto_OpenSSL.Provider;
      Finished   : Secret;
      Transcript : Transcript_Hash;
      Result     : out Secret);

   procedure Update_QUIC_Traffic
     (Provider : Crypto_OpenSSL.Provider;
      Current  : Secret;
      Next     : out Secret);

   procedure Update_QUIC_Keys
     (Provider : Crypto_OpenSSL.Provider;
      Current  : QUIC_Traffic_Keys;
      Next     : out QUIC_Traffic_Keys);

   procedure Clear (Item : out Handshake_Secrets);
   procedure Clear (Item : out Application_Secrets);
   procedure Clear (Item : out QUIC_Traffic_Keys);
   procedure Clear (Item : out Secret);
end Flyology.QUIC.TLS_Key_Schedule;
