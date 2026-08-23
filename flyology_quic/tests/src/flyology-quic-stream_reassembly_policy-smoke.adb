procedure Flyology.QUIC.Stream_Reassembly_Policy.Smoke is
   use type Ada.Streams.Stream_Element;

   Item   : Reassembly_State;
   Status : Insert_Status;
begin
   Reset (Item);
   Insert (Item, 5, True, (1 => Character'Pos ('!')), Status);
   pragma Assert
     (Status = Accepted
      and then Contiguous_Length (Item) = 0
      and then Highest_Offset (Item) = 6
      and then Has_Final_Size (Item)
      and then Final_Size (Item) = 6
      and then not Is_Complete (Item));
   Insert
     (Item, 0, False,
      (Character'Pos ('h'), Character'Pos ('e'), Character'Pos ('l'),
       Character'Pos ('l'), Character'Pos ('o')),
      Status);
   pragma Assert
     (Status = Accepted
      and then Contiguous_Length (Item) = 6
      and then Available_Length (Item) = 6
      and then Is_Complete (Item));
   pragma Assert
     (Element (Item, 0) = Character'Pos ('h')
      and then Element (Item, 5) = Character'Pos ('!'));
   Consume (Item, 5);
   pragma Assert
     (Available_Length (Item) = 1
      and then Element (Item, 0) = Character'Pos ('!'));
   Insert (Item, 5, True, (1 => Character'Pos ('!')), Status);
   pragma Assert (Status = Duplicate and then Is_Complete (Item));
   Insert (Item, 6, False, (1 => Character'Pos ('x')), Status);
   pragma Assert (Status = Final_Size_Error);
   Insert (Item, 4, True, (1 => Character'Pos ('o')), Status);
   pragma Assert (Status = Final_Size_Error);

   Reset (Item);
   Insert (Item, 3, False, (1 => Character'Pos ('d')), Status);
   Insert (Item, 2, True, (1 => Character'Pos ('c')), Status);
   pragma Assert
     (Status = Final_Size_Error and then not Has_Final_Size (Item));
   Insert (Item, 2, False, (1 => Character'Pos ('X')), Status);
   pragma Assert (Status = Accepted);
   Insert (Item, 2, False, (1 => Character'Pos ('c')), Status);
   pragma Assert (Status = Conflicting_Overlap);

   Reset (Item);
   Insert (Item, 2, True, (1 .. 0 => 0), Status);
   pragma Assert
     (Status = Accepted and then Has_Final_Size (Item)
      and then Final_Size (Item) = 2 and then not Is_Complete (Item));
   Insert
     (Item, 0, False, (Character'Pos ('a'), Character'Pos ('b')), Status);
   pragma Assert (Status = Accepted and then Is_Complete (Item));

   Reset (Item);
   Insert
     (Item, Varint_Policy.Value_Type (Max_Stream_Data), False,
      (1 => Character'Pos ('x')), Status);
   pragma Assert
     (Status = Exceeds_Capacity
      and then Contiguous_Length (Item) = 0
      and then Highest_Offset (Item) = 0);

   declare
      Window : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Max_Stream_Data)) :=
          (others => Character'Pos ('w'));
   begin
      Reset (Item);
      Insert (Item, 0, False, Window, Status);
      pragma Assert
        (Status = Accepted
         and then Available_Length (Item) = Max_Stream_Data);
      Consume (Item, Max_Stream_Data);
      pragma Assert
        (Available_Length (Item) = 0
         and then Consumed_Offset (Item) = Max_Stream_Data);
      Insert
        (Item, 0, False, Window (Window'First .. Window'First + 7), Status);
      pragma Assert (Status = Duplicate);
      Insert
        (Item, Varint_Policy.Value_Type (Max_Stream_Data), True,
         (1 => Character'Pos ('x')), Status);
      pragma Assert
        (Status = Accepted
         and then Available_Length (Item) = 1
         and then Element (Item, 0) = Character'Pos ('x')
         and then Is_Complete (Item));
   end;
end Flyology.QUIC.Stream_Reassembly_Policy.Smoke;
