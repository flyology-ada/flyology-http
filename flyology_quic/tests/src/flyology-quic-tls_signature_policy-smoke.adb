procedure Flyology.QUIC.TLS_Signature_Policy.Smoke is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Array;

   Transcript : Transcript_Hash;
   Server_Input : Signature_Input;
   Client_Input : Signature_Input;
   Server_Context : constant String :=
     "TLS 1.3, server CertificateVerify";
   Client_Context : constant String :=
     "TLS 1.3, client CertificateVerify";
begin
   for Index in Transcript'Range loop
      Transcript (Index) :=
        Ada.Streams.Stream_Element
          (Natural (Index) - Natural (Transcript'First));
   end loop;
   Server_Input := Build (Server, Transcript);
   Client_Input := Build (Client, Transcript);

   for Index in Ada.Streams.Stream_Element_Offset range 1 .. 64 loop
      pragma Assert
        (Server_Input (Index) = 16#20#
         and then Client_Input (Index) = 16#20#);
   end loop;
   for Index in Server_Context'Range loop
      pragma Assert
        (Server_Input
           (Ada.Streams.Stream_Element_Offset
              (65 + Index - Server_Context'First)) =
           Ada.Streams.Stream_Element (Character'Pos (Server_Context (Index))));
      pragma Assert
        (Client_Input
           (Ada.Streams.Stream_Element_Offset
              (65 + Index - Client_Context'First)) =
           Ada.Streams.Stream_Element (Character'Pos (Client_Context (Index))));
   end loop;
   pragma Assert (Server_Input (98) = 0 and then Client_Input (98) = 0);
   pragma Assert
     (Server_Input (99 .. 130) = Transcript
      and then Client_Input (99 .. 130) = Transcript);
end Flyology.QUIC.TLS_Signature_Policy.Smoke;
