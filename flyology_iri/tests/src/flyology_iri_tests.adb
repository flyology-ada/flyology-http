with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology_IRI;
with Flyology_IRI_Differential;

procedure Flyology_IRI_Tests is
   use Flyology_IRI;

   procedure Assert (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Assert;

   procedure Reject
     (Input  : String;
      Syntax : Syntax_Kind;
      Error  : Error_Kind)
   is
      Found  : constant Parse_Error := Diagnose (Input, Syntax);
      Raised : Boolean := False;
   begin
      Assert
        (Found.Kind = Error,
         "unexpected error for " & Input & ": " & Error_Kind'Image (Found.Kind));
      begin
         declare
            Ignored : constant Reference := Parse (Input, Syntax);
         begin
            Assert (Image (Ignored)'Length > Natural'Last, "unreachable");
         end;
      exception
         when Malformed_Reference =>
            Raised := True;
      end;
      Assert (Raised, "Parse accepted " & Input);
   end Reject;

   procedure Check_Resolution (Relative, Expected : String) is
      Base   : constant Reference := Parse ("http://a/b/c/d;p?q", URI_Syntax);
   begin
      declare
         Actual : constant Reference := Resolve (Base, Relative);
         --  The serialization form validates with Diagnose instead of building
         --  this Reference, so every resolution the suite covers also asserts
         --  that the two forms cannot drift apart.
         Text   : constant String := Resolve (Base, Relative);
      begin
         Assert
           (Image (Actual) = Expected,
            "resolve " & Relative & " produced " & Image (Actual));
         Assert
           (Text = Expected,
            "resolve " & Relative & " to String produced " & Text);
      end;
   end Check_Resolution;

   --  Encode one code point at or above U+0080 as UTF-8.
   function UTF8 (Code : Natural) return String is
   begin
      if Code < 16#800# then
         return Character'Val (16#C0# + Code / 16#40#)
           & Character'Val (16#80# + Code mod 16#40#);
      elsif Code < 16#1_0000# then
         return Character'Val (16#E0# + Code / 16#1000#)
           & Character'Val (16#80# + (Code / 16#40#) mod 16#40#)
           & Character'Val (16#80# + Code mod 16#40#);
      else
         return Character'Val (16#F0# + Code / 16#4_0000#)
           & Character'Val (16#80# + (Code / 16#1000#) mod 16#40#)
           & Character'Val (16#80# + (Code / 16#40#) mod 16#40#)
           & Character'Val (16#80# + Code mod 16#40#);
      end if;
   end UTF8;

   --  RFC 3987 admits ucschar in every IRI component and iprivate in the
   --  query alone. URI_Syntax admits neither.
   procedure Check_IRI_Code_Point
     (Code : Natural; UCS_OK, Query_OK : Boolean)
   is
      Text  : constant String := UTF8 (Code);
      Label : constant String := " at code point" & Natural'Image (Code);
   begin
      Assert
        (Can_Parse ("http://a" & Text & "b/", IRI_Syntax) = UCS_OK,
         "IRI host" & Label);
      Assert
        (Can_Parse ("http://a/p" & Text, IRI_Syntax) = UCS_OK,
         "IRI path" & Label);
      Assert
        (Can_Parse ("http://a/p#" & Text, IRI_Syntax) = UCS_OK,
         "IRI fragment" & Label);
      Assert
        (Can_Parse ("http://a/p?x=" & Text, IRI_Syntax) = Query_OK,
         "IRI query" & Label);
      Assert
        (not Can_Parse ("http://a/p?x=" & Text, URI_Syntax),
         "URI query" & Label);
   end Check_IRI_Code_Point;

   procedure Check_Resolution_Base
     (Base_Text     : String;
      Relative      : String;
      Expected      : String;
      Expected_Host : String;
      Syntax        : Syntax_Kind := URI_Syntax)
   is
      Base : constant Reference := Parse (Base_Text, Syntax);
   begin
      declare
         Actual : constant Reference := Resolve (Base, Relative);
         Text   : constant String := Resolve (Base, Relative);
      begin
         Assert
           (Image (Actual) = Expected,
            "resolve " & Relative & " against " & Base_Text
            & " produced " & Image (Actual));
         Assert
           (Host (Actual) = Expected_Host,
            "resolve " & Relative & " against " & Base_Text
            & " produced host " & Host (Actual));
         Assert
           (Text = Image (Actual),
            "resolve " & Relative & " against " & Base_Text
            & " to String produced " & Text);
      end;
   end Check_Resolution_Base;

   procedure Check_Web (Input, Expected : String) is
      Actual : constant Reference := Parse (Input, Web_URL_Syntax);
   begin
      Assert
        (Image (Actual) = Expected,
         "web parse " & Input & " produced " & Image (Actual));
   end Check_Web;

   procedure Check_Web (Input, Base, Expected : String) is
      Base_URL : constant Reference := Parse (Base, Web_URL_Syntax);
      Actual   : constant Reference := Parse (Input, Base_URL);
   begin
      Assert
        (Image (Actual) = Expected,
         "web resolve " & Input & " produced " & Image (Actual));
   end Check_Web;

   --  A host the WHATWG host parser must refuse. Every entry point runs
   --  that parser in web URL mode, so all three answer alike and Diagnose
   --  names the authority.
   procedure Reject_Host (Host_Text : String) is
      Input  : constant String := "http://" & Host_Text & "/";
      Found  : constant Parse_Error := Diagnose (Input, Web_URL_Syntax);
      Raised : Boolean := False;
   begin
      Assert
        (not Can_Parse (Input, Web_URL_Syntax),
         "Can_Parse accepted host " & Host_Text);
      Assert
        (Found.Kind = Invalid_Authority,
         "Diagnose reported " & Error_Kind'Image (Found.Kind)
         & " for host " & Host_Text);
      begin
         declare
            Ignored : constant Reference := Parse (Input, Web_URL_Syntax);
         begin
            Assert (Image (Ignored)'Length > Natural'Last, "unreachable");
         end;
      exception
         when Malformed_Reference =>
            Raised := True;
      end;
      Assert (Raised, "Parse accepted host " & Host_Text);
   end Reject_Host;

   --  Locate a project file from either the crate root or the tests
   --  directory the test script runs the binary from. An empty result means
   --  the file was not found, which the caller reports as a failure rather
   --  than skipping the check.
   function Project_File (Relative : String) return String is
      From_Tests : constant String := "../" & Relative;
   begin
      if Ada.Directories.Exists (From_Tests) then
         return From_Tests;
      elsif Ada.Directories.Exists (Relative) then
         return Relative;
      elsif Ada.Directories.Exists ("flyology_iri/" & Relative) then
         return "flyology_iri/" & Relative;
      else
         return "";
      end if;
   end Project_File;

   --  Hold the release profile to the suppression scope proof-status.md
   --  records. Only Allowed_Unit may carry -gnatp; an empty Allowed_Unit
   --  forbids suppression outright. Reading the project file back is what
   --  keeps a widened suppression from landing unnoticed, because a build
   --  with checks removed compiles and passes exactly like one without.
   procedure Check_Suppression_Scope
     (Relative : String; Allowed_Unit : String)
   is
      use Ada.Strings.Fixed;
      Path  : constant String := Project_File (Relative);
      File  : Ada.Text_IO.File_Type;
      Found : Natural := 0;
   begin
      Assert
        (Path /= "",
         Relative & " not found from " & Ada.Directories.Current_Directory);
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line    : constant String := Ada.Text_IO.Get_Line (File);
            Trimmed : constant String := Trim (Line, Ada.Strings.Both);
         begin
            if Index (Trimmed, "--") /= Trimmed'First
              and then Index (Line, "-gnatp") > 0
            then
               Found := Found + 1;
               Assert
                 (Allowed_Unit /= ""
                  and then Index (Line, '"' & Allowed_Unit & '"') > 0,
                  Relative & " suppresses checks"
                  & (if Allowed_Unit = "" then ""
                     else " outside " & Allowed_Unit)
                  & ": " & Trimmed);
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);
      Assert
        (Found = (if Allowed_Unit = "" then 0 else 1),
         Relative & " carries" & Natural'Image (Found)
         & " check suppressions");
   end Check_Suppression_Scope;

   function Repeat (Text : String; Count : Positive) return String is
      Result : String (1 .. Text'Length * Count);
   begin
      for Index in 1 .. Count loop
         Result (Text'Length * (Index - 1) + 1 .. Text'Length * Index) := Text;
      end loop;
      return Result;
   end Repeat;

   --  Drive every entry point in every syntax over one hostile input. The
   --  release profile compiles the Flyology_IRI body with -gnatp, so a
   --  latent index or slice bound error there becomes an out-of-bounds
   --  access instead of a Constraint_Error. This binary is built with every
   --  check on, which is what turns the corpus below into a guard for that
   --  body: nothing but Malformed_Reference may escape.
   procedure Stress (Input : String; Label : String) is
      Value : Reference;
      Error : Parse_Error;
      Base  : constant Reference :=
        Parse ("http://base.example/a/b?q", Web_URL_Syntax);
   begin
      for Grammar in Syntax_Kind loop
         declare
            Accepted : constant Boolean :=
              Can_Parse (Input, Grammar, Positive'Last);
            Raised   : Boolean := False;
         begin
            Assert
              ((Diagnose (Input, Grammar, Positive'Last).Kind = No_Error)
                 = Accepted,
               Label & ": Can_Parse and Diagnose disagree");
            Try_Parse (Input, Value, Error, Grammar, Positive'Last);
            Assert
              ((Error.Kind = No_Error) = Accepted
               and then Is_Valid (Value) = Accepted,
               Label & ": Try_Parse and Can_Parse disagree");
            begin
               declare
                  Ignored : constant Reference :=
                    Parse (Input, Grammar, Positive'Last);
               begin
                  Assert
                    (Is_Valid (Ignored), Label & ": Parse returned invalid");
               end;
            exception
               when Malformed_Reference =>
                  Raised := True;
            end;
            Assert
              (Raised /= Accepted, Label & ": Parse and Can_Parse disagree");
         end;
      end loop;
      Try_Parse (Input, Base, Value, Error, Positive'Last);
      Assert
        (Is_Valid (Value) = (Error.Kind = No_Error),
         Label & ": based Try_Parse validity and error disagree");
      begin
         declare
            Ignored : constant Reference :=
              Resolve (Base, Input, Positive'Last);
         begin
            Assert (Is_Valid (Ignored), Label & ": Resolve returned invalid");
         end;
      exception
         when Malformed_Reference =>
            null;
      end;
   exception
      when Escaped : others =>
         Assert
           (False,
            Label & " escaped as "
            & Ada.Exceptions.Exception_Name (Escaped)
            & ": " & Ada.Exceptions.Exception_Message (Escaped));
   end Stress;

   --  An absent component has a zero span, which the component getter has to
   --  answer before it reaches Ada.Strings.Unbounded.Slice: that subprogram
   --  takes a Positive Low and raises on zero. The guard is invisible in a
   --  reference that carries every component, so name the absent ones here.
   procedure Check_Absent (Label : String; Value : String) is
   begin
      Assert
        (Value'Length = 0,
         Label & " is absent but returned """ & Value & """");
   end Check_Absent;

   URL : constant Reference := Parse
     ("HTTPS://user:pass@Example.COM:8443/a/b?x=1#frag", Web_URL_Syntax);
   IRI : constant Reference := Parse
     ("https://例え.テスト/道?名前=値#部分", IRI_Syntax);
   IPv6 : constant Reference := Parse
     ("http://[2001:db8::1]:8080/path", URI_Syntax);
begin
   Assert (Can_Parse ("urn:isbn:0451450523", URI_Syntax), "URN rejected");
   Assert (Can_Parse ("../images/logo.svg", URI_Syntax), "relative URI rejected");
   Assert (Kind (URL) = Absolute_Reference, "URL kind");
   Assert (Image (URL) =
     "https://user:pass@example.com:8443/a/b?x=1#frag", "URL normalization");
   Assert (Scheme (URL) = "https", "scheme");
   Assert (Authority (URL) = "user:pass@example.com:8443", "authority");
   Assert (Userinfo (URL) = "user:pass", "userinfo");
   Assert (Host (URL) = "example.com", "host");
   Assert (Port (URL) = "8443", "port");
   Assert (Path (URL) = "/a/b", "path");
   Assert (Has_Query (URL) and then Query (URL) = "x=1", "query");
   Assert (Has_Fragment (URL) and then Fragment (URL) = "frag", "fragment");
   Assert (Origin (URL) = "https://example.com:8443", "HTTP origin adapter");
   Assert (Target (URL) = "/a/b?x=1", "HTTP target adapter");

   Check_Absent ("userinfo", Userinfo (IPv6));
   Check_Absent ("query", Query (IPv6));
   Check_Absent ("fragment", Fragment (IPv6));
   Check_Absent ("scheme", Scheme (Parse ("../images/logo.svg", URI_Syntax)));
   Check_Absent ("authority", Authority (Parse ("urn:isbn:0", URI_Syntax)));
   Check_Absent ("host", Host (Parse ("urn:isbn:0", URI_Syntax)));
   Check_Absent ("port", Port (Parse ("http://example.com/", URI_Syntax)));
   Check_Absent ("path", Path (Parse ("http://example.com", URI_Syntax)));

   Assert (Image (Parse ("https://example.com", Web_URL_Syntax)) =
     "https://example.com/", "empty web path normalization");
   Assert (Host (IRI) = "例え.テスト", "UTF-8 IRI host");
   Assert (Path (IRI) = "/道", "UTF-8 IRI path");
   Assert (Host (IPv6) = "2001:db8::1", "IPv6 host");
   Assert (Port (IPv6) = "8080", "IPv6 port");
   Assert
     (Origin
        (Parse ("wss://user@[2001:db8::1]:8443/socket", Web_URL_Syntax)) =
        "wss://[2001:db8::1]:8443",
      "WebSocket IPv6 origin adapter");
   Assert
     (Target (Parse ("https://example.com/path?#ignored", Web_URL_Syntax)) =
        "/path?",
      "empty query and omitted fragment adapter");
   Assert
     (Image (Parse ("https://bücher.example/", Web_URL_Syntax)) =
        "https://xn--bcher-kva.example/",
      "IDNA Latin label");
   Assert
     (Image (Parse ("https://例え.テスト/", Web_URL_Syntax)) =
        "https://xn--r8jz45g.xn--zckzah/",
      "IDNA Japanese labels");
   Assert
     (Image (Parse ("https://faß.de/", Web_URL_Syntax)) =
        "https://xn--fa-hia.de/",
      "IDNA nontransitional sharp s");
   declare
      Actual : constant String :=
        Image (Parse ("https://GOO​⁠﻿goo.com/", Web_URL_Syntax));
   begin
      Assert
        (Actual = "https://googoo.com/",
         "IDNA ignored format characters: " & Actual);
   end;
   --  IDNA disallows every domain code point that carries no glyph. The C1
   --  controls, the bidi controls and the two joiners used to survive UTS
   --  #46 mapping and reach a Punycode label, so an invisible character
   --  could ride inside a host that this parser called valid and ada-url
   --  4.0.0 refuses.
   Reject_Host (UTF8 (16#0080#) & ".com");
   Reject_Host ("x" & UTF8 (16#009F#) & "y.com");
   Reject_Host (UTF8 (16#200E#) & "example.com");
   Reject_Host (UTF8 (16#200F#) & "example.com");
   Reject_Host (UTF8 (16#202E#) & "example.com");
   Reject_Host (UTF8 (16#2066#) & "example.com");
   Reject_Host ("ex" & UTF8 (16#200C#) & "ample.com");
   Reject_Host ("ex" & UTF8 (16#200D#) & "ample.com");
   Reject_Host (UTF8 (16#E000#) & ".com");
   Reject_Host (UTF8 (16#10_FFFD#) & ".com");

   --  UTS #46 specifies a convert-and-validate step for a label that is
   --  already Punycode, but WHATWG's domain-to-ASCII observably copies one
   --  through: ada-url 4.0.0 and the pinned WPT corpus both keep these
   --  hosts, so decoding and revalidating them would be a regression.
   Check_Web ("http://xn--/", "http://xn--/");
   Check_Web ("http://xn--a/", "http://xn--a/");
   Check_Web ("http://a.b.c.xn--pokxncvks/", "http://a.b.c.xn--pokxncvks/");

   --  RFC 5893's bidi rule forbids one label from carrying strong letters
   --  of both directions, whichever comes first.
   Reject_Host (UTF8 (16#05D0#) & UTF8 (16#05D1#) & "abc.com");
   Reject_Host ("abc" & UTF8 (16#05D0#) & UTF8 (16#05D1#) & ".com");
   Reject_Host (UTF8 (16#0645#) & "x.com");
   Assert
     (Image (Parse
        ("http://" & UTF8 (16#05D0#) & UTF8 (16#05D1#) & ".com/",
         Web_URL_Syntax)) = "http://xn--4dbc.com/",
      "single-direction right-to-left label rejected");
   Assert
     (Image (Parse ("http://xn--4dbc.com/", Web_URL_Syntax)) =
        "http://xn--4dbc.com/",
      "pre-encoded right-to-left label rejected");

   --  WHATWG domain-to-ASCII runs Unicode ToASCII with VerifyDnsLength
   --  false, so neither the 63-octet DNS label limit nor the 253-octet name
   --  limit applies. The normalized fast path never enforced them, so host
   --  validity used to depend on letter case: the same name parsed in lower
   --  case and failed once one letter forced the IDNA path.
   declare
      Label : constant String (1 .. 64) := [others => 'a'];
      Upper : constant String := 'A' & Label (2 .. Label'Last);
      Name  : constant String (1 .. 300) := [others => 'b'];
      Cased : constant String := 'B' & Name (2 .. Name'Last);
   begin
      Assert
        (Host (Parse ("http://" & Label & "/", Web_URL_Syntax)) = Label,
         "64-octet label rejected");
      Assert
        (Host (Parse ("http://" & Upper & "/", Web_URL_Syntax)) = Label,
         "64-octet label rejected once one letter is upper case");
      Assert
        (Host (Parse ("http://" & Name & "/", Web_URL_Syntax)) = Name,
         "300-octet name rejected");
      Assert
        (Host (Parse ("http://" & Cased & "/", Web_URL_Syntax)) = Name,
         "300-octet name rejected once one letter is upper case");
      Assert
        (Can_Parse ("http://" & Upper & "/", Web_URL_Syntax),
         "Can_Parse rejects a 64-octet label with an upper-case letter");
   end;

   Check_Web ("#x", "mailto:x@x.com", "mailto:x@x.com#x");
   Assert
     (Has_Query (Parse ("?", URI_Syntax))
      and then Query (Parse ("?", URI_Syntax)) = "",
      "empty query presence");
   Assert
     (Has_Fragment (Parse ("#", URI_Syntax))
      and then Fragment (Parse ("#", URI_Syntax)) = "",
      "empty fragment presence");

   Reject ("http://example.com/%", URI_Syntax, Invalid_Percent_Encoding);
   Assert
     (Image (Parse ("http://example.com/%", Web_URL_Syntax)) =
        "http://example.com/%",
      "WHATWG URL preserves malformed percent escape with validation warning");
   Reject ("1http://example.com", URI_Syntax, Invalid_Scheme);
   Reject ("http://[2001:::1]/", URI_Syntax, Invalid_Authority);
   --  RFC 3986 dec-octet forbids a leading zero, so an IPv4-in-IPv6 literal
   --  has exactly one accepted spelling and cannot be zero-padded past a
   --  host comparison.
   Reject ("http://[::1.2.3.04]/", URI_Syntax, Invalid_Authority);
   Reject ("http://[::01.2.3.4]/", URI_Syntax, Invalid_Authority);
   Reject ("http://[::1.2.3.004]/", URI_Syntax, Invalid_Authority);
   Assert
     (Can_Parse ("http://[::1.2.3.4]/", URI_Syntax),
      "IPv4-in-IPv6 literal rejected");
   Assert
     (Can_Parse ("http://[::0.0.0.0]/", URI_Syntax),
      "single-zero dec-octets rejected");
   Assert
     (Can_Parse ("http://[::255.255.255.0]/", URI_Syntax),
      "trailing zero dec-octet rejected");
   Reject ("http://example.com:abc/", URI_Syntax, Invalid_Authority);
   Reject ("/relative", Web_URL_Syntax, Relative_URL);
   Assert
     (Image (Parse ("http://例え.テスト/", Web_URL_Syntax)) =
        "http://xn--r8jz45g.xn--zckzah/",
      "WHATWG URL IDNA host");
   Check_Web
     ("http://example.com////../..", "http://example.com//");
   Check_Web ("http://foo.09..", "http://foo.09../");
   Check_Web ("http://./", "http://./");
   Check_Web ("/", "file:///C:/a/b", "file:///C:/");
   Check_Web
     ("file://localhost//a//../..//foo", "file://///foo");
   Check_Web ("///test", "http://example.org/", "http://test/");
   Check_Web ("\a", "foo://foo/a", "foo://foo/\a");
   declare
      Sentinel : constant Reference := Parse
        ("non-spec:/.//path", Web_URL_Syntax);
   begin
      Assert (Image (Sentinel) = "non-spec:/.//path", "path sentinel image");
      Assert (Path (Sentinel) = "//path", "path sentinel component");
   end;
   declare
      Base_URL : constant Reference := Parse ("about:blank", Web_URL_Syntax);
      Actual   : Reference;
      Error    : Parse_Error;
   begin
      Try_Parse ("", Base_URL, Actual, Error);
      Assert (Error.Kind /= No_Error, "empty input accepted against opaque base");
   end;
   Assert
     (Diagnose ("http://example.com", URI_Syntax, 4).Kind = Too_Long,
      "length bound");

   --  RFC 3987 ucschar starts at U+00A0 and skips the surrogate, the
   --  private use and the noncharacter blocks; iprivate is confined to the
   --  query. Well-formed UTF-8 alone is not the IRI grammar.
   Reject ("http://a" & UTF8 (16#85#) & "b/", IRI_Syntax, Invalid_Authority);
   Check_IRI_Code_Point (16#80#, False, False);
   Check_IRI_Code_Point (16#85#, False, False);
   Check_IRI_Code_Point (16#9F#, False, False);
   Check_IRI_Code_Point (16#A0#, True, True);
   --  U+2028 LINE SEPARATOR lies inside ucschar's U+00A0 .. U+D7FF range,
   --  so RFC 3987 admits it however unwelcome it is downstream.
   Check_IRI_Code_Point (16#2028#, True, True);
   Check_IRI_Code_Point (16#D7FF#, True, True);
   Check_IRI_Code_Point (16#E000#, False, True);
   Check_IRI_Code_Point (16#F8FF#, False, True);
   Check_IRI_Code_Point (16#F900#, True, True);
   Check_IRI_Code_Point (16#FDCF#, True, True);
   Check_IRI_Code_Point (16#FDD0#, False, False);
   Check_IRI_Code_Point (16#FDF0#, True, True);
   Check_IRI_Code_Point (16#FFEF#, True, True);
   Check_IRI_Code_Point (16#FFFE#, False, False);
   Check_IRI_Code_Point (16#1_0000#, True, True);
   Check_IRI_Code_Point (16#1_FFFD#, True, True);
   Check_IRI_Code_Point (16#1_FFFE#, False, False);
   Check_IRI_Code_Point (16#E_0FFF#, False, False);
   Check_IRI_Code_Point (16#E_1000#, True, True);
   Check_IRI_Code_Point (16#F_0000#, False, True);
   Check_IRI_Code_Point (16#10_FFFD#, False, True);
   Check_IRI_Code_Point (16#10_FFFE#, False, False);
   Assert
     (Can_Parse ("https://例え.テスト/道?名前=値#部分", IRI_Syntax),
      "legitimate ucschar IRI rejected");

   Check_Resolution ("g:h", "g:h");
   Check_Resolution ("g", "http://a/b/c/g");
   Check_Resolution ("./g", "http://a/b/c/g");
   Check_Resolution ("g/", "http://a/b/c/g/");
   Check_Resolution ("/g", "http://a/g");
   Check_Resolution ("//g", "http://g");
   Check_Resolution ("?y", "http://a/b/c/d;p?y");
   Check_Resolution ("g?y", "http://a/b/c/g?y");
   Check_Resolution ("#s", "http://a/b/c/d;p?q#s");
   Check_Resolution ("g#s", "http://a/b/c/g#s");
   Check_Resolution ("..", "http://a/b/");
   Check_Resolution ("../g", "http://a/b/g");
   Check_Resolution ("../../g", "http://a/g");

   --  RFC 3986 section 5.2.3 merge excludes the characters after the base
   --  path's right-most '/' while retaining that '/'.  Every case of the
   --  section 5.4 suite above uses a base whose path has an interior slash,
   --  so a merge that dropped the retained separator stayed invisible there.
   --  Site-root and single-segment bases expose it, and the resolved host
   --  must never move away from the base authority.
   Check_Resolution_Base
     ("http://good.com/", "index.html",
      "http://good.com/index.html", "good.com");
   Check_Resolution_Base
     ("http://good.com/x", "evil.com/",
      "http://good.com/evil.com/", "good.com");
   Check_Resolution_Base
     ("http://good.com/x", "../up", "http://good.com/up", "good.com");
   Check_Resolution_Base
     ("http://good.com/x", "./same", "http://good.com/same", "good.com");
   Check_Resolution_Base
     ("http://good.com/a/b", "c.html",
      "http://good.com/a/c.html", "good.com");
   Check_Resolution_Base
     ("http://good.com", "index.html",
      "http://good.com/index.html", "good.com");
   Check_Resolution_Base
     ("https://例え.テスト/x", "evil.テスト/p",
      "https://例え.テスト/evil.テスト/p", "例え.テスト", IRI_Syntax);
   --  A base path with no '/' at all merges to the relative path alone.
   Check_Resolution_Base
     ("mailto:fred@example.com", "joe", "mailto:joe", "");

   --  The serialization-returning Resolve validates URI and IRI results with
   --  Diagnose rather than by building a second Reference. That shortcut is
   --  sound only where Diagnose and Parse agree and a parse stores its input
   --  verbatim, which web mode does not: it normalizes. Resolving with a web
   --  base is reachable whenever the relative reference is itself an absolute
   --  URL, so pin that the two forms still agree there.
   declare
      Web_Base : constant Reference :=
        Parse ("https://example.com/a/b", Web_URL_Syntax);
      Built    : constant Reference := Resolve (Web_Base, "HTTPS://Other.COM");
      Text     : constant String := Resolve (Web_Base, "HTTPS://Other.COM");
   begin
      Assert
        (Text = Image (Built),
         "web resolve to String produced " & Text & " against "
         & Image (Built));
      Assert
        (Text = "https://other.com/",
         "web resolve to String skipped normalization: " & Text);
   end;

   --  Both forms reject a relative base, and neither returns a result the
   --  other would have refused.
   declare
      Relative_Base : constant Reference := Parse ("/only/a/path", URI_Syntax);
      Raised        : Boolean := False;
   begin
      declare
         Ignored : constant String := Resolve (Relative_Base, "g");
      begin
         Assert (Ignored'Length > Natural'Last, "unreachable");
      end;
   exception
      when Malformed_Reference =>
         Raised := True;
         Assert (Raised, "relative base rejected by the String form");
   end;

   --  Web URL mode used to reach the grammar through an analyzer of its
   --  own, which skipped WHATWG preprocessing and never ran the host
   --  parser. It called a space, a CR LF and a backslash inside a host
   --  valid, and disagreed with Parse on the authority it had accepted.
   Reject ("http://exa mple.com/", Web_URL_Syntax, Invalid_Authority);
   Assert
     (Host (Parse ("http://good.com" & ASCII.CR & ASCII.LF & "evil/",
                   Web_URL_Syntax)) = "good.comevil",
      "CR LF stripped from the host before analysis");
   Assert
     (Diagnose ("http://good.com" & ASCII.CR & ASCII.LF & "evil/",
                Web_URL_Syntax).Kind = No_Error,
      "Diagnose rejects a host WHATWG accepts");
   Assert
     (Host (Parse ("http://good.com\evil.com/", Web_URL_Syntax))
        = "good.com",
      "backslash starts the path");
   Assert
     (Can_Parse ("http:///foo", Web_URL_Syntax)
      and then Diagnose ("http:///foo", Web_URL_Syntax).Kind = No_Error
      and then Host (Parse ("http:///foo", Web_URL_Syntax)) = "foo",
      "extra authority slashes");

   --  Max_Length bounds the serialization, which carries the path slash
   --  WHATWG inserts, so the input length alone is not the bound.
   Assert
     (not Can_Parse ("http://a", Web_URL_Syntax, 8)
      and then Diagnose ("http://a", Web_URL_Syntax, 8).Kind = Too_Long,
      "Can_Parse accepted an input whose serialization is one byte longer");
   Assert
     (Can_Parse ("http://a", Web_URL_Syntax, 9),
      "serialized length rejected at its own bound");

   --  A web failure carries the same category and offset Diagnose reports,
   --  not Invalid_Character at offset zero.
   declare
      Input : constant String := "http://example.com:65536/";
      Found : constant Parse_Error := Diagnose (Input, Web_URL_Syntax);
      Value : Reference;
      Error : Parse_Error;
   begin
      Try_Parse (Input, Value, Error, Web_URL_Syntax);
      Assert
        (Found = (Kind => Invalid_Authority, Offset => 24),
         "Diagnose reported " & Error_Kind'Image (Found.Kind)
         & Natural'Image (Found.Offset));
      Assert (Error = Found, "Try_Parse reported a different failure");
   end;
   declare
      Input : constant String := "http://exa" & ASCII.HT & "mple.com:65536/";
      Error : constant Parse_Error := Diagnose (Input, Web_URL_Syntax);
   begin
      --  Offsets name a byte of the caller's input, not of the text left
      --  after WHATWG preprocessing removed the tab.
      Assert
        (Error = (Kind => Invalid_Authority, Offset => 25),
         "stripped byte shifted the reported offset");
   end;

   --  A rejected parse and a successful parse of "" are component-wise
   --  identical, so a caller that ignores Error needs another way to tell
   --  them apart, and the rejected one reported IRI_Syntax whatever syntax
   --  it was asked for.
   declare
      Fresh    : Reference;
      Rejected : Reference;
      Empty    : Reference;
      Error    : Parse_Error;
   begin
      Assert (not Is_Valid (Fresh), "default reference reports valid");
      Try_Parse ("http://exa mple.com/", Rejected, Error, Web_URL_Syntax);
      Assert (Error.Kind /= No_Error, "malformed web URL accepted");
      Assert (not Is_Valid (Rejected), "rejected reference reports valid");
      Assert
        (Syntax (Rejected) = Web_URL_Syntax,
         "rejected reference reports "
         & Syntax_Kind'Image (Syntax (Rejected)));
      Try_Parse ("", Empty, Error, IRI_Syntax);
      Assert (Error.Kind = No_Error, "empty reference rejected");
      Assert (Is_Valid (Empty), "empty reference reports invalid");
      Assert
        (Image (Empty) = Image (Rejected)
         and then Kind (Empty) = Kind (Rejected),
         "empty and rejected references stopped being alike");
   end;

   --  Can_Parse, Diagnose, Parse and Try_Parse reach one grammar through
   --  several routes, and Web_URL_Syntax splits again into a fast path and
   --  the WHATWG path. A seeded corpus holds them to one answer.
   declare
      Found : constant Natural := Flyology_IRI_Differential.Disagreements;
   begin
      Assert
        (Found = 0,
         "entry points disagree on" & Natural'Image (Found) & " cases");
   end;

   --  Finding 43: the release profile trades runtime checks for the
   --  published medians. Pin the scope of that trade, and exercise the one
   --  body it covers with the input shapes that would reach an unchecked
   --  index: oversized components, deep dot-segment nesting, truncated
   --  percent escapes, malformed punycode, control bytes, and numbers past
   --  every bound the parser converts.
   Check_Suppression_Scope ("flyology_iri.gpr", "flyology_iri.adb");
   Check_Suppression_Scope
     ("benchmarks/flyology_iri_benchmarks.gpr", "");
   Stress ("", "empty input");
   Stress ("http://", "scheme without host");
   Stress ("http://a", "shortest fast-path host");
   Stress ("https://a", "shortest fast-path https host");
   Stress ("http://" & Repeat ("a", 64 * 1024) & "/", "64 KiB host label");
   Stress
     ("http://" & Repeat ("a.", 32 * 1024) & "b/", "32768 host labels");
   Stress ("http://a/" & Repeat ("b", 64 * 1024), "64 KiB path");
   Stress ("http://a/" & Repeat ("../", 5_000), "5000 dot segments");
   Stress ("http://a/" & Repeat ("./", 5_000), "5000 single dot segments");
   Stress
     ("http://a/" & Repeat ("%2e%2e/", 2_000), "2000 encoded dot segments");
   Stress ("http://a/?" & Repeat ("x", 64 * 1024), "64 KiB query");
   Stress ("http://a/#" & Repeat ("f", 64 * 1024), "64 KiB fragment");
   Stress ("http://a/" & Repeat ("%", 4_096), "4096 bare percent signs");
   Stress ("http://a/" & Repeat ("%4", 4_096), "4096 truncated escapes");
   Stress ("http://a/p%", "percent at end of path");
   Stress ("http://a/p%4", "one hex digit at end of path");
   Stress ("http://a%", "percent at end of host");
   Stress ("http://xn--/", "empty punycode label");
   Stress ("http://xn--a/", "truncated punycode label");
   Stress ("http://xn--" & Repeat ("9", 4_096) & "/", "punycode overflow");
   Stress ("http://a:" & Repeat ("9", 4_096) & "/", "oversized port");
   Stress ("http://a:65536/", "port past 16 bits");
   Stress ("http://a:-1/", "negative port");
   Stress ("http://" & Repeat ("255.", 1_024) & "255/", "IPv4 label flood");
   Stress ("http://[" & Repeat (":", 4_096) & "]/", "IPv6 colon flood");
   Stress ("http://[::" & Repeat ("f", 4_096) & "]/", "IPv6 hex flood");
   Stress ("http://[::1.2.3.4.5.6.7.8]/", "overlong IPv4-in-IPv6");
   Stress ("http://a/" & Character'Val (0), "NUL in path");
   Stress ("http://a" & Character'Val (0) & "/", "NUL in host");
   Stress ("http://a/" & Character'Val (16#7F#), "DEL in path");
   Stress
     ("http://a/" & Repeat (Character'Val (9) & "", 4_096), "tab flood");
   Stress ("//" & Repeat ("a", 64 * 1024), "network path reference");
   Stress (Repeat ("/", 64 * 1024), "slash flood");
   Stress (Repeat ("a", 64 * 1024) & ":", "64 KiB scheme");
   Stress (Repeat (UTF8 (16#1_0000#), 8_192), "supplementary plane flood");
   Stress (Repeat (Character'Val (16#80#) & "", 8_192), "bare continuation");
   Stress
     ("http://a/" & Repeat (Character'Val (16#F4#) & "", 8_192),
      "truncated four byte leads");

   Ada.Text_IO.Put_Line ("flyology_iri tests passed");
end Flyology_IRI_Tests;
