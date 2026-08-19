with Ada.Characters.Handling;
with Ada.Strings.Unbounded;
with Flyology_IRI.IDNA;

package body Flyology_IRI.Web is

   package U renames Ada.Strings.Unbounded;

   type URL_Parts is record
      Scheme       : U.Unbounded_String;
      Username     : U.Unbounded_String;
      Password     : U.Unbounded_String;
      Host         : U.Unbounded_String;
      Port         : U.Unbounded_String;
      Path         : U.Unbounded_String;
      Query        : U.Unbounded_String;
      Fragment     : U.Unbounded_String;
      Has_Authority : Boolean := False;
      Has_Query     : Boolean := False;
      Has_Fragment  : Boolean := False;
      Opaque_Path   : Boolean := False;
      Valid         : Boolean := False;
      Error         : Parse_Error;
   end record;

   --  Record a failure and its offset into the preprocessed text. Offsets
   --  are mapped back onto the caller's input by Parse.
   procedure Fail
     (Value  : in out URL_Parts;
      Kind   : Error_Kind;
      Offset : Natural := 0)
   is
   begin
      Value.Valid := False;
      Value.Error := (Kind => Kind, Offset => Offset);
   end Fail;

   function Is_Alpha (C : Character) return Boolean is
     (C in 'A' .. 'Z' | 'a' .. 'z');

   function Is_Digit (C : Character) return Boolean is (C in '0' .. '9');

   function Is_Hex (C : Character) return Boolean is
     (C in '0' .. '9' | 'A' .. 'F' | 'a' .. 'f');

   function Hex_Value (C : Character) return Natural is
     (if C in '0' .. '9' then Character'Pos (C) - Character'Pos ('0')
      elsif C in 'A' .. 'F' then Character'Pos (C) - Character'Pos ('A') + 10
      else Character'Pos (C) - Character'Pos ('a') + 10);

   function Hex_Digit (Value : Natural) return Character is
     (if Value < 10
      then Character'Val (Character'Pos ('0') + Value)
      else Character'Val (Character'Pos ('A') + Value - 10));

   function Special (Scheme : String) return Boolean is
     (Scheme in "ftp" | "file" | "http" | "https" | "ws" | "wss");

   function Default_Port (Scheme : String) return String is
     (if Scheme = "ftp" then "21"
      elsif Scheme = "http" or else Scheme = "ws" then "80"
      elsif Scheme = "https" or else Scheme = "wss" then "443"
      else "");

   function Windows_Drive (Text : String) return Boolean is
     (Text'Length >= 2
      and then Is_Alpha (Text (Text'First))
      and then Text (Text'First + 1) in ':' | '|'
      and then (Text'Length = 2
                or else Text (Text'First + 2) in '/' | '\' | '?' | '#'));

   --  WHATWG strips leading and trailing C0 controls and spaces before
   --  parsing. Preprocess and Input_Offset share the bounds so that a
   --  reported offset always names the byte the parser rejected.
   procedure Trim_Bounds (Input : String; First, Last : out Natural) is
   begin
      First := Input'First;
      Last := Input'Last;
      while First <= Last and then Character'Pos (Input (First)) <= 16#20# loop
         First := First + 1;
      end loop;
      while Last >= First and then Character'Pos (Input (Last)) <= 16#20# loop
         Last := Last - 1;
      end loop;
   end Trim_Bounds;

   function Preprocess (Input : String) return String is
      First : Natural;
      Last  : Natural;
   begin
      Trim_Bounds (Input, First, Last);
      --  Almost no input carries the bytes this removes, and for those the
      --  trimmed slice already is the answer. Appending the kept bytes one
      --  at a time allocated an accumulator, and grew it, only to reproduce
      --  the input verbatim.
      for Index in First .. Last loop
         if Input (Index) in ASCII.HT | ASCII.LF | ASCII.CR then
            declare
               Result : U.Unbounded_String;
            begin
               for Kept in First .. Last loop
                  if Input (Kept) not in ASCII.HT | ASCII.LF | ASCII.CR then
                     U.Append (Result, Input (Kept));
                  end if;
               end loop;
               return U.To_String (Result);
            end;
         end if;
      end loop;
      --  Slid to one, because Input_Offset and the parser below read the
      --  result at one-based offsets.
      declare
         subtype Kept_Bytes is String (1 .. Last - First + 1);
      begin
         return Kept_Bytes (Input (First .. Last));
      end;
   end Preprocess;

   --  Map a one-based offset into the preprocessed text back onto the
   --  caller's input. Preprocessing only removes bytes, so counting the
   --  bytes it kept recovers the original position.
   function Input_Offset (Input : String; Offset : Natural) return Natural is
      First  : Natural;
      Last   : Natural;
      Kept   : Natural := 0;
      Mapped : Natural := 0;
   begin
      if Offset = 0 then
         return 0;
      end if;
      Trim_Bounds (Input, First, Last);
      for Index in First .. Last loop
         if Input (Index) not in ASCII.HT | ASCII.LF | ASCII.CR then
            Kept := Kept + 1;
            Mapped := Index - Input'First + 1;
            exit when Kept = Offset;
         end if;
      end loop;
      if Kept = Offset then
         return Mapped;
      elsif Kept + 1 = Offset then
         --  One past the last retained byte, as reported for a component
         --  that ended before the parser expected it to.
         return Mapped + 1;
      else
         return 0;
      end if;
   end Input_Offset;

   type Encode_Set is (Userinfo_Set, Path_Set, Query_Set, Special_Query_Set,
                       Fragment_Set, Opaque_Set);

   function Must_Encode (C : Character; Set : Encode_Set) return Boolean is
      Code : constant Natural := Character'Pos (C);
   begin
      if Code >= 16#80# or else Code < 16#20# or else Code = 16#7F# then
         return True;
      elsif C = ' ' then
         return Set /= Opaque_Set;
      end if;
      case Set is
         when Userinfo_Set =>
            return C in '"' | '#' | '/' | ':' | ';' | '<' | '=' | '>' | '?'
                         | '@' | '[' | '\' | ']' | '^' | '|' | '`' | '{' | '}';
         when Path_Set =>
            return C in '"' | '#' | '<' | '>' | '?' | '^' | '`' | '{' | '}';
         when Query_Set =>
            return C in '"' | '#' | '<' | '>';
         when Special_Query_Set =>
            return C in '"' | '#' | ''' | '<' | '>';
         when Fragment_Set =>
            return C in '"' | '<' | '>' | '`';
         when Opaque_Set =>
            return Character'Pos (C) < 16#20# or else C = Character'Val (16#7F#);
      end case;
   end Must_Encode;

   --  Counted first, then written straight into the returned object. The
   --  count is exact, so the result is the only storage this needs: the
   --  accumulator it replaces took a heap block, grew it a byte at a time,
   --  and was then copied out whole.
   function Encode (Input : String; Set : Encode_Set) return String is
      Length : Natural := 0;
   begin
      for C of Input loop
         Length := Length + (if Must_Encode (C, Set) then 3 else 1);
      end loop;
      return Result : String (1 .. Length) do
         declare
            Last : Natural := 0;
            Code : Natural;
         begin
            for C of Input loop
               if Must_Encode (C, Set) then
                  Code := Character'Pos (C);
                  Result (Last + 1) := '%';
                  Result (Last + 2) := Hex_Digit (Code / 16);
                  Result (Last + 3) := Hex_Digit (Code mod 16);
                  Last := Last + 3;
               else
                  Result (Last + 1) := C;
                  Last := Last + 1;
               end if;
            end loop;
         end;
      end return;
   end Encode;

   function Encode_Opaque_Path
     (Input : String; Has_Tail : Boolean) return String is
   begin
      if not Has_Tail then
         return Encode (Input, Opaque_Set);
      end if;
      --  A single trailing space is the one byte the opaque set leaves alone
      --  that a tail would run into, so it is escaped here instead. Encoding
      --  the empty slice yields the empty string, which covers an input that
      --  is nothing but that space.
      if Input'Length > 0 and then Input (Input'Last) = ' ' then
         return Encode (Input (Input'First .. Input'Last - 1), Opaque_Set)
                & "%20";
      end if;
      return Encode (Input, Opaque_Set);
   end Encode_Opaque_Path;

   --  An escape is recognised by the same test in both passes, so the
   --  counted length is the written length.
   function Is_Escape_At (Input : String; Position : Natural) return Boolean is
     (Input (Position) = '%'
      and then Position + 2 <= Input'Last
      and then Is_Hex (Input (Position + 1))
      and then Is_Hex (Input (Position + 2)));

   function Percent_Decode (Input : String) return String is
      Length   : Natural := 0;
      Position : Natural := Input'First;
   begin
      while Position <= Input'Last loop
         Length := Length + 1;
         Position :=
           Position + (if Is_Escape_At (Input, Position) then 3 else 1);
      end loop;
      return Result : String (1 .. Length) do
         declare
            Last : Natural := 0;
         begin
            Position := Input'First;
            while Position <= Input'Last loop
               Last := Last + 1;
               if Is_Escape_At (Input, Position) then
                  Result (Last) :=
                    Character'Val
                      (Hex_Value (Input (Position + 1)) * 16
                       + Hex_Value (Input (Position + 2)));
                  Position := Position + 3;
               else
                  Result (Last) := Input (Position);
                  Position := Position + 1;
               end if;
            end loop;
         end;
      end return;
   end Percent_Decode;

   function Number_Image (Value : Long_Long_Integer) return String is
      Text : constant String := Long_Long_Integer'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Number_Image;

   function Parse_IPv4_Number
     (Text : String; Value : out Long_Long_Integer) return Boolean
   is
      First : Natural := Text'First;
      Base  : Long_Long_Integer := 10;
      Digit : Natural;
   begin
      Value := 0;
      if Text'Length >= 2 and then Text (First) = '0' then
         if Text'Length >= 2 and then Text (First + 1) in 'x' | 'X' then
            Base := 16;
            First := First + 2;
         else
            Base := 8;
            First := First + 1;
         end if;
      end if;
      if First > Text'Last then
         return True;
      end if;
      for Index in First .. Text'Last loop
         if Is_Digit (Text (Index)) then
            Digit := Character'Pos (Text (Index)) - Character'Pos ('0');
         elsif Base = 16 and then Text (Index) in 'A' .. 'F' | 'a' .. 'f' then
            Digit := Hex_Value (Text (Index));
         else
            return False;
         end if;
         if Long_Long_Integer (Digit) >= Base
           or else Value > (Long_Long_Integer'Last - Long_Long_Integer (Digit)) / Base
         then
            return False;
         end if;
         Value := Value * Base + Long_Long_Integer (Digit);
      end loop;
      return True;
   end Parse_IPv4_Number;

   function Canonical_IPv4
     (Input : String; Is_IPv4 : out Boolean; Success : out Boolean) return String
   is
      type Values_Array is array (Positive range 1 .. 4) of Long_Long_Integer;
      Values   : Values_Array := [others => 0];
      Count    : Natural := 0;
      Start    : Natural := Input'First;
      Last     : Natural := Input'Last;
      Value    : Long_Long_Integer;
      Address  : Long_Long_Integer;
      Factor   : Long_Long_Integer;

      function Ends_In_Number (Label : String) return Boolean is
         First : Natural := Label'First;
      begin
         if Label'Length >= 2 and then Label (First) = '0'
           and then Label (First + 1) in 'x' | 'X'
         then
            First := First + 2;
            if First > Label'Last then
               return True;
            end if;
            for Index in First .. Label'Last loop
               if not Is_Hex (Label (Index)) then
                  return False;
               end if;
            end loop;
            return True;
         end if;
         for C of Label loop
            if not Is_Digit (C) then
               return False;
            end if;
         end loop;
         return Label'Length > 0;
      end Ends_In_Number;
   begin
      Is_IPv4 := False;
      Success := True;
      if Input'Length = 0 then
         return Input;
      end if;
      --  Only one trailing dot is ignored by the IPv4 parser.  With two or
      --  more trailing dots, the last domain label is empty and the host is
      --  not an IPv4 address.
      if Input'Length >= 2
        and then Input (Input'Last) = '.'
        and then Input (Input'Last - 1) = '.'
      then
         return Input;
      end if;
      if Input (Last) = '.' then
         Last := Last - 1;
      end if;
      if Last < Start then
         return Input;
      end if;
      declare
         Label_First : Natural := Last;
      begin
         while Label_First > Input'First and then Input (Label_First - 1) /= '.' loop
            Label_First := Label_First - 1;
         end loop;
         if not Ends_In_Number (Input (Label_First .. Last)) then
            return Input;
         end if;
         Is_IPv4 := True;
      end;
      for Position in Start .. Last + 1 loop
         if Position > Last or else Input (Position) = '.' then
            Count := Count + 1;
            if Count > 4 or else Position = Start
              or else not Parse_IPv4_Number
                (Input (Start .. Position - 1), Value)
            then
               Success := False;
               return Input;
            end if;
            Values (Count) := Value;
            Start := Position + 1;
         end if;
      end loop;
      if Count = 0 then
         return Input;
      end if;
      for Index in 1 .. Count - 1 loop
         if Values (Index) > 255 then
            Is_IPv4 := True;
            Success := False;
            return "";
         end if;
      end loop;
      Factor := 1;
      for Index in 1 .. 5 - Count loop
         Factor := Factor * 256;
      end loop;
      if Values (Count) >= Factor then
         Is_IPv4 := True;
         Success := False;
         return "";
      end if;
      Address := Values (Count);
      Factor := 256 * 256 * 256;
      for Index in 1 .. Count - 1 loop
         Address := Address + Values (Index) * Factor;
         Factor := Factor / 256;
      end loop;
      return
        Number_Image ((Address / 16#1000000#) mod 256) & "."
        & Number_Image ((Address / 16#10000#) mod 256) & "."
        & Number_Image ((Address / 16#100#) mod 256) & "."
        & Number_Image (Address mod 256);
   end Canonical_IPv4;

   function Hex_Image (Value : Natural) return String is
      Result : String (1 .. 4);
      First  : Positive := Result'Last;
      Number : Natural := Value;
   begin
      loop
         Result (First) := Character'Val
           ((if Number mod 16 < 10 then Character'Pos ('0')
             else Character'Pos ('a') - 10) + Number mod 16);
         Number := Number / 16;
         exit when Number = 0;
         First := First - 1;
      end loop;
      return Result (First .. Result'Last);
   end Hex_Image;

   function Canonical_IPv6 (Input : String; Success : out Boolean) return String is
      type Pieces_Array is array (Natural range 0 .. 7) of Natural;
      Pieces       : Pieces_Array := [others => 0];
      Piece_Count  : Natural := 0;
      Compress_At  : Integer := -1;
      Position     : Natural := Input'First;
      Start        : Natural;
      Value        : Natural;
      Best_First   : Integer := -1;
      Best_Length  : Natural := 1;
      Run_First    : Natural;
      Run_Length   : Natural;
      Result       : U.Unbounded_String;
   begin
      Success := False;
      if Input'Length = 0 then
         return "";
      end if;
      if Input (Position) = ':' then
         if Position = Input'Last or else Input (Position + 1) /= ':' then
            return "";
         end if;
         Compress_At := 0;
         Position := Position + 2;
      end if;
      while Position <= Input'Last loop
         if Piece_Count = 8 then
            return "";
         end if;
         Start := Position;
         Value := 0;
         while Position <= Input'Last and then Is_Hex (Input (Position)) loop
            if Position - Start = 4 then
               return "";
            end if;
            Value := Value * 16 + Hex_Value (Input (Position));
            Position := Position + 1;
         end loop;
         if Position <= Input'Last and then Input (Position) = '.' then
            declare
               IPv4 : constant String := Input (Start .. Input'Last);
               A, B, C, D : Natural := 0;
               Part : Natural := 1;
               Digit_Count : Natural := 0;
            begin
               if Piece_Count > 6 then
                  return "";
               end if;
               for Ch of IPv4 loop
                  if Is_Digit (Ch) then
                     Digit_Count := Digit_Count + 1;
                     if Part = 1 then A := A * 10 + Character'Pos (Ch) - 48;
                     elsif Part = 2 then B := B * 10 + Character'Pos (Ch) - 48;
                     elsif Part = 3 then C := C * 10 + Character'Pos (Ch) - 48;
                     else D := D * 10 + Character'Pos (Ch) - 48;
                     end if;
                  elsif Ch = '.' and then Digit_Count > 0 and then Part < 4 then
                     Part := Part + 1;
                     Digit_Count := 0;
                  else
                     return "";
                  end if;
               end loop;
               if Part /= 4 or else Digit_Count = 0
                 or else A > 255 or else B > 255 or else C > 255 or else D > 255
               then
                  return "";
               end if;
               Pieces (Piece_Count) := A * 256 + B;
               Pieces (Piece_Count + 1) := C * 256 + D;
               Piece_Count := Piece_Count + 2;
               Position := Input'Last + 1;
               exit;
            end;
         end if;
         if Position = Start then
            return "";
         end if;
         Pieces (Piece_Count) := Value;
         Piece_Count := Piece_Count + 1;
         exit when Position > Input'Last;
         if Input (Position) /= ':' then
            return "";
         end if;
         if Position < Input'Last and then Input (Position + 1) = ':' then
            if Compress_At /= -1 then
               return "";
            end if;
            Compress_At := Integer (Piece_Count);
            Position := Position + 2;
            exit when Position > Input'Last;
         else
            Position := Position + 1;
            if Position > Input'Last then
               return "";
            end if;
         end if;
      end loop;
      if Compress_At >= 0 then
         declare
            Missing : constant Natural := 8 - Piece_Count;
         begin
            if Missing = 0 then
               return "";
            end if;
            for Index in reverse Natural (Compress_At) .. Piece_Count - 1 loop
               Pieces (Index + Missing) := Pieces (Index);
            end loop;
            for Index in Natural (Compress_At) .. Natural (Compress_At) + Missing - 1 loop
               Pieces (Index) := 0;
            end loop;
            Piece_Count := 8;
         end;
      elsif Piece_Count /= 8 then
         return "";
      end if;
      Run_First := 0;
      while Run_First < 8 loop
         if Pieces (Run_First) = 0 then
            Run_Length := 1;
            while Run_First + Run_Length < 8
              and then Pieces (Run_First + Run_Length) = 0
            loop
               Run_Length := Run_Length + 1;
            end loop;
            if Run_Length > Best_Length then
               Best_First := Integer (Run_First);
               Best_Length := Run_Length;
            end if;
            Run_First := Run_First + Run_Length;
         else
            Run_First := Run_First + 1;
         end if;
      end loop;
      for Index in Pieces'Range loop
         if Index = Best_First then
            U.Append (Result, "::");
         elsif Best_First >= 0
           and then Index > Natural (Best_First)
           and then Index < Natural (Best_First) + Best_Length
         then
            null;
         else
            if U.Length (Result) > 0
              and then U.Element (Result, U.Length (Result)) /= ':'
            then
               U.Append (Result, ':');
            end if;
            U.Append (Result, Hex_Image (Pieces (Index)));
         end if;
      end loop;
      Success := True;
      return U.To_String (Result);
   end Canonical_IPv6;

   function Canonical_Host
     (Input : String; Is_Special : Boolean; Success : out Boolean) return String
   is
      Decoded : constant String := Percent_Decode (Input);
      IDNA_OK : Boolean;
      IPv4    : Boolean;
      IP_OK   : Boolean;
   begin
      Success := False;
      if Input'Length >= 2
        and then Input (Input'First) = '[' and then Input (Input'Last) = ']'
      then
         declare
            Address : constant String := Canonical_IPv6
              (Input (Input'First + 1 .. Input'Last - 1), IP_OK);
         begin
            Success := IP_OK;
            return (if IP_OK then "[" & Address & "]" else "");
         end;
      elsif not Is_Special then
         for C of Input loop
            if C = Character'Val (0)
              or else C = ' '
              or else C in '#' | '/' | ':' | '<' | '>' | '?' | '@' | '[' | '\'
                           | ']' | '^' | '|'
            then
               return "";
            end if;
         end loop;
         Success := True;
         return Encode (Input, Opaque_Set);
      end if;
      declare
         Domain : constant String := Flyology_IRI.IDNA.To_ASCII (Decoded, IDNA_OK);
      begin
         if not IDNA_OK then
            return "";
         end if;
         for C of Domain loop
            if Character'Pos (C) <= 16#20#
              or else C in '#' | '%' | '/' | ':' | '<' | '>' | '?' | '@' | '['
                           | '\' | ']' | '^' | '|'
            then
               return "";
            end if;
         end loop;
         declare
            Address : constant String := Canonical_IPv4 (Domain, IPv4, IP_OK);
         begin
            if not IP_OK then
               return "";
            end if;
            Success := True;
            return (if IPv4 then Address else Domain);
         end;
      end;
   end Canonical_Host;

   function Dot_Segment (Segment : String) return Integer is
      Lower : String (1 .. Segment'Length);
      J     : Natural := 0;
   begin
      for Index in Segment'Range loop
         J := J + 1;
         Lower (J) := Ada.Characters.Handling.To_Lower (Segment (Index));
      end loop;
      if Lower in "." | "%2e" then
         return 1;
      elsif Lower in ".." | ".%2e" | "%2e." | "%2e%2e" then
         return 2;
      else
         return 0;
      end if;
   end Dot_Segment;

   procedure Shorten_Path
     (Path : in out U.Unbounded_String; Protect_Drive : Boolean := False)
   is
      Text  : constant String := U.To_String (Path);
      Slash : Natural := 0;
      Search_Last : Natural := Text'Last;
   begin
      if Protect_Drive
        and then Text'Length in 3 .. 4
        and then Text (Text'First) = '/'
        and then Is_Alpha (Text (Text'First + 1))
        and then Text (Text'First + 2) = ':'
        and then (Text'Length = 3 or else Text (Text'Last) = '/')
      then
         return;
      end if;
      --  A trailing slash after another slash is an empty path segment.  A
      --  double-dot segment removes exactly that empty segment, not both
      --  separators.
      if Text'Length > 1
        and then Text (Text'Last) = '/'
        and then Text (Text'Last - 1) = '/'
      then
         U.Set_Unbounded_String (Path, Text (Text'First .. Text'Last - 1));
         return;
      end if;
      if Text'Length > 1 and then Text (Text'Last) = '/' then
         Search_Last := Text'Last - 1;
      end if;
      for Index in reverse Text'First .. Search_Last loop
         if Text (Index) = '/' then
            Slash := Index;
            exit;
         end if;
      end loop;
      if Slash = Text'First then
         U.Set_Unbounded_String (Path, "/");
      elsif Slash = 0 then
         U.Set_Unbounded_String (Path, "");
      else
         U.Set_Unbounded_String (Path, Text (Text'First .. Slash));
      end if;
   end Shorten_Path;

   function Normalize_Path
     (Input      : String;
      Is_Special : Boolean;
      Absolute   : Boolean;
      Is_File    : Boolean) return String
   is
      Result   : U.Unbounded_String;
      Segment  : U.Unbounded_String;
      Position : Natural := Input'First;
      C        : Character;
      Drive_First : constant Natural :=
        (if Input'Length > 0
             and then Input (Input'First) in '/' | '\'
         then Input'First + 1 else Input'First);
      Is_Drive : constant Boolean :=
        Drive_First <= Input'Last
        and then Windows_Drive (Input (Drive_First .. Input'Last));

      procedure Commit (At_End : Boolean) is
         Text : constant String := U.To_String (Segment);
         Dot  : constant Integer := Dot_Segment (Text);
      begin
         if Dot = 2 then
            Shorten_Path (Result, Protect_Drive => Is_File);
            if At_End
              and then (U.Length (Result) = 0
                        or else U.Element (Result, U.Length (Result)) /= '/')
            then
               U.Append (Result, '/');
            end if;
         elsif Dot = 1 then
            if At_End
              and then (U.Length (Result) = 0
                        or else U.Element (Result, U.Length (Result)) /= '/')
            then
               U.Append (Result, '/');
            end if;
         elsif Text'Length > 0 then
            if U.Length (Result) > 0
              and then U.Element (Result, U.Length (Result)) /= '/'
            then
               U.Append (Result, '/');
            end if;
            U.Append (Result, Encode (Text, Path_Set));
         end if;
         U.Set_Unbounded_String (Segment, "");
      end Commit;
   begin
      if Input'Length = 0 then
         return (if Absolute then "/" else "");
      end if;
      if Absolute then
         U.Append (Result, '/');
      end if;
      if Input (Position) = '/' or else (Is_Special and then Input (Position) = '\') then
         Position := Position + 1;
      end if;
      while Position <= Input'Last loop
         C := Input (Position);
         if C = '/' or else (Is_Special and then C = '\') then
            declare
               Dot : constant Integer := Dot_Segment (U.To_String (Segment));
            begin
               Commit (False);
               if Dot = 0
                 or else U.Length (Result) = 0
                 or else U.Element (Result, U.Length (Result)) /= '/'
               then
                  U.Append (Result, '/');
               end if;
            end;
         else
            U.Append (Segment, C);
         end if;
         Position := Position + 1;
      end loop;
      Commit (True);
      declare
         Text : String := U.To_String (Result);
      begin
         if Is_Special and then Is_Drive and then Text'Length >= 3
           and then Text (Text'First) = '/'
           and then Is_Alpha (Text (Text'First + 1))
           and then Text (Text'First + 2) = '|'
         then
            Text (Text'First + 2) := ':';
         end if;
         return Text;
      end;
   end Normalize_Path;

   function Serialize (Value : URL_Parts) return String is
      Result : U.Unbounded_String;
   begin
      U.Append (Result, U.To_String (Value.Scheme) & ":");
      if Value.Has_Authority then
         U.Append (Result, "//");
         if U.Length (Value.Username) > 0 or else U.Length (Value.Password) > 0 then
            U.Append (Result, U.To_String (Value.Username));
            if U.Length (Value.Password) > 0 then
               U.Append (Result, ":" & U.To_String (Value.Password));
            end if;
            U.Append (Result, '@');
         end if;
         U.Append (Result, U.To_String (Value.Host));
         if U.Length (Value.Port) > 0 then
            U.Append (Result, ":" & U.To_String (Value.Port));
         end if;
      end if;
      if not Value.Has_Authority
        and then U.Length (Value.Path) >= 2
        and then U.Element (Value.Path, 1) = '/'
        and then U.Element (Value.Path, 2) = '/'
      then
         U.Append (Result, "/.");
      end if;
      U.Append (Result, U.To_String (Value.Path));
      if Value.Has_Query then
         U.Append (Result, "?" & U.To_String (Value.Query));
      end if;
      if Value.Has_Fragment then
         U.Append (Result, "#" & U.To_String (Value.Fragment));
      end if;
      return U.To_String (Result);
   end Serialize;

   procedure Parse_Authority
     (Text : String; Is_Special : Boolean; Value : in out URL_Parts)
   is
      At_Sign   : Natural := 0;
      Host_First : Natural := Text'First;
      Host_Last  : Natural := Text'Last;
      Port_Colon : Natural := 0;
      Host_OK    : Boolean;
      Port_Value : Natural := 0;
   begin
      for Index in Text'Range loop
         if Text (Index) = '@' then
            At_Sign := Index;
         end if;
      end loop;
      if At_Sign /= 0 then
         declare
            Password_Mode : Boolean := False;
         begin
            for Index in Text'First .. At_Sign - 1 loop
               if Text (Index) = '@' then
                  if Password_Mode then
                     U.Append (Value.Password, "%40");
                  else
                     U.Append (Value.Username, "%40");
                  end if;
               elsif Text (Index) = ':' and then not Password_Mode then
                  Password_Mode := True;
               else
                  if Password_Mode then
                     U.Append
                       (Value.Password, Encode (Text (Index .. Index), Userinfo_Set));
                  else
                     U.Append
                       (Value.Username, Encode (Text (Index .. Index), Userinfo_Set));
                  end if;
               end if;
            end loop;
         end;
         Host_First := At_Sign + 1;
      end if;
      if Host_First > Text'Last then
         Fail (Value, Invalid_Authority, Host_First);
         return;
      end if;
      if Text (Host_First) = '[' then
         Host_Last := 0;
         for Index in Host_First + 1 .. Text'Last loop
            if Text (Index) = ']' then
               Host_Last := Index;
               exit;
            end if;
         end loop;
         if Host_Last = 0 then
            Fail (Value, Invalid_Authority, Host_First);
            return;
         elsif Host_Last < Text'Last then
            if Text (Host_Last + 1) /= ':' then
               Fail (Value, Invalid_Authority, Host_Last + 1);
               return;
            end if;
            Port_Colon := Host_Last + 1;
         end if;
      else
         for Index in reverse Host_First .. Text'Last loop
            if Text (Index) = ':' then
               Port_Colon := Index;
               Host_Last := Index - 1;
               exit;
            end if;
         end loop;
      end if;
      declare
         Host_Text : constant String :=
           (if Host_First <= Host_Last then Text (Host_First .. Host_Last) else "");
         Canonical : constant String := Canonical_Host (Host_Text, Is_Special, Host_OK);
      begin
         if not Host_OK or else (Is_Special and then Canonical'Length = 0) then
            Fail (Value, Invalid_Authority, Host_First);
            return;
         end if;
         U.Set_Unbounded_String (Value.Host, Canonical);
      end;
      if Port_Colon /= 0 and then Port_Colon < Text'Last then
         if U.To_String (Value.Scheme) = "file" then
            Fail (Value, Invalid_Authority, Port_Colon);
            return;
         end if;
         for Index in Port_Colon + 1 .. Text'Last loop
            if not Is_Digit (Text (Index)) then
               Fail (Value, Invalid_Authority, Index);
               return;
            end if;
            Port_Value := Port_Value * 10 + Character'Pos (Text (Index)) - 48;
            if Port_Value > 65_535 then
               Fail (Value, Invalid_Authority, Index);
               return;
            end if;
         end loop;
         declare
            Port_Text : constant String := Number_Image (Long_Long_Integer (Port_Value));
         begin
            if Port_Text /= Default_Port (U.To_String (Value.Scheme)) then
               U.Set_Unbounded_String (Value.Port, Port_Text);
            end if;
         end;
      end if;
      if Port_Colon /= 0 and then Host_First > Host_Last then
         Fail (Value, Invalid_Authority, Host_First);
         return;
      end if;
      if U.To_String (Value.Scheme) = "file"
        and then U.To_String (Value.Host) = "localhost"
      then
         Value.Host := U.Null_Unbounded_String;
      end if;
      Value.Has_Authority := True;
   end Parse_Authority;

   procedure Parse_Tail
     (Text         : String;
      Position     : in out Natural;
      Is_Special   : Boolean;
      Absolute_Path : Boolean;
      Value        : in out URL_Parts)
   is
      Path_Last : Natural := Text'Last;
      Query_At  : Natural := 0;
      Hash_At   : Natural := 0;
   begin
      for Index in Position .. Text'Last loop
         if Text (Index) = '?' and then Query_At = 0 then
            Query_At := Index;
            Path_Last := Index - 1;
         elsif Text (Index) = '#' then
            Hash_At := Index;
            if Query_At = 0 then
               Path_Last := Index - 1;
            end if;
            exit;
         end if;
      end loop;
      if Position <= Path_Last then
         U.Set_Unbounded_String
           (Value.Path,
            Normalize_Path
              (Text (Position .. Path_Last),
               Is_Special,
               Absolute_Path,
               U.To_String (Value.Scheme) = "file"));
      elsif Absolute_Path and then Value.Has_Authority and then Is_Special then
         U.Set_Unbounded_String (Value.Path, "/");
      end if;
      if Query_At /= 0 then
         Value.Has_Query := True;
         declare
            Last : constant Natural :=
              (if Hash_At = 0 then Text'Last else Hash_At - 1);
         begin
            U.Set_Unbounded_String
              (Value.Query,
               Encode
                 (Text (Query_At + 1 .. Last),
                  (if Is_Special then Special_Query_Set else Query_Set)));
         end;
      end if;
      if Hash_At /= 0 then
         Value.Has_Fragment := True;
         U.Set_Unbounded_String
           (Value.Fragment,
            Encode (Text (Hash_At + 1 .. Text'Last), Fragment_Set));
      end if;
      Position := Text'Last + 1;
   end Parse_Tail;

   --  A scheme candidate is the run before a colon that precedes the first
   --  slash of the hierarchical part. Without such a colon the input is a
   --  relative reference, which web URL mode does not accept on its own.
   --  This is the classification the URI and IRI grammars apply, so the
   --  three syntaxes report a missing scheme the same way.
   function Scheme_Failure (Text : String; Offset : Natural) return Parse_Error
   is
      Hier_Last : Natural := Text'Last;
   begin
      for Index in Text'Range loop
         if Text (Index) in '#' | '?' then
            Hier_Last := Index - 1;
            exit;
         end if;
      end loop;
      for Index in Text'First .. Hier_Last loop
         exit when Text (Index) = '/';
         if Text (Index) = ':' then
            return
              (Kind   => Invalid_Scheme,
               Offset => (if Offset = 0 then 1 else Offset));
         end if;
      end loop;
      return (Kind => Relative_URL, Offset => 0);
   end Scheme_Failure;

   function Parse_Absolute (Text : String; Success : out Boolean) return URL_Parts;

   function Parse_Absolute (Text : String; Success : out Boolean) return URL_Parts is
      Value      : URL_Parts;
      Colon      : Natural := 0;
      Position   : Natural;
      Is_Special : Boolean;
      Authority_Last : Natural;
      Parse_Authority_Now : Boolean := False;
   begin
      Success := False;
      if Text'Length = 0 or else not Is_Alpha (Text (Text'First)) then
         Value.Error := Scheme_Failure (Text, 0);
         return Value;
      end if;
      for Index in Text'First + 1 .. Text'Last loop
         if Text (Index) = ':' then
            Colon := Index;
            exit;
         elsif not Is_Alpha (Text (Index)) and then not Is_Digit (Text (Index))
           and then Text (Index) not in '+' | '-' | '.'
         then
            Value.Error :=
              Scheme_Failure (Text, Index - Text'First + 1);
            return Value;
         end if;
      end loop;
      if Colon = 0 then
         Value.Error := Scheme_Failure (Text, 0);
         return Value;
      end if;
      U.Set_Unbounded_String
        (Value.Scheme,
         Ada.Characters.Handling.To_Lower (Text (Text'First .. Colon - 1)));
      Is_Special := Special (U.To_String (Value.Scheme));
      Position := Colon + 1;
      Value.Valid := True;

      if not Is_Special
        and then (Position > Text'Last or else Text (Position) /= '/')
      then
         Value.Opaque_Path := True;
         declare
            Query_At : Natural := 0;
            Hash_At  : Natural := 0;
            Path_Last : Natural := Text'Last;
         begin
            for Index in Position .. Text'Last loop
               if Text (Index) = '?' and then Query_At = 0 then
                  Query_At := Index;
                  Path_Last := Index - 1;
               elsif Text (Index) = '#' then
                  Hash_At := Index;
                  if Query_At = 0 then Path_Last := Index - 1; end if;
                  exit;
               end if;
            end loop;
            U.Set_Unbounded_String
              (Value.Path,
               Encode_Opaque_Path
                 (Text (Position .. Path_Last), Query_At /= 0 or else Hash_At /= 0));
            if Query_At /= 0 then
               Value.Has_Query := True;
               U.Set_Unbounded_String
                 (Value.Query,
                  Encode
                    (Text (Query_At + 1 .. (if Hash_At = 0 then Text'Last else Hash_At - 1)),
                     Query_Set));
            end if;
            if Hash_At /= 0 then
               Value.Has_Fragment := True;
               U.Set_Unbounded_String
                 (Value.Fragment, Encode (Text (Hash_At + 1 .. Text'Last), Fragment_Set));
            end if;
         end;
         Success := True;
         return Value;
      end if;

      if U.To_String (Value.Scheme) = "file" then
         Value.Has_Authority := True;
         if Position + 1 <= Text'Last
           and then Text (Position) in '/' | '\'
           and then Text (Position + 1) in '/' | '\'
         then
            Position := Position + 2;
            Parse_Authority_Now := True;
         end if;
      elsif Is_Special then
         while Position <= Text'Last and then Text (Position) in '/' | '\' loop
            Position := Position + 1;
         end loop;
         Parse_Authority_Now := True;
      elsif Position + 1 <= Text'Last
        and then Text (Position .. Position + 1) = "//"
      then
         Position := Position + 2;
         Parse_Authority_Now := True;
      end if;

      if Parse_Authority_Now then
         Authority_Last := Text'Last;
         for Index in Position .. Text'Last loop
            if Text (Index) in '/' | '?' | '#'
              or else (Is_Special and then Text (Index) = '\')
            then
               Authority_Last := Index - 1;
               exit;
            end if;
         end loop;
         if U.To_String (Value.Scheme) = "file"
           and then Position <= Authority_Last
           and then Windows_Drive (Text (Position .. Authority_Last))
         then
            Value.Has_Authority := True;
            Value.Host := U.Null_Unbounded_String;
            declare
               Tail : constant String := "/" & Text (Position .. Text'Last);
               Tail_Position : Natural := Tail'First;
            begin
               Parse_Tail (Tail, Tail_Position, True, True, Value);
               Success := Value.Valid;
               return Value;
            end;
         end if;
         if Position > Authority_Last and then Is_Special
           and then U.To_String (Value.Scheme) /= "file"
         then
            Fail (Value, Invalid_Authority, Position);
            return Value;
         elsif Position > Authority_Last then
            Value.Has_Authority := True;
            Position := Authority_Last + 1;
         else
            Parse_Authority
              (Text (Position .. Authority_Last), Is_Special, Value);
            if not Value.Valid then
               return Value;
            end if;
            Position := Authority_Last + 1;
         end if;
      end if;
      Parse_Tail (Text, Position, Is_Special, True, Value);
      Success := Value.Valid;
      return Value;
   end Parse_Absolute;

   function Parse_Relative
     (Text : String; Base : URL_Parts; Success : out Boolean) return URL_Parts
   is
      Value      : URL_Parts := Base;
      Position   : Natural := Text'First;
      Is_Special : constant Boolean := Special (U.To_String (Base.Scheme));
      Authority_Last : Natural;
      Colon : Natural := 0;
      Drive_After_Slashes : Boolean := False;
   begin
      Success := False;
      Value.Has_Fragment := False;
      U.Set_Unbounded_String (Value.Fragment, "");
      if Text'Length = 0 then
         if Base.Opaque_Path then
            Fail (Value, Relative_URL);
            return Value;
         end if;
         Value.Valid := True;
         Success := True;
         return Value;
      end if;

      if Is_Alpha (Text (Text'First)) then
         for Index in Text'First + 1 .. Text'Last loop
            if Text (Index) = ':' then
               Colon := Index;
               exit;
            elsif not Is_Alpha (Text (Index)) and then not Is_Digit (Text (Index))
              and then Text (Index) not in '+' | '-' | '.'
            then
               exit;
            end if;
         end loop;
      end if;
      if Colon /= 0 then
         declare
            Candidate : constant String := Ada.Characters.Handling.To_Lower
              (Text (Text'First .. Colon - 1));
         begin
            if Candidate /= U.To_String (Base.Scheme)
              or else not Special (Candidate)
              or else (Colon + 2 <= Text'Last
                       and then Text (Colon + 1) in '/' | '\'
                       and then Text (Colon + 2) in '/' | '\')
            then
               return Parse_Absolute (Text, Success);
            end if;
            Position := Colon + 1;
         end;
      end if;

      if Position > Text'Last then
         Value.Valid := True;
         Success := True;
         return Value;
      end if;

      if Position <= Text'Last and then Text (Position) = '#' then
         Value.Has_Fragment := True;
         U.Set_Unbounded_String
           (Value.Fragment, Encode (Text (Position + 1 .. Text'Last), Fragment_Set));
         Value.Valid := True;
         Success := True;
         return Value;
      end if;

      if Base.Opaque_Path then
         Fail (Value, Relative_URL);
         return Value;
      end if;

      if Position <= Text'Last and then Text (Position) = '?' then
         Value.Has_Query := True;
         U.Set_Unbounded_String
           (Value.Query,
            Encode
              (Text (Position + 1 .. Text'Last),
               (if Is_Special then Special_Query_Set else Query_Set)));
         Value.Valid := True;
         Success := True;
         return Value;
      end if;

      Value.Has_Query := False;
      U.Set_Unbounded_String (Value.Query, "");
      if U.To_String (Value.Scheme) = "file"
        and then Position + 3 <= Text'Last
        and then Text (Position) in '/' | '\'
        and then Text (Position + 1) in '/' | '\'
        and then Windows_Drive (Text (Position + 2 .. Text'Last))
      then
         Position := Position + 2;
         Drive_After_Slashes := True;
      end if;
      if U.To_String (Value.Scheme) = "file"
        and then Position <= Text'Last
        and then Windows_Drive (Text (Position .. Text'Last))
      then
         Value.Username := U.Null_Unbounded_String;
         Value.Password := U.Null_Unbounded_String;
         if Drive_After_Slashes then
            Value.Host := U.Null_Unbounded_String;
         end if;
         Value.Port := U.Null_Unbounded_String;
         Value.Path := U.Null_Unbounded_String;
         Value.Has_Authority := True;
         Parse_Tail (Text, Position, True, True, Value);
         Value.Valid := True;
         Success := True;
         return Value;
      end if;
      if Position + 1 <= Text'Last
        and then
          ((Is_Special
            and then Text (Position) in '/' | '\'
            and then Text (Position + 1) in '/' | '\')
           or else
             (not Is_Special
              and then Text (Position .. Position + 1) = "//"))
      then
         Position := Position + 2;
         if Is_Special and then U.To_String (Value.Scheme) /= "file" then
            while Position <= Text'Last
              and then Text (Position) in '/' | '\'
            loop
               Position := Position + 1;
            end loop;
         end if;
         Value.Username := U.Null_Unbounded_String;
         Value.Password := U.Null_Unbounded_String;
         Value.Host := U.Null_Unbounded_String;
         Value.Port := U.Null_Unbounded_String;
         Authority_Last := Text'Last;
         for Index in Position .. Text'Last loop
            if Text (Index) in '/' | '?' | '#'
              or else (Is_Special and then Text (Index) = '\')
            then
               Authority_Last := Index - 1;
               exit;
            end if;
         end loop;
         if Position > Authority_Last then
            if U.To_String (Value.Scheme) = "file" or else not Is_Special then
               Value.Has_Authority := True;
               Value.Host := U.Null_Unbounded_String;
               Position := Authority_Last + 1;
            else
               Fail (Value, Invalid_Authority, Position);
               return Value;
            end if;
         else
            Parse_Authority (Text (Position .. Authority_Last), Is_Special, Value);
            if not Value.Valid then
               return Value;
            end if;
            Position := Authority_Last + 1;
         end if;
         Value.Path := U.Null_Unbounded_String;
         Parse_Tail (Text, Position, Is_Special, True, Value);
      elsif Text (Position) = '/'
        or else (Is_Special and then Text (Position) = '\')
      then
         declare
            Base_Path : constant String := U.To_String (Base.Path);
            Has_Drive : constant Boolean :=
              U.To_String (Value.Scheme) = "file"
              and then Base_Path'Length >= 3
              and then Base_Path (Base_Path'First) = '/'
              and then Is_Alpha (Base_Path (Base_Path'First + 1))
              and then Base_Path (Base_Path'First + 2) = ':'
              and then not
                (Position < Text'Last
                 and then Windows_Drive
                   (Text (Position + 1 .. Text'Last)));
         begin
            Value.Path := U.Null_Unbounded_String;
            if Has_Drive then
               declare
                  Merged : constant String :=
                    Base_Path (Base_Path'First .. Base_Path'First + 2)
                    & Text (Position .. Text'Last);
                  P : Natural := Merged'First;
               begin
                  Parse_Tail (Merged, P, Is_Special, True, Value);
               end;
            else
               Parse_Tail (Text, Position, Is_Special, True, Value);
            end if;
         end;
      else
         declare
            Base_Path : constant String := U.To_String (Value.Path);
            Last_Slash : Natural := 0;
         begin
            for Index in reverse Base_Path'Range loop
               if Base_Path (Index) = '/' then
                  Last_Slash := Index;
                  exit;
               end if;
            end loop;
            declare
               Prefix : constant String :=
                 (if Last_Slash = 0 then ""
                  else Base_Path (Base_Path'First .. Last_Slash));
               Merged : constant String := Prefix & Text (Position .. Text'Last);
               P : Natural := Merged'First;
            begin
               Value.Path := U.Null_Unbounded_String;
               Parse_Tail (Merged, P, Is_Special, True, Value);
            end;
         end;
      end if;
      Value.Valid := True;
      Success := True;
      return Value;
   end Parse_Relative;

   function Parse
     (Input    : String;
      Base     : String;
      Has_Base : Boolean;
      Error    : out Parse_Error) return String
   is
      Text    : constant String := Preprocess (Input);
      Base_OK : Boolean;
      Success : Boolean := False;
      Parsed  : URL_Parts;
   begin
      Error := (Kind => No_Error, Offset => 0);
      if Has_Base then
         declare
            Base_Text : constant String := Preprocess (Base);
            Base_URL  : constant URL_Parts := Parse_Absolute (Base_Text, Base_OK);
         begin
            if not Base_OK then
               --  The base failed to reparse, so its offsets name bytes the
               --  caller never supplied.
               Error := (Kind => Base_URL.Error.Kind, Offset => 0);
               return "";
            end if;
            Parsed := Parse_Relative (Text, Base_URL, Success);
         end;
      else
         Parsed := Parse_Absolute (Text, Success);
      end if;
      if not Success or else not Parsed.Valid then
         Error :=
           (if Parsed.Error.Kind = No_Error
            then (Kind => Invalid_Character, Offset => 0)
            else (Kind   => Parsed.Error.Kind,
                  Offset => Input_Offset (Input, Parsed.Error.Offset)));
         return "";
      end if;
      return Serialize (Parsed);
   end Parse;

end Flyology_IRI.Web;
