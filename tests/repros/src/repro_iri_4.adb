--  IRI-4: Resolve recomposes a "//"-prefixed path that has no authority into
--  an authority, and rewrites a WHATWG opaque path under a web base.
--
--  Asserts the CORRECT behaviour: the resolved reference's components must
--  agree with RFC 3986 section 5.2.2 (T.authority stays undefined when
--  neither the relative reference nor the applicable base supplies one) and,
--  for a web base, with what Parse gives for the same absolute reference.

with Ada.Exceptions;
with Flyology_IRI;
with Repro_Support;

procedure Repro_IRI_4 is
   use Flyology_IRI;
   use Repro_Support;

   procedure Show (Label : String; R : Reference) is
   begin
      Note (Label & ": image=[" & Image (R) & "] has_authority="
            & Boolean'Image (Has_Authority (R))
            & " host=[" & Host (R) & "] path=[" & Path (R) & "]");
   end Show;

begin
   --  1. Web base, non-special absolute reference with a "/.//"  path.
   declare
      Web_Base : constant Reference := Parse ("http://base/", Web_URL_Syntax);
      Direct   : constant Reference := Parse ("sc:/.//p", Web_URL_Syntax);
      Resolved : constant Reference := Resolve (Web_Base, "sc:/.//p");
   begin
      Show ("Parse  (sc:/.//p)", Direct);
      Show ("Resolve(sc:/.//p)", Resolved);
      Check (not Has_Authority (Resolved),
             "Resolve (http://base/, ""sc:/.//p"") must have no authority");
      Expect_Equal (Host (Resolved), "",
                    "resolved host for sc:/.//p");
      Expect_Equal (Image (Resolved), Image (Direct),
                    "Resolve of an absolute reference must equal Parse of it");
   end;

   --  2. Web base, absolute reference with a WHATWG opaque path.
   declare
      Web_Base : constant Reference := Parse ("http://base/", Web_URL_Syntax);
      Direct   : constant Reference := Parse ("mailto:a/../b", Web_URL_Syntax);
      Resolved : constant Reference := Resolve (Web_Base, "mailto:a/../b");
   begin
      Show ("Parse  (mailto:a/../b)", Direct);
      Show ("Resolve(mailto:a/../b)", Resolved);
      Expect_Equal (Image (Resolved), Image (Direct),
                    "an opaque path must not be dot-reduced by Resolve");
   end;

   --  3. URI base with a scheme but no authority; the relative reference
   --     carries neither a scheme nor an authority.  RFC 3986 section 5.2.2
   --     leaves T.authority undefined and gives T.path = "//p".
   declare
      URI_Base : constant Reference := Parse ("sc:/a/b", URI_Syntax);
      Resolved : constant Reference := Resolve (URI_Base, "..//p");
   begin
      Show ("Resolve(sc:/a/b, ..//p)", Resolved);
      Check (not Has_Authority (Resolved),
             "Resolve (sc:/a/b, ""..//p"") must have no authority");
      Expect_Equal (Host (Resolved), "", "resolved host for ..//p");
   end;

   --  4. The same shape with an authority-less file: base, which is the
   --     realistic form of case 3.
   declare
      File_Base : constant Reference := Parse ("file:/etc/x", URI_Syntax);
      Resolved  : constant Reference := Resolve (File_Base, "..//evil.com");
   begin
      Show ("Resolve(file:/etc/x, ..//evil.com)", Resolved);
      Check (not Has_Authority (Resolved),
             "Resolve (file:/etc/x, ""..//evil.com"") must have no authority");
      Expect_Equal (Host (Resolved), "", "resolved host for ..//evil.com");
   end;

   --  5. Reachability: with "/.//" the base's path depth does not matter, so
   --     an ordinary authority-less file: URI is enough.
   declare
      File_Base : constant Reference :=
        Parse ("file:/var/www/index.html", URI_Syntax);
      Resolved  : constant Reference := Resolve (File_Base, "/.//evil.com");
   begin
      Show ("Resolve(file:/var/www/index.html, /.//evil.com)", Resolved);
      Check (not Has_Authority (Resolved),
             "Resolve (file:/var/www/index.html, ""/.//evil.com"") must have"
             & " no authority");
      Expect_Equal (Host (Resolved), "", "resolved host for /.//evil.com");
   end;

   --  6. Controls that must already PASS.  A base that carries an authority
   --     is safe in every shape, because the emitted "//authority" makes the
   --     recomposition unambiguous; that is why the prior audit's finding-1
   --     regression suite, which uses authority-bearing bases throughout,
   --     cannot see this.
   Note ("controls: shapes that must resolve correctly");
   declare
      Web  : constant Reference := Parse ("http://good.com/a/b", URI_Syntax);
      R1   : constant Reference := Resolve (Web, "/.//evil.com");
      R2   : constant Reference := Resolve (Web, "..//evil.com");
   begin
      Show ("Resolve(http://good.com/a/b, /.//evil.com)", R1);
      Expect_Equal (Host (R1), "good.com",
                    "authority-bearing base keeps its host (/.//)");
      Expect_Equal (Host (R2), "good.com",
                    "authority-bearing base keeps its host (..//)");
   end;
   declare
      --  A network-path reference legitimately supplies the authority, so
      --  RFC 3986 section 5.2.2 gives T.authority = R.authority here.
      File_Base : constant Reference := Parse ("file:/a/b", URI_Syntax);
      R3        : constant Reference := Resolve (File_Base, "//evil.com");
   begin
      Show ("Resolve(file:/a/b, //evil.com)", R3);
      Expect_Equal (Host (R3), "evil.com",
                    "an explicit network-path reference does supply the host");
   end;

   --  7. For a fixer: the String-returning Resolve validates a URI or IRI
   --     result with Diagnose instead of building a second Reference
   --     (flyology_iri.adb:1672-1697), and the assembled bytes are a
   --     well-formed URI, so both overloads currently agree on the wrong
   --     answer.  A guard added to only one of them would break the
   --     Text = Image (Actual) assertion in Check_Resolution_Base.
   Note ("Diagnose (""sc://p"", URI_Syntax) = "
         & Error_Kind'Image (Diagnose ("sc://p", URI_Syntax).Kind)
         & "; Diagnose (""file://evil.com"", URI_Syntax) = "
         & Error_Kind'Image (Diagnose ("file://evil.com", URI_Syntax).Kind));
   declare
      File_Base : constant Reference :=
        Parse ("file:/var/www/index.html", URI_Syntax);
      Text      : constant String := Resolve (File_Base, "/.//evil.com");
   begin
      Note ("the String-returning Resolve gives [" & Text & "]");
   end;

   Finish;
exception
   when E : others =>
      Note ("unexpected exception: " & Ada.Exceptions.Exception_Information (E));
      Check (False, "spike raised");
      Finish;
end Repro_IRI_4;
