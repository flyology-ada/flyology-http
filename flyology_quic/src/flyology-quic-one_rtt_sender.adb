with Flyology.QUIC.Protection_Policy;
with Interfaces;

package body Flyology.QUIC.One_RTT_Sender is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.Unsigned_64;

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
   is
      Number_Offset : constant Natural := 1 + Destination.Length;
      Header_Length : constant Natural :=
        Number_Offset + Natural (Number_Length);
      Packet_Length : constant Natural :=
        Header_Length + Natural (Plaintext'Length) + 16;
      Protected_Length : constant Natural :=
        Natural (Number_Length) + Natural (Plaintext'Length) + 16;
   begin
      Packet := (others => 0);
      Result := (Number_Length => Number_Length, others => <>);
      if Protected_Length < 20 then
         Result.Status := Insufficient_Protected_Payload;
         return;
      elsif Packet_Length > Max_Packet_Length then
         Result.Status := Packet_Too_Large;
         return;
      elsif Packet'Length < Ada.Streams.Stream_Element_Offset (Packet_Length)
      then
         Result.Status := Output_Too_Small;
         return;
      end if;

      declare
         Header : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (Header_Length));
         Ciphertext : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (Plaintext'Length + 16));
         Encoded_Number : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (Number_Length));
         Truncated : Interfaces.Unsigned_64 :=
           Interfaces.Unsigned_64 (Number)
           mod Packet_Number_Policy.Window
             (Packet_Number_Policy.Encoded_Length (Number_Length));
         Sample : Crypto_OpenSSL.Header_Sample;
         Mask   : Crypto_OpenSSL.Header_Mask;
         First  : Ada.Streams.Stream_Element :=
           16#40#
           + (if Spin then 16#20# else 0)
           + (if Key_Phase then 16#04# else 0)
           + Ada.Streams.Stream_Element (Number_Length - 1);
      begin
         Header (1) := First;
         for Index in 1 .. Destination.Length loop
            Header (Ada.Streams.Stream_Element_Offset (Index + 1)) :=
              Destination.Data (Ada.Streams.Stream_Element_Offset (Index));
         end loop;
         for Index in reverse Encoded_Number'Range loop
            Encoded_Number (Index) :=
              Ada.Streams.Stream_Element (Truncated mod 256);
            Truncated := Truncated / 256;
         end loop;
         Header
           (Ada.Streams.Stream_Element_Offset (Number_Offset + 1)
              .. Ada.Streams.Stream_Element_Offset (Header_Length)) :=
           Encoded_Number;

         Crypto_OpenSSL.Protect
           (Backend, Key, Protection_Policy.Make_Nonce (IV, Number), Header,
            Plaintext, Ciphertext);
         Sample :=
           Ciphertext
             (Ciphertext'First
                + Ada.Streams.Stream_Element_Offset (4 - Number_Length)
              .. Ciphertext'First
                + Ada.Streams.Stream_Element_Offset (19 - Number_Length));
         Crypto_OpenSSL.Make_Header_Mask
           (Backend, Header_Key, Sample, Mask);
         Protection_Policy.Apply_Header_Protection
           (First, Encoded_Number, Long_Header => False, Mask => Mask);
         Header (1) := First;
         Header
           (Ada.Streams.Stream_Element_Offset (Number_Offset + 1)
              .. Ada.Streams.Stream_Element_Offset (Header_Length)) :=
           Encoded_Number;
         Packet
           (Packet'First
              .. Packet'First
                   + Ada.Streams.Stream_Element_Offset (Header_Length - 1)) :=
           Header;
         Packet
           (Packet'First + Ada.Streams.Stream_Element_Offset (Header_Length)
              .. Packet'First
                   + Ada.Streams.Stream_Element_Offset (Packet_Length - 1)) :=
           Ciphertext;
         Result :=
           (Status               => Sent,
            Packet_Length        => Packet_Length,
            Header_Length        => Header_Length,
            Packet_Number_Offset => Number_Offset,
            Number_Length        => Number_Length);
      end;
   end Send;
end Flyology.QUIC.One_RTT_Sender;
