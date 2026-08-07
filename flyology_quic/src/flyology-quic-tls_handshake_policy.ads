with Ada.Streams;
with Flyology.QUIC.TLS_Extension_Policy;

--  Internal, proved framing policy for QUIC's TLS 1.3 hello messages.
--
--  Parsing consumes one handshake message from a CRYPTO-stream prefix. All
--  reported ranges borrow from the input and use zero-based offsets.
private package Flyology.QUIC.TLS_Handshake_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type TLS_Extension_Policy.Parse_Status;

   subtype Handshake_Offset is Natural range 0 .. 65_535;

   type Message_Kind is
     (Client_Hello,
      Server_Hello,
      Encrypted_Extensions);

   type Parse_Status is
     (Parsed,
      Need_More_Data,
      Unsupported_Message,
      Invalid_Handshake,
      Invalid_Extensions);

   type Parse_Result is record
      Status            : Parse_Status := Need_More_Data;
      Kind              : Message_Kind := Client_Hello;
      Consumed          : Handshake_Offset := 0;
      Random_Offset     : Handshake_Offset := 0;
      Session_ID_Offset : Handshake_Offset := 0;
      Session_ID_Length : Natural range 0 .. 32 := 0;
      Extensions_Offset : Handshake_Offset := 0;
      Extensions_Length : Handshake_Offset := 0;
      Extensions        : TLS_Extension_Policy.Parse_Result;
   end record;

   function Parse
     (Data : Ada.Streams.Stream_Element_Array) return Parse_Result
   with
     Global => null,
     Pre => Data'Length <= 65_535,
     Post =>
       (if Parse'Result.Status = Parsed then
           Parse'Result.Extensions.Status =
             TLS_Extension_Policy.Parsed);

   subtype Hello_Random is Ada.Streams.Stream_Element_Array (1 .. 32);
   subtype Session_ID_Length is Natural range 0 .. 32;
   type Session_ID is record
      Data   : Ada.Streams.Stream_Element_Array (1 .. 32) := (others => 0);
      Length : Session_ID_Length := 0;
   end record;

   Max_Encoded_Handshake : constant := 1_200;
   type Encode_Status is (Encoded, Extension_Encoding_Failed);
   type Encode_Result is record
      Status : Encode_Status := Extension_Encoding_Failed;
      Data   : Ada.Streams.Stream_Element_Array
        (1 .. Max_Encoded_Handshake) := (others => 0);
      Length : Natural range 0 .. Max_Encoded_Handshake := 0;
   end record;

   function Encode_Client_Hello
     (Random               : Hello_Random;
      Key                  : TLS_Extension_Policy.X25519_Public_Key;
      ALPN                 : Ada.Streams.Stream_Element_Array;
      Transport_Parameters : Ada.Streams.Stream_Element_Array)
      return Encode_Result
   with
     Global => null,
     Pre => ALPN'Length in 1 .. 255
       and then Transport_Parameters'Length <= 512;

   function Encode_Server_Hello
     (Random  : Hello_Random;
      Session : Session_ID;
      Key     : TLS_Extension_Policy.X25519_Public_Key) return Encode_Result
   with Global => null;

   function Encode_Encrypted_Extensions
     (ALPN                 : Ada.Streams.Stream_Element_Array;
      Transport_Parameters : Ada.Streams.Stream_Element_Array)
      return Encode_Result
   with
     Global => null,
     Pre => ALPN'Length in 1 .. 255
       and then Transport_Parameters'Length <= 512;
end Flyology.QUIC.TLS_Handshake_Policy;
