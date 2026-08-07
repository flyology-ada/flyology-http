with Ada.Streams;
with Flyology.QUIC.Crypto_OpenSSL;
with Flyology.QUIC.Long_Header_Policy;
with Flyology.QUIC.Packet_Number_Policy;

--  Internal transmit path for one QUIC v1 1-RTT packet.
private package Flyology.QUIC.One_RTT_Sender is
   use type Ada.Streams.Stream_Element_Array;

   Max_Packet_Length : constant := 65_535;

   type Send_Status is
     (Sent,
      Insufficient_Protected_Payload,
      Packet_Too_Large,
      Output_Too_Small);

   type Send_Result is record
      Status               : Send_Status := Output_Too_Small;
      Packet_Length        : Natural range 0 .. Max_Packet_Length := 0;
      Header_Length        : Natural range 0 .. Max_Packet_Length := 0;
      Packet_Number_Offset : Natural range 0 .. Max_Packet_Length := 0;
      Number_Length        : Long_Header_Policy.Packet_Number_Length := 1;
   end record;

   procedure Send
     (Backend       : Crypto_OpenSSL.Provider;
      Key           : Crypto_OpenSSL.AES_128_Key;
      IV            : Crypto_OpenSSL.AES_GCM_IV;
      Header_Key    : Crypto_OpenSSL.AES_128_Key;
      Destination   : Long_Header_Policy.Connection_ID;
      Number        : Packet_Number_Policy.Packet_Number;
      Number_Length : Long_Header_Policy.Packet_Number_Length;
      Key_Phase     : Boolean;
      Spin          : Boolean;
      Plaintext     : Ada.Streams.Stream_Element_Array;
      Packet        : out Ada.Streams.Stream_Element_Array;
      Result        : out Send_Result)
   with
     Pre =>
       Destination.Length <= Long_Header_Policy.V1_Connection_ID_Length'Last
       and then Plaintext'Length <= Max_Packet_Length,
     Post =>
       (if Result.Status /= Sent then
           Packet = (Packet'Range => 0)
        else
           Result.Packet_Length = Result.Header_Length + Plaintext'Length + 16
           and then Result.Packet_Length <= Packet'Length);
end Flyology.QUIC.One_RTT_Sender;
