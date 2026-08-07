with Flyology.QUIC.Transport_Parameter_Policy;

procedure Flyology.QUIC.TLS_Session.Smoke is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Array;
   use type TLS_Key_Schedule.QUIC_Traffic_Keys;
   use type Transport_Parameter_Policy.Encode_Status;

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
       (Hex ("f491306c81165ffd97822f3ef58de891" &
             "8779314457f5501e42d3f68504cd3aa8"));
   ALPN : constant Ada.Streams.Stream_Element_Array := Hex ("6833");

   Client_Parameters : Transport_Parameter_Policy.Transport_Parameters;
   Server_Parameters : Transport_Parameter_Policy.Transport_Parameters;
   Client_Encoded : Transport_Parameter_Policy.Encode_Result;
   Server_Encoded : Transport_Parameter_Policy.Encode_Result;

   procedure Reach_Server_Authentication
     (Client_Session : in out Session;
      Server_Session : in out Session;
      Authentication : out Ada.Streams.Stream_Element_Array;
      Authentication_Length : out Natural)
   is
      Client_Hello : Ada.Streams.Stream_Element_Array (1 .. 1_200);
      Server_Hello : Ada.Streams.Stream_Element_Array (1 .. 1_200);
      Client_Result : Operation_Result;
      Server_Result : Server_Flight_Result;
   begin
      Initialize_Client
        (Client_Session, ALPN,
         Client_Encoded.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Client_Encoded.Length)),
         Certificate);
      Initialize_Server
        (Server_Session, ALPN,
         Server_Encoded.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Server_Encoded.Length)),
         Certificate, Private_Key);
      Start_Client (Client_Session, Client_Hello, Client_Result);
      pragma Assert (Client_Result.Status = Succeeded);
      Accept_Client_Hello
        (Server_Session,
         Client_Hello
           (1 .. Ada.Streams.Stream_Element_Offset
                    (Client_Result.Output_Length)),
         Server_Hello, Authentication, Server_Result);
      pragma Assert (Server_Result.Status = Succeeded);
      Accept_Server_Hello
        (Client_Session,
         Server_Hello
           (1 .. Ada.Streams.Stream_Element_Offset
                    (Server_Result.Server_Hello_Length)),
         Client_Result);
      pragma Assert (Client_Result.Status = Succeeded);
      Authentication_Length := Server_Result.Authentication_Length;
   end Reach_Server_Authentication;
begin
   Client_Parameters.Initial_Source_Connection_ID :=
     (Present => True,
      Data => (1 => 16#83#, 2 => 16#94#, 3 => 16#c8#, 4 => 16#f0#,
               5 => 16#3e#, 6 => 16#51#, 7 => 16#57#, 8 => 16#08#,
               others => 0),
      Length => 8);
   Server_Parameters.Original_Destination_Connection_ID :=
     Client_Parameters.Initial_Source_Connection_ID;
   Server_Parameters.Initial_Source_Connection_ID :=
     (Present => True,
      Data => (1 => 1, 2 => 2, 3 => 3, 4 => 4,
               5 => 5, 6 => 6, 7 => 7, 8 => 8, others => 0),
      Length => 8);
   Client_Encoded :=
     Transport_Parameter_Policy.Encode
       (Client_Parameters, Transport_Parameter_Policy.Client);
   Server_Encoded :=
     Transport_Parameter_Policy.Encode
       (Server_Parameters, Transport_Parameter_Policy.Server);
   pragma Assert
     (Client_Encoded.Status = Transport_Parameter_Policy.Encoded
      and then Server_Encoded.Status = Transport_Parameter_Policy.Encoded);

   declare
      Client_Session : Session;
      Server_Session : Session;
      Client_Hello : Ada.Streams.Stream_Element_Array (1 .. 1_200);
      Server_Hello : Ada.Streams.Stream_Element_Array (1 .. 1_200);
      Authentication : Ada.Streams.Stream_Element_Array (1 .. 18_000);
      Client_Finished : Ada.Streams.Stream_Element_Array (1 .. 36);
      Client_Result : Operation_Result;
      Server_Result : Server_Flight_Result;
      Client_Send, Client_Receive : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Server_Send, Server_Receive : TLS_Key_Schedule.QUIC_Traffic_Keys;
   begin
      Initialize_Client
        (Client_Session, ALPN,
         Client_Encoded.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Client_Encoded.Length)),
         Certificate);
      Initialize_Server
        (Server_Session, ALPN,
         Server_Encoded.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Server_Encoded.Length)),
         Certificate, Private_Key);

      Start_Client (Client_Session, Client_Hello, Client_Result);
      pragma Assert (Client_Result.Status = Succeeded);
      Accept_Client_Hello
        (Server_Session,
         Client_Hello
           (1 .. Ada.Streams.Stream_Element_Offset
                    (Client_Result.Output_Length)),
         Server_Hello, Authentication, Server_Result);
      pragma Assert
        (Server_Result.Status = Succeeded
         and then Server_Result.Server_Hello_Length > 0
         and then Server_Result.Authentication_Length > 0);

      Accept_Server_Hello
        (Client_Session,
         Server_Hello
           (1 .. Ada.Streams.Stream_Element_Offset
                    (Server_Result.Server_Hello_Length)),
         Client_Result);
      pragma Assert (Client_Result.Status = Succeeded);
      Get_Handshake_Keys (Client_Session, Client_Send, Client_Receive);
      Get_Handshake_Keys (Server_Session, Server_Send, Server_Receive);
      pragma Assert
        (Client_Send = Server_Receive
         and then Client_Receive = Server_Send);

      Accept_Server_Authentication
        (Client_Session,
         Authentication
           (1 .. Ada.Streams.Stream_Element_Offset
                    (Server_Result.Authentication_Length)),
         Client_Finished, Client_Result);
      pragma Assert
        (Client_Result.Status = Succeeded
         and then Is_Connected (Client_Session));
      Accept_Client_Finished
        (Server_Session,
         Client_Finished
           (1 .. Ada.Streams.Stream_Element_Offset
                    (Client_Result.Output_Length)),
         Client_Result);
      pragma Assert
        (Client_Result.Status = Succeeded
         and then Is_Connected (Server_Session));

      Get_Application_Keys (Client_Session, Client_Send, Client_Receive);
      Get_Application_Keys (Server_Session, Server_Send, Server_Receive);
      pragma Assert
        (Client_Send = Server_Receive
         and then Client_Receive = Server_Send
         and then Has_Peer_Parameters (Client_Session)
         and then Has_Peer_Parameters (Server_Session));
   end;

   declare
      Client_Session : Session;
      Server_Session : Session;
      Authentication : Ada.Streams.Stream_Element_Array (1 .. 18_000);
      Authentication_Length : Natural;
      Client_Finished : Ada.Streams.Stream_Element_Array (1 .. 36);
      Result : Operation_Result;
   begin
      Reach_Server_Authentication
        (Client_Session, Server_Session, Authentication,
         Authentication_Length);
      Authentication
        (Ada.Streams.Stream_Element_Offset (Authentication_Length)) :=
          Authentication
            (Ada.Streams.Stream_Element_Offset (Authentication_Length)) xor 1;
      Accept_Server_Authentication
        (Client_Session,
         Authentication
           (1 .. Ada.Streams.Stream_Element_Offset (Authentication_Length)),
         Client_Finished, Result);
      pragma Assert
        (Result.Status = Finished_Failed
         and then State (Client_Session) = Failed
         and then not Has_Peer_Parameters (Client_Session));
   end;
end Flyology.QUIC.TLS_Session.Smoke;
