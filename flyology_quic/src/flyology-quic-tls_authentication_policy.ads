with Ada.Streams;

--  Internal, proved TLS 1.3 framing policy for authentication messages.
--  Certificate and signature payload ranges borrow from the input and use
--  zero-based offsets. Cryptographic validation remains outside this unit.
private package Flyology.QUIC.TLS_Authentication_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   subtype Message_Offset is Natural range 0 .. 65_535;
   subtype Certificate_Count is Natural range 0 .. 8;

   type Message_Kind is
     (Certificate_Message,
      Certificate_Verify_Message,
      Finished_Message);

   type Signature_Scheme is
     (ECDSA_SECP256R1_SHA256,
      RSA_PSS_RSAE_SHA256,
      ED25519);

   type Parse_Status is
     (Parsed,
      Need_More_Data,
      Unsupported_Message,
      Unsupported_Signature,
      Too_Many_Certificates,
      Invalid_Authentication);

   type Certificate_Descriptor is record
      Offset : Message_Offset := 0;
      Length : Message_Offset := 0;
   end record;

   type Certificate_Descriptors is
     array (Positive range 1 .. 8) of Certificate_Descriptor;

   type Parse_Result is record
      Status         : Parse_Status := Need_More_Data;
      Kind           : Message_Kind := Certificate_Message;
      Consumed       : Message_Offset := 0;
      Context_Offset : Message_Offset := 0;
      Context_Length : Natural range 0 .. 255 := 0;
      Certificates   : Certificate_Descriptors := (others => (others => 0));
      Certificate_Total : Certificate_Count := 0;
      Scheme          : Signature_Scheme := ED25519;
      Signature_Offset : Message_Offset := 0;
      Signature_Length : Message_Offset := 0;
      Verify_Offset   : Message_Offset := 0;
   end record;

   function Parse
     (Data : Ada.Streams.Stream_Element_Array) return Parse_Result
   with
     Global => null,
     Pre => Data'Length <= 65_535;

   subtype Verify_Data is Ada.Streams.Stream_Element_Array (1 .. 32);
   Max_Encoded_Authentication : constant := 16_384;

   type Encode_Status is (Encoded, Input_Too_Large);
   type Encode_Result is record
      Status : Encode_Status := Input_Too_Large;
      Data   : Ada.Streams.Stream_Element_Array
        (1 .. Max_Encoded_Authentication) := (others => 0);
      Length : Natural range 0 .. Max_Encoded_Authentication := 0;
   end record;

   function Encode_Certificate
     (Certificate : Ada.Streams.Stream_Element_Array;
      Extensions  : Ada.Streams.Stream_Element_Array) return Encode_Result
   with
     Global => null,
     Pre => Certificate'Length in 1 .. Max_Encoded_Authentication
       and then Extensions'Length <= Max_Encoded_Authentication;

   function Encode_Certificate_Verify
     (Scheme    : Signature_Scheme;
      Signature : Ada.Streams.Stream_Element_Array) return Encode_Result
   with
     Global => null,
     Pre => Signature'Length in 1 .. Max_Encoded_Authentication;

   function Encode_Finished (Verify : Verify_Data) return Encode_Result
   with Global => null;
end Flyology.QUIC.TLS_Authentication_Policy;
