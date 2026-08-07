with Ada.Streams;

--  Internal, proved construction of the TLS 1.3 CertificateVerify input.
--  Cryptographic signing and certificate validation remain outside this unit.
private package Flyology.QUIC.TLS_Signature_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   type Endpoint_Role is (Client, Server);
   subtype Transcript_Hash is Ada.Streams.Stream_Element_Array (1 .. 32);
   subtype Signature_Input is Ada.Streams.Stream_Element_Array (1 .. 130);

   function Build
     (Role       : Endpoint_Role;
      Transcript : Transcript_Hash) return Signature_Input
   with Global => null;
end Flyology.QUIC.TLS_Signature_Policy;
