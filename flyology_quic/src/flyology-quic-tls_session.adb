with Flyology.QUIC.TLS_Authentication_Policy;
with Flyology.QUIC.TLS_Handshake_Policy;
with Flyology.QUIC.TLS_Signature_Policy;

package body Flyology.QUIC.TLS_Session is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Array;
   use type Ada.Streams.Stream_Element_Offset;
   use type TLS_Authentication_Policy.Encode_Status;
   use type TLS_Authentication_Policy.Message_Kind;
   use type TLS_Authentication_Policy.Parse_Status;
   use type TLS_Authentication_Policy.Signature_Scheme;
   use type TLS_Handshake_Policy.Encode_Status;
   use type TLS_Handshake_Policy.Message_Kind;
   use type TLS_Handshake_Policy.Parse_Status;
   use type Transport_Parameter_Policy.Decode_Status;

   function State (Item : Session) return Session_State is
     (Item.Current_State);

   function Is_Initialized (Item : Session) return Boolean is
     (Item.Current_State /= Uninitialized);

   function Is_Connected (Item : Session) return Boolean is
     (Item.Current_State = Connected);

   function Has_Handshake_Keys (Item : Session) return Boolean is
     (Item.Handshake_Keys_Ready);

   function Has_Peer_Parameters (Item : Session) return Boolean is
     (Item.Peer_Transport_Ready);

   procedure Mark_Failed (Item : in out Session) is
   begin
      Item.Current_State := Failed;
      Item.X25519_Private := (others => 0);
      Item.Signing_Key := (others => 0);
      TLS_Key_Schedule.Clear (Item.Handshake_Secrets);
      TLS_Key_Schedule.Clear (Item.Application_Secrets);
      TLS_Key_Schedule.Clear (Item.Client_Handshake_Keys);
      TLS_Key_Schedule.Clear (Item.Server_Handshake_Keys);
      TLS_Key_Schedule.Clear (Item.Client_Application_Keys);
      TLS_Key_Schedule.Clear (Item.Server_Application_Keys);
      Item.Handshake_Keys_Ready := False;
      Item.Peer_Transport_Ready := False;
   end Mark_Failed;

   function Append_Transcript
     (Item : in out Session;
      Data : Ada.Streams.Stream_Element_Array) return Boolean
   is
      Length : constant Natural := Natural (Data'Length);
   begin
      if Length > Max_Transcript - Item.Transcript_Length then
         return False;
      elsif Length > 0 then
         Item.Transcript
           (Ada.Streams.Stream_Element_Offset (Item.Transcript_Length + 1)
              .. Ada.Streams.Stream_Element_Offset
                   (Item.Transcript_Length + Length)) := Data;
         Item.Transcript_Length := Item.Transcript_Length + Length;
      end if;
      return True;
   end Append_Transcript;

   procedure Hash_Transcript
     (Item   : Session;
      Digest : out TLS_Key_Schedule.Transcript_Hash)
   is
   begin
      Crypto_OpenSSL.SHA256
        (Item.Backend,
         Item.Transcript
           (1 .. Ada.Streams.Stream_Element_Offset (Item.Transcript_Length)),
         Digest);
   end Hash_Transcript;

   procedure Put
     (Output   : in out Ada.Streams.Stream_Element_Array;
      Position : in out Natural;
      Data     : Ada.Streams.Stream_Element_Array)
   is
      Length : constant Natural := Natural (Data'Length);
   begin
      if Length > 0 then
         Output
           (Output'First + Ada.Streams.Stream_Element_Offset (Position)
              .. Output'First
                   + Ada.Streams.Stream_Element_Offset
                       (Position + Length - 1)) :=
             Data;
         Position := Position + Length;
      end if;
   end Put;

   function Secure_Equal
     (Left  : Ada.Streams.Stream_Element_Array;
      Right : Ada.Streams.Stream_Element_Array) return Boolean
   is
      Difference : Ada.Streams.Stream_Element := 0;
   begin
      if Left'Length /= Right'Length then
         return False;
      end if;
      for Offset in Ada.Streams.Stream_Element_Offset range
        0 .. Left'Length - 1
      loop
         Difference :=
           Difference
             or (Left (Left'First + Offset) xor Right (Right'First + Offset));
      end loop;
      return Difference = 0;
   end Secure_Equal;

   procedure Initialize_Common
     (Item                 : in out Session;
      Role                 : Endpoint_Role;
      ALPN                 : Ada.Streams.Stream_Element_Array;
      Transport_Parameters : Ada.Streams.Stream_Element_Array)
   is
   begin
      Crypto_OpenSSL.Initialize_Provider (Item.Backend);
      Item.Role := Role;
      Item.ALPN_Length := Natural (ALPN'Length);
      Item.ALPN (1 .. ALPN'Length) := ALPN;
      Item.Local_Transport_Length := Natural (Transport_Parameters'Length);
      if Transport_Parameters'Length > 0 then
         Item.Local_Transport (1 .. Transport_Parameters'Length) :=
           Transport_Parameters;
      end if;
   end Initialize_Common;

   procedure Initialize_Client
     (Item                 : in out Session;
      ALPN                 : Ada.Streams.Stream_Element_Array;
      Transport_Parameters : Ada.Streams.Stream_Element_Array;
      Pinned_Certificate   : Ada.Streams.Stream_Element_Array)
   is
   begin
      Initialize_Common (Item, Client, ALPN, Transport_Parameters);
      Item.Certificate_Length := Natural (Pinned_Certificate'Length);
      Item.Certificate (1 .. Pinned_Certificate'Length) := Pinned_Certificate;
      Item.Current_State := Client_Ready;
   end Initialize_Client;

   procedure Initialize_Server
     (Item                 : in out Session;
      ALPN                 : Ada.Streams.Stream_Element_Array;
      Transport_Parameters : Ada.Streams.Stream_Element_Array;
      Certificate_DER      : Ada.Streams.Stream_Element_Array;
      Private_Key          : Crypto_OpenSSL.Ed25519_Private_Key)
   is
   begin
      Initialize_Common (Item, Server, ALPN, Transport_Parameters);
      Item.Certificate_Length := Natural (Certificate_DER'Length);
      Item.Certificate (1 .. Certificate_DER'Length) := Certificate_DER;
      Item.Signing_Key := Private_Key;
      Item.Current_State := Server_Waiting_Client_Hello;
   end Initialize_Server;

   function Validate_Extensions
     (Item        : in out Session;
      Input       : Ada.Streams.Stream_Element_Array;
      Parsed      : TLS_Handshake_Policy.Parse_Result;
      Sender_Role : Transport_Parameter_Policy.Endpoint_Role)
      return Operation_Status
   is
      ALPN_Start : constant Ada.Streams.Stream_Element_Offset :=
        Input'First
          + Ada.Streams.Stream_Element_Offset
              (Parsed.Extensions_Offset
                 + Parsed.Extensions.ALPN_Protocol_Offset);
      TP_Start : constant Ada.Streams.Stream_Element_Offset :=
        Input'First
          + Ada.Streams.Stream_Element_Offset
              (Parsed.Extensions_Offset
                 + Parsed.Extensions.Transport_Parameters_Offset);
      Decoded : Transport_Parameter_Policy.Decode_Result;
   begin
      if Parsed.Extensions.ALPN_Protocol_Length /= Item.ALPN_Length
        or else Input
          (ALPN_Start
             .. ALPN_Start
                  + Ada.Streams.Stream_Element_Offset
                      (Item.ALPN_Length - 1)) /=
            Item.ALPN
              (1 .. Ada.Streams.Stream_Element_Offset (Item.ALPN_Length))
      then
         return ALPN_Mismatch;
      end if;

      if Parsed.Extensions.Transport_Parameters_Length = 0 then
         return Invalid_Transport_Parameters;
      end if;
      Decoded :=
        Transport_Parameter_Policy.Decode
          (Input
             (TP_Start
                .. TP_Start
                     + Ada.Streams.Stream_Element_Offset
                         (Parsed.Extensions.Transport_Parameters_Length - 1)),
           Sender_Role);
      if Decoded.Status /= Transport_Parameter_Policy.Decoded then
         return Invalid_Transport_Parameters;
      end if;
      Item.Peer_Transport := Decoded.Parameters;
      Item.Peer_Transport_Ready := True;
      return Succeeded;
   end Validate_Extensions;

   procedure Start_Client
     (Item   : in out Session;
      Output : out Ada.Streams.Stream_Element_Array;
      Result : out Operation_Result)
   is
      Random  : TLS_Handshake_Policy.Hello_Random;
      Encoded : TLS_Handshake_Policy.Encode_Result;
   begin
      Output := (others => 0);
      Result := (others => <>);
      if Item.Current_State /= Client_Ready then
         return;
      end if;
      Crypto_OpenSSL.Generate_X25519
        (Item.Backend, Item.X25519_Private, Item.X25519_Public);
      Crypto_OpenSSL.Random_Bytes (Item.Backend, Random);
      Encoded :=
        TLS_Handshake_Policy.Encode_Client_Hello
          (Random, Item.X25519_Public,
           Item.ALPN
             (1 .. Ada.Streams.Stream_Element_Offset (Item.ALPN_Length)),
           Item.Local_Transport
             (1 .. Ada.Streams.Stream_Element_Offset
                      (Item.Local_Transport_Length)));
      if Encoded.Status /= TLS_Handshake_Policy.Encoded then
         Result.Status := Encoding_Failed;
         Mark_Failed (Item);
         return;
      elsif not Append_Transcript
        (Item, Encoded.Data (1 .. Ada.Streams.Stream_Element_Offset
                                      (Encoded.Length)))
      then
         Result.Status := Transcript_Too_Large;
         Mark_Failed (Item);
         return;
      end if;
      Output
        (Output'First
           .. Output'First
                + Ada.Streams.Stream_Element_Offset (Encoded.Length - 1)) :=
          Encoded.Data
            (1 .. Ada.Streams.Stream_Element_Offset (Encoded.Length));
      Result.Status := Succeeded;
      Result.Output_Length := Encoded.Length;
      Item.Current_State := Client_Waiting_Server_Hello;
   exception
      when Crypto_OpenSSL.Crypto_Error =>
         Result.Status := Crypto_Failed;
         Mark_Failed (Item);
   end Start_Client;

   procedure Accept_Client_Hello
     (Item                   : in out Session;
      Input                  : Ada.Streams.Stream_Element_Array;
      Server_Hello           : out Ada.Streams.Stream_Element_Array;
      Authentication_Flight  : out Ada.Streams.Stream_Element_Array;
      Result                 : out Server_Flight_Result)
   is
      Parsed : TLS_Handshake_Policy.Parse_Result;
      Status : Operation_Status;
      Peer_Key : Crypto_OpenSSL.X25519_Public_Key;
      Random   : TLS_Handshake_Policy.Hello_Random;
      Session_ID : TLS_Handshake_Policy.Session_ID;
      Hello    : TLS_Handshake_Policy.Encode_Result;
      Extensions : TLS_Handshake_Policy.Encode_Result;
      Certificate : TLS_Authentication_Policy.Encode_Result;
      Certificate_Verify : TLS_Authentication_Policy.Encode_Result;
      Finished : TLS_Authentication_Policy.Encode_Result;
      Shared   : Crypto_OpenSSL.X25519_Shared_Secret;
      Hash     : TLS_Key_Schedule.Transcript_Hash;
      Signature_Input : TLS_Signature_Policy.Signature_Input;
      Signature : Crypto_OpenSSL.Ed25519_Signature;
      Verify_Data : TLS_Authentication_Policy.Verify_Data;
      Position : Natural := 0;
      Key_Start : Ada.Streams.Stream_Element_Offset;
   begin
      Server_Hello := (others => 0);
      Authentication_Flight := (others => 0);
      Result := (others => <>);
      if Item.Current_State /= Server_Waiting_Client_Hello then
         return;
      end if;
      Parsed := TLS_Handshake_Policy.Parse (Input);
      if Parsed.Status /= TLS_Handshake_Policy.Parsed
        or else Parsed.Kind /= TLS_Handshake_Policy.Client_Hello
      then
         Result.Status :=
           (if Parsed.Status = TLS_Handshake_Policy.Invalid_Extensions
            then Invalid_Extensions else Invalid_Message);
         Mark_Failed (Item);
         return;
      end if;
      Status :=
        Validate_Extensions
          (Item,
           Input
             (Input'First
                .. Input'First
                     + Ada.Streams.Stream_Element_Offset
                         (Parsed.Consumed - 1)),
           Parsed, Transport_Parameter_Policy.Client);
      if Status /= Succeeded then
         Result.Status := Status;
         Mark_Failed (Item);
         return;
      end if;
      Key_Start :=
        Input'First
          + Ada.Streams.Stream_Element_Offset
              (Parsed.Extensions_Offset
                 + Parsed.Extensions.Key_Share_Offset);
      Peer_Key := Input (Key_Start .. Key_Start + 31);
      if not Append_Transcript
        (Item,
         Input
           (Input'First
              .. Input'First
                   + Ada.Streams.Stream_Element_Offset (Parsed.Consumed - 1)))
      then
         Result.Status := Transcript_Too_Large;
         Mark_Failed (Item);
         return;
      end if;

      Crypto_OpenSSL.Generate_X25519
        (Item.Backend, Item.X25519_Private, Item.X25519_Public);
      Crypto_OpenSSL.Random_Bytes (Item.Backend, Random);
      Session_ID.Length := Parsed.Session_ID_Length;
      if Session_ID.Length > 0 then
         Session_ID.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Session_ID.Length)) :=
             Input
               (Input'First
                  + Ada.Streams.Stream_Element_Offset
                      (Parsed.Session_ID_Offset)
                  .. Input'First
                       + Ada.Streams.Stream_Element_Offset
                           (Parsed.Session_ID_Offset + Session_ID.Length - 1));
      end if;
      Hello :=
        TLS_Handshake_Policy.Encode_Server_Hello
          (Random, Session_ID, Item.X25519_Public);
      if Hello.Status /= TLS_Handshake_Policy.Encoded then
         Result.Status := Encoding_Failed;
         Mark_Failed (Item);
         return;
      end if;
      Server_Hello
        (Server_Hello'First
           .. Server_Hello'First
                + Ada.Streams.Stream_Element_Offset (Hello.Length - 1)) :=
          Hello.Data (1 .. Ada.Streams.Stream_Element_Offset (Hello.Length));
      if not Append_Transcript
        (Item, Hello.Data (1 .. Ada.Streams.Stream_Element_Offset
                                    (Hello.Length)))
      then
         Result.Status := Transcript_Too_Large;
         Mark_Failed (Item);
         return;
      end if;

      Crypto_OpenSSL.X25519_Shared
        (Item.Backend, Item.X25519_Private, Peer_Key, Shared);
      Hash_Transcript (Item, Hash);
      TLS_Key_Schedule.Derive_Handshake
        (Item.Backend, Shared, Hash, Item.Handshake_Secrets);
      Shared := (others => 0);
      TLS_Key_Schedule.Derive_QUIC_Keys
        (Item.Backend, Item.Handshake_Secrets.Client_Traffic,
         Item.Client_Handshake_Keys);
      TLS_Key_Schedule.Derive_QUIC_Keys
        (Item.Backend, Item.Handshake_Secrets.Server_Traffic,
         Item.Server_Handshake_Keys);
      Item.Handshake_Keys_Ready := True;

      Extensions :=
        TLS_Handshake_Policy.Encode_Encrypted_Extensions
          (Item.ALPN
             (1 .. Ada.Streams.Stream_Element_Offset (Item.ALPN_Length)),
           Item.Local_Transport
             (1 .. Ada.Streams.Stream_Element_Offset
                      (Item.Local_Transport_Length)));
      Certificate :=
        TLS_Authentication_Policy.Encode_Certificate
          (Item.Certificate
             (1 .. Ada.Streams.Stream_Element_Offset
                      (Item.Certificate_Length)),
           (1 .. 0 => 0));
      if Extensions.Status /= TLS_Handshake_Policy.Encoded
        or else Certificate.Status /= TLS_Authentication_Policy.Encoded
      then
         Result.Status := Encoding_Failed;
         Mark_Failed (Item);
         return;
      end if;
      Put
        (Authentication_Flight, Position,
         Extensions.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Extensions.Length)));
      if not Append_Transcript
        (Item, Extensions.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Extensions.Length)))
      then
         Result.Status := Transcript_Too_Large;
         Mark_Failed (Item);
         return;
      end if;
      Put
        (Authentication_Flight, Position,
         Certificate.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Certificate.Length)));
      if not Append_Transcript
        (Item, Certificate.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Certificate.Length)))
      then
         Result.Status := Transcript_Too_Large;
         Mark_Failed (Item);
         return;
      end if;

      Hash_Transcript (Item, Hash);
      Signature_Input :=
        TLS_Signature_Policy.Build
          (TLS_Signature_Policy.Server,
           TLS_Signature_Policy.Transcript_Hash'(Hash));
      Crypto_OpenSSL.Ed25519_Sign
        (Item.Backend, Item.Signing_Key, Signature_Input, Signature);
      Certificate_Verify :=
        TLS_Authentication_Policy.Encode_Certificate_Verify
          (TLS_Authentication_Policy.ED25519, Signature);
      if Certificate_Verify.Status /= TLS_Authentication_Policy.Encoded then
         Result.Status := Encoding_Failed;
         Mark_Failed (Item);
         return;
      end if;
      Put
        (Authentication_Flight, Position,
         Certificate_Verify.Data
           (1 .. Ada.Streams.Stream_Element_Offset
                    (Certificate_Verify.Length)));
      if not Append_Transcript
        (Item, Certificate_Verify.Data
           (1 .. Ada.Streams.Stream_Element_Offset
                    (Certificate_Verify.Length)))
      then
         Result.Status := Transcript_Too_Large;
         Mark_Failed (Item);
         return;
      end if;

      Hash_Transcript (Item, Hash);
      TLS_Key_Schedule.Finished_Verify_Data
        (Item.Backend, Item.Handshake_Secrets.Server_Finished, Hash,
         Verify_Data);
      Finished := TLS_Authentication_Policy.Encode_Finished (Verify_Data);
      Put
        (Authentication_Flight, Position,
         Finished.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Finished.Length)));
      if not Append_Transcript
        (Item, Finished.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Finished.Length)))
      then
         Result.Status := Transcript_Too_Large;
         Mark_Failed (Item);
         return;
      end if;

      Hash_Transcript (Item, Hash);
      TLS_Key_Schedule.Derive_Application
        (Item.Backend, Item.Handshake_Secrets, Hash,
         Item.Application_Secrets);
      TLS_Key_Schedule.Derive_QUIC_Keys
        (Item.Backend, Item.Application_Secrets.Client_Traffic,
         Item.Client_Application_Keys);
      TLS_Key_Schedule.Derive_QUIC_Keys
        (Item.Backend, Item.Application_Secrets.Server_Traffic,
         Item.Server_Application_Keys);
      Item.Current_State := Server_Waiting_Finished;
      Result.Status := Succeeded;
      Result.Consumed := Parsed.Consumed;
      Result.Server_Hello_Length := Hello.Length;
      Result.Authentication_Length := Position;
   exception
      when Crypto_OpenSSL.Crypto_Error =>
         Result.Status := Crypto_Failed;
         Mark_Failed (Item);
   end Accept_Client_Hello;

   procedure Accept_Server_Hello
     (Item   : in out Session;
      Input  : Ada.Streams.Stream_Element_Array;
      Result : out Operation_Result)
   is
      Parsed : TLS_Handshake_Policy.Parse_Result;
      Peer_Key : Crypto_OpenSSL.X25519_Public_Key;
      Key_Start : Ada.Streams.Stream_Element_Offset;
      Shared : Crypto_OpenSSL.X25519_Shared_Secret;
      Hash   : TLS_Key_Schedule.Transcript_Hash;
   begin
      Result := (others => <>);
      if Item.Current_State /= Client_Waiting_Server_Hello then
         return;
      end if;
      Parsed := TLS_Handshake_Policy.Parse (Input);
      if Parsed.Status /= TLS_Handshake_Policy.Parsed
        or else Parsed.Kind /= TLS_Handshake_Policy.Server_Hello
        or else Parsed.Session_ID_Length /= 0
      then
         Result.Status :=
           (if Parsed.Status = TLS_Handshake_Policy.Invalid_Extensions
            then Invalid_Extensions else Invalid_Message);
         Mark_Failed (Item);
         return;
      end if;
      Key_Start :=
        Input'First
          + Ada.Streams.Stream_Element_Offset
              (Parsed.Extensions_Offset
                 + Parsed.Extensions.Key_Share_Offset);
      Peer_Key := Input (Key_Start .. Key_Start + 31);
      if not Append_Transcript
        (Item,
         Input
           (Input'First
              .. Input'First
                   + Ada.Streams.Stream_Element_Offset (Parsed.Consumed - 1)))
      then
         Result.Status := Transcript_Too_Large;
         Mark_Failed (Item);
         return;
      end if;
      Crypto_OpenSSL.X25519_Shared
        (Item.Backend, Item.X25519_Private, Peer_Key, Shared);
      Hash_Transcript (Item, Hash);
      TLS_Key_Schedule.Derive_Handshake
        (Item.Backend, Shared, Hash, Item.Handshake_Secrets);
      Shared := (others => 0);
      TLS_Key_Schedule.Derive_QUIC_Keys
        (Item.Backend, Item.Handshake_Secrets.Client_Traffic,
         Item.Client_Handshake_Keys);
      TLS_Key_Schedule.Derive_QUIC_Keys
        (Item.Backend, Item.Handshake_Secrets.Server_Traffic,
         Item.Server_Handshake_Keys);
      Item.Handshake_Keys_Ready := True;
      Item.Current_State := Client_Waiting_Authentication;
      Result.Status := Succeeded;
      Result.Consumed := Parsed.Consumed;
   exception
      when Crypto_OpenSSL.Crypto_Error =>
         Result.Status := Crypto_Failed;
         Mark_Failed (Item);
   end Accept_Server_Hello;

   procedure Accept_Server_Authentication
     (Item            : in out Session;
      Input           : Ada.Streams.Stream_Element_Array;
      Client_Finished : out Ada.Streams.Stream_Element_Array;
      Result          : out Operation_Result)
   is
      Position : Natural := 0;
      Before   : Natural;
      Hello    : TLS_Handshake_Policy.Parse_Result;
      Auth     : TLS_Authentication_Policy.Parse_Result;
      Status   : Operation_Status;
      Hash     : TLS_Key_Schedule.Transcript_Hash;
      Signature_Input : TLS_Signature_Policy.Signature_Input;
      Signature : Crypto_OpenSSL.Ed25519_Signature;
      Verified  : Boolean;
      Expected  : TLS_Key_Schedule.Secret;
      Finished  : TLS_Authentication_Policy.Encode_Result;
      Resumption : TLS_Key_Schedule.Secret;
      Leaf_Start : Ada.Streams.Stream_Element_Offset;
      Signature_Start : Ada.Streams.Stream_Element_Offset;
      Verify_Start : Ada.Streams.Stream_Element_Offset;
   begin
      Client_Finished := (others => 0);
      Result := (others => <>);
      if Item.Current_State /= Client_Waiting_Authentication then
         return;
      end if;

      Hello := TLS_Handshake_Policy.Parse (Input);
      if Hello.Status /= TLS_Handshake_Policy.Parsed
        or else Hello.Kind /= TLS_Handshake_Policy.Encrypted_Extensions
      then
         Result.Status :=
           (if Hello.Status = TLS_Handshake_Policy.Invalid_Extensions
            then Invalid_Extensions else Invalid_Message);
         Mark_Failed (Item);
         return;
      end if;
      Status :=
        Validate_Extensions
          (Item,
           Input
             (Input'First
                .. Input'First
                     + Ada.Streams.Stream_Element_Offset (Hello.Consumed - 1)),
           Hello, Transport_Parameter_Policy.Server);
      if Status /= Succeeded then
         Result.Status := Status;
         Mark_Failed (Item);
         return;
      end if;
      if not Append_Transcript
        (Item, Input
           (Input'First
              .. Input'First
                   + Ada.Streams.Stream_Element_Offset (Hello.Consumed - 1)))
      then
         Result.Status := Transcript_Too_Large;
         Mark_Failed (Item);
         return;
      end if;
      Position := Hello.Consumed;

      Before := Position;
      Auth :=
        TLS_Authentication_Policy.Parse
          (Input
             (Input'First + Ada.Streams.Stream_Element_Offset (Position)
                .. Input'Last));
      if Auth.Status /= TLS_Authentication_Policy.Parsed
        or else Auth.Kind /= TLS_Authentication_Policy.Certificate_Message
        or else Auth.Context_Length /= 0
        or else Auth.Certificate_Total = 0
        or else Auth.Certificates (1).Length /= Item.Certificate_Length
      then
         Result.Status := Certificate_Mismatch;
         Mark_Failed (Item);
         return;
      end if;
      Leaf_Start :=
        Input'First + Ada.Streams.Stream_Element_Offset
          (Before + Auth.Certificates (1).Offset);
      if Input
        (Leaf_Start
           .. Leaf_Start
                + Ada.Streams.Stream_Element_Offset
                    (Item.Certificate_Length - 1)) /=
          Item.Certificate
            (1 .. Ada.Streams.Stream_Element_Offset (Item.Certificate_Length))
      then
         Result.Status := Certificate_Mismatch;
         Mark_Failed (Item);
         return;
      end if;
      if not Append_Transcript
        (Item, Input
           (Input'First + Ada.Streams.Stream_Element_Offset (Before)
              .. Input'First + Ada.Streams.Stream_Element_Offset
                   (Before + Auth.Consumed - 1)))
      then
         Result.Status := Transcript_Too_Large;
         Mark_Failed (Item);
         return;
      end if;
      Position := Position + Auth.Consumed;

      Before := Position;
      Auth :=
        TLS_Authentication_Policy.Parse
          (Input
             (Input'First + Ada.Streams.Stream_Element_Offset (Position)
                .. Input'Last));
      if Auth.Status /= TLS_Authentication_Policy.Parsed
        or else Auth.Kind /=
          TLS_Authentication_Policy.Certificate_Verify_Message
        or else Auth.Scheme /= TLS_Authentication_Policy.ED25519
        or else Auth.Signature_Length /= 64
      then
         Result.Status := Signature_Failed;
         Mark_Failed (Item);
         return;
      end if;
      Hash_Transcript (Item, Hash);
      Signature_Input :=
        TLS_Signature_Policy.Build
          (TLS_Signature_Policy.Server,
           TLS_Signature_Policy.Transcript_Hash'(Hash));
      Signature_Start :=
        Input'First + Ada.Streams.Stream_Element_Offset
          (Before + Auth.Signature_Offset);
      Signature := Input (Signature_Start .. Signature_Start + 63);
      Crypto_OpenSSL.Ed25519_Verify_Certificate
        (Item.Backend,
         Item.Certificate
           (1 .. Ada.Streams.Stream_Element_Offset (Item.Certificate_Length)),
         Signature_Input, Signature, Verified);
      if not Verified then
         Result.Status := Signature_Failed;
         Mark_Failed (Item);
         return;
      end if;
      if not Append_Transcript
        (Item, Input
           (Input'First + Ada.Streams.Stream_Element_Offset (Before)
              .. Input'First + Ada.Streams.Stream_Element_Offset
                   (Before + Auth.Consumed - 1)))
      then
         Result.Status := Transcript_Too_Large;
         Mark_Failed (Item);
         return;
      end if;
      Position := Position + Auth.Consumed;

      Before := Position;
      Auth :=
        TLS_Authentication_Policy.Parse
          (Input
             (Input'First + Ada.Streams.Stream_Element_Offset (Position)
                .. Input'Last));
      if Auth.Status /= TLS_Authentication_Policy.Parsed
        or else Auth.Kind /= TLS_Authentication_Policy.Finished_Message
      then
         Result.Status := Finished_Failed;
         Mark_Failed (Item);
         return;
      end if;
      Hash_Transcript (Item, Hash);
      TLS_Key_Schedule.Finished_Verify_Data
        (Item.Backend, Item.Handshake_Secrets.Server_Finished, Hash, Expected);
      Verify_Start :=
        Input'First + Ada.Streams.Stream_Element_Offset
          (Before + Auth.Verify_Offset);
      if not Secure_Equal
        (Expected, Input (Verify_Start .. Verify_Start + 31))
      then
         Result.Status := Finished_Failed;
         Mark_Failed (Item);
         return;
      end if;
      if not Append_Transcript
        (Item, Input
           (Input'First + Ada.Streams.Stream_Element_Offset (Before)
              .. Input'First + Ada.Streams.Stream_Element_Offset
                   (Before + Auth.Consumed - 1)))
      then
         Result.Status := Transcript_Too_Large;
         Mark_Failed (Item);
         return;
      end if;
      Position := Position + Auth.Consumed;

      Hash_Transcript (Item, Hash);
      TLS_Key_Schedule.Derive_Application
        (Item.Backend, Item.Handshake_Secrets, Hash,
         Item.Application_Secrets);
      TLS_Key_Schedule.Derive_QUIC_Keys
        (Item.Backend, Item.Application_Secrets.Client_Traffic,
         Item.Client_Application_Keys);
      TLS_Key_Schedule.Derive_QUIC_Keys
        (Item.Backend, Item.Application_Secrets.Server_Traffic,
         Item.Server_Application_Keys);

      TLS_Key_Schedule.Finished_Verify_Data
        (Item.Backend, Item.Handshake_Secrets.Client_Finished, Hash, Expected);
      Finished :=
        TLS_Authentication_Policy.Encode_Finished
          (TLS_Authentication_Policy.Verify_Data'(Expected));
      Client_Finished
        (Client_Finished'First
           .. Client_Finished'First
                + Ada.Streams.Stream_Element_Offset (Finished.Length - 1)) :=
          Finished.Data
            (1 .. Ada.Streams.Stream_Element_Offset (Finished.Length));
      if not Append_Transcript
        (Item, Finished.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Finished.Length)))
      then
         Result.Status := Transcript_Too_Large;
         Mark_Failed (Item);
         return;
      end if;
      Hash_Transcript (Item, Hash);
      TLS_Key_Schedule.Derive_Resumption
        (Item.Backend, Item.Handshake_Secrets, Hash, Resumption);
      TLS_Key_Schedule.Clear (Resumption);
      Item.X25519_Private := (others => 0);
      Item.Current_State := Connected;
      Result.Status := Succeeded;
      Result.Consumed := Position;
      Result.Output_Length := Finished.Length;
   exception
      when Crypto_OpenSSL.Crypto_Error =>
         Result.Status := Crypto_Failed;
         Mark_Failed (Item);
   end Accept_Server_Authentication;

   procedure Accept_Client_Finished
     (Item   : in out Session;
      Input  : Ada.Streams.Stream_Element_Array;
      Result : out Operation_Result)
   is
      Parsed : TLS_Authentication_Policy.Parse_Result;
      Hash   : TLS_Key_Schedule.Transcript_Hash;
      Expected : TLS_Key_Schedule.Secret;
      Resumption : TLS_Key_Schedule.Secret;
      Verify_Start : Ada.Streams.Stream_Element_Offset;
   begin
      Result := (others => <>);
      if Item.Current_State /= Server_Waiting_Finished then
         return;
      end if;
      Parsed := TLS_Authentication_Policy.Parse (Input);
      if Parsed.Status /= TLS_Authentication_Policy.Parsed
        or else Parsed.Kind /= TLS_Authentication_Policy.Finished_Message
      then
         Result.Status := Finished_Failed;
         Mark_Failed (Item);
         return;
      end if;
      Hash_Transcript (Item, Hash);
      TLS_Key_Schedule.Finished_Verify_Data
        (Item.Backend, Item.Handshake_Secrets.Client_Finished, Hash, Expected);
      Verify_Start :=
        Input'First
          + Ada.Streams.Stream_Element_Offset (Parsed.Verify_Offset);
      if not Secure_Equal
        (Expected, Input (Verify_Start .. Verify_Start + 31))
      then
         Result.Status := Finished_Failed;
         Mark_Failed (Item);
         return;
      end if;
      if not Append_Transcript
        (Item, Input
           (Input'First
              .. Input'First
                   + Ada.Streams.Stream_Element_Offset (Parsed.Consumed - 1)))
      then
         Result.Status := Transcript_Too_Large;
         Mark_Failed (Item);
         return;
      end if;
      Hash_Transcript (Item, Hash);
      TLS_Key_Schedule.Derive_Resumption
        (Item.Backend, Item.Handshake_Secrets, Hash, Resumption);
      TLS_Key_Schedule.Clear (Resumption);
      Item.X25519_Private := (others => 0);
      Item.Signing_Key := (others => 0);
      Item.Current_State := Connected;
      Result.Status := Succeeded;
      Result.Consumed := Parsed.Consumed;
   exception
      when Crypto_OpenSSL.Crypto_Error =>
         Result.Status := Crypto_Failed;
         Mark_Failed (Item);
   end Accept_Client_Finished;

   procedure Get_Handshake_Keys
     (Item      : Session;
      Sending   : out TLS_Key_Schedule.QUIC_Traffic_Keys;
      Receiving : out TLS_Key_Schedule.QUIC_Traffic_Keys)
   is
   begin
      if Item.Role = Client then
         Sending := Item.Client_Handshake_Keys;
         Receiving := Item.Server_Handshake_Keys;
      else
         Sending := Item.Server_Handshake_Keys;
         Receiving := Item.Client_Handshake_Keys;
      end if;
   end Get_Handshake_Keys;

   procedure Get_Application_Keys
     (Item      : Session;
      Sending   : out TLS_Key_Schedule.QUIC_Traffic_Keys;
      Receiving : out TLS_Key_Schedule.QUIC_Traffic_Keys)
   is
   begin
      if Item.Role = Client then
         Sending := Item.Client_Application_Keys;
         Receiving := Item.Server_Application_Keys;
      else
         Sending := Item.Server_Application_Keys;
         Receiving := Item.Client_Application_Keys;
      end if;
   end Get_Application_Keys;

   function Peer_Parameters
     (Item : Session) return Transport_Parameter_Policy.Transport_Parameters is
     (Item.Peer_Transport);
end Flyology.QUIC.TLS_Session;
