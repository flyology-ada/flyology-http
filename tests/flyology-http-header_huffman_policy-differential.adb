with Ada.Streams;
with Ada.IO_Exceptions;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

procedure Flyology.HTTP.Header_Huffman_Policy.Differential is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;

   Hex_Digits : constant String := "0123456789abcdef";

   function Nibble (Value : Character) return Ada.Streams.Stream_Element is
     (case Value is
        when '0' .. '9' => Character'Pos (Value) - Character'Pos ('0'),
        when 'a' .. 'f' => Character'Pos (Value) - Character'Pos ('a') + 10,
        when 'A' .. 'F' => Character'Pos (Value) - Character'Pos ('A') + 10,
        when others => raise Constraint_Error with "invalid hexadecimal");

   function Hex (Value : String) return Ada.Streams.Stream_Element_Array is
      Result : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Value'Length / 2));
   begin
      if Value'Length mod 2 /= 0 then
         raise Constraint_Error with "odd hexadecimal length";
      end if;
      for Index in Result'Range loop
         declare
            Offset : constant Natural := Natural (Index - Result'First) * 2;
         begin
            Result (Index) :=
              Nibble (Value (Value'First + Offset)) * 16
                + Nibble (Value (Value'First + Offset + 1));
         end;
      end loop;
      return Result;
   end Hex;

   procedure Put_Hex (Value : String) is
      Result : Ada.Strings.Unbounded.Unbounded_String;
   begin
      for Item of Value loop
         declare
            Octet : constant Natural := Character'Pos (Item);
         begin
            Ada.Strings.Unbounded.Append
              (Result, Hex_Digits (Octet / 16 + 1));
            Ada.Strings.Unbounded.Append
              (Result, Hex_Digits (Octet mod 16 + 1));
         end;
      end loop;
      Ada.Text_IO.Put_Line (Ada.Strings.Unbounded.To_String (Result));
   end Put_Hex;
begin
   loop
      begin
         declare
            Line   : constant String := Ada.Text_IO.Get_Line;
            Result : constant Decode_Result :=
              Decode (Hex (Line), Max_Output_Length);
         begin
            if Result.Status = Decoded then
               Put_Hex (Result.Data (1 .. Result.Length));
            else
               Ada.Text_IO.Put_Line ("ERROR");
            end if;
         end;
      exception
         when Ada.IO_Exceptions.End_Error =>
            exit;
         when others =>
            Ada.Text_IO.Put_Line ("ERROR");
      end;
   end loop;
end Flyology.HTTP.Header_Huffman_Policy.Differential;
