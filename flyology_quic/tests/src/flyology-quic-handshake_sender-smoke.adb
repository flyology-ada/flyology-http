with Flyology.QUIC.Handshake_Packet_Policy;
with Flyology.QUIC.Handshake_Receiver;
with Flyology.QUIC.Protection_Policy;

procedure Flyology.QUIC.Handshake_Sender.Smoke is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Handshake_Packet_Policy.Parse_Status;
   use type Handshake_Receiver.Receive_Status;
   use type Long_Header_Policy.Packet_Kind;
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

   function ID
     (Value : Ada.Streams.Stream_Element_Array)
      return Long_Header_Policy.Connection_ID
   is
      Result : Long_Header_Policy.Connection_ID;
   begin
      Result.Length := Natural (Value'Length);
      if Value'Length > 0 then
         Result.Data (1 .. Value'Length) := Value;
      end if;
      return Result;
   end ID;

   Backend : Crypto_OpenSSL.Provider;
   Key : constant Crypto_OpenSSL.AES_128_Key :=
     Crypto_OpenSSL.AES_128_Key'(Hex ("1f369613dd76d5467730efcbe3b1a22d"));
   IV : constant Crypto_OpenSSL.AES_GCM_IV :=
     Crypto_OpenSSL.AES_GCM_IV'(Hex ("fa044b2f42a3fd3b46fb255c"));
   HP : constant Crypto_OpenSSL.AES_128_Key :=
     Crypto_OpenSSL.AES_128_Key'(Hex ("9f50449e04a0e810283a1e9933adedd2"));
   Destination : constant Long_Header_Policy.Connection_ID :=
     ID (Hex ("8394c8f03e515708"));
   Source : constant Long_Header_Policy.Connection_ID :=
     ID (Hex ("01020304"));
begin
   Crypto_OpenSSL.Initialize_Provider (Backend);

   declare
      Plaintext : constant Ada.Streams.Stream_Element_Array :=
        Hex
          ("06001e0100001a000000000000000000" &
           "00000000000000000000000000000000");
      Packet : Ada.Streams.Stream_Element_Array (0 .. 127);
      Decoded : Ada.Streams.Stream_Element_Array (Packet'Range);
      Result : Send_Result;
      Received : Handshake_Receiver.Receive_Result;
      Envelope : Handshake_Packet_Policy.Parse_Result;
      Tampered : Ada.Streams.Stream_Element_Array (Packet'Range);
   begin
      Send
        (Backend, Key, IV, HP, Destination, Source, 16#1234#, 2,
         Plaintext, Packet, Result);
      pragma Assert
        (Result.Status = Sent
         and then Result.Packet_Length = 70
         and then Result.Packet_Number_Offset = 20
         and then Result.Header_Length = 22);
      Envelope :=
        Handshake_Packet_Policy.Parse
          (Packet
             (Packet'First
                .. Packet'First
                     + Ada.Streams.Stream_Element_Offset
                         (Result.Packet_Length - 1)));
      pragma Assert
        (Envelope.Status = Handshake_Packet_Policy.Parsed
         and then Envelope.Header.Kind = Long_Header_Policy.Handshake
         and then Envelope.Consumed = Result.Packet_Length);

      Handshake_Receiver.Receive
        (Backend, Key, IV, HP, 16#1234#,
         Packet
           (Packet'First
              .. Packet'First
                   + Ada.Streams.Stream_Element_Offset
                       (Result.Packet_Length - 1)),
         Decoded, Received);
      pragma Assert
        (Received.Status = Handshake_Receiver.Received
         and then Received.Number = 16#1234#
         and then Received.Plaintext_Length = Plaintext'Length
         and then Decoded
           (Decoded'First
              .. Decoded'First + Plaintext'Length - 1) = Plaintext);

      Tampered := Packet;
      Tampered
        (Packet'First
           + Ada.Streams.Stream_Element_Offset (Result.Packet_Length - 1)) :=
        Tampered
          (Packet'First
             + Ada.Streams.Stream_Element_Offset (Result.Packet_Length - 1))
          xor 1;
      Handshake_Receiver.Receive
        (Backend, Key, IV, HP, 16#1234#,
         Tampered
           (Tampered'First
              .. Tampered'First
                   + Ada.Streams.Stream_Element_Offset
                       (Result.Packet_Length - 1)),
         Decoded, Received);
      pragma Assert
        (Received.Status = Handshake_Receiver.Authentication_Failed
         and then Decoded = (Decoded'Range => 0));

      declare
         Prefix : constant Long_Header_Policy.Encoded_Prefix :=
           Long_Header_Policy.Encode_Protected_V1_Prefix
             (Long_Header_Policy.Handshake, 2, Destination, Source);
         Header : Ada.Streams.Stream_Element_Array (1 .. 22);
         Encoded_Number : Ada.Streams.Stream_Element_Array (1 .. 2) :=
           (16#12#, 16#34#);
         Ciphertext : Ada.Streams.Stream_Element_Array (1 .. 48);
         Invalid_Packet : Ada.Streams.Stream_Element_Array (1 .. 70);
         Sample : Crypto_OpenSSL.Header_Sample;
         Mask : Crypto_OpenSSL.Header_Mask;
         First : Ada.Streams.Stream_Element;
      begin
         Header (1 .. 19) := Prefix.Data (1 .. 19);
         Header (1) := Header (1) or 16#04#;
         Header (20) := 50;
         Header (21 .. 22) := Encoded_Number;
         Crypto_OpenSSL.Protect
           (Backend, Key, Protection_Policy.Make_Nonce (IV, 16#1234#),
            Header, Plaintext, Ciphertext);
         Sample := Ciphertext (3 .. 18);
         Crypto_OpenSSL.Make_Header_Mask (Backend, HP, Sample, Mask);
         First := Header (1);
         Protection_Policy.Apply_Header_Protection
           (First, Encoded_Number, Long_Header => True, Mask => Mask);
         Header (1) := First;
         Header (21 .. 22) := Encoded_Number;
         Invalid_Packet (1 .. 22) := Header;
         Invalid_Packet (23 .. 70) := Ciphertext;

         Handshake_Receiver.Receive
           (Backend, Key, IV, HP, 16#1234#, Invalid_Packet, Decoded,
            Received);
         pragma Assert
           (Received.Status = Handshake_Receiver.Invalid_Reserved_Bits
            and then Decoded = (Decoded'Range => 0));
      end;

      declare
         Too_Small : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (Result.Packet_Length - 1));
      begin
         Send
           (Backend, Key, IV, HP, Destination, Source, 16#1234#, 2,
            Plaintext, Too_Small, Result);
         pragma Assert
           (Result.Status = Output_Too_Small
            and then Too_Small = (Too_Small'Range => 0));
      end;
   end;

   declare
      Tiny : constant Ada.Streams.Stream_Element_Array := (0, 0);
      Packet : Ada.Streams.Stream_Element_Array (1 .. 64);
      Result : Send_Result;
   begin
      Send
        (Backend, Key, IV, HP, Destination, Source, 0, 1, Tiny, Packet,
         Result);
      pragma Assert
        (Result.Status = Insufficient_Protected_Payload
         and then Packet = (Packet'Range => 0));
   end;
end Flyology.QUIC.Handshake_Sender.Smoke;
