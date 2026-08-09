with Ada.Finalization;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Flyology.QUIC.Connections;

--  Generates temporary self-signed credentials for local HTTP development.
--  TLS/TCP uses a broadly compatible RSA certificate while the current QUIC
--  profile uses Ed25519. This package invokes the OpenSSL command-line tool;
--  it does not provide or replace production certificate management.
package Flyology.HTTP.Server.Development_Certificates is

   --  Owns generated credential files and removes them during finalization.
   --  The object is limited so private-key ownership cannot be copied.
   type Identity is limited private;

   --  Generate self-signed RSA and Ed25519 credentials for localhost and
   --  127.0.0.1. Existing credentials owned by Item are discarded first.
   --  An empty OpenSSL_Command selects FLYOLOGY_HTTP_OPENSSL, a conventional
   --  OpenSSL 3 installation, or the first openssl command on PATH.
   --  @param Item Credential owner to initialize
   --  @param OpenSSL_Command Optional path to an OpenSSL command with Ed25519
   --    support
   --  @exception Program_Error OpenSSL is unavailable or generation fails
   procedure Generate
     (Item            : in out Identity;
      OpenSSL_Command : String := "");

   --  Report whether Item currently owns generated credential files.
   --  @param Item Credential owner to inspect
   --  @return True after successful Generate and before Discard
   function Is_Generated (Item : Identity) return Boolean;

   --  Return the PEM certificate path for a TLS/TCP server provider.
   --  @param Item Generated credential owner
   --  @return Path to the self-signed RSA certificate
   function TLS_Certificate_File (Item : Identity) return String
   with Pre => Is_Generated (Item);

   --  Return the PEM private-key path for a TLS/TCP server provider.
   --  @param Item Generated credential owner
   --  @return Path to the RSA private key
   function TLS_Private_Key_File (Item : Identity) return String
   with Pre => Is_Generated (Item);

   --  Read the DER-encoded certificate required by the QUIC server profile.
   --  @param Item Generated credential owner
   --  @return Self-signed Ed25519 certificate covering localhost and
   --    127.0.0.1
   function QUIC_Certificate_DER
     (Item : Identity) return Ada.Streams.Stream_Element_Array
   with Pre => Is_Generated (Item);

   --  Read the raw private key required by the QUIC server profile.
   --  @param Item Generated credential owner
   --  @return Raw 32-byte Ed25519 private key
   function QUIC_Private_Key
     (Item : Identity)
      return Flyology.QUIC.Connections.Ed25519_Private_Key
   with Pre => Is_Generated (Item);

   --  Remove all generated files. Calling Discard repeatedly is harmless.
   --  TLS providers must load the PEM paths and callers must read the QUIC
   --  values before discarding Item.
   --  @param Item Credential owner to clear
   procedure Discard (Item : in out Identity);

private
   type Identity is new Ada.Finalization.Limited_Controlled with record
      Directory             : Ada.Strings.Unbounded.Unbounded_String;
      TLS_Certificate_Path  : Ada.Strings.Unbounded.Unbounded_String;
      TLS_Private_Key_Path  : Ada.Strings.Unbounded.Unbounded_String;
      QUIC_Certificate_Path : Ada.Strings.Unbounded.Unbounded_String;
      QUIC_Private_Key_Path : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Remove credentials that remain when their owner leaves scope.
   --  @param Item Credential owner being finalized
   overriding procedure Finalize (Item : in out Identity);
end Flyology.HTTP.Server.Development_Certificates;
