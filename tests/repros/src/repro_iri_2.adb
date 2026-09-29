--  IRI-2: the IPv4-in-IPv6 tail accepts leading zeros the WHATWG IPv6 parser
--  rejects.
--
--  Asserts the CORRECT behaviour.  WHATWG URL Standard, IPv6 parser:
--  "If ipv4Piece is 0, IPv4-in-IPv6-invalid-code-point validation error,
--  return failure."

with Ada.Exceptions;
with Flyology_IRI;
with Repro_Support;

procedure Repro_IRI_2 is
   use Flyology_IRI;
   use Repro_Support;

   procedure Must_Reject (Input : String) is
   begin
      if Can_Parse (Input, Web_URL_Syntax) then
         Check (False, Input & " accepted, normalized to host ["
                & Host (Parse (Input, Web_URL_Syntax)) & "]");
      else
         Check (True, Input & " rejected");
      end if;
   end Must_Reject;

   procedure Must_Accept (Input, Expected_Host : String) is
   begin
      if Can_Parse (Input, Web_URL_Syntax) then
         Expect_Equal (Host (Parse (Input, Web_URL_Syntax)), Expected_Host,
                       Input & " host");
      else
         Check (False, Input & " wrongly rejected");
      end if;
   end Must_Accept;

begin
   Note ("a leading zero anywhere in the dotted tail must fail");
   Must_Reject ("http://[::01.2.3.4]/");
   Must_Reject ("http://[::1.2.3.04]/");
   Must_Reject ("http://[::0255.1.1.1]/");
   Must_Reject ("http://[::00.0.0.0]/");
   Must_Reject ("http://[::0127.0.0.1]/");
   Must_Reject ("http://[::ffff:01.2.3.4]/");

   --  Host is documented (flyology_iri.ads:249) as the host WITHOUT the
   --  IPv6 brackets, so these expectations are bracketless.
   Note ("a single zero piece is legal and must still be accepted");
   Must_Accept ("http://[::0.0.0.0]/", "::");
   Must_Accept ("http://[::1.2.3.4]/", "::102:304");
   Must_Accept ("http://[::127.0.0.1]/", "::7f00:1");

   Note ("the RFC 3986 path already rejects the same shape, so the two"
         & " syntaxes disagree");
   Check (not Can_Parse ("http://[::01.2.3.4]/", URI_Syntax),
          "URI_Syntax rejects [::01.2.3.4]");

   Finish;
exception
   when E : others =>
      Note ("unexpected exception: "
            & Ada.Exceptions.Exception_Information (E));
      Check (False, "spike raised");
      Finish;
end Repro_IRI_2;
