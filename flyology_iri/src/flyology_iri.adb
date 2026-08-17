with Ada.Characters.Handling;
with Flyology_IRI.Web;

package body Flyology_IRI is

   package Unbounded renames Ada.Strings.Unbounded;

   type Analysis is record
      Error             : Parse_Error;
      Kind_Value        : Reference_Kind := Empty_Reference;
      Scheme_Part       : Span;
      Authority_Part    : Span;
      Userinfo_Part     : Span;
      Host_Part         : Span;
      Port_Part         : Span;
      Path_Part         : Span;
      Query_Part        : Span;
      Fragment_Part     : Span;
      Authority_Present : Boolean := False;
      Query_Present     : Boolean := False;
      Fragment_Present  : Boolean := False;
   end record;

   function Char_At (Input : String; Offset : Positive) return Character is
     (Input (Input'First + Offset - 1));

   function Byte (Input : String; Offset : Positive) return Natural is
     (Character'Pos (Char_At (Input, Offset)));

   function Is_Alpha (C : Character) return Boolean is
     (C in 'A' .. 'Z' | 'a' .. 'z');
   pragma Inline_Always (Is_Alpha);

   function Is_Digit (C : Character) return Boolean is (C in '0' .. '9');
   pragma Inline_Always (Is_Digit);

   function Is_Hex (C : Character) return Boolean is
     (C in '0' .. '9' | 'A' .. 'F' | 'a' .. 'f');
   pragma Inline_Always (Is_Hex);

   function Is_Unreserved (C : Character) return Boolean is
     (Is_Alpha (C)
      or else Is_Digit (C)
      or else C in '-' | '.' | '_' | '~');
   pragma Inline_Always (Is_Unreserved);

   function Is_Sub_Delimiter (C : Character) return Boolean is
     (C in '!' | '$' | '&' | ''' | '(' | ')' | '*' | '+' | ',' | ';' | '=');
   pragma Inline_Always (Is_Sub_Delimiter);

   function Fast_Dot_Segment
     (Input : String; First, Last : Natural) return Boolean
   is
      Length : constant Natural :=
        (if First = 0 or else First > Last then 0 else Last - First + 1);

      function Encoded_Dot (Offset : Positive) return Boolean is
        (Char_At (Input, Offset) = '%'
         and then Char_At (Input, Offset + 1) = '2'
         and then Char_At (Input, Offset + 2) in 'e' | 'E');
   begin
      return
        (case Length is
           when 1 => Char_At (Input, First) = '.',
           when 2 => Char_At (Input, First) = '.'
                     and then Char_At (Input, First + 1) = '.',
           when 3 => Encoded_Dot (First),
           when 4 =>
             (Char_At (Input, First) = '.' and then Encoded_Dot (First + 1))
             or else
             (Encoded_Dot (First) and then Char_At (Input, Last) = '.'),
           when 6 => Encoded_Dot (First) and then Encoded_Dot (First + 3),
           when others => False);
   end Fast_Dot_Segment;

   type Fast_Byte_Class is (Allowed_Byte, Delimiter_Byte, Rejected_Byte);
   type Fast_Class_Table is array (Character) of Fast_Byte_Class;

   Fast_Host_Class : constant Fast_Class_Table :=
     ['/' | '?' | '#' => Delimiter_Byte,
      Character'Val (0) .. ' ' | Character'Val (16#7F#) .. Character'Last
        | ':' | '<' | '>' | '@' | '[' | '\' | ']' | '^' | '|' | '%' =>
          Rejected_Byte,
      others => Allowed_Byte];

   Fast_Rest_Class : constant Fast_Class_Table :=
     ['?' | '#' => Delimiter_Byte,
      Character'Val (0) .. ' ' | Character'Val (16#7F#) .. Character'Last
        | '"' | '<' | '>' | '`' | '{' | '}' | '^' | '\' | '%' | ''' =>
          Rejected_Byte,
      others => Allowed_Byte];

   function Fast_Web_Analysis
     (Input      : String;
      Result     : out Analysis;
      Need_Slash : out Boolean) return Boolean
   is
      Length     : constant Natural := Input'Length;
      Position   : Natural;
      Host_First : Natural;
      Host_Last  : Natural;
      Label_First : Natural;
      Previous_Label_First : Natural;
      Path_First : Natural;
      Path_Last  : Natural;
      Segment_First : Natural;
      Path_Has_Dot : Boolean := False;
      Shift      : Natural := 0;
      C          : Character;
   begin
      Result := (others => <>);
      Need_Slash := False;
      if Length >= 8
        and then Char_At (Input, 1) = 'h'
        and then Char_At (Input, 2) = 't'
        and then Char_At (Input, 3) = 't'
        and then Char_At (Input, 4) = 'p'
      then
         if Char_At (Input, 5) = ':'
           and then Char_At (Input, 6) = '/'
           and then Char_At (Input, 7) = '/'
         then
            Result.Scheme_Part := (First => 1, Last => 4);
            Position := 8;
         elsif Length >= 9
           and then Char_At (Input, 5) = 's'
           and then Char_At (Input, 6) = ':'
           and then Char_At (Input, 7) = '/'
           and then Char_At (Input, 8) = '/'
         then
            Result.Scheme_Part := (First => 1, Last => 5);
            Position := 9;
         else
            return False;
         end if;
      else
         return False;
      end if;

      Host_First := Position;
      Label_First := Position;
      Previous_Label_First := Position;
      if Is_Digit (Char_At (Input, Host_First)) then
         return False;
      end if;
      while Position <= Length loop
         C := Char_At (Input, Position);
         exit when Fast_Host_Class (C) = Delimiter_Byte;
         if Fast_Host_Class (C) = Rejected_Byte or else C in 'A' .. 'Z' then
            return False;
         end if;
         if C = '.' then
            Previous_Label_First := Label_First;
            Label_First := Position + 1;
         end if;
         Position := Position + 1;
      end loop;
      Host_Last := Position - 1;
      if Host_Last < Host_First then
         return False;
      elsif Char_At (Input, Host_Last) = '.'
        and then Host_Last > Host_First
        and then Char_At (Input, Host_Last - 1) /= '.'
        and then Is_Digit (Char_At (Input, Previous_Label_First))
      then
         return False;
      elsif Char_At (Input, Host_Last) /= '.'
        and then Is_Digit (Char_At (Input, Label_First))
      then
         return False;
      end if;

      Result.Kind_Value := Absolute_Reference;
      Result.Authority_Present := True;
      Result.Authority_Part := (First => Host_First, Last => Host_Last);
      Result.Host_Part := Result.Authority_Part;
      if Position <= Length and then Char_At (Input, Position) = '/' then
         Path_First := Position;
         Position := Position + 1;
         while Position <= Length loop
            C := Char_At (Input, Position);
            exit when Fast_Rest_Class (C) = Delimiter_Byte;
            if Fast_Rest_Class (C) = Rejected_Byte
              and then C not in '%' | '''
            then
               return False;
            end if;
            Path_Has_Dot := Path_Has_Dot or else C in '.' | '%';
            Position := Position + 1;
         end loop;
         Path_Last := Position - 1;

         if Path_Has_Dot then
            Segment_First := Path_First + 1;
            for Index in Path_First + 1 .. Path_Last + 1 loop
               if Index > Path_Last or else Char_At (Input, Index) = '/' then
                  if Fast_Dot_Segment (Input, Segment_First, Index - 1) then
                     return False;
                  end if;
                  Segment_First := Index + 1;
               end if;
            end loop;
         end if;
      else
         Need_Slash := True;
         Shift := 1;
         Path_First := Position;
         Path_Last := Position;
      end if;

      Result.Path_Part := (First => Path_First, Last => Path_Last);
      if Position <= Length and then Char_At (Input, Position) = '?' then
         Result.Query_Present := True;
         Result.Query_Part.First := Position + 1 + Shift;
         Position := Position + 1;
         while Position <= Length and then Char_At (Input, Position) /= '#' loop
            C := Char_At (Input, Position);
            if C not in '?' | '%'
              and then Fast_Rest_Class (C) = Rejected_Byte
            then
               return False;
            end if;
            Position := Position + 1;
         end loop;
         Result.Query_Part.Last := Position - 1 + Shift;
      end if;
      if Position <= Length and then Char_At (Input, Position) = '#' then
         Result.Fragment_Present := True;
         Result.Fragment_Part.First := Position + 1 + Shift;
         Position := Position + 1;
         while Position <= Length loop
            C := Char_At (Input, Position);
            if C not in '?' | '#' | '%'
              and then Fast_Rest_Class (C) = Rejected_Byte
            then
               return False;
            end if;
            Position := Position + 1;
         end loop;
         Result.Fragment_Part.Last := Length + Shift;
      end if;
      Result.Error := (Kind => No_Error, Offset => 0);
      return True;
   end Fast_Web_Analysis;

   function Fast_Can_Parse_Web (Input : String) return Boolean is
      Length        : constant Natural := Input'Length;
      First         : constant Natural := Input'First;
      Last          : constant Natural := Input'Last;
      Position      : Natural;
      Host_First    : Natural;
      Host_Last     : Natural;
      Label_First   : Natural;
      Previous_Label_First : Natural;
      C             : Character;
   begin
      if Length >= 8
        and then Input (First) = 'h'
        and then Input (First + 1) = 't'
        and then Input (First + 2) = 't'
        and then Input (First + 3) = 'p'
      then
         if Input (First + 4) = ':'
           and then Input (First + 5) = '/'
           and then Input (First + 6) = '/'
         then
            Position := First + 7;
         elsif Length >= 9
           and then Input (First + 4) = 's'
           and then Input (First + 5) = ':'
           and then Input (First + 6) = '/'
           and then Input (First + 7) = '/'
         then
            Position := First + 8;
         else
            return False;
         end if;
      else
         return False;
      end if;

      Host_First := Position;
      Label_First := Position;
      Previous_Label_First := Position;
      if Is_Digit (Input (Host_First)) then
         return False;
      end if;
      while Position <= Last loop
         C := Input (Position);
         exit when C in '/' | '?' | '#';
         if Character'Pos (C) not in 16#21# .. 16#7E#
           or else C in ':' | '<' | '>' | '@' | '[' | '\' | ']' | '^' | '|'
                        | '%'
         then
            return False;
         end if;
         if C = '.' then
            Previous_Label_First := Label_First;
            Label_First := Position + 1;
         end if;
         Position := Position + 1;
      end loop;
      if Position = Host_First then
         return False;
      end if;
      --  Once an absolute special URL reaches path state, the WHATWG parser
      --  cannot fail: remaining bytes are encoded or normalized.  A numeric
      --  final host label is the exception because it enters IPv4 parsing.
      Host_Last := Position - 1;
      if Input (Host_Last) = '.' then
         return Host_Last = Host_First
           or else Input (Host_Last - 1) = '.'
           or else not Is_Digit (Input (Previous_Label_First));
      end if;
      return not Is_Digit (Input (Label_First));
   end Fast_Can_Parse_Web;

   function Failure (Kind : Error_Kind; Offset : Natural) return Analysis is
      Result : Analysis;
   begin
      Result.Error := (Kind => Kind, Offset => Offset);
      return Result;
   end Failure;

   --  Report whether RFC 3987 admits a U+E000 .. U+FFFF code point. ucschar
   --  skips the private use area, which iprivate restores for the query
   --  alone, and skips the noncharacters at U+FDD0 and U+FFF0.
   function Is_IRI_Upper_BMP
     (Code : Natural; Private_OK : Boolean) return Boolean is
     (Code in 16#F900# .. 16#FDCF#
      or else Code in 16#FDF0# .. 16#FFEF#
      or else (Private_OK and then Code in 16#E000# .. 16#F8FF#));

   --  Report whether RFC 3987 admits a supplementary code point. Planes 1
   --  through 13 stop two positions below their last, plane 14 starts at
   --  U+E1000, and planes 15 and 16 are iprivate in their entirety.
   function Is_IRI_Supplementary
     (Code : Natural; Private_OK : Boolean) return Boolean is
     (if Code <= 16#D_FFFD# then Code mod 16#1_0000# <= 16#FFFD#
      elsif Code <= 16#E_FFFD# then Code >= 16#E_1000#
      else Private_OK and then Code mod 16#1_0000# <= 16#FFFD#);

   --  Accept one UTF-8 sequence and report its width. IRI_Classes also
   --  applies the RFC 3987 character classes, which admit ucschar in every
   --  component and iprivate in the query alone, the latter selected by
   --  Private_OK. The classes are tested from the bytes already loaded
   --  here, and a three-byte lead byte at or below ED settles the whole of
   --  U+0800 .. U+D7FF without decoding anything.
   function Is_Valid_UTF_8_At
     (Input       : String;
      Offset      : Positive;
      IRI_Classes : Boolean;
      Private_OK  : Boolean;
      Width       : out Positive) return Boolean
   is
      B0 : constant Natural := Byte (Input, Offset);
      B1, B2, B3 : Natural := 0;
      Left : constant Natural := Input'Length - Offset;

      function Continuation (Value : Natural) return Boolean is
        (Value in 16#80# .. 16#BF#);
   begin
      Width := 1;
      if B0 < 16#80# then
         return B0 >= 16#20# and then B0 /= 16#7F#;
      elsif B0 in 16#C2# .. 16#DF# then
         if Left < 1 then
            return False;
         end if;
         B1 := Byte (Input, Offset + 1);
         Width := 2;
         return Continuation (B1)
           and then (not IRI_Classes
                     or else B0 > 16#C2#
                     or else B1 >= 16#A0#);
      elsif B0 in 16#E0# .. 16#EF# then
         if Left < 2 then
            return False;
         end if;
         B1 := Byte (Input, Offset + 1);
         B2 := Byte (Input, Offset + 2);
         Width := 3;
         return Continuation (B1)
           and then Continuation (B2)
           and then (B0 /= 16#E0# or else B1 >= 16#A0#)
           and then (B0 /= 16#ED# or else B1 <= 16#9F#)
           and then (not IRI_Classes
                     or else B0 <= 16#ED#
                     or else Is_IRI_Upper_BMP
                       ((B0 - 16#E0#) * 16#1000#
                        + (B1 - 16#80#) * 16#40# + B2 - 16#80#,
                        Private_OK));
      elsif B0 in 16#F0# .. 16#F4# then
         if Left < 3 then
            return False;
         end if;
         B1 := Byte (Input, Offset + 1);
         B2 := Byte (Input, Offset + 2);
         B3 := Byte (Input, Offset + 3);
         Width := 4;
         return Continuation (B1)
           and then Continuation (B2)
           and then Continuation (B3)
           and then (B0 /= 16#F0# or else B1 >= 16#90#)
           and then (B0 /= 16#F4# or else B1 <= 16#8F#)
           and then (not IRI_Classes
                     or else Is_IRI_Supplementary
                       ((B0 - 16#F0#) * 16#4_0000#
                        + (B1 - 16#80#) * 16#1000#
                        + (B2 - 16#80#) * 16#40# + B3 - 16#80#,
                        Private_OK));
      else
         return False;
      end if;
   end Is_Valid_UTF_8_At;

   function Validate_Range
     (Input       : String;
      First, Last : Natural;
      Syntax      : Syntax_Kind;
      Context     : Character) return Parse_Error
   is
      Position : Natural := First;
      Width    : Positive;
      C        : Character;
      Allowed  : Boolean;

      --  RFC 3987 restricts the non-ASCII code points, and grants iprivate
      --  to the query alone. Both are fixed for the whole range.
      IRI_Classes : constant Boolean := Syntax = IRI_Syntax;
      Private_OK  : constant Boolean := Context = 'q';
   begin
      while Position /= 0 and then Position <= Last loop
         C := Char_At (Input, Position);
         if Character'Pos (C) >= 16#80# then
            if Syntax = URI_Syntax
              or else not Is_Valid_UTF_8_At
                (Input, Position, IRI_Classes, Private_OK, Width)
              or else Position + Width - 1 > Last
            then
               return (Kind => Invalid_Character, Offset => Position);
            end if;
            Position := Position + Width;
         elsif C = '%' then
            if Position + 2 > Last
              or else not Is_Hex (Char_At (Input, Position + 1))
              or else not Is_Hex (Char_At (Input, Position + 2))
            then
               if Syntax = Web_URL_Syntax then
                  Position := Position + 1;
               else
                  return (Kind => Invalid_Percent_Encoding, Offset => Position);
               end if;
            else
               Position := Position + 3;
            end if;
         else
            Allowed :=
              (if Syntax = Web_URL_Syntax and then Context in 'p' | 'q' | 'f'
               then Character'Pos (C) in 16#20# .. 16#7E#
               else (case Context is
                  when 'u' => Is_Unreserved (C) or else Is_Sub_Delimiter (C)
                              or else C = ':',
                  when 'h' => Is_Unreserved (C) or else Is_Sub_Delimiter (C),
                  when 'p' => Is_Unreserved (C) or else Is_Sub_Delimiter (C)
                              or else C in ':' | '@' | '/',
                  when others =>
                     Is_Unreserved (C) or else Is_Sub_Delimiter (C)
                     or else C in ':' | '@' | '/' | '?'));
            if not Allowed then
               return (Kind => Invalid_Character, Offset => Position);
            end if;
            Position := Position + 1;
         end if;
      end loop;
      return (Kind => No_Error, Offset => 0);
   end Validate_Range;

   --  Match the RFC 3986 IPv4address production, whose dec-octet forbids a
   --  leading zero.  WHATWG IPv4 parsing is separate and lives in
   --  Flyology_IRI.Web.Canonical_IPv4.
   function Valid_IPv4
     (Input : String; First, Last : Positive) return Boolean
   is
      Parts      : Natural := 0;
      Position   : Natural := First;
      Digit_Count : Natural;
      Value      : Natural;
      Leading_0  : Boolean;
   begin
      while Position <= Last loop
         Parts := Parts + 1;
         if Parts > 4 then
            return False;
         end if;
         Digit_Count := 0;
         Value := 0;
         Leading_0 := Char_At (Input, Position) = '0';
         while Position <= Last and then Char_At (Input, Position) /= '.' loop
            if not Is_Digit (Char_At (Input, Position)) then
               return False;
            end if;
            Digit_Count := Digit_Count + 1;
            if Digit_Count > 3 then
               return False;
            end if;
            Value := Value * 10
              + Character'Pos (Char_At (Input, Position)) - Character'Pos ('0');
            Position := Position + 1;
         end loop;
         if Digit_Count = 0 or else Value > 255
           or else (Leading_0 and then Digit_Count > 1)
         then
            return False;
         end if;
         if Position <= Last then
            Position := Position + 1;
            if Position > Last then
               return False;
            end if;
         end if;
      end loop;
      return Parts = 4;
   end Valid_IPv4;

   function Valid_IP_Literal
     (Input : String; First, Last : Positive) return Boolean
   is
      Position       : Natural := First;
      Pieces         : Natural := 0;
      Digit_Count    : Natural := 0;
      Double_Colon   : Boolean := False;
      Piece_First    : Natural := First;
   begin
      if Char_At (Input, First) in 'v' | 'V' then
         Position := First + 1;
         Digit_Count := 0;
         while Position <= Last and then Is_Hex (Char_At (Input, Position)) loop
            Digit_Count := Digit_Count + 1;
            Position := Position + 1;
         end loop;
         if Digit_Count = 0 or else Position > Last or else Char_At (Input, Position) /= '.' then
            return False;
         end if;
         Position := Position + 1;
         if Position > Last then
            return False;
         end if;
         while Position <= Last loop
            if not Is_Unreserved (Char_At (Input, Position))
              and then not Is_Sub_Delimiter (Char_At (Input, Position))
              and then Char_At (Input, Position) /= ':'
            then
               return False;
            end if;
            Position := Position + 1;
         end loop;
         return True;
      end if;

      if Char_At (Input, Position) = ':' then
         if Position = Last or else Char_At (Input, Position + 1) /= ':' then
            return False;
         end if;
         Double_Colon := True;
         Position := Position + 2;
      end if;

      while Position <= Last loop
         Piece_First := Position;
         Digit_Count := 0;
         while Position <= Last and then Is_Hex (Char_At (Input, Position)) loop
            Digit_Count := Digit_Count + 1;
            if Digit_Count > 4 then
               return False;
            end if;
            Position := Position + 1;
         end loop;
         if Position <= Last and then Char_At (Input, Position) = '.' then
            if Pieces > 6
              or else not Valid_IPv4 (Input, Piece_First, Last)
            then
               return False;
            end if;
            Pieces := Pieces + 2;
            Position := Last + 1;
            exit;
         elsif Digit_Count = 0 then
            return False;
         end if;
         Pieces := Pieces + 1;
         if Pieces > 8 then
            return False;
         end if;
         if Position <= Last then
            if Char_At (Input, Position) /= ':' then
               return False;
            end if;
            if Position < Last and then Char_At (Input, Position + 1) = ':' then
               if Double_Colon then
                  return False;
               end if;
               Double_Colon := True;
               Position := Position + 2;
               if Position > Last then
                  exit;
               end if;
            else
               Position := Position + 1;
               if Position > Last then
                  return False;
               end if;
            end if;
         end if;
      end loop;
      return (Double_Colon and then Pieces < 8)
        or else (not Double_Colon and then Pieces = 8);
   end Valid_IP_Literal;

   function Analyze
     (Input      : String;
      Syntax     : Syntax_Kind;
      Max_Length : Positive) return Analysis
   is
      Result          : Analysis;
      Length          : constant Natural := Input'Length;
      Main_Last       : Natural := Length;
      Hier_Last       : Natural := Length;
      Colon           : Natural := 0;
      Slash           : Natural := 0;
      Position        : Natural := 1;
      Authority_First : Natural := 0;
      Authority_Last  : Natural := 0;
      At_Sign         : Natural := 0;
      Host_First      : Natural := 0;
      Host_Last       : Natural := 0;
      Port_Colon      : Natural := 0;
      Check           : Parse_Error;
      Port_Value      : Natural := 0;
      Special_URL     : Boolean := False;
   begin
      if Length > Max_Length then
         return Failure (Too_Long, 0);
      end if;

      for Index in 1 .. Length loop
         if Syntax /= Web_URL_Syntax
           and then (Character'Pos (Char_At (Input, Index)) < 16#20#
           or else Char_At (Input, Index) = Character'Val (16#7F#)
           or else Char_At (Input, Index) = ' ')
         then
            return Failure (Invalid_Character, Index);
         end if;
      end loop;

      for Index in 1 .. Length loop
         if Char_At (Input, Index) = '#' then
            Result.Fragment_Present := True;
            Result.Fragment_Part := (First => Index + 1, Last => Length);
            Main_Last := Index - 1;
            exit;
         end if;
      end loop;
      Hier_Last := Main_Last;
      for Index in 1 .. Main_Last loop
         if Char_At (Input, Index) = '?' then
            Result.Query_Present := True;
            Result.Query_Part := (First => Index + 1, Last => Main_Last);
            Hier_Last := Index - 1;
            exit;
         end if;
      end loop;

      for Index in 1 .. Hier_Last loop
         if Char_At (Input, Index) = ':' then
            Colon := Index;
            exit;
         elsif Char_At (Input, Index) = '/' then
            Slash := Index;
            exit;
         end if;
      end loop;

      if Colon /= 0 and then (Slash = 0 or else Colon < Slash) then
         if Colon = 1 or else not Is_Alpha (Char_At (Input, 1)) then
            return Failure (Invalid_Scheme, 1);
         end if;
         for Index in 2 .. Colon - 1 loop
            if not Is_Alpha (Char_At (Input, Index))
              and then not Is_Digit (Char_At (Input, Index))
              and then Char_At (Input, Index) not in '+' | '-' | '.'
            then
               return Failure (Invalid_Scheme, Index);
            end if;
         end loop;
         Result.Scheme_Part := (First => 1, Last => Colon - 1);
         Position := Colon + 1;
         Result.Kind_Value := Absolute_Reference;
      elsif Syntax = Web_URL_Syntax then
         return Failure (Relative_URL, 0);
      elsif Hier_Last > 0 and then Char_At (Input, 1) = '/' then
         Result.Kind_Value := Absolute_Path_Reference;
      elsif Hier_Last > 0 then
         Result.Kind_Value := Relative_Path_Reference;
      else
         Result.Kind_Value := Empty_Reference;
      end if;

      if Position + 1 <= Hier_Last
        and then Char_At (Input, Position) = '/'
        and then Char_At (Input, Position + 1) = '/'
      then
         Result.Authority_Present := True;
         Authority_First := Position + 2;
         Authority_Last := Hier_Last;
         for Index in Authority_First .. Hier_Last loop
            if Char_At (Input, Index) = '/' then
               Authority_Last := Index - 1;
               exit;
            end if;
         end loop;
         Result.Authority_Part :=
           (First => Authority_First, Last => Authority_Last);
         if Result.Scheme_Part.First = 0 then
            Result.Kind_Value := Network_Path_Reference;
         end if;
         Position := Authority_Last + 1;

         if Authority_First <= Authority_Last then
            for Index in Authority_First .. Authority_Last loop
               if Char_At (Input, Index) = '@' then
                  At_Sign := Index;
               end if;
            end loop;
         end if;
         if At_Sign /= 0 then
            Result.Userinfo_Part :=
              (First => Authority_First, Last => At_Sign - 1);
            Check := Validate_Range
              (Input, Authority_First, At_Sign - 1, Syntax, 'u');
            if Check.Kind /= No_Error then
               Result.Error := Check;
               return Result;
            end if;
            Host_First := At_Sign + 1;
         else
            Host_First := Authority_First;
         end if;

         if Host_First <= Authority_Last
           and then Char_At (Input, Host_First) = '['
         then
            Host_Last := 0;
            for Index in Host_First + 1 .. Authority_Last loop
               if Char_At (Input, Index) = ']' then
                  Host_Last := Index;
                  exit;
               end if;
            end loop;
            if Host_Last = 0
              or else Host_Last = Host_First + 1
              or else not Valid_IP_Literal
                (Input, Host_First + 1, Host_Last - 1)
            then
               return Failure (Invalid_Authority, Host_First);
            end if;
            Result.Host_Part :=
              (First => Host_First + 1, Last => Host_Last - 1);
            if Host_Last < Authority_Last then
               if Char_At (Input, Host_Last + 1) /= ':' then
                  return Failure (Invalid_Authority, Host_Last + 1);
               end if;
               Port_Colon := Host_Last + 1;
            end if;
         else
            Host_Last := Authority_Last;
            if Host_First <= Authority_Last then
               for Index in reverse Host_First .. Authority_Last loop
                  if Char_At (Input, Index) = ':' then
                     Port_Colon := Index;
                     Host_Last := Index - 1;
                     exit;
                  end if;
               end loop;
            end if;
            Result.Host_Part := (First => Host_First, Last => Host_Last);
            if Syntax /= Web_URL_Syntax then
               Check := Validate_Range (Input, Host_First, Host_Last, Syntax, 'h');
               if Check.Kind /= No_Error then
                  Result.Error := (Invalid_Authority, Check.Offset);
                  return Result;
               end if;
            end if;
         end if;

         if Port_Colon /= 0 then
            if Port_Colon = Authority_Last then
               if Syntax = Web_URL_Syntax then
                  return Failure (Invalid_Authority, Port_Colon);
               end if;
               Result.Port_Part :=
                 (First => Port_Colon + 1, Last => Port_Colon);
            else
               Result.Port_Part :=
                 (First => Port_Colon + 1, Last => Authority_Last);
               for Index in Port_Colon + 1 .. Authority_Last loop
                  if not Is_Digit (Char_At (Input, Index)) then
                     return Failure (Invalid_Authority, Index);
                  end if;
                  if Syntax = Web_URL_Syntax then
                     Port_Value := Port_Value * 10
                       + Character'Pos (Char_At (Input, Index))
                       - Character'Pos ('0');
                     if Port_Value > 65_535 then
                        return Failure (Invalid_Authority, Index);
                     end if;
                  end if;
               end loop;
            end if;
         end if;
      end if;

      if Position <= Hier_Last then
         Result.Path_Part := (First => Position, Last => Hier_Last);
      else
         Result.Path_Part := (First => Position, Last => Position - 1);
      end if;

      Check := Validate_Range
        (Input, Result.Path_Part.First, Result.Path_Part.Last, Syntax, 'p');
      if Check.Kind /= No_Error then
         Result.Error :=
           (Kind => (if Check.Kind = Invalid_Percent_Encoding
                     then Invalid_Percent_Encoding else Invalid_Path),
            Offset => Check.Offset);
         return Result;
      end if;
      Check := Validate_Range
        (Input, Result.Query_Part.First, Result.Query_Part.Last, Syntax, 'q');
      if Check.Kind /= No_Error then
         Result.Error := Check;
         return Result;
      end if;
      --  Context 'f' shares the query's ASCII grammar but not its iprivate
      --  allowance, which RFC 3987 grants to the query alone.
      Check := Validate_Range
        (Input, Result.Fragment_Part.First, Result.Fragment_Part.Last,
         Syntax, 'f');
      if Check.Kind /= No_Error then
         Result.Error := Check;
         return Result;
      end if;

      if Result.Scheme_Part.First = 0
        and then not Result.Authority_Present
        and then Result.Path_Part.First <= Result.Path_Part.Last
        and then Char_At (Input, Result.Path_Part.First) /= '/'
      then
         for Index in Result.Path_Part.First .. Result.Path_Part.Last loop
            exit when Char_At (Input, Index) = '/';
            if Char_At (Input, Index) = ':' then
               return Failure (Invalid_Path, Index);
            end if;
         end loop;
      end if;

      if Syntax = Web_URL_Syntax then
         declare
            Scheme_Text : String (1 .. Result.Scheme_Part.Last);
         begin
            for Index in Scheme_Text'Range loop
               Scheme_Text (Index) := Ada.Characters.Handling.To_Lower
                 (Char_At (Input, Result.Scheme_Part.First + Index - 1));
            end loop;
            if Scheme_Text in "http" | "https" | "ws" | "wss" | "ftp" then
               Special_URL := True;
               if not Result.Authority_Present
                 or else Result.Host_Part.First > Result.Host_Part.Last
               then
                  return Failure (Invalid_Authority, Position);
               end if;
            elsif Scheme_Text = "file" then
               Special_URL := True;
               if not Result.Authority_Present then
                  return Failure (Unsupported_URL, Position);
               end if;
            end if;
         end;
         if Result.Userinfo_Part.First /= 0
           and then Result.Host_Part.First > Result.Host_Part.Last
         then
            return Failure (Invalid_Authority, Result.Userinfo_Part.First);
         end if;
         if Result.Host_Part.First /= 0
           and then Result.Host_Part.First <= Result.Host_Part.Last
         then
            for Index in Result.Host_Part.First .. Result.Host_Part.Last loop
               if Special_URL
                 and then (Character'Pos (Char_At (Input, Index)) >= 16#80#
                           or else Char_At (Input, Index) = '%')
               then
                  return Failure (Unsupported_URL, Index);
               end if;
            end loop;
         end if;
      end if;

      Result.Error := (Kind => No_Error, Offset => 0);
      return Result;
   end Analyze;

   procedure Set_Reference
     (Value  : out Reference;
      Text   : String;
      Syntax : Syntax_Kind;
      Parsed : Analysis)
   is
   begin
      Unbounded.Set_Unbounded_String (Value.Text, Text);
      Value.Syntax_Value := Syntax;
      Value.Kind_Value := Parsed.Kind_Value;
      Value.Scheme_Part := Parsed.Scheme_Part;
      Value.Authority_Part := Parsed.Authority_Part;
      Value.Userinfo_Part := Parsed.Userinfo_Part;
      Value.Host_Part := Parsed.Host_Part;
      Value.Port_Part := Parsed.Port_Part;
      Value.Path_Part := Parsed.Path_Part;
      Value.Query_Part := Parsed.Query_Part;
      Value.Fragment_Part := Parsed.Fragment_Part;
      Value.Authority_Present := Parsed.Authority_Present;
      Value.Query_Present := Parsed.Query_Present;
      Value.Fragment_Present := Parsed.Fragment_Present;
      Value.Valid_Value := True;
   end Set_Reference;

   --  A failed parse leaves the caller a default reference whose component
   --  getters return an empty string. It still reports the syntax the
   --  caller asked for, and Is_Valid tells it apart from a parsed empty
   --  reference.
   procedure Set_Failure (Value : out Reference; Syntax : Syntax_Kind) is
   begin
      Value := (others => <>);
      Value.Syntax_Value := Syntax;
   end Set_Failure;

   --  Settle a web URL without allocating whenever the input is already its
   --  own serialization. Returns False when only the WHATWG pipeline can
   --  answer, and otherwise reports Too_Long or No_Error along with the
   --  spans Try_Parse needs. Every entry point enters web URL mode here.
   function Web_Fast_Path
     (Input      : String;
      Max_Length : Positive;
      Result     : out Analysis;
      Need_Slash : out Boolean;
      Error      : out Parse_Error) return Boolean
   is
   begin
      Error := (Kind => No_Error, Offset => 0);
      if Input'Length > Max_Length then
         Result := (others => <>);
         Need_Slash := False;
         Error := (Kind => Too_Long, Offset => 0);
         return True;
      end if;
      if not Fast_Web_Analysis (Input, Result, Need_Slash) then
         return False;
      end if;
      if Need_Slash and then Input'Length = Max_Length then
         --  The serialization carries the path slash WHATWG inserts.
         Error := (Kind => Too_Long, Offset => 0);
      end if;
      return True;
   end Web_Fast_Path;

   --  Normalize a web URL through the WHATWG parser and analyze the
   --  serialization it produces. This is the only route to Flyology_IRI.Web
   --  for absolute web URLs, so Can_Parse, Diagnose and Try_Parse cannot
   --  reach different verdicts.
   --  @param Build True to construct the reference on success
   --  @param Value Parsed reference when Build is True and parsing
   --  succeeds, otherwise a default reference
   procedure Web_Slow_Path
     (Input      : String;
      Max_Length : Positive;
      Build      : Boolean;
      Value      : out Reference;
      Error      : out Parse_Error)
   is
      Web_Error  : Parse_Error;
      Normalized : constant String :=
        Flyology_IRI.Web.Parse (Input, "", False, Web_Error);
      Parsed     : Analysis;
   begin
      if Web_Error.Kind /= No_Error then
         Error := Web_Error;
      elsif Normalized'Length > Max_Length then
         Error := (Kind => Too_Long, Offset => 0);
      else
         Parsed := Analyze (Normalized, Web_URL_Syntax, Max_Length);
         Error := Parsed.Error;
      end if;
      if Error.Kind = No_Error and then Build then
         Set_Reference (Value, Normalized, Web_URL_Syntax, Parsed);
      else
         Set_Failure (Value, Web_URL_Syntax);
      end if;
   end Web_Slow_Path;

   --  Report the failure Try_Parse would report, without constructing a
   --  reference. The reference it declares is never handed out; it exists
   --  so that Can_Parse and Diagnose carry no controlled object of their
   --  own. The body sits at the end of this unit and is never inlined,
   --  which keeps the allocating path away from the code the entry points
   --  execute for an already-normalized URL: placing it here instead cost
   --  the measured can_parse median three nanoseconds.
   function Web_Validate
     (Input : String; Max_Length : Positive) return Parse_Error;
   pragma No_Inline (Web_Validate);

   function Can_Parse
     (Input      : String;
      Syntax     : Syntax_Kind := IRI_Syntax;
      Max_Length : Positive := Default_Max_Length) return Boolean
   is
   begin
      if Input'Length > Max_Length then
         return False;
      end if;
      if Syntax /= Web_URL_Syntax then
         return Analyze (Input, Syntax, Max_Length).Error.Kind = No_Error;
      end if;
      --  Percent-encoding expands one byte to at most three and the
      --  serialization adds at most the inserted path slash, so an input
      --  this short cannot serialize past the bound. Anything longer takes
      --  the exact path, where the bound is applied to the serialization.
      --  The product is taken in a wider type because Max_Length may be
      --  Positive'Last.
      if Long_Long_Integer (Input'Length) * 3 < Long_Long_Integer (Max_Length)
        and then Fast_Can_Parse_Web (Input)
      then
         return True;
      end if;
      return Web_Validate (Input, Max_Length).Kind = No_Error;
   end Can_Parse;

   function Diagnose
     (Input      : String;
      Syntax     : Syntax_Kind := IRI_Syntax;
      Max_Length : Positive := Default_Max_Length) return Parse_Error is
     (if Syntax = Web_URL_Syntax
      then Web_Validate (Input, Max_Length)
      else Analyze (Input, Syntax, Max_Length).Error);

   function Parse
     (Input      : String;
      Syntax     : Syntax_Kind := IRI_Syntax;
      Max_Length : Positive := Default_Max_Length) return Reference
   is
      Result : Reference;
      Error  : Parse_Error;
   begin
      Try_Parse (Input, Result, Error, Syntax, Max_Length);
      if Error.Kind /= No_Error then
         raise Malformed_Reference with
           Error_Kind'Image (Error.Kind) & " at byte"
           & Natural'Image (Error.Offset);
      end if;
      return Result;
   end Parse;

   procedure Try_Parse
     (Input      : String;
      Value      : out Reference;
      Error      : out Parse_Error;
      Syntax     : Syntax_Kind := IRI_Syntax;
      Max_Length : Positive := Default_Max_Length)
   is
      Fast   : Analysis;
      Parsed : Analysis;
      Need_Slash : Boolean;
   begin
      if Syntax = Web_URL_Syntax then
         if Web_Fast_Path (Input, Max_Length, Fast, Need_Slash, Error) then
            if Error.Kind /= No_Error then
               Set_Failure (Value, Syntax);
            elsif Need_Slash then
               declare
                  Insert_At : constant Natural :=
                    Input'First + Fast.Path_Part.First - 1;
                  Normalized : constant String :=
                    Input (Input'First .. Insert_At - 1) & "/"
                    & Input (Insert_At .. Input'Last);
               begin
                  Set_Reference (Value, Normalized, Syntax, Fast);
               end;
            else
               Set_Reference (Value, Input, Syntax, Fast);
            end if;
            return;
         end if;
         Web_Slow_Path (Input, Max_Length, True, Value, Error);
         return;
      end if;
      Parsed := Analyze (Input, Syntax, Max_Length);
      Error := Parsed.Error;
      if Error.Kind /= No_Error then
         Set_Failure (Value, Syntax);
      else
         Set_Reference (Value, Input, Syntax, Parsed);
      end if;
   end Try_Parse;

   function Parse
     (Input      : String;
      Base       : Reference;
      Max_Length : Positive := Default_Max_Length) return Reference
   is
      Result : Reference;
      Error  : Parse_Error;
   begin
      Try_Parse (Input, Base, Result, Error, Max_Length);
      if Error.Kind /= No_Error then
         raise Malformed_Reference with Error_Kind'Image (Error.Kind);
      end if;
      return Result;
   end Parse;

   procedure Try_Parse
     (Input      : String;
      Base       : Reference;
      Value      : out Reference;
      Error      : out Parse_Error;
      Max_Length : Positive := Default_Max_Length)
   is
      Web_Error  : Parse_Error;
      Normalized : constant String := Flyology_IRI.Web.Parse
        (Input, Image (Base), Base.Syntax_Value = Web_URL_Syntax, Web_Error);
      Parsed     : Analysis;
   begin
      if Base.Syntax_Value /= Web_URL_Syntax then
         Set_Failure (Value, Web_URL_Syntax);
         Error := (Kind => Unsupported_URL, Offset => 0);
         return;
      elsif Web_Error.Kind /= No_Error then
         Set_Failure (Value, Web_URL_Syntax);
         Error := Web_Error;
         return;
      elsif Input'Length > Max_Length
        or else Normalized'Length > Max_Length
      then
         Set_Failure (Value, Web_URL_Syntax);
         Error := (Kind => Too_Long, Offset => 0);
         return;
      end if;
      Parsed := Analyze (Normalized, Web_URL_Syntax, Max_Length);
      if Parsed.Error.Kind /= No_Error then
         Set_Failure (Value, Web_URL_Syntax);
         Error := Parsed.Error;
         return;
      end if;
      Set_Reference (Value, Normalized, Web_URL_Syntax, Parsed);
      Error := (Kind => No_Error, Offset => 0);
   end Try_Parse;

   --  Every public component getter reaches the stored serialization through
   --  here, so copying the whole reference to return one span made each of
   --  them cost the length of the reference rather than the length of the
   --  component. Unbounded.Slice copies only the requested range. The zero
   --  guard has to stay ahead of it because an absent component has First = 0
   --  and Unbounded.Slice takes a Positive Low.
   --
   --  The old shape cost more than the extra bytes suggest: the release
   --  objects show To_String called unconditionally and ahead of the zero
   --  test, so an absent component also paid a whole-reference copy, and a
   --  present one paid two allocations and two copies rather than one.
   --
   --  The result's bounds are unchanged: GNAT's Unbounded.Slice returns the
   --  underlying Low .. High range, which is what the discarded whole-text
   --  copy was sliced by. The language does not pin those bounds the way it
   --  pins To_String's lower bound of one, so every consumer in this crate
   --  reads the result through 'First, 'Last, or 'Range instead.
   function Slice (Value : Reference; Part : Span) return String is
   begin
      if Part.First = 0 or else Part.First > Part.Last then
         return "";
      end if;
      return Unbounded.Slice (Value.Text, Part.First, Part.Last);
   end Slice;

   function Is_Valid (Value : Reference) return Boolean is
     (Value.Valid_Value);

   function Syntax (Value : Reference) return Syntax_Kind is
     (Value.Syntax_Value);

   function Kind (Value : Reference) return Reference_Kind is
     (Value.Kind_Value);

   function Image (Value : Reference) return String is
     (Unbounded.To_String (Value.Text));

   function Image_Length (Value : Reference) return Natural is
     (Unbounded.Length (Value.Text));

   function Has_Scheme (Value : Reference) return Boolean is
     (Value.Scheme_Part.First /= 0);

   function Scheme (Value : Reference) return String is
     (Slice (Value, Value.Scheme_Part));

   function Has_Authority (Value : Reference) return Boolean is
     (Value.Authority_Present);

   function Authority (Value : Reference) return String is
     (Slice (Value, Value.Authority_Part));

   function Userinfo (Value : Reference) return String is
     (Slice (Value, Value.Userinfo_Part));

   function Host (Value : Reference) return String is
     (Slice (Value, Value.Host_Part));

   function Port (Value : Reference) return String is
     (Slice (Value, Value.Port_Part));

   function Path (Value : Reference) return String is
      Text : constant String := Slice (Value, Value.Path_Part);
   begin
      --  WHATWG serialization inserts "/." before a non-authority path that
      --  starts with two slashes.  It is a serialization guard, not part of
      --  the URL object's pathname.
      if Value.Syntax_Value = Web_URL_Syntax
        and then not Value.Authority_Present
        and then Text'Length >= 4
        and then Text (Text'First .. Text'First + 3) = "/.//"
      then
         return Text (Text'First + 2 .. Text'Last);
      end if;
      return Text;
   end Path;

   function Has_Query (Value : Reference) return Boolean is
     (Value.Query_Present);

   function Query (Value : Reference) return String is
     (Slice (Value, Value.Query_Part));

   function Has_Fragment (Value : Reference) return Boolean is
     (Value.Fragment_Present);

   function Fragment (Value : Reference) return String is
     (Slice (Value, Value.Fragment_Part));

   function Origin (Value : Reference) return String is
      Scheme_Text    : constant String := Scheme (Value);
      Authority_Text : constant String := Authority (Value);
      Host_First     : Natural := Authority_Text'First;
   begin
      if Value.Syntax_Value /= Web_URL_Syntax
        or else Scheme_Text not in "http" | "https" | "ws" | "wss"
        or else not Value.Authority_Present
        or else Value.Host_Part.First > Value.Host_Part.Last
      then
         raise Malformed_Reference with "URL has no HTTP or WebSocket origin";
      end if;
      for Index in Authority_Text'Range loop
         if Authority_Text (Index) = '@' then
            Host_First := Index + 1;
         end if;
      end loop;
      return Scheme_Text & "://"
        & Authority_Text (Host_First .. Authority_Text'Last);
   end Origin;

   function Target (Value : Reference) return String is
      Scheme_Text : constant String := Scheme (Value);
   begin
      if Value.Syntax_Value /= Web_URL_Syntax
        or else Scheme_Text not in "http" | "https" | "ws" | "wss"
        or else not Value.Authority_Present
      then
         raise Malformed_Reference with
           "URL has no HTTP origin-form request target";
      end if;
      return Path (Value)
        & (if Value.Query_Present then "?" & Query (Value) else "");
   end Target;

   procedure Remove_Last_Segment (Output : in out Unbounded.Unbounded_String) is
      Text : constant String := Unbounded.To_String (Output);
      Slash : Natural := 0;
   begin
      for Index in reverse Text'Range loop
         if Text (Index) = '/' then
            Slash := Index;
            exit;
         end if;
      end loop;
      if Slash = 0 then
         Unbounded.Set_Unbounded_String (Output, "");
      else
         Unbounded.Set_Unbounded_String (Output, Text (Text'First .. Slash - 1));
      end if;
   end Remove_Last_Segment;

   function Remove_Dot_Segments (Input : String) return String is
      --  The loop below indexes from one, so Input has to be renormalized.
      --  A constrained subtype does that at the cost of one copy; the
      --  Unbounded round-trip it replaces did the same renormalization
      --  through the heap.
      Source   : constant String (1 .. Input'Length) := Input;
      Position : Natural := 1;
      Output   : Unbounded.Unbounded_String;
      Next     : Natural;
   begin
      while Position <= Source'Length loop
         if Position + 2 <= Source'Length
           and then Source (Position .. Position + 2) = "../"
         then
            Position := Position + 3;
         elsif Position + 1 <= Source'Length
           and then Source (Position .. Position + 1) = "./"
         then
            Position := Position + 2;
         elsif Position + 2 <= Source'Length
           and then Source (Position .. Position + 2) = "/./"
         then
            Position := Position + 2;
         elsif Position + 1 = Source'Length
           and then Source (Position .. Position + 1) = "/."
         then
            Unbounded.Append (Output, '/');
            exit;
         elsif Position + 3 <= Source'Length
           and then Source (Position .. Position + 3) = "/../"
         then
            Position := Position + 3;
            Remove_Last_Segment (Output);
         elsif Position + 2 = Source'Length
           and then Source (Position .. Position + 2) = "/.."
         then
            Remove_Last_Segment (Output);
            Unbounded.Append (Output, '/');
            exit;
         elsif Source (Position .. Source'Length) in "." | ".." then
            exit;
         else
            Next := Position;
            if Source (Position) = '/' then
               Next := Position + 1;
            end if;
            while Next <= Source'Length and then Source (Next) /= '/' loop
               Next := Next + 1;
            end loop;
            Unbounded.Append (Output, Source (Position .. Next - 1));
            Position := Next;
         end if;
      end loop;
      return Unbounded.To_String (Output);
   end Remove_Dot_Segments;

   function Resolve
     (Base       : Reference;
      Relative   : String;
      Max_Length : Positive := Default_Max_Length) return Reference
   is
      Rel      : constant Reference :=
        Parse (Relative, Base.Syntax_Value, Max_Length);
      --  Every branch below reads the relative path, and the merge path reads
      --  it three times. One local keeps the getter to a single call.
      Rel_Path : constant String := Path (Rel);
      Target   : Unbounded.Unbounded_String;
      Prefix   : Unbounded.Unbounded_String;
   begin
      if not Has_Scheme (Base) then
         raise Malformed_Reference with "base reference is not absolute";
      end if;

      if Has_Scheme (Rel) then
         Unbounded.Append (Target, Scheme (Rel) & ":");
         if Has_Authority (Rel) then
            Unbounded.Append (Target, "//" & Authority (Rel));
         end if;
         Unbounded.Append (Target, Remove_Dot_Segments (Rel_Path));
         if Has_Query (Rel) then
            Unbounded.Append (Target, "?" & Query (Rel));
         end if;
      else
         Unbounded.Append (Target, Scheme (Base) & ":");
         if Has_Authority (Rel) then
            Unbounded.Append (Target, "//" & Authority (Rel));
            Unbounded.Append (Target, Remove_Dot_Segments (Rel_Path));
            if Has_Query (Rel) then
               Unbounded.Append (Target, "?" & Query (Rel));
            end if;
         else
            declare
               --  Read once for the empty-path test, the merge test, and the
               --  merge itself.
               Base_Path : constant String := Path (Base);
            begin
               if Has_Authority (Base) then
                  Unbounded.Append (Target, "//" & Authority (Base));
               end if;
               if Rel_Path'Length = 0 then
                  Unbounded.Append (Target, Base_Path);
                  if Has_Query (Rel) then
                     Unbounded.Append (Target, "?" & Query (Rel));
                  elsif Has_Query (Base) then
                     Unbounded.Append (Target, "?" & Query (Base));
                  end if;
               else
                  if Rel_Path (Rel_Path'First) = '/' then
                     Unbounded.Append
                       (Target, Remove_Dot_Segments (Rel_Path));
                  else
                     if Has_Authority (Base)
                       and then Base_Path'Length = 0
                     then
                        Unbounded.Append (Prefix, '/');
                     else
                        --  RFC 3986 section 5.2.3 merge excludes the
                        --  characters after the base path's right-most '/'
                        --  but retains that '/'.  A base path without any
                        --  '/' merges to the relative path alone, so Prefix
                        --  stays empty.
                        for Index in reverse Base_Path'Range loop
                           if Base_Path (Index) = '/' then
                              Unbounded.Set_Unbounded_String
                                (Prefix,
                                 Base_Path (Base_Path'First .. Index));
                              exit;
                           end if;
                        end loop;
                     end if;
                     Unbounded.Append
                       (Target,
                        Remove_Dot_Segments
                          (Unbounded.To_String (Prefix) & Rel_Path));
                  end if;
                  if Has_Query (Rel) then
                     Unbounded.Append (Target, "?" & Query (Rel));
                  end if;
               end if;
            end;
         end if;
      end if;
      if Has_Fragment (Rel) then
         Unbounded.Append (Target, "#" & Fragment (Rel));
      end if;
      return Parse
        (Unbounded.To_String (Target), Base.Syntax_Value, Max_Length);
   end Resolve;

   function Web_Validate
     (Input : String; Max_Length : Positive) return Parse_Error
   is
      Fast       : Analysis;
      Need_Slash : Boolean;
      Error      : Parse_Error;
      Ignored    : Reference;
   begin
      if Web_Fast_Path (Input, Max_Length, Fast, Need_Slash, Error) then
         return Error;
      end if;
      Web_Slow_Path (Input, Max_Length, False, Ignored, Error);
      return Error;
   end Web_Validate;

end Flyology_IRI;
