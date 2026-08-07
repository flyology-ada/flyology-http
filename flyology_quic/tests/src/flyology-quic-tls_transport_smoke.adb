with Ada.Streams;
with Flyology.QUIC.Crypto_OpenSSL;
with Flyology.QUIC.Crypto_Frame_Policy;
with Flyology.QUIC.Handshake_Connection;
with Flyology.QUIC.Initial_Connection;
with Flyology.QUIC.Initial_Frame_Policy;
with Flyology.QUIC.Long_Header_Policy;
with Flyology.QUIC.TLS_Key_Schedule;
with Flyology.QUIC.TLS_Session;
with Flyology.QUIC.Transport_Parameter_Policy;
with Flyology.QUIC.Varint_Policy;

procedure Flyology.QUIC.TLS_Transport_Smoke is
   use type Ada.Streams.Stream_Element_Array;
   use type Ada.Streams.Stream_Element_Offset;
   use type Crypto_Frame_Policy.Encode_Status;
   use type Handshake_Connection.Build_Status;
   use type Handshake_Connection.Process_Status;
   use type Initial_Connection.Build_Status;
   use type Initial_Connection.Process_Status;
   use type Initial_Frame_Policy.Frame_Kind;
   use type Initial_Frame_Policy.Parse_Status;
   use type TLS_Key_Schedule.QUIC_Traffic_Keys;
   use type TLS_Session.Operation_Status;
   use type Transport_Parameter_Policy.Encode_Status;
   use type Varint_Policy.Value_Type;

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
     (Data : Ada.Streams.Stream_Element_Array)
      return Long_Header_Policy.Connection_ID
   is
      Result : Long_Header_Policy.Connection_ID;
   begin
      Result.Length := Natural (Data'Length);
      if Data'Length > 0 then
         Result.Data (1 .. Data'Length) := Data;
      end if;
      return Result;
   end ID;

   Certificate : constant Ada.Streams.Stream_Element_Array :=
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
       (Hex
          ("f491306c81165ffd97822f3ef58de891" &
           "8779314457f5501e42d3f68504cd3aa8"));
   ALPN : constant Ada.Streams.Stream_Element_Array := Hex ("6833");

   Original_ID_Data : constant Ada.Streams.Stream_Element_Array :=
     Hex ("8394c8f03e515708");
   Original_ID : constant Long_Header_Policy.Connection_ID :=
     ID (Original_ID_Data);
   Client_ID : constant Long_Header_Policy.Connection_ID :=
     ID (Hex ("aabbccdd01020304"));
   Server_ID : constant Long_Header_Policy.Connection_ID :=
     ID (Hex ("1020304050607080"));

   Client_Parameters : Transport_Parameter_Policy.Transport_Parameters;
   Server_Parameters : Transport_Parameter_Policy.Transport_Parameters;
   Client_Encoded : Transport_Parameter_Policy.Encode_Result;
   Server_Encoded : Transport_Parameter_Policy.Encode_Result;

   Client_TLS : TLS_Session.Session;
   Server_TLS : TLS_Session.Session;
   Client_Initial : Initial_Connection.Connection;
   Server_Initial : Initial_Connection.Connection;
begin
   Client_Parameters.Initial_Source_Connection_ID :=
     (Present => True,
      Data => (1 => 16#AA#, 2 => 16#BB#, 3 => 16#CC#, 4 => 16#DD#,
               5 => 1, 6 => 2, 7 => 3, 8 => 4, others => 0),
      Length => 8);
   Client_Parameters.Initial_Max_Data := (Present => True, Value => 65_536);
   Client_Parameters.Initial_Max_Streams_Bidi :=
     (Present => True, Value => 16);

   Server_Parameters.Original_Destination_Connection_ID :=
     (Present => True,
      Data => (1 => 16#83#, 2 => 16#94#, 3 => 16#C8#, 4 => 16#F0#,
               5 => 16#3E#, 6 => 16#51#, 7 => 16#57#, 8 => 16#08#,
               others => 0),
      Length => 8);
   Server_Parameters.Initial_Source_Connection_ID :=
     (Present => True,
      Data => (1 => 16#10#, 2 => 16#20#, 3 => 16#30#, 4 => 16#40#,
               5 => 16#50#, 6 => 16#60#, 7 => 16#70#, 8 => 16#80#,
               others => 0),
      Length => 8);
   Server_Parameters.Initial_Max_Data :=
     (Present => True, Value => 1_048_576);
   Server_Parameters.Initial_Max_Streams_Bidi :=
     (Present => True, Value => 32);

   Client_Encoded :=
     Transport_Parameter_Policy.Encode
       (Client_Parameters, Transport_Parameter_Policy.Client);
   Server_Encoded :=
     Transport_Parameter_Policy.Encode
       (Server_Parameters, Transport_Parameter_Policy.Server);
   pragma Assert
     (Client_Encoded.Status = Transport_Parameter_Policy.Encoded
      and then Server_Encoded.Status = Transport_Parameter_Policy.Encoded);

   TLS_Session.Initialize_Client
     (Client_TLS, ALPN,
      Client_Encoded.Data
        (1 .. Ada.Streams.Stream_Element_Offset (Client_Encoded.Length)),
      Certificate);
   TLS_Session.Initialize_Server
     (Server_TLS, ALPN,
      Server_Encoded.Data
        (1 .. Ada.Streams.Stream_Element_Offset (Server_Encoded.Length)),
      Certificate, Private_Key);
   Initial_Connection.Initialize
     (Client_Initial, Initial_Connection.Client, Original_ID_Data,
      Original_ID, Client_ID);
   Initial_Connection.Initialize
     (Server_Initial, Initial_Connection.Server, Original_ID_Data,
      Client_ID, Server_ID);

   declare
      Client_Hello : Ada.Streams.Stream_Element_Array (1 .. 1_200);
      TLS_Result : TLS_Session.Operation_Result;
      Client_Frame : Crypto_Frame_Policy.Encode_Result;
      Client_Plaintext : Ada.Streams.Stream_Element_Array (1 .. 1_157) :=
        (others => 0);
      Client_Packet : Ada.Streams.Stream_Element_Array (1 .. 1_200);
      Initial_Build : Initial_Connection.Build_Result;
      Server_Decoded : Ada.Streams.Stream_Element_Array (1 .. 1_200);
      Initial_Process : Initial_Connection.Process_Result;
      Client_Crypto : Initial_Frame_Policy.Parse_Result;
      Server_Hello : Ada.Streams.Stream_Element_Array (1 .. 1_200);
      Authentication : Ada.Streams.Stream_Element_Array (1 .. 18_000);
      Server_Result : TLS_Session.Server_Flight_Result;
   begin
      TLS_Session.Start_Client (Client_TLS, Client_Hello, TLS_Result);
      pragma Assert (TLS_Result.Status = TLS_Session.Succeeded);
      Client_Frame :=
        Crypto_Frame_Policy.Encode
          (0, Client_Hello
             (1 .. Ada.Streams.Stream_Element_Offset
                     (TLS_Result.Output_Length)));
      pragma Assert
        (Client_Frame.Status = Crypto_Frame_Policy.Encoded
         and then Client_Frame.Length <= Client_Plaintext'Length);
      Client_Plaintext
        (1 .. Ada.Streams.Stream_Element_Offset (Client_Frame.Length)) :=
          Client_Frame.Data
            (1 .. Ada.Streams.Stream_Element_Offset (Client_Frame.Length));
      Initial_Connection.Build_Initial
        (Client_Initial, (1 .. 0 => 0), Client_Plaintext, Client_Packet,
         Initial_Build);
      pragma Assert
        (Initial_Build.Status = Initial_Connection.Built
         and then Initial_Build.Packet_Length = 1_200);
      Initial_Connection.Process_Initial
        (Server_Initial, Client_Packet, Server_Decoded, Initial_Process);
      pragma Assert
        (Initial_Process.Status = Initial_Connection.Processed
         and then Initial_Process.Packet.Plaintext_Length =
           Client_Plaintext'Length);
      Client_Crypto :=
        Initial_Frame_Policy.Parse_Next
          (Server_Decoded (1 .. Client_Plaintext'Length), 0);
      pragma Assert
        (Client_Crypto.Status = Initial_Frame_Policy.Parsed
         and then Client_Crypto.Kind = Initial_Frame_Policy.Crypto
         and then Client_Crypto.Crypto_Offset = 0);

      TLS_Session.Accept_Client_Hello
        (Server_TLS,
         Server_Decoded
           (Server_Decoded'First
              + Client_Crypto.Crypto_Data_Offset
            .. Server_Decoded'First
              + Client_Crypto.Crypto_Data_Offset
              + Client_Crypto.Crypto_Length - 1),
         Server_Hello, Authentication, Server_Result);
      pragma Assert
        (Server_Result.Status = TLS_Session.Succeeded
         and then TLS_Session.Has_Handshake_Keys (Server_TLS));

      declare
         Server_Frame : constant Crypto_Frame_Policy.Encode_Result :=
           Crypto_Frame_Policy.Encode
             (0, Server_Hello
                (1 .. Ada.Streams.Stream_Element_Offset
                        (Server_Result.Server_Hello_Length)));
         Server_Packet : Ada.Streams.Stream_Element_Array (1 .. 1_600);
         Client_Decoded : Ada.Streams.Stream_Element_Array
           (Server_Packet'Range);
         Server_Build : Initial_Connection.Build_Result;
         Client_Process : Initial_Connection.Process_Result;
         Server_Crypto : Initial_Frame_Policy.Parse_Result;
      begin
         pragma Assert
           (Server_Frame.Status = Crypto_Frame_Policy.Encoded);
         Initial_Connection.Build_Initial
           (Server_Initial, (1 .. 0 => 0),
            Server_Frame.Data
              (1 .. Ada.Streams.Stream_Element_Offset (Server_Frame.Length)),
            Server_Packet, Server_Build);
         pragma Assert (Server_Build.Status = Initial_Connection.Built);
         Initial_Connection.Process_Initial
           (Client_Initial,
            Server_Packet
              (1 .. Ada.Streams.Stream_Element_Offset
                      (Server_Build.Packet_Length)),
            Client_Decoded, Client_Process);
         pragma Assert
           (Client_Process.Status = Initial_Connection.Processed);
         Server_Crypto :=
           Initial_Frame_Policy.Parse_Next
             (Client_Decoded
                (1 .. Ada.Streams.Stream_Element_Offset
                        (Client_Process.Packet.Plaintext_Length)),
              0);
         pragma Assert
           (Server_Crypto.Status = Initial_Frame_Policy.Parsed
            and then Server_Crypto.Kind = Initial_Frame_Policy.Crypto);
         TLS_Session.Accept_Server_Hello
           (Client_TLS,
            Client_Decoded
              (Client_Decoded'First + Server_Crypto.Crypto_Data_Offset
               .. Client_Decoded'First + Server_Crypto.Crypto_Data_Offset
                    + Server_Crypto.Crypto_Length - 1),
            TLS_Result);
         pragma Assert
           (TLS_Result.Status = TLS_Session.Succeeded
            and then TLS_Session.Has_Handshake_Keys (Client_TLS));
      end;

      declare
         Client_Send, Client_Receive :
           TLS_Key_Schedule.QUIC_Traffic_Keys;
         Server_Send, Server_Receive :
           TLS_Key_Schedule.QUIC_Traffic_Keys;
         Client_Handshake : Handshake_Connection.Connection;
         Server_Handshake : Handshake_Connection.Connection;
      begin
         TLS_Session.Get_Handshake_Keys
           (Client_TLS, Client_Send, Client_Receive);
         TLS_Session.Get_Handshake_Keys
           (Server_TLS, Server_Send, Server_Receive);
         pragma Assert
           (Client_Send = Server_Receive
            and then Client_Receive = Server_Send);
         Handshake_Connection.Initialize
           (Client_Handshake, Client_Send, Client_Receive,
            Server_ID, Client_ID);
         Handshake_Connection.Initialize
           (Server_Handshake, Server_Send, Server_Receive,
            Client_ID, Server_ID);

         declare
            Server_Frame : constant Crypto_Frame_Policy.Encode_Result :=
              Crypto_Frame_Policy.Encode
                (0, Authentication
                   (1 .. Ada.Streams.Stream_Element_Offset
                           (Server_Result.Authentication_Length)));
            Server_Packet : Ada.Streams.Stream_Element_Array (1 .. 20_000);
            Client_Decoded : Ada.Streams.Stream_Element_Array
              (Server_Packet'Range);
            Built_Packet : Handshake_Connection.Build_Result;
            Processed_Packet : Handshake_Connection.Process_Result;
            Server_Crypto : Initial_Frame_Policy.Parse_Result;
            Client_Finished : Ada.Streams.Stream_Element_Array (1 .. 36);
         begin
            pragma Assert
              (Server_Frame.Status = Crypto_Frame_Policy.Encoded);
            Handshake_Connection.Build_Handshake
              (Server_Handshake,
               Server_Frame.Data
                 (1 .. Ada.Streams.Stream_Element_Offset
                         (Server_Frame.Length)),
               Server_Packet, Built_Packet);
            pragma Assert
              (Built_Packet.Status = Handshake_Connection.Built);
            Handshake_Connection.Process_Handshake
              (Client_Handshake,
               Server_Packet
                 (1 .. Ada.Streams.Stream_Element_Offset
                         (Built_Packet.Packet_Length)),
               Client_Decoded, Processed_Packet);
            pragma Assert
              (Processed_Packet.Status = Handshake_Connection.Processed);
            Server_Crypto :=
              Initial_Frame_Policy.Parse_Next
                (Client_Decoded
                   (1 .. Ada.Streams.Stream_Element_Offset
                           (Processed_Packet.Packet.Plaintext_Length)),
                 0);
            pragma Assert
              (Server_Crypto.Status = Initial_Frame_Policy.Parsed
               and then Server_Crypto.Kind = Initial_Frame_Policy.Crypto);
            TLS_Session.Accept_Server_Authentication
              (Client_TLS,
               Client_Decoded
                 (Client_Decoded'First + Server_Crypto.Crypto_Data_Offset
                  .. Client_Decoded'First
                       + Server_Crypto.Crypto_Data_Offset
                       + Server_Crypto.Crypto_Length - 1),
               Client_Finished, TLS_Result);
            pragma Assert
              (TLS_Result.Status = TLS_Session.Succeeded
               and then TLS_Session.Is_Connected (Client_TLS));

            declare
               Client_Frame : constant Crypto_Frame_Policy.Encode_Result :=
                 Crypto_Frame_Policy.Encode
                   (0, Client_Finished
                      (1 .. Ada.Streams.Stream_Element_Offset
                              (TLS_Result.Output_Length)));
               Client_Packet : Ada.Streams.Stream_Element_Array (1 .. 128);
               Server_Decoded : Ada.Streams.Stream_Element_Array
                 (Client_Packet'Range);
               Client_Build : Handshake_Connection.Build_Result;
               Server_Process : Handshake_Connection.Process_Result;
               Client_Crypto : Initial_Frame_Policy.Parse_Result;
            begin
               Handshake_Connection.Build_Handshake
                 (Client_Handshake,
                  Client_Frame.Data
                    (1 .. Ada.Streams.Stream_Element_Offset
                            (Client_Frame.Length)),
                  Client_Packet, Client_Build);
               pragma Assert
                 (Client_Build.Status = Handshake_Connection.Built);
               Handshake_Connection.Process_Handshake
                 (Server_Handshake,
                  Client_Packet
                    (1 .. Ada.Streams.Stream_Element_Offset
                            (Client_Build.Packet_Length)),
                  Server_Decoded, Server_Process);
               pragma Assert
                 (Server_Process.Status = Handshake_Connection.Processed);
               Client_Crypto :=
                 Initial_Frame_Policy.Parse_Next
                   (Server_Decoded
                      (1 .. Ada.Streams.Stream_Element_Offset
                              (Server_Process.Packet.Plaintext_Length)),
                    0);
               TLS_Session.Accept_Client_Finished
                 (Server_TLS,
                  Server_Decoded
                    (Server_Decoded'First
                       + Client_Crypto.Crypto_Data_Offset
                     .. Server_Decoded'First
                          + Client_Crypto.Crypto_Data_Offset
                          + Client_Crypto.Crypto_Length - 1),
                  TLS_Result);
               pragma Assert
                 (TLS_Result.Status = TLS_Session.Succeeded
                  and then TLS_Session.Is_Connected (Server_TLS));
            end;
         end;

         TLS_Session.Get_Application_Keys
           (Client_TLS, Client_Send, Client_Receive);
         TLS_Session.Get_Application_Keys
           (Server_TLS, Server_Send, Server_Receive);
         pragma Assert
           (Client_Send = Server_Receive
            and then Client_Receive = Server_Send
            and then TLS_Session.Has_Peer_Parameters (Client_TLS)
            and then TLS_Session.Has_Peer_Parameters (Server_TLS));
      end;
   end;
end Flyology.QUIC.TLS_Transport_Smoke;
