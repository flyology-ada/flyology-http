with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Interfaces;
with Flyology_IRI;

package body Flyology_IRI_Differential is

   package U renames Ada.Strings.Unbounded;

   use Flyology_IRI;
   use type Interfaces.Unsigned_64;

   Report_Limit : constant := 40;

   Reported : Natural := 0;

   --  A 64-bit linear congruential generator drives the corpus so that the
   --  same inputs are produced on every run and on every target.
   State : Interfaces.Unsigned_64;

   procedure Reset is
   begin
      State := 16#2545_F491_4F6C_DD1D#;
   end Reset;

   function Next (Bound : Positive) return Natural is
   begin
      State := State * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407;
      return Natural
        ((State / 2 ** 33) mod Interfaces.Unsigned_64 (Bound));
   end Next;

   Fragment_Count : constant := 64;

   --  Corpus fragments chosen to reach the delimiters, the host grammar and
   --  the WHATWG preprocessing rules where the entry points can part ways.
   function Fragment (Index : Natural) return String is
     (case Index is
        when 0 => "http://",
        when 1 => "https://",
        when 2 => "HTTP://",
        when 3 => "ftp://",
        when 4 => "file://",
        when 5 => "ws://",
        when 6 => "non-spec:",
        when 7 => "mailto:",
        when 8 => "a:",
        when 9 => "1http://",
        when 10 => "//",
        when 11 => "/",
        when 12 => "",
        when 13 => "example.com",
        when 14 => "good.com",
        when 15 => "EXAMPLE.com",
        when 16 => "a",
        when 17 => "0x7f.1",
        when 18 => "127.0.0.1",
        when 19 => "[::1]",
        when 20 => "[2001:db8::1]",
        when 21 => "[2001:::1]",
        when 22 => "xn--a",
        when 23 => "xn--",
        when 24 => ".",
        when 25 => "..",
        when 26 => "a..b",
        when 27 => "café",
        when 28 => "例え.テスト",
        when 29 => "a%41b",
        when 30 => "%zz",
        when 31 => ":8080",
        when 32 => ":65536",
        when 33 => ":80",
        when 34 => ":",
        when 35 => "u:p@",
        when 36 => "@",
        when 37 => "%",
        when 38 => "\",
        when 39 => ASCII.CR & ASCII.LF,
        when 40 => "" & ASCII.HT,
        when 41 => " ",
        when 42 => "<",
        when 43 => ">",
        when 44 => "^",
        when 45 => "|",
        when 46 => "[",
        when 47 => "]",
        when 48 => "/a/b",
        when 49 => "/../..",
        when 50 => "/.",
        when 51 => "/%",
        when 52 => "/%zz",
        when 53 => "?x=1",
        when 54 => "#f",
        when 55 => "/a\b",
        when 56 => "/a b",
        when 57 => "/'q",
        when 58 => "/a`b",
        when 59 => "/{}",
        when 60 => "" & ASCII.DEL,
        when 61 => "" & Character'Val (16#01#),
        when 62 => "evil",
        when 63 => "/foo",
        when others => "");

   function Hex_Digit (Value : Natural) return Character is
     (if Value < 10
      then Character'Val (Character'Pos ('0') + Value)
      else Character'Val (Character'Pos ('a') + Value - 10));

   --  Render an input on one line, escaping every byte outside printable
   --  ASCII so that a corpus case can be replayed from the report.
   function Escaped (Text : String) return String is
      Result : U.Unbounded_String;
      Code   : Natural;
   begin
      for C of Text loop
         if C in ' ' .. '~' and then C /= '\' then
            U.Append (Result, C);
         else
            Code := Character'Pos (C);
            U.Append
              (Result,
               "\x" & Hex_Digit (Code / 16) & Hex_Digit (Code mod 16));
         end if;
      end loop;
      return U.To_String (Result);
   end Escaped;

   function Image (Value : Parse_Error) return String is
     (Error_Kind'Image (Value.Kind) & "@" & Natural'Image (Value.Offset));

   procedure Report
     (Label  : String;
      Input  : String;
      Syn    : Syntax_Kind;
      Max    : Positive;
      Detail : String;
      Count  : in out Natural)
   is
   begin
      Count := Count + 1;
      if Reported < Report_Limit then
         Reported := Reported + 1;
         Ada.Text_IO.Put_Line
           ("disagree " & Label & " input=" & Escaped (Input)
            & " syntax=" & Syntax_Kind'Image (Syn)
            & " max=" & Natural'Image (Max) & " " & Detail);
      end if;
   end Report;

   --  Contract of flyology_iri.ads: Can_Parse is True exactly when Diagnose
   --  reports No_Error, Parse raises exactly when it does not, and
   --  Try_Parse reports the same failure Diagnose does.
   procedure Check
     (Input : String;
      Syn   : Syntax_Kind;
      Max   : Positive;
      Count : in out Natural)
   is
      Found   : constant Parse_Error := Diagnose (Input, Syn, Max);
      Allowed : constant Boolean := Can_Parse (Input, Syn, Max);
      Value   : Reference;
      Error   : Parse_Error;
      Raised  : Boolean := False;
   begin
      Try_Parse (Input, Value, Error, Syn, Max);
      if Allowed /= (Found.Kind = No_Error) then
         Report
           ("can_parse/diagnose", Input, Syn, Max,
            "diagnose=" & Image (Found) & " can_parse="
            & Boolean'Image (Allowed), Count);
      end if;
      if Error /= Found then
         Report
           ("try_parse/diagnose", Input, Syn, Max,
            "diagnose=" & Image (Found) & " try_parse=" & Image (Error),
            Count);
      end if;
      begin
         declare
            Parsed : constant Reference := Parse (Input, Syn, Max);
         begin
            if Image_Length (Parsed) > Max then
               Report
                 ("serialized_length", Input, Syn, Max,
                  "image_length=" & Natural'Image (Image_Length (Parsed)),
                  Count);
            end if;
         end;
      exception
         when Malformed_Reference =>
            Raised := True;
      end;
      if Raised /= (Found.Kind /= No_Error) then
         Report
           ("parse/diagnose", Input, Syn, Max,
            "diagnose=" & Image (Found) & " raised="
            & Boolean'Image (Raised), Count);
      end if;
      if Syntax (Value) /= Syn then
         Report
           ("syntax", Input, Syn, Max,
            "try_parse_syntax=" & Syntax_Kind'Image (Syntax (Value)),
            Count);
      end if;
      if Is_Valid (Value) /= (Error.Kind = No_Error) then
         Report
           ("is_valid", Input, Syn, Max,
            "try_parse=" & Image (Error) & " is_valid="
            & Boolean'Image (Is_Valid (Value)), Count);
      end if;
   end Check;

   --  A reference that parsed at its own serialized length must fail one
   --  byte below it: Max_Length bounds the serialization, not the input.
   procedure Check_Bound
     (Input : String;
      Syn   : Syntax_Kind;
      Count : in out Natural)
   is
      Value  : Reference;
      Error  : Parse_Error;
      Length : Natural;
   begin
      Try_Parse (Input, Value, Error, Syn);
      if Error.Kind /= No_Error then
         return;
      end if;
      Length := Image_Length (Value);
      if Length < 2 then
         return;
      end if;
      Check (Input, Syn, Length, Count);
      Check (Input, Syn, Length - 1, Count);
      if Can_Parse (Input, Syn, Length - 1) then
         Report
           ("bound", Input, Syn, Length - 1,
            "can_parse accepted below the serialized length"
            & Natural'Image (Length), Count);
      end if;
   end Check_Bound;

   procedure Check_All (Input : String; Count : in out Natural) is
   begin
      for Syn in Syntax_Kind loop
         Check (Input, Syn, 8 * 1_024, Count);
         Check (Input, Syn, Positive'Max (1, Input'Length), Count);
         Check_Bound (Input, Syn, Count);
      end loop;
   end Check_All;

   Corpus_Size : constant := 10_000;

   function Disagreements return Natural is
      Count : Natural := 0;
   begin
      --  The cases the audit reported, kept alongside the seeded corpus so
      --  that a shrinking corpus cannot lose them.
      Check_All ("http://exa mple.com/", Count);
      Check_All ("http://good.com" & ASCII.CR & ASCII.LF & "evil/", Count);
      Check_All ("http://good.com\evil.com/", Count);
      Check_All ("http:///foo", Count);
      Check_All ("http://example.com:65536/", Count);
      Check_All ("http://a", Count);
      Check_All ("http://example.com", Count);
      Check_All ("", Count);

      Reset;
      for Case_Index in 1 .. Corpus_Size loop
         declare
            Parts : constant Natural := 1 + Next (5);
            Input : U.Unbounded_String;
         begin
            --  Half the corpus is rooted at a special scheme, which is what
            --  the allocation-free fast paths accept: an input that never
            --  reaches them cannot show them disagreeing with the rest.
            if Next (2) = 0 then
               U.Append (Input, Fragment (Next (2)));
            end if;
            for Part in 1 .. Parts loop
               U.Append (Input, Fragment (Next (Fragment_Count)));
            end loop;
            Check_All (U.To_String (Input), Count);
         end;
      end loop;
      return Count;
   end Disagreements;

end Flyology_IRI_Differential;
