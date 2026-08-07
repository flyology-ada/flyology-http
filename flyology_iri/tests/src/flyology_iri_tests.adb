with Ada.Text_IO;
with Flyology_IRI;

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
      begin
         Assert
           (Image (Actual) = Expected,
            "resolve " & Relative & " produced " & Image (Actual));
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
      begin
         Assert
           (Image (Actual) = Expected,
            "resolve " & Relative & " against " & Base_Text
            & " produced " & Image (Actual));
         Assert
           (Host (Actual) = Expected_Host,
            "resolve " & Relative & " against " & Base_Text
            & " produced host " & Host (Actual));
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

   Ada.Text_IO.Put_Line ("flyology_iri tests passed");
end Flyology_IRI_Tests;
