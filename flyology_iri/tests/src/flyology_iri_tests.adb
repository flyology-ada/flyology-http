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
