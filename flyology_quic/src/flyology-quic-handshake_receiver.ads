with Ada.Streams;
with Flyology.QUIC.Crypto_OpenSSL;
with Flyology.QUIC.Handshake_Packet_Policy;
with Flyology.QUIC.Packet_Number_Policy;

--  Internal receive path for one QUIC v1 Handshake packet.
--
--  The caller supplies keys and the next expected packet number for the
--  independent Handshake packet-number space. Duplicate detection and frame
--  processing remain outside this bounded packet operation.
private package Flyology.QUIC.Handshake_Receiver is
   use type Ada.Streams.Stream_Element_Array;

   type Receive_Status is
     (Received,
      Envelope_Rejected,
      Authentication_Failed,
      Invalid_Reserved_Bits);

   type Receive_Result is record
      Status           : Receive_Status := Envelope_Rejected;
      Envelope         : Handshake_Packet_Policy.Parse_Result;
      First_Byte       : Ada.Streams.Stream_Element := 0;
      Number_Length    : Positive range 1 .. 4 := 1;
      Number           : Packet_Number_Policy.Packet_Number := 0;
      Header_Length    : Handshake_Packet_Policy.Datagram_Offset := 0;
      Plaintext_Length : Handshake_Packet_Policy.Datagram_Offset := 0;
   end record;

   procedure Receive
     (Backend         : Crypto_OpenSSL.Provider;
      Key             : Crypto_OpenSSL.AES_128_Key;
      IV              : Crypto_OpenSSL.AES_GCM_IV;
      Header_Key      : Crypto_OpenSSL.AES_128_Key;
      Expected_Number : Packet_Number_Policy.Packet_Number;
      Packet          : Ada.Streams.Stream_Element_Array;
      Plaintext       : out Ada.Streams.Stream_Element_Array;
      Result          : out Receive_Result)
   with
     Pre => Packet'Length <= 65_535 and then Plaintext'Length >= Packet'Length,
     Post =>
       (if Result.Status /= Received then
           Plaintext = (Plaintext'Range => 0));
end Flyology.QUIC.Handshake_Receiver;
