with Ada.Directories;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Flyology.HTTP.Server.Development_Certificates;
with Flyology.QUIC.Connections;

procedure Development_Certificates_Smoke is
   package Certificates renames
     Flyology.HTTP.Server.Development_Certificates;
   package Unbounded renames Ada.Strings.Unbounded;

   use type Ada.Streams.Stream_Element;

   Item : Certificates.Identity;
begin
   pragma Assert (not Certificates.Is_Generated (Item));
   Certificates.Generate (Item);
   pragma Assert (Certificates.Is_Generated (Item));

   declare
      First_TLS_Certificate : constant String :=
        Certificates.TLS_Certificate_File (Item);
      First_TLS_Key : constant String :=
        Certificates.TLS_Private_Key_File (Item);
      QUIC_Certificate : constant Ada.Streams.Stream_Element_Array :=
        Certificates.QUIC_Certificate_DER (Item);
      QUIC_Key : constant Flyology.QUIC.Connections.Ed25519_Private_Key :=
        Certificates.QUIC_Private_Key (Item);
      Nonzero_Key_Byte : Boolean := False;
   begin
      pragma Assert (Ada.Directories.Exists (First_TLS_Certificate));
      pragma Assert (Ada.Directories.Exists (First_TLS_Key));
      pragma Assert (QUIC_Certificate'Length in 1 .. 4_096);
      for Byte of QUIC_Key loop
         Nonzero_Key_Byte := Nonzero_Key_Byte or else Byte /= 0;
      end loop;
      pragma Assert (Nonzero_Key_Byte);

      Certificates.Generate (Item);
      pragma Assert (not Ada.Directories.Exists (First_TLS_Certificate));
      pragma Assert (not Ada.Directories.Exists (First_TLS_Key));
   end;

   declare
      TLS_Certificate : constant String :=
        Certificates.TLS_Certificate_File (Item);
   begin
      Certificates.Discard (Item);
      pragma Assert (not Certificates.Is_Generated (Item));
      pragma Assert (not Ada.Directories.Exists (TLS_Certificate));
      Certificates.Discard (Item);
   end;

   declare
      Finalized_Certificate : Unbounded.Unbounded_String;
   begin
      declare
         Temporary : Certificates.Identity;
      begin
         Certificates.Generate (Temporary);
         Finalized_Certificate := Unbounded.To_Unbounded_String
           (Certificates.TLS_Certificate_File (Temporary));
      end;
      pragma Assert
        (not Ada.Directories.Exists
           (Unbounded.To_String (Finalized_Certificate)));
   end;
end Development_Certificates_Smoke;
