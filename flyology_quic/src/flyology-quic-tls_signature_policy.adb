package body Flyology.QUIC.TLS_Signature_Policy
  with SPARK_Mode => On
is
   function Build
     (Role       : Endpoint_Role;
      Transcript : Transcript_Hash) return Signature_Input
   is
      Context : constant String :=
        (if Role = Server
         then "TLS 1.3, server CertificateVerify"
         else "TLS 1.3, client CertificateVerify");
      Result  : Signature_Input := (others => 16#20#);
   begin
      for Index in Context'Range loop
         Result
           (Ada.Streams.Stream_Element_Offset (65 + Index - Context'First)) :=
             Ada.Streams.Stream_Element (Character'Pos (Context (Index)));
      end loop;
      Result (98) := 0;
      Result (99 .. 130) := Transcript;
      return Result;
   end Build;
end Flyology.QUIC.TLS_Signature_Policy;
