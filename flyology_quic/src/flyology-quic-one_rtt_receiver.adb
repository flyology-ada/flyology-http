with Flyology.QUIC.Protection_Policy;

package body Flyology.QUIC.One_RTT_Receiver is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type One_RTT_Packet_Policy.Parse_Status;

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
   is
      Envelope         : One_RTT_Packet_Policy.Parse_Result;
      Sample           : Crypto_OpenSSL.Header_Sample;
      Mask             : Crypto_OpenSSL.Header_Mask;
      Protected_Number : Protection_Policy.Packet_Number_Prefix;
      Unprotected      : Protection_Policy.Unprotected_Long_Header;
      Number           : Packet_Number_Policy.Packet_Number;
   begin
      Plaintext := (others => 0);
      Result := (others => <>);
      Envelope := One_RTT_Packet_Policy.Parse (Packet, Destination_Length);
      Result.Envelope := Envelope;
      if Envelope.Status /= One_RTT_Packet_Policy.Parsed then
         return;
      end if;
      Sample :=
        Packet
          (Packet'First + Ada.Streams.Stream_Element_Offset
             (Envelope.Packet_Number_Offset + 4)
           .. Packet'First + Ada.Streams.Stream_Element_Offset
             (Envelope.Packet_Number_Offset + 19));
      Protected_Number :=
        Packet
          (Packet'First + Ada.Streams.Stream_Element_Offset
             (Envelope.Packet_Number_Offset)
           .. Packet'First + Ada.Streams.Stream_Element_Offset
             (Envelope.Packet_Number_Offset + 3));
      Crypto_OpenSSL.Make_Header_Mask (Backend, Header_Key, Sample, Mask);
      Unprotected :=
        Protection_Policy.Remove_Short_Header_Protection
          (Envelope.First_Byte, Protected_Number, Mask);
      Number :=
        Packet_Number_Policy.Reconstruct_From_Expected
          (Expected_Number, Unprotected.Truncated_Number,
           Packet_Number_Policy.Encoded_Length (Unprotected.Number_Length));
      Result.First_Byte := Unprotected.First_Byte;
      Result.Number_Length := Unprotected.Number_Length;
      Result.Number := Number;
      Result.Key_Phase := (Unprotected.First_Byte and 16#04#) /= 0;
      Result.Spin := (Unprotected.First_Byte and 16#20#) /= 0;
      Result.Header_Length :=
        Envelope.Packet_Number_Offset + Unprotected.Number_Length;
      Result.Plaintext_Length :=
        Envelope.Protected_Length - Unprotected.Number_Length - 16;

      declare
         Header : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (Result.Header_Length));
         Ciphertext : constant Ada.Streams.Stream_Element_Array :=
           Packet
             (Packet'First
                + Ada.Streams.Stream_Element_Offset (Result.Header_Length)
              .. Packet'First
                + Ada.Streams.Stream_Element_Offset (Envelope.Consumed - 1));
         Decoded : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (Result.Plaintext_Length));
         Authenticated : Boolean;
      begin
         Header :=
           Packet
             (Packet'First
                .. Packet'First + Ada.Streams.Stream_Element_Offset
                     (Result.Header_Length - 1));
         Header (1) := Unprotected.First_Byte;
         for Index in 1 .. Unprotected.Number_Length loop
            Header
              (Ada.Streams.Stream_Element_Offset
                 (Envelope.Packet_Number_Offset + Index)) :=
               Unprotected.Encoded_Number
                 (Ada.Streams.Stream_Element_Offset (Index));
         end loop;
         Crypto_OpenSSL.Unprotect
           (Backend, Key, Protection_Policy.Make_Nonce (IV, Number), Header,
            Ciphertext, Decoded, Authenticated);
         if not Authenticated then
            Result.Status := Authentication_Failed;
            return;
         elsif (Unprotected.First_Byte and 16#18#) /= 0 then
            Result.Status := Invalid_Reserved_Bits;
            return;
         end if;
         if Result.Plaintext_Length > 0 then
            Plaintext
              (Plaintext'First
                 .. Plaintext'First + Ada.Streams.Stream_Element_Offset
                      (Result.Plaintext_Length - 1)) := Decoded;
         end if;
         Result.Status := Received;
      end;
   end Receive;
end Flyology.QUIC.One_RTT_Receiver;
