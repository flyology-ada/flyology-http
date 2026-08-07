with Ada.Streams;

--  Internal, proved TLS 1.3 extension policy for QUIC handshakes.
--
--  Data is the extension-entry sequence after the enclosing TLS two-byte
--  vector length. Reported offsets are zero-based and borrow from Data.
private package Flyology.QUIC.TLS_Extension_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   subtype Extension_Offset is Natural range 0 .. 65_535;
   subtype Extension_Count is Natural range 0 .. 128;

   type Extension_Context is
     (Client_Hello,
      Server_Hello,
      Encrypted_Extensions);

   type Parse_Status is
     (Parsed,
      Truncated,
      Too_Many_Extensions,
      Duplicate_Extension,
      Extension_Not_Allowed,
      Invalid_Extension_Value,
      Missing_Required_Extension);

   type Parse_Result is record
      Status                      : Parse_Status := Truncated;
      Count                       : Extension_Count := 0;
      Has_Supported_TLS_1_3       : Boolean := False;
      Has_X25519_Key_Share        : Boolean := False;
      Key_Share_Offset            : Extension_Offset := 0;
      Has_Compatible_Signature    : Boolean := False;
      Has_ALPN                    : Boolean := False;
      ALPN_Protocol_Offset        : Extension_Offset := 0;
      ALPN_Protocol_Length        : Natural range 0 .. 255 := 0;
      Has_Transport_Parameters    : Boolean := False;
      Transport_Parameters_Offset : Extension_Offset := 0;
      Transport_Parameters_Length : Extension_Offset := 0;
   end record;

   function Parse
     (Data    : Ada.Streams.Stream_Element_Array;
      Context : Extension_Context) return Parse_Result
   with
     Global => null,
     Pre => Data'Length <= 65_535,
     Post =>
       (if Parse'Result.Status = Parsed then
           Parse'Result.Has_Supported_TLS_1_3 =
             (Context /= Encrypted_Extensions)
           and then Parse'Result.Has_X25519_Key_Share =
             (Context /= Encrypted_Extensions)
           and then Parse'Result.Has_Compatible_Signature =
             (Context = Client_Hello)
           and then Parse'Result.Has_ALPN =
             (Context /= Server_Hello)
           and then Parse'Result.Has_Transport_Parameters =
             (Context /= Server_Hello));

   subtype X25519_Public_Key is Ada.Streams.Stream_Element_Array (1 .. 32);
   Max_Encoded_Extensions : constant := 1_024;

   type Encode_Status is (Encoded, Input_Too_Large);
   type Encode_Result is record
      Status : Encode_Status := Input_Too_Large;
      Data   : Ada.Streams.Stream_Element_Array
        (1 .. Max_Encoded_Extensions) := (others => 0);
      Length : Natural range 0 .. Max_Encoded_Extensions := 0;
   end record;

   function Encode_Client_Hello
     (Key                  : X25519_Public_Key;
      ALPN                 : Ada.Streams.Stream_Element_Array;
      Transport_Parameters : Ada.Streams.Stream_Element_Array)
      return Encode_Result
   with
     Global => null,
     Pre => ALPN'Length in 1 .. 255
       and then Transport_Parameters'Length <= 512;

   function Encode_Server_Hello
     (Key : X25519_Public_Key) return Encode_Result
   with Global => null;

   function Encode_Encrypted_Extensions
     (ALPN                 : Ada.Streams.Stream_Element_Array;
      Transport_Parameters : Ada.Streams.Stream_Element_Array)
      return Encode_Result
   with
     Global => null,
     Pre => ALPN'Length in 1 .. 255
       and then Transport_Parameters'Length <= 512;
end Flyology.QUIC.TLS_Extension_Policy;
