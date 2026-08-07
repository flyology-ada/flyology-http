procedure Flyology.QUIC.Crypto_Reassembly_Policy.Smoke is
   use type Ada.Streams.Stream_Element;

   function Nibble (Value : Character) return Natural is
     (case Value is
         when '0' .. '9' => Character'Pos (Value) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (Value) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (Value) - Character'Pos ('A') + 10,
         when others => raise Constraint_Error);

   function Hex (Value : String) return Ada.Streams.Stream_Element_Array is
      Result : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Value'Length / 2));
      Source : Positive := Value'First;
   begin
      pragma Assert (Value'Length mod 2 = 0);
      for Element of Result loop
         Element :=
           Ada.Streams.Stream_Element
             (16 * Nibble (Value (Source)) + Nibble (Value (Source + 1)));
         Source := Source + 2;
      end loop;
      return Result;
   end Hex;

   Item   : Reassembly_State;
   Status : Insert_Status;
begin
   Reset (Item);
   Insert (Item, 5, Hex ("776f726c64"), Status);
   pragma Assert
     (Status = Accepted
      and then Contiguous_Length (Item) = 0
      and then Highest_Offset (Item) = 10);
   Insert (Item, 3, Hex ("616258"), Status);
   pragma Assert
     (Status = Conflicting_Overlap
      and then Contiguous_Length (Item) = 0
      and then Highest_Offset (Item) = 10);
   Insert (Item, 0, Hex ("68656c6c6f"), Status);
   pragma Assert
     (Status = Accepted
      and then Contiguous_Length (Item) = 10
      and then Highest_Offset (Item) = 10);
   pragma Assert
     (Element (Item, 0) = Character'Pos ('h')
      and then Element (Item, 4) = Character'Pos ('o')
      and then Element (Item, 9) = Character'Pos ('d'));

   Insert (Item, 3, Hex ("6c6f776f"), Status);
   pragma Assert
     (Status = Duplicate and then Contiguous_Length (Item) = 10);
   Insert (Item, 4, Hex ("58"), Status);
   pragma Assert
     (Status = Conflicting_Overlap
      and then Contiguous_Length (Item) = 10
      and then Element (Item, 4) = Character'Pos ('o'));

   Reset (Item);
   declare
      Server_Hello : constant Ada.Streams.Stream_Element_Array :=
        Hex
          ("020000560303eefce7f7b37ba1d1632e" &
           "96677825ddf73988cfc79825df566dc5" &
           "430b9a045a1200130100002e00330024" &
           "001d00209d3c940d89690b84d08a60" &
           "993c144eca684d1081287c834d5311bc" &
           "f32bb9da1a002b00020304");
   begin
      Insert (Item, 37, Server_Hello (38 .. Server_Hello'Last), Status);
      pragma Assert
        (Status = Accepted
         and then Contiguous_Length (Item) = 0
         and then Highest_Offset (Item) = Server_Hello'Length);
      Insert (Item, 0, Server_Hello (1 .. 37), Status);
      pragma Assert
        (Status = Accepted
         and then Contiguous_Length (Item) = Server_Hello'Length);
      for Index in Stream_Index range 0 .. Server_Hello'Length - 1 loop
         pragma Assert
           (Element (Item, Index) = Server_Hello (Server_Hello'First + Index));
      end loop;
      Insert (Item, 20, Server_Hello (21 .. 50), Status);
      pragma Assert (Status = Duplicate);
   end;

   Insert
     (Item, Varint_Policy.Value_Type (Max_Crypto_Data - 1), Hex ("00"), Status);
   pragma Assert
     (Status = Accepted
      and then Contiguous_Length (Item) = 90
      and then Highest_Offset (Item) = Max_Crypto_Data);
   Insert
     (Item, Varint_Policy.Value_Type (Max_Crypto_Data), Hex ("00"), Status);
   pragma Assert
     (Status = Exceeds_Capacity
      and then Contiguous_Length (Item) = 90
      and then Highest_Offset (Item) = Max_Crypto_Data);
   Insert
     (Item, Varint_Policy.Value_Type (Max_Crypto_Data), (1 .. 0 => 0),
      Status);
   pragma Assert
     (Status = Duplicate and then Contiguous_Length (Item) = 90);

   Reset (Item);
   Insert (Item, 2, Hex ("6364"), Status);
   Insert (Item, 0, Hex ("6162"), Status);
   pragma Assert
     (Status = Accepted
      and then Contiguous_Length (Item) = 4
      and then Highest_Offset (Item) = 4);
end Flyology.QUIC.Crypto_Reassembly_Policy.Smoke;
