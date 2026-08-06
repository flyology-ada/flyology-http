with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology_IRI;

procedure Flyology_IRI_URL_CLI is
   package CLI renames Ada.Command_Line;

   function Hex_Value (C : Character) return Natural is
     (if C in '0' .. '9' then Character'Pos (C) - Character'Pos ('0')
      elsif C in 'A' .. 'F' then Character'Pos (C) - Character'Pos ('A') + 10
      else Character'Pos (C) - Character'Pos ('a') + 10);

   function Decode (Text : String) return String is
      Result : String (1 .. Text'Length / 2);
      Source : Natural := Text'First;
   begin
      if Text'Length mod 2 /= 0 then
         raise Constraint_Error;
      end if;
      for Index in Result'Range loop
         Result (Index) := Character'Val
           (Hex_Value (Text (Source)) * 16 + Hex_Value (Text (Source + 1)));
         Source := Source + 2;
      end loop;
      return Result;
   end Decode;

   function Encode (Text : String) return String is
      Hex_Chars : constant String := "0123456789abcdef";
      Result : String (1 .. Text'Length * 2);
      Target : Natural := 1;
      Value  : Natural;
   begin
      for C of Text loop
         Value := Character'Pos (C);
         Result (Target) := Hex_Chars (Value / 16 + 1);
         Result (Target + 1) := Hex_Chars (Value mod 16 + 1);
         Target := Target + 2;
      end loop;
      return Result;
   end Encode;

   procedure Put_URL (Value : Flyology_IRI.Reference) is
      Userinfo  : constant String := Flyology_IRI.Userinfo (Value);
      Authority : constant String := Flyology_IRI.Authority (Value);
      Port      : constant String := Flyology_IRI.Port (Value);
      User_Colon : Natural := 0;
      Last_At    : Natural := 0;
   begin
      for Index in Userinfo'Range loop
         if Userinfo (Index) = ':' then
            User_Colon := Index;
            exit;
         end if;
      end loop;
      for Index in Authority'Range loop
         if Authority (Index) = '@' then
            Last_At := Index;
         end if;
      end loop;
      declare
         Username : constant String :=
           (if User_Colon = 0 then Userinfo
            else Userinfo (Userinfo'First .. User_Colon - 1));
         Password : constant String :=
           (if User_Colon = 0 then ""
            else Userinfo (User_Colon + 1 .. Userinfo'Last));
         Host : constant String :=
           (if Last_At = 0 then Authority
            else Authority (Last_At + 1 .. Authority'Last));
         Hostname : constant String :=
           (if Port'Length = 0 then Host
            else Host (Host'First .. Host'Last - Port'Length - 1));
         Search : constant String :=
           (if Flyology_IRI.Query (Value)'Length > 0
            then "?" & Flyology_IRI.Query (Value) else "");
         Hash : constant String :=
           (if Flyology_IRI.Fragment (Value)'Length > 0
            then "#" & Flyology_IRI.Fragment (Value) else "");
         Fields : constant array (Positive range 1 .. 10) of
           Ada.Strings.Unbounded.Unbounded_String :=
             [Ada.Strings.Unbounded.To_Unbounded_String
                (Flyology_IRI.Image (Value)),
              Ada.Strings.Unbounded.To_Unbounded_String
                (Flyology_IRI.Scheme (Value) & ":"),
              Ada.Strings.Unbounded.To_Unbounded_String (Username),
              Ada.Strings.Unbounded.To_Unbounded_String (Password),
              Ada.Strings.Unbounded.To_Unbounded_String (Host),
              Ada.Strings.Unbounded.To_Unbounded_String (Hostname),
              Ada.Strings.Unbounded.To_Unbounded_String (Port),
              Ada.Strings.Unbounded.To_Unbounded_String
                (Flyology_IRI.Path (Value)),
              Ada.Strings.Unbounded.To_Unbounded_String (Search),
              Ada.Strings.Unbounded.To_Unbounded_String (Hash)];
      begin
         Ada.Text_IO.Put ("OK");
         for Field of Fields loop
            Ada.Text_IO.Put
              (ASCII.HT & Encode (Ada.Strings.Unbounded.To_String (Field)));
         end loop;
         Ada.Text_IO.New_Line;
      end;
   end Put_URL;
begin
   if CLI.Argument_Count /= 2 then
      CLI.Set_Exit_Status (CLI.Failure);
      return;
   end if;
   declare
      Input : constant String := Decode (CLI.Argument (1));
   begin
      if CLI.Argument (2) = "-" then
         declare
            URL : constant Flyology_IRI.Reference := Flyology_IRI.Parse
              (Input, Flyology_IRI.Web_URL_Syntax, Positive'Last);
         begin
            Put_URL (URL);
         end;
      else
         declare
            Base : constant Flyology_IRI.Reference := Flyology_IRI.Parse
              (Decode (CLI.Argument (2)), Flyology_IRI.Web_URL_Syntax, Positive'Last);
            URL  : constant Flyology_IRI.Reference := Flyology_IRI.Parse
              (Input, Base, Positive'Last);
         begin
            Put_URL (URL);
         end;
      end if;
   exception
      when E : others =>
         Ada.Text_IO.Put_Line
           ("FAIL" & ASCII.HT & Ada.Exceptions.Exception_Message (E));
   end;
end Flyology_IRI_URL_CLI;
