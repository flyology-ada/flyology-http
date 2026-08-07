with Ada.Characters.Handling;
with Ada.Strings.Unbounded;
with Ada.Strings.Wide_Wide_Unbounded;
with Ada.Strings.UTF_Encoding;
with Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
with Ada.Wide_Wide_Characters.Handling;

package body Flyology_IRI.IDNA is

   package Bytes renames Ada.Strings.Unbounded;
   package Wide renames Ada.Strings.Wide_Wide_Unbounded;
   package UTF renames Ada.Strings.UTF_Encoding;
   package UTF_32 renames Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
   package Unicode renames Ada.Wide_Wide_Characters.Handling;

   Base         : constant Long_Long_Integer := 36;
   T_Min        : constant Long_Long_Integer := 1;
   T_Max        : constant Long_Long_Integer := 26;
   Skew         : constant Long_Long_Integer := 38;
   Damp         : constant Long_Long_Integer := 700;
   Initial_Bias : constant Long_Long_Integer := 72;
   Initial_N    : constant Long_Long_Integer := 128;

   function Encode_Digit (Value : Long_Long_Integer) return Character is
     (if Value < 26
      then Character'Val (Character'Pos ('a') + Integer (Value))
      else Character'Val (Character'Pos ('0') + Integer (Value - 26)));

   function Adapt
     (Original_Delta : Long_Long_Integer;
      Points         : Long_Long_Integer;
      First_Time     : Boolean) return Long_Long_Integer
   is
      Delta_Value : Long_Long_Integer :=
        (if First_Time then Original_Delta / Damp else Original_Delta / 2);
      K     : Long_Long_Integer := 0;
   begin
      Delta_Value := Delta_Value + Delta_Value / Points;
      while Delta_Value > ((Base - T_Min) * T_Max) / 2 loop
         Delta_Value := Delta_Value / (Base - T_Min);
         K := K + Base;
      end loop;
      return K + ((Base - T_Min + 1) * Delta_Value) / (Delta_Value + Skew);
   end Adapt;

   function Punycode
     (Label : Wide_Wide_String; Success : out Boolean) return String
   is
      Result : Bytes.Unbounded_String;
      N      : Long_Long_Integer := Initial_N;
      Delta_Value : Long_Long_Integer := 0;
      Bias   : Long_Long_Integer := Initial_Bias;
      Basic  : Long_Long_Integer := 0;
      Handled : Long_Long_Integer;
      M, Code, Q, K, T : Long_Long_Integer;
   begin
      Success := False;
      for Item of Label loop
         Code := Wide_Wide_Character'Pos (Item);
         if Code < 16#80# then
            Bytes.Append
              (Result,
               Ada.Characters.Handling.To_Lower (Character'Val (Code)));
            Basic := Basic + 1;
         end if;
      end loop;
      Handled := Basic;
      if Basic > 0 and then Basic < Long_Long_Integer (Label'Length) then
         Bytes.Append (Result, '-');
      end if;

      while Handled < Long_Long_Integer (Label'Length) loop
         M := Long_Long_Integer'Last;
         for Item of Label loop
            Code := Wide_Wide_Character'Pos (Item);
            if Code >= N and then Code < M then
               M := Code;
            end if;
         end loop;
         if M = Long_Long_Integer'Last
           or else M - N >
             (Long_Long_Integer'Last - Delta_Value) / (Handled + 1)
         then
            return "";
         end if;
         Delta_Value := Delta_Value + (M - N) * (Handled + 1);
         N := M;
         for Item of Label loop
            Code := Wide_Wide_Character'Pos (Item);
            if Code < N then
               if Delta_Value = Long_Long_Integer'Last then
                  return "";
               end if;
               Delta_Value := Delta_Value + 1;
            elsif Code = N then
               Q := Delta_Value;
               K := Base;
               loop
                  T :=
                    (if K <= Bias + T_Min then T_Min
                     elsif K >= Bias + T_Max then T_Max
                     else K - Bias);
                  exit when Q < T;
                  Bytes.Append
                    (Result,
                     Encode_Digit (T + ((Q - T) mod (Base - T))));
                  Q := (Q - T) / (Base - T);
                  K := K + Base;
               end loop;
               Bytes.Append (Result, Encode_Digit (Q));
               Bias := Adapt (Delta_Value, Handled + 1, Handled = Basic);
               Delta_Value := 0;
               Handled := Handled + 1;
            end if;
         end loop;
         Delta_Value := Delta_Value + 1;
         N := N + 1;
      end loop;
      Success := True;
      return Bytes.To_String (Result);
   end Punycode;

   function Map_Input
     (Input : Wide_Wide_String; Success : out Boolean)
      return Wide_Wide_String
   is
      Result : Wide.Unbounded_Wide_Wide_String;
      Code   : Natural;
      Mapped : Wide_Wide_Character;
   begin
      Success := False;
      for Item of Input loop
         Code := Wide_Wide_Character'Pos (Item);
         if Code in 16#00AD# | 16#034F# | 16#1806# | 16#180B# .. 16#180D#
           | 16#200B# | 16#2060# | 16#FE00# .. 16#FE0F# | 16#FEFF#
         then
            null;
         elsif Code in 16#0000# .. 16#001F# | 16#007F#
           or else Code = 16#FFFD#
           or else Unicode.Is_Space (Item)
           or else Code in 16#D800# .. 16#DFFF#
           or else Code in 16#FDD0# .. 16#FDEF#
           or else Code mod 16#10000# in 16#FFFE# | 16#FFFF#
         then
            return "";
         elsif Code in 16#3002# | 16#FF0E# | 16#FF61# then
            Wide.Append (Result, '.');
         elsif Code in 16#FF01# .. 16#FF5E# then
            Mapped := Wide_Wide_Character'Val (Code - 16#FEE0#);
            Wide.Append (Result, Unicode.To_Lower (Mapped));
         elsif Code in 16#1D400# .. 16#1D7FF# then
            Wide.Append (Result, Unicode.To_Lower (Unicode.To_Basic (Item)));
         else
            Wide.Append (Result, Unicode.To_Lower (Item));
         end if;
      end loop;
      Success := True;
      return Wide.To_Wide_Wide_String (Result);
   end Map_Input;

   --  WHATWG domain-to-ASCII runs Unicode ToASCII with VerifyDnsLength
   --  false, so the DNS 63-octet label and 253-octet name limits are not
   --  applied here. Only the WHATWG forbidden domain code points are.
   function Valid_ASCII_Label (Label : String) return Boolean is
   begin
      if Label'Length = 0 then
         return False;
      end if;
      for C of Label loop
         if Character'Pos (C) <= 16#20#
           or else Character'Pos (C) = 16#7F#
           or else C in '#' | '%' | '/' | ':' | '<' | '>' | '?' | '@' | '['
                        | '\' | ']' | '^' | '|'
         then
            return False;
         end if;
      end loop;
      return True;
   end Valid_ASCII_Label;

   function To_ASCII (Input : String; Success : out Boolean) return String is
      Decoded : Wide.Unbounded_Wide_Wide_String;
   begin
      Success := False;
      begin
         Decoded := Wide.To_Unbounded_Wide_Wide_String
           (UTF_32.Decode (UTF.UTF_8_String (Input)));
      exception
         when UTF.Encoding_Error =>
            return "";
      end;
      declare
         Mapped_OK : Boolean;
         Mapped    : constant Wide_Wide_String :=
           Map_Input (Wide.To_Wide_Wide_String (Decoded), Mapped_OK);
         Result    : Bytes.Unbounded_String;
         Start     : Positive := 1;
         Label_OK  : Boolean;
         First_Label : Boolean := True;
      begin
         if not Mapped_OK or else Mapped'Length = 0 then
            return "";
         end if;
         for Position in 1 .. Mapped'Length + 1 loop
            if Position > Mapped'Length or else Mapped (Position) = '.' then
               if not First_Label then
                  Bytes.Append (Result, '.');
               end if;
               First_Label := False;
               if Position /= Start then
                  declare
                  Label : constant Wide_Wide_String :=
                    Mapped (Start .. Position - 1);
                  ASCII_Only : Boolean := True;
                  begin
                     for Item of Label loop
                        if Wide_Wide_Character'Pos (Item) >= 16#80# then
                           ASCII_Only := False;
                           exit;
                        end if;
                     end loop;
                     if ASCII_Only then
                        declare
                           Text : String (1 .. Label'Length);
                        begin
                           for Index in Label'Range loop
                              Text (Index - Label'First + 1) :=
                                Character'Val
                                  (Wide_Wide_Character'Pos (Label (Index)));
                           end loop;
                           if not Valid_ASCII_Label (Text) then
                              return "";
                           end if;
                           Bytes.Append (Result, Text);
                        end;
                     else
                        declare
                           Encoded : constant String := Punycode (Label, Label_OK);
                        begin
                           if not Label_OK then
                              return "";
                           end if;
                           Bytes.Append (Result, "xn--" & Encoded);
                        end;
                     end if;
                  end;
               end if;
               Start := Position + 1;
            end if;
         end loop;
         Success := True;
         return Bytes.To_String (Result);
      end;
   end To_ASCII;

end Flyology_IRI.IDNA;
