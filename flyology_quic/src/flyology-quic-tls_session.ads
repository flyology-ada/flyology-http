with Ada.Streams;
with Flyology.QUIC.Crypto_OpenSSL;
with Flyology.QUIC.TLS_Key_Schedule;
with Flyology.QUIC.Transport_Parameter_Policy;

--  Internal Ada-owned TLS 1.3 handshake state for QUIC v1.
--
--  The first authentication profile uses an Ed25519 leaf certificate pinned
--  by exact DER. General trust-store and endpoint-name policy will layer on
--  the same authenticated transcript after the transport handshake works.
private package Flyology.QUIC.TLS_Session is
   type Endpoint_Role is (Client, Server);
   type Session_State is
     (Uninitialized,
      Client_Ready,
      Client_Waiting_Server_Hello,
      Client_Waiting_Authentication,
      Server_Waiting_Client_Hello,
      Server_Waiting_Finished,
      Connected,
      Failed);

   type Operation_Status is
     (Succeeded,
      Invalid_State,
      Invalid_Message,
      Invalid_Extensions,
      Invalid_Transport_Parameters,
      ALPN_Mismatch,
      Certificate_Mismatch,
      Signature_Failed,
      Finished_Failed,
      Encoding_Failed,
      Transcript_Too_Large,
      Crypto_Failed);

   type Operation_Result is record
      Status        : Operation_Status := Invalid_State;
      Consumed      : Natural range 0 .. 65_535 := 0;
      Output_Length : Natural range 0 .. 65_535 := 0;
   end record;

   type Server_Flight_Result is record
      Status                  : Operation_Status := Invalid_State;
      Consumed                : Natural range 0 .. 65_535 := 0;
      Server_Hello_Length     : Natural range 0 .. 1_200 := 0;
      Authentication_Length   : Natural range 0 .. 18_000 := 0;
   end record;

   Max_Certificate_DER       : constant := 16_000;
   Max_Server_Hello          : constant := 1_200;
   Max_Server_Authentication : constant := 18_000;
   Max_Client_Finished       : constant := 36;

   type Session is limited private;

   function State (Item : Session) return Session_State;
   function Is_Initialized (Item : Session) return Boolean;
   function Is_Connected (Item : Session) return Boolean;
   function Has_Handshake_Keys (Item : Session) return Boolean;
   function Has_Peer_Parameters (Item : Session) return Boolean;

   procedure Initialize_Client
     (Item                 : in out Session;
      ALPN                 : Ada.Streams.Stream_Element_Array;
      Transport_Parameters : Ada.Streams.Stream_Element_Array;
      Pinned_Certificate   : Ada.Streams.Stream_Element_Array)
   with
     Pre =>
       not Is_Initialized (Item)
       and then ALPN'Length in 1 .. 255
       and then Transport_Parameters'Length <= 512
       and then Pinned_Certificate'Length in 1 .. Max_Certificate_DER,
     Post => State (Item) = Client_Ready;

   procedure Initialize_Server
     (Item                 : in out Session;
      ALPN                 : Ada.Streams.Stream_Element_Array;
      Transport_Parameters : Ada.Streams.Stream_Element_Array;
      Certificate_DER      : Ada.Streams.Stream_Element_Array;
      Private_Key          : Crypto_OpenSSL.Ed25519_Private_Key)
   with
     Pre =>
       not Is_Initialized (Item)
       and then ALPN'Length in 1 .. 255
       and then Transport_Parameters'Length <= 512
       and then Certificate_DER'Length in 1 .. Max_Certificate_DER,
     Post => State (Item) = Server_Waiting_Client_Hello;

   procedure Start_Client
     (Item   : in out Session;
      Output : out Ada.Streams.Stream_Element_Array;
      Result : out Operation_Result)
   with Pre => Output'Length >= 1_200;

   procedure Accept_Client_Hello
     (Item                   : in out Session;
      Input                  : Ada.Streams.Stream_Element_Array;
      Server_Hello           : out Ada.Streams.Stream_Element_Array;
      Authentication_Flight  : out Ada.Streams.Stream_Element_Array;
      Result                 : out Server_Flight_Result)
   with
     Pre =>
       Input'Length <= 65_535
       and then Server_Hello'Length >= Max_Server_Hello
       and then Authentication_Flight'Length >= Max_Server_Authentication;

   procedure Accept_Server_Hello
     (Item   : in out Session;
      Input  : Ada.Streams.Stream_Element_Array;
      Result : out Operation_Result)
   with Pre => Input'Length <= 65_535;

   procedure Accept_Server_Authentication
     (Item            : in out Session;
      Input           : Ada.Streams.Stream_Element_Array;
      Client_Finished : out Ada.Streams.Stream_Element_Array;
      Result          : out Operation_Result)
   with
     Pre =>
       Input'Length <= 65_535
       and then Client_Finished'Length >= Max_Client_Finished;

   procedure Accept_Client_Finished
     (Item   : in out Session;
      Input  : Ada.Streams.Stream_Element_Array;
      Result : out Operation_Result)
   with Pre => Input'Length <= 65_535;

   procedure Get_Handshake_Keys
     (Item    : Session;
      Sending : out TLS_Key_Schedule.QUIC_Traffic_Keys;
      Receiving : out TLS_Key_Schedule.QUIC_Traffic_Keys)
   with Pre => Has_Handshake_Keys (Item);

   procedure Get_Application_Keys
     (Item    : Session;
      Sending : out TLS_Key_Schedule.QUIC_Traffic_Keys;
      Receiving : out TLS_Key_Schedule.QUIC_Traffic_Keys)
   with Pre => Is_Connected (Item);

   function Peer_Parameters
     (Item : Session) return Transport_Parameter_Policy.Transport_Parameters
   with Pre => Has_Peer_Parameters (Item);
private
   Max_Transcript : constant := 65_535;

   type Session is limited record
      Backend : Crypto_OpenSSL.Provider;
      Current_State : Session_State := Uninitialized;
      Role          : Endpoint_Role := Client;
      Transcript : Ada.Streams.Stream_Element_Array (1 .. Max_Transcript) :=
        (others => 0);
      Transcript_Length : Natural range 0 .. Max_Transcript := 0;
      ALPN : Ada.Streams.Stream_Element_Array (1 .. 255) := (others => 0);
      ALPN_Length : Natural range 0 .. 255 := 0;
      Local_Transport : Ada.Streams.Stream_Element_Array (1 .. 512) :=
        (others => 0);
      Local_Transport_Length : Natural range 0 .. 512 := 0;
      Certificate : Ada.Streams.Stream_Element_Array
        (1 .. Max_Certificate_DER) := (others => 0);
      Certificate_Length : Natural range 0 .. Max_Certificate_DER := 0;
      Signing_Key : Crypto_OpenSSL.Ed25519_Private_Key := (others => 0);
      X25519_Private : Crypto_OpenSSL.X25519_Private_Key := (others => 0);
      X25519_Public  : Crypto_OpenSSL.X25519_Public_Key := (others => 0);
      Handshake_Secrets : TLS_Key_Schedule.Handshake_Secrets;
      Application_Secrets : TLS_Key_Schedule.Application_Secrets;
      Client_Handshake_Keys : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Server_Handshake_Keys : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Client_Application_Keys : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Server_Application_Keys : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Handshake_Keys_Ready : Boolean := False;
      Peer_Transport : Transport_Parameter_Policy.Transport_Parameters;
      Peer_Transport_Ready : Boolean := False;
   end record;
end Flyology.QUIC.TLS_Session;
