with Ada.Streams;
with Flyology.QUIC.Crypto_OpenSSL;
with Flyology.QUIC.Long_Header_Policy;
with Flyology.QUIC.One_RTT_Packet_Policy;
with Flyology.QUIC.Packet_Number_Policy;

--  Internal receive path for one QUIC v1 1-RTT packet.
private package Flyology.QUIC.One_RTT_Receiver is
   use type Ada.Streams.Stream_Element_Array;

   type Receive_Status is
     (Received,
      Envelope_Rejected,
      Authentication_Failed,
      Invalid_Reserved_Bits);

   type Receive_Result is record
      Status           : Receive_Status := Envelope_Rejected;
      Envelope         : One_RTT_Packet_Policy.Parse_Result;
      First_Byte       : Ada.Streams.Stream_Element := 0;
      Number_Length    : Positive range 1 .. 4 := 1;
      Number           : Packet_Number_Policy.Packet_Number := 0;
      Key_Phase        : Boolean := False;
      Spin             : Boolean := False;
      Header_Length    : One_RTT_Packet_Policy.Datagram_Offset := 0;
      Plaintext_Length : One_RTT_Packet_Policy.Datagram_Offset := 0;
   end record;

   procedure Receive
     (Backend            : Crypto_OpenSSL.Provider;
      Key                : Crypto_OpenSSL.AES_128_Key;
      IV                 : Crypto_OpenSSL.AES_GCM_IV;
      Header_Key         : Crypto_OpenSSL.AES_128_Key;
      Destination_Length : Long_Header_Policy.V1_Connection_ID_Length;
      Expected_Number    : Packet_Number_Policy.Packet_Number;
      Packet             : Ada.Streams.Stream_Element_Array;
      Plaintext          : out Ada.Streams.Stream_Element_Array;
      Result             : out Receive_Result)
   with
     Pre => Packet'Length <= 65_535 and then Plaintext'Length >= Packet'Length,
     Post =>
       (if Result.Status /= Received then
           Plaintext = (Plaintext'Range => 0));
end Flyology.QUIC.One_RTT_Receiver;
