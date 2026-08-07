with Ada.Streams;

package body Flyology.QUIC.TLS_Key_Schedule is
   use type Ada.Streams.Stream_Element_Offset;

   Prefix : constant String := "tls13 ";
   Empty  : constant Ada.Streams.Stream_Element_Array (1 .. 0) :=
     (others => 0);

   procedure Clear (Item : out Handshake_Secrets) is
   begin
      Item := (others => (others => 0));
   end Clear;

   procedure Clear (Item : out Application_Secrets) is
   begin
      Item := (others => (others => 0));
   end Clear;

   procedure Clear (Item : out QUIC_Traffic_Keys) is
   begin
      Item := (others => (others => 0));
   end Clear;

   procedure Clear (Item : out Secret) is
   begin
      Item := (others => 0);
   end Clear;

   procedure HKDF_Extract
     (Provider : Crypto_OpenSSL.Provider;
      Salt     : Ada.Streams.Stream_Element_Array;
      IKM      : Ada.Streams.Stream_Element_Array;
      Result   : out Secret) is
   begin
      Crypto_OpenSSL.HMAC_SHA256 (Provider, Salt, IKM, Result);
   exception
      when others =>
         Clear (Result);
         raise;
   end HKDF_Extract;

   procedure HKDF_Expand_Label
     (Provider : Crypto_OpenSSL.Provider;
      PRK      : Secret;
      Label    : String;
      Context  : Ada.Streams.Stream_Element_Array;
      Output   : out Ada.Streams.Stream_Element_Array)
   is
      Full_Label_Length : constant Natural := Prefix'Length + Label'Length;
      Info_Length : constant Natural :=
        2 + 1 + Full_Label_Length + 1 + Context'Length + 1;
      Info : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Info_Length));
      Digest : Secret := (others => 0);
      Cursor : Ada.Streams.Stream_Element_Offset := Info'First;

      procedure Put (Value : Ada.Streams.Stream_Element) is
      begin
         Info (Cursor) := Value;
         Cursor := Cursor + 1;
      end Put;
   begin
      Output := (others => 0);
      Put (Ada.Streams.Stream_Element (Output'Length / 256));
      Put (Ada.Streams.Stream_Element (Output'Length mod 256));
      Put (Ada.Streams.Stream_Element (Full_Label_Length));
      for Element_Character of Prefix loop
         Put
           (Ada.Streams.Stream_Element
              (Standard.Character'Pos (Element_Character)));
      end loop;
      for Element_Character of Label loop
         Put
           (Ada.Streams.Stream_Element
              (Standard.Character'Pos (Element_Character)));
      end loop;
      Put (Ada.Streams.Stream_Element (Context'Length));
      for Element of Context loop
         Put (Element);
      end loop;
      Put (1);
      Crypto_OpenSSL.HMAC_SHA256 (Provider, PRK, Info, Digest);
      for Offset in Ada.Streams.Stream_Element_Offset range
        0 .. Ada.Streams.Stream_Element_Offset (Output'Length - 1)
      loop
         Output (Output'First + Offset) := Digest (Digest'First + Offset);
      end loop;
      Clear (Digest);
      Info := (others => 0);
   exception
      when others =>
         Output := (others => 0);
         Clear (Digest);
         Info := (others => 0);
         raise;
   end HKDF_Expand_Label;

   procedure Derive_Secret
     (Provider : Crypto_OpenSSL.Provider;
      PRK      : Secret;
      Label    : String;
      Context  : Transcript_Hash;
      Result   : out Secret) is
   begin
      HKDF_Expand_Label (Provider, PRK, Label, Context, Result);
   end Derive_Secret;

   procedure Derive_Handshake
     (Provider         : Crypto_OpenSSL.Provider;
      Shared           : Shared_Secret;
      Hello_Transcript : Transcript_Hash;
      Result           : out Handshake_Secrets)
   is
      Zero       : Secret := (others => 0);
      Empty_Hash : Secret := (others => 0);
      Early      : Secret := (others => 0);
      Derived    : Secret := (others => 0);
      Next_Derived : Secret := (others => 0);
      Candidate  : Handshake_Secrets;
   begin
      Clear (Result);
      Clear (Candidate);
      Crypto_OpenSSL.SHA256 (Provider, Empty, Empty_Hash);
      HKDF_Extract (Provider, Zero, Zero, Early);
      Derive_Secret (Provider, Early, "derived", Empty_Hash, Derived);
      HKDF_Extract (Provider, Derived, Shared, Candidate.Handshake);
      Derive_Secret
        (Provider, Candidate.Handshake, "c hs traffic", Hello_Transcript,
         Candidate.Client_Traffic);
      Derive_Secret
        (Provider, Candidate.Handshake, "s hs traffic", Hello_Transcript,
         Candidate.Server_Traffic);
      HKDF_Expand_Label
        (Provider, Candidate.Client_Traffic, "finished", Empty,
         Candidate.Client_Finished);
      HKDF_Expand_Label
        (Provider, Candidate.Server_Traffic, "finished", Empty,
         Candidate.Server_Finished);
      Derive_Secret
        (Provider, Candidate.Handshake, "derived", Empty_Hash,
         Next_Derived);
      HKDF_Extract (Provider, Next_Derived, Zero, Candidate.Master);
      Result := Candidate;
      Clear (Candidate);
      Clear (Zero);
      Clear (Empty_Hash);
      Clear (Early);
      Clear (Derived);
      Clear (Next_Derived);
   exception
      when others =>
         Clear (Result);
         Clear (Candidate);
         Clear (Zero);
         Clear (Empty_Hash);
         Clear (Early);
         Clear (Derived);
         Clear (Next_Derived);
         raise;
   end Derive_Handshake;

   procedure Derive_Application
     (Provider          : Crypto_OpenSSL.Provider;
      Handshake         : Handshake_Secrets;
      Server_Transcript : Transcript_Hash;
      Result            : out Application_Secrets)
   is
      Candidate : Application_Secrets;
   begin
      Clear (Result);
      Clear (Candidate);
      Derive_Secret
        (Provider, Handshake.Master, "c ap traffic", Server_Transcript,
         Candidate.Client_Traffic);
      Derive_Secret
        (Provider, Handshake.Master, "s ap traffic", Server_Transcript,
         Candidate.Server_Traffic);
      Derive_Secret
        (Provider, Handshake.Master, "exp master", Server_Transcript,
         Candidate.Exporter);
      Result := Candidate;
      Clear (Candidate);
   exception
      when others =>
         Clear (Result);
         Clear (Candidate);
         raise;
   end Derive_Application;

   procedure Derive_Resumption
     (Provider          : Crypto_OpenSSL.Provider;
      Handshake         : Handshake_Secrets;
      Client_Transcript : Transcript_Hash;
      Result            : out Secret) is
   begin
      Derive_Secret
        (Provider, Handshake.Master, "res master", Client_Transcript, Result);
   exception
      when others =>
         Clear (Result);
         raise;
   end Derive_Resumption;

   procedure Derive_QUIC_Keys
     (Provider : Crypto_OpenSSL.Provider;
      Traffic  : Secret;
      Result   : out QUIC_Traffic_Keys)
   is
      Candidate : QUIC_Traffic_Keys;
   begin
      Clear (Result);
      Clear (Candidate);
      HKDF_Expand_Label
        (Provider, Traffic, "quic key", Empty, Candidate.Key);
      HKDF_Expand_Label
        (Provider, Traffic, "quic iv", Empty, Candidate.IV);
      HKDF_Expand_Label
        (Provider, Traffic, "quic hp", Empty, Candidate.HP);
      Result := Candidate;
      Clear (Candidate);
   exception
      when others =>
         Clear (Result);
         Clear (Candidate);
         raise;
   end Derive_QUIC_Keys;

   procedure Finished_Verify_Data
     (Provider   : Crypto_OpenSSL.Provider;
      Finished   : Secret;
      Transcript : Transcript_Hash;
      Result     : out Secret) is
   begin
      Crypto_OpenSSL.HMAC_SHA256
        (Provider, Finished, Transcript, Result);
   exception
      when others =>
         Clear (Result);
         raise;
   end Finished_Verify_Data;

   procedure Update_QUIC_Traffic
     (Provider : Crypto_OpenSSL.Provider;
      Current  : Secret;
      Next     : out Secret) is
   begin
      HKDF_Expand_Label (Provider, Current, "quic ku", Empty, Next);
   exception
      when others =>
         Clear (Next);
         raise;
   end Update_QUIC_Traffic;
end Flyology.QUIC.TLS_Key_Schedule;
