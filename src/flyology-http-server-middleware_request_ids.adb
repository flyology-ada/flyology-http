with Ada.Real_Time;
with Interfaces;
with System.Storage_Elements;

package body Flyology.HTTP.Server.Middleware_Request_IDs is

   use type Interfaces.Unsigned_64;

   subtype Word is Interfaces.Unsigned_64;

   Golden : constant Word := 16#9E37_79B9_7F4A_7C15#;

   Hex_Digits : constant String := "0123456789abcdef";

   protected Generator is
      procedure Take (Value : out Natural);
   private
      Counter : Natural := 0;
   end Generator;

   protected body Generator is
      procedure Take (Value : out Natural) is
      begin
         if Counter = Natural'Last then
            Counter := 1;
         else
            Counter := Counter + 1;
         end if;
         Value := Counter;
      end Take;
   end Generator;

   --  Avalanche one word into another. The step is a bijection, so the
   --  identifiers it derives from distinct counter values stay distinct.
   function Mix (Value : Word) return Word;

   --  Collect per-process key material once, at elaboration.
   function Initial_Key return Word;

   --  Map one counter value onto its published identifier.
   function Scramble (Counter : Word) return Word;

   --  Render one word as sixteen lowercase hexadecimal digits.
   function Hex_Image (Value : Word) return String;

   function Mix (Value : Word) return Word is
      Result : Word := Value;
   begin
      Result := (Result xor Interfaces.Shift_Right (Result, 30))
        * 16#BF58_476D_1CE4_E5B9#;
      Result := (Result xor Interfaces.Shift_Right (Result, 27))
        * 16#94D0_49BB_1331_11EB#;
      return Result xor Interfaces.Shift_Right (Result, 31);
   end Mix;

   function Initial_Key return Word is
      Anchor  : aliased Word := 0;
      Seconds : Ada.Real_Time.Seconds_Count;
      Rest    : Ada.Real_Time.Time_Span;
      Result  : Word;
   begin
      Ada.Real_Time.Split (Ada.Real_Time.Clock, Seconds, Rest);
      Result := Mix (Word'Mod (Seconds) xor Golden);
      Result := Result xor Mix
        (Word'Mod
           (Long_Long_Integer
              (Ada.Real_Time.To_Duration (Rest) * 1_000_000)));
      --  The loader chooses this address, so it contributes whatever the
      --  platform's address-space layout randomization provides.
      Result := Result xor Mix
        (Word'Mod (System.Storage_Elements.To_Integer (Anchor'Address)));
      return Result;
   end Initial_Key;

   --  Two independent draws: the clock advances between them.
   Key_A : constant Word := Initial_Key or 1;
   Key_B : constant Word := Initial_Key;

   function Scramble (Counter : Word) return Word is
     (Mix ((Counter + Golden) * Key_A) xor Key_B);

   function Hex_Image (Value : Word) return String is
      Result : String (1 .. 16);
      Rest   : Word := Value;
   begin
      for Index in reverse Result'Range loop
         Result (Index) :=
           Hex_Digits (Hex_Digits'First + Natural (Rest and 16#F#));
         Rest := Interfaces.Shift_Right (Rest, 4);
      end loop;
      return Result;
   end Hex_Image;

   function Valid (Value : String) return Boolean is
   begin
      if Value'Length = 0 or else Value'Length > 128 then
         return False;
      end if;
      for Item of Value loop
         if Item not in 'a' .. 'z'
           and then Item not in 'A' .. 'Z'
           and then Item not in '0' .. '9'
           and then Item not in '-' | '.' | '_'
         then
            return False;
         end if;
      end loop;
      return True;
   end Valid;

   function Generate_Default return String is
      Value : Natural;
   begin
      Generator.Take (Value);
      --  The counter keeps identifiers unique within the process; the keyed
      --  permutation keeps the count itself off the wire.
      return "fly-" & Hex_Image (Scramble (Word (Value)));
   end Generate_Default;

   procedure Call
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange;
      Next    : in out Components.Next_Handler)
   is
      Inbound : constant String := X.Request_Header (Header_Name);
      Generated : Ada.Strings.Unbounded.Unbounded_String;
   begin
      if Trust_Inbound and then Valid (Inbound) then
         Generated := Ada.Strings.Unbounded.To_Unbounded_String (Inbound);
      elsif Generate = null then
         Generated := Ada.Strings.Unbounded.To_Unbounded_String
           (Generate_Default);
      else
         --  X is a read-only borrow for the duration of this call. A custom
         --  generator must not retain it or return attacker-controlled bytes
         --  without its own normalization policy.
         Generate (Context, X, Generated);
         if not Valid (Ada.Strings.Unbounded.To_String (Generated)) then
            raise Constraint_Error with
              "request ID generator returned an invalid value";
         end if;
      end if;

      declare
         Value : constant String :=
           Ada.Strings.Unbounded.To_String (Generated);
      begin
         --  Validation precedes both mutations, so a bad custom value cannot
         --  enter exchange state, response headers, logs, or metrics.
         X.Set_Request_ID (Value);
         X.Add_Header (Header_Name, Value);
      end;
      Next.Call (Context, X);
   end Call;

end Flyology.HTTP.Server.Middleware_Request_IDs;
