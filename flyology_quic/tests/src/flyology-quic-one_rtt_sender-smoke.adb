with Flyology.QUIC.One_RTT_Receiver;
with Flyology.QUIC.Protection_Policy;

procedure Flyology.QUIC.One_RTT_Sender.Smoke is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type One_RTT_Receiver.Receive_Status;
   use type Packet_Number_Policy.Packet_Number;

   function ID
     (Data : Ada.Streams.Stream_Element_Array)
      return Long_Header_Policy.Connection_ID
   is
      Result : Long_Header_Policy.Connection_ID;
   begin
      Result.Length := Natural (Data'Length);
      Result.Data (1 .. Data'Length) := Data;
      return Result;
   end ID;

   Backend : Crypto_OpenSSL.Provider;
   Key : constant Crypto_OpenSSL.AES_128_Key := (others => 16#11#);
   IV  : constant Crypto_OpenSSL.AES_GCM_IV := (others => 16#22#);
   HP  : constant Crypto_OpenSSL.AES_128_Key := (others => 16#33#);
   Destination : constant Long_Header_Policy.Connection_ID :=
     ID ((16#83#, 16#94#, 16#C8#, 16#F0#,
          16#3E#, 16#51#, 16#57#, 16#08#));
begin
   Crypto_OpenSSL.Initialize_Provider (Backend);
   declare
      Plaintext : constant Ada.Streams.Stream_Element_Array :=
        (16#01#, 0, 0, 0, 0, 0, 0, 0);
      Packet : Ada.Streams.Stream_Element_Array (0 .. 63);
      Decoded : Ada.Streams.Stream_Element_Array (Packet'Range);
      Sent_Packet : Send_Result;
      Received_Packet : One_RTT_Receiver.Receive_Result;
      Tampered : Ada.Streams.Stream_Element_Array (Packet'Range);
   begin
      Send
        (Backend, Key, IV, HP, Destination, 16#1234#, 2, True, True,
         Plaintext, Packet, Sent_Packet);
      pragma Assert
        (Sent_Packet.Status = Sent
         and then Sent_Packet.Packet_Length = 35
         and then Sent_Packet.Packet_Number_Offset = 9
         and then Sent_Packet.Header_Length = 11);
      One_RTT_Receiver.Receive
        (Backend, Key, IV, HP, 8, 16#1234#,
         Packet
           (Packet'First
              .. Packet'First + Ada.Streams.Stream_Element_Offset
                   (Sent_Packet.Packet_Length - 1)),
         Decoded, Received_Packet);
      pragma Assert
        (Received_Packet.Status = One_RTT_Receiver.Received
         and then Received_Packet.Number = 16#1234#
         and then Received_Packet.Key_Phase
         and then Received_Packet.Spin
         and then Received_Packet.Plaintext_Length = Plaintext'Length
         and then Decoded
           (Decoded'First .. Decoded'First + Plaintext'Length - 1) =
           Plaintext);

      Tampered := Packet;
      Tampered
        (Tampered'First + Ada.Streams.Stream_Element_Offset
           (Sent_Packet.Packet_Length - 1)) :=
        Tampered
          (Tampered'First + Ada.Streams.Stream_Element_Offset
             (Sent_Packet.Packet_Length - 1)) xor 1;
      One_RTT_Receiver.Receive
        (Backend, Key, IV, HP, 8, 16#1234#,
         Tampered
           (Tampered'First
              .. Tampered'First + Ada.Streams.Stream_Element_Offset
                   (Sent_Packet.Packet_Length - 1)),
         Decoded, Received_Packet);
      pragma Assert
        (Received_Packet.Status = One_RTT_Receiver.Authentication_Failed
         and then Decoded = (Decoded'Range => 0));

      declare
         Header : Ada.Streams.Stream_Element_Array (1 .. 11);
         Encoded_Number : Ada.Streams.Stream_Element_Array (1 .. 2) :=
           (16#12#, 16#34#);
         Ciphertext : Ada.Streams.Stream_Element_Array (1 .. 24);
         Invalid_Packet : Ada.Streams.Stream_Element_Array (1 .. 35);
         Sample : Crypto_OpenSSL.Header_Sample;
         Mask : Crypto_OpenSSL.Header_Mask;
         First : Ada.Streams.Stream_Element := 16#49#;
      begin
         Header (1) := First;
         Header (2 .. 9) := Destination.Data (1 .. 8);
         Header (10 .. 11) := Encoded_Number;
         Crypto_OpenSSL.Protect
           (Backend, Key, Protection_Policy.Make_Nonce (IV, 16#1234#),
            Header, Plaintext, Ciphertext);
         Sample := Ciphertext (3 .. 18);
         Crypto_OpenSSL.Make_Header_Mask (Backend, HP, Sample, Mask);
         Protection_Policy.Apply_Header_Protection
           (First, Encoded_Number, Long_Header => False, Mask => Mask);
         Header (1) := First;
         Header (10 .. 11) := Encoded_Number;
         Invalid_Packet (1 .. 11) := Header;
         Invalid_Packet (12 .. 35) := Ciphertext;
         One_RTT_Receiver.Receive
           (Backend, Key, IV, HP, 8, 16#1234#, Invalid_Packet, Decoded,
            Received_Packet);
         pragma Assert
           (Received_Packet.Status = One_RTT_Receiver.Invalid_Reserved_Bits
            and then Decoded = (Decoded'Range => 0));
      end;
   end;

   declare
      Empty : constant Ada.Streams.Stream_Element_Array (1 .. 0) :=
        (others => 0);
      Packet : Ada.Streams.Stream_Element_Array (1 .. 64);
      Decoded : Ada.Streams.Stream_Element_Array (Packet'Range);
      Sent_Packet : Send_Result;
      Received_Packet : One_RTT_Receiver.Receive_Result;
   begin
      Send
        (Backend, Key, IV, HP, Destination, 4, 4, False, False, Empty,
         Packet, Sent_Packet);
      pragma Assert
        (Sent_Packet.Status = Sent and then Sent_Packet.Packet_Length = 29);
      One_RTT_Receiver.Receive
        (Backend, Key, IV, HP, 8, 0,
         Packet
           (1 .. Ada.Streams.Stream_Element_Offset
                   (Sent_Packet.Packet_Length)),
         Decoded, Received_Packet);
      pragma Assert
        (Received_Packet.Status = One_RTT_Receiver.Received
         and then Received_Packet.Number = 4
         and then Received_Packet.Plaintext_Length = 0);
   end;

   declare
      Tiny : constant Ada.Streams.Stream_Element_Array := (0, 0);
      Packet : Ada.Streams.Stream_Element_Array (1 .. 64);
      Result : Send_Result;
   begin
      Send
        (Backend, Key, IV, HP, Destination, 0, 1, False, False, Tiny,
         Packet, Result);
      pragma Assert (Result.Status = Insufficient_Protected_Payload);
   end;
end Flyology.QUIC.One_RTT_Sender.Smoke;
