--  QUIC-TLS-5: a TLS authentication failure closes the connection with
--  CRYPTO_ERROR + internal_error (0x150) instead of the alert RFC 8446
--  requires.
--
--  The client's CONNECTION_CLOSE is delivered back to the server, which
--  decrypts it with its own Handshake keys, so Peer_Close_Error reports the
--  exact error code that went on the wire.
--
--  Expected per RFC 8446: a certificate the client will not accept is
--  bad_certificate (42), QUIC 0x12A; a CertificateVerify that does not
--  verify is decrypt_error (51), QUIC 0x133.

with Ada.Streams;
with Flyology.QUIC.Transport_Parameter_Policy;
with Repro_Support;

procedure Flyology.QUIC.Connection_Driver.Repro_Quic_Tls_5 is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Transport_Parameter_Policy.Encode_Status;

   subtype Bytes is Ada.Streams.Stream_Element_Array;

   function Nibble (Value : Character) return Natural is
     (case Value is
         when '0' .. '9' => Character'Pos (Value) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (Value) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (Value) - Character'Pos ('A') + 10,
         when others => raise Constraint_Error);

   function Hex (Value : String) return Bytes is
      Result : Bytes (1 .. Ada.Streams.Stream_Element_Offset
                             (Value'Length / 2));
      Source : Positive := Value'First;
   begin
      pragma Assert (Value'Length mod 2 = 0);
      for Element of Result loop
         Element := Ada.Streams.Stream_Element
           (16 * Nibble (Value (Source)) + Nibble (Value (Source + 1)));
         Source := Source + 2;
      end loop;
      return Result;
   end Hex;

   function ID (Data : Bytes) return Long_Header_Policy.Connection_ID is
      Result : Long_Header_Policy.Connection_ID;
   begin
      Result.Length := Natural (Data'Length);
      Result.Data (1 .. Data'Length) := Data;
      return Result;
   end ID;

   function Parameter
     (Value : Long_Header_Policy.Connection_ID)
      return Transport_Parameter_Policy.Connection_ID_Parameter
   is
      Result : Transport_Parameter_Policy.Connection_ID_Parameter;
   begin
      Result.Present := True;
      Result.Length := Value.Length;
      if Value.Length > 0 then
         Result.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Value.Length)) :=
           Value.Data (1 .. Ada.Streams.Stream_Element_Offset (Value.Length));
      end if;
      return Result;
   end Parameter;

   Certificate : constant Bytes :=
     Hex
       ("3082013c3081efa0030201020214434e3e3873a520217edf913fba03f4" &
        "ea17411e64300506032b657030143112301006035504030c096c6f6361" &
        "6c686f7374301e170d3236303830373230323830385a170d3336303830" &
        "343230323830385a30143112301006035504030c096c6f63616c686f73" &
        "74302a300506032b65700321006380a1de85cdd187a3134d096ff12e8b" &
        "1e47aa4c94cff3c4144bad3ee5f81eaea3533051301d0603551d0e0416" &
        "0414d3dd952a2ff44a35af38d9249d71a454ced348ce301f0603551d23" &
        "041830168014d3dd952a2ff44a35af38d9249d71a454ced348ce300f060" &
        "3551d130101ff040530030101ff300506032b657003410024075a33b818" &
        "be62a4f328b79bd8f79febe7d3710fb44ba7a7b2d8e12bc3d1e4056d5" &
        "c20fba04e183430175b62ed1a107eb518dfaacf11045fa0e5a6feba2c0f");
   Private_Key : constant Crypto_OpenSSL.Ed25519_Private_Key :=
     Crypto_OpenSSL.Ed25519_Private_Key'
       (Hex ("f491306c81165ffd97822f3ef58de891" &
             "8779314457f5501e42d3f68504cd3aa8"));
   --  A different Ed25519 seed; every 32-byte value is a valid seed.
   Foreign_Key : constant Crypto_OpenSSL.Ed25519_Private_Key :=
     Crypto_OpenSSL.Ed25519_Private_Key'
       (Hex ("0102030405060708090a0b0c0d0e0f10" &
             "1112131415161718191a1b1c1d1e1f20"));

   function Mutated return Bytes is
      Result : Bytes := Certificate;
   begin
      --  One byte of the subjectPublicKey field.
      Result (Result'Last - 40) := Result (Result'Last - 40) xor 1;
      return Result;
   end Mutated;

   Wrong_Pin : constant Bytes := Mutated;

   ALPN : constant Bytes := Hex ("6833");
   Original_ID : constant Bytes := Hex ("8394c8f03e515708");
   Original_Destination : constant Long_Header_Policy.Connection_ID :=
     ID (Original_ID);
   Client_ID : constant Long_Header_Policy.Connection_ID :=
     ID (Hex ("aabbccdd01020304"));
   Server_ID : constant Long_Header_Policy.Connection_ID :=
     ID (Hex ("1020304050607080"));

   procedure Deliver
     (From   : Datagram_Batch;
      Target : in out Connection;
      Reply  : out Datagram_Batch;
      Now    : Application_Space.Timestamp)
   is
      Produced : Datagram_Batch;
      Outcome  : Operation_Result;
   begin
      Reply := (others => <>);
      for Index in 1 .. From.Count loop
         Process_Datagram
           (Target,
            From.Items (Index).Data
              (1 .. Ada.Streams.Stream_Element_Offset
                      (From.Items (Index).Length)),
            Produced, Outcome, Now);
         if Produced.Count > 0 then
            Reply := Produced;
         end if;
      end loop;
   end Deliver;

   procedure Run_Case
     (Label      : String;
      Pin        : Bytes;
      Server_Key : Crypto_OpenSSL.Ed25519_Private_Key;
      Expected   : Varint_Policy.Value_Type;
      Expected_Name : String)
   is
      Client_Parameters, Server_Parameters :
        Transport_Parameter_Policy.Transport_Parameters;
      Client_Encoded, Server_Encoded :
        Transport_Parameter_Policy.Encode_Result;
      Client, Server : Connection;
      Flight, Reply  : Datagram_Batch;
      Result         : Operation_Result;
   begin
      Client_Parameters.Initial_Source_Connection_ID := Parameter (Client_ID);
      Client_Parameters.Initial_Max_Data := (Present => True, Value => 65_536);
      Client_Parameters.Initial_Max_Stream_Data_Bidi_Local :=
        (Present => True, Value => 16_384);
      Client_Parameters.Initial_Max_Stream_Data_Bidi_Remote :=
        (Present => True, Value => 16_384);
      Client_Parameters.Initial_Max_Stream_Data_Uni :=
        (Present => True, Value => 16_384);
      Client_Parameters.Initial_Max_Streams_Bidi :=
        (Present => True, Value => 8);
      Client_Parameters.Initial_Max_Streams_Uni :=
        (Present => True, Value => 8);

      Server_Parameters.Original_Destination_Connection_ID :=
        Parameter (Original_Destination);
      Server_Parameters.Initial_Source_Connection_ID := Parameter (Server_ID);
      Server_Parameters.Initial_Max_Data := (Present => True, Value => 65_536);
      Server_Parameters.Initial_Max_Stream_Data_Bidi_Local :=
        (Present => True, Value => 16_384);
      Server_Parameters.Initial_Max_Stream_Data_Bidi_Remote :=
        (Present => True, Value => 16_384);
      Server_Parameters.Initial_Max_Stream_Data_Uni :=
        (Present => True, Value => 16_384);
      Server_Parameters.Initial_Max_Streams_Bidi :=
        (Present => True, Value => 8);
      Server_Parameters.Initial_Max_Streams_Uni :=
        (Present => True, Value => 8);

      Client_Encoded := Transport_Parameter_Policy.Encode
        (Client_Parameters, Transport_Parameter_Policy.Client);
      Server_Encoded := Transport_Parameter_Policy.Encode
        (Server_Parameters, Transport_Parameter_Policy.Server);
      pragma Assert
        (Client_Encoded.Status = Transport_Parameter_Policy.Encoded
         and then Server_Encoded.Status = Transport_Parameter_Policy.Encoded);

      Initialize_Client
        (Client, ALPN,
         Client_Encoded.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Client_Encoded.Length)),
         Pin, Original_ID, Original_Destination, Client_ID,
         Client_Parameters);
      Initialize_Server
        (Server, ALPN,
         Server_Encoded.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Server_Encoded.Length)),
         Certificate, Server_Key, Original_ID, Client_ID, Server_ID,
         Server_Parameters);

      Start_Client (Client, Flight, Result, Now => 0);
      pragma Assert (Result.Status = Succeeded and then Flight.Count = 1);
      Deliver (Flight, Server, Reply, Now => 10);
      pragma Assert (State (Server) = Server_Handshake);
      Deliver (Reply, Client, Flight, Now => 20);

      Repro_Support.Note
        (Label & ": client state = " & Connection_State'Image (State (Client))
         & ", datagrams emitted =" & Natural'Image (Flight.Count));
      Repro_Support.Check
        (State (Client) = Failed,
         Label & ": the client rejects the server authentication");
      Repro_Support.Check
        (Flight.Count = 1,
         Label & ": the client sends a CONNECTION_CLOSE");

      if Flight.Count = 1 then
         Deliver (Flight, Server, Reply, Now => 30);
         if State (Server) = Peer_Closed then
            Repro_Support.Note
              (Label & ": error code on the wire ="
               & Varint_Policy.Value_Type'Image (Peer_Close_Error (Server)));
            Repro_Support.Check
              (Peer_Close_Error (Server) = Expected,
               Label & ": closes with " & Expected_Name
               & " (" & Varint_Policy.Value_Type'Image (Expected) & ")");
         else
            Repro_Support.Check
              (False,
               Label & ": the server observes the peer CONNECTION_CLOSE");
         end if;
      end if;
   end Run_Case;

begin
   Repro_Support.Note
     ("QUIC-TLS-5: CONNECTION_CLOSE error codes for TLS failures");

   --  RFC 8446 6.2: bad_certificate(42) for a certificate the peer will not
   --  accept; QUIC maps a TLS alert A to 0x100 + A, so 0x12A.
   Run_Case
     ("pinned certificate mismatch", Wrong_Pin, Private_Key,
      16#12A#, "CRYPTO_ERROR + bad_certificate");

   --  RFC 8446 4.4.3: a CertificateVerify that does not verify "MUST
   --  terminate the handshake with a decrypt_error alert" (51), QUIC 0x133.
   Run_Case
     ("CertificateVerify signed with a foreign key", Certificate, Foreign_Key,
      16#133#, "CRYPTO_ERROR + decrypt_error");

   Repro_Support.Finish;
end Flyology.QUIC.Connection_Driver.Repro_Quic_Tls_5;
