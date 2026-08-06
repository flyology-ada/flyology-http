with Ada.Streams;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

procedure Flyology.HTTP.HTTP_2_HPACK.Differential is
   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;

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

   Item : Decoder;
begin
   while not Ada.Text_IO.End_Of_File loop
      declare
         Line       : constant String := Ada.Text_IO.Get_Line;
         Fields     : Flyology.HTTP.Headers.List;
         Status     : Status_Code;
         Has_Status : Boolean;
         Output     : Unbounded_String;
      begin
         begin
            Decode_Response
              (Item, Hex (Line), False, Fields, Status, Has_Status);
            Append (Output, "OK|" & Status_Code'Image (Status));
            for Index in 1 .. Flyology.HTTP.Headers.Count (Fields) loop
               Append
                 (Output,
                  "|" & Flyology.HTTP.Headers.Name (Fields, Index)
                    & "=" & Flyology.HTTP.Headers.Value (Fields, Index));
            end loop;
            Ada.Text_IO.Put_Line (To_String (Output));
         exception
            when others =>
               Ada.Text_IO.Put_Line ("ERROR");
         end;
      end;
   end loop;
end Flyology.HTTP.HTTP_2_HPACK.Differential;
