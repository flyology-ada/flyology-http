with Ada.Finalization;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Flyology.QUIC.Connections;

--  Temporary self-signed identity for the HTTP/3 application showcase.
package HTTP3_Development_Identity is

   type Identity is limited private;

   --  Generate one Ed25519 localhost identity with the OpenSSL command-line
   --  tool. The PEM files support TLS/TCP; the same certificate and key are
   --  exposed in the DER and raw forms used by the current QUIC profile.
   procedure Generate (Item : in out Identity);

   --  Remove generated files after the TLS provider has loaded its PEM input.
   procedure Discard (Item : in out Identity);

   function Certificate_PEM (Item : Identity) return String;
   function Private_Key_PEM (Item : Identity) return String;

   function Certificate_DER
     (Item : Identity) return Ada.Streams.Stream_Element_Array;

   function Private_Key
     (Item : Identity)
      return Flyology.QUIC.Connections.Ed25519_Private_Key;

private
   type Identity is new Ada.Finalization.Limited_Controlled with record
      Directory        : Ada.Strings.Unbounded.Unbounded_String;
      Certificate_Path : Ada.Strings.Unbounded.Unbounded_String;
      Private_Key_Path : Ada.Strings.Unbounded.Unbounded_String;
      Certificate_DER_Path : Ada.Strings.Unbounded.Unbounded_String;
      Private_Key_DER_Path : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   overriding procedure Finalize (Item : in out Identity);
end HTTP3_Development_Identity;
