procedure Flyology.QUIC.Stream_Table_Policy.Smoke is
   use type Ada.Streams.Stream_Element;
   use type Varint_Policy.Value_Type;

   function Hex (Text : String) return Ada.Streams.Stream_Element_Array is
      Result : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Text'Length / 2));

      function Digit (Value : Character) return Ada.Streams.Stream_Element is
        (if Value in '0' .. '9' then Character'Pos (Value) - Character'Pos ('0')
         else Character'Pos (Value) - Character'Pos ('a') + 10);
   begin
      for Index in Result'Range loop
         Result (Index) :=
           16 * Digit (Text (Text'First + 2 * Natural (Index - Result'First)))
           + Digit (Text (Text'First + 2 * Natural (Index - Result'First) + 1));
      end loop;
      return Result;
   end Hex;

   Item   : Stream_Table;
   Result : Process_Result;
   Status : Insert_Status;
begin
   Reset (Item);
   Process_Plaintext
     (Item, Hex ("010a00036162630e0402017a"), Result);
   pragma Assert
     (Result.Status = Processed and then Result.Frame_Count = 3
      and then Stream_Count (Item) = 2
      and then Available_Length (Item, 0) = 3
      and then Available_Length (Item, 4) = 0);

   Process_Plaintext (Item, Hex ("0e04000278790f040300"), Result);
   pragma Assert
     (Result.Status = Processed
      and then Available_Length (Item, 4) = 3
      and then Is_Complete (Item, 4)
      and then Element (Item, 4, 0) = Character'Pos ('x')
      and then Element (Item, 4, 2) = Character'Pos ('z'));
   Consume (Item, 4, 2);
   pragma Assert
     (Available_Length (Item, 4) = 1
      and then Element (Item, 4, 0) = Character'Pos ('z'));

   Process_Plaintext (Item, Hex ("0e04010159"), Result);
   pragma Assert (Result.Status = Conflicting_Stream_Data);

   Process_Plaintext (Item, Hex ("04002a03"), Result);
   pragma Assert
     (Result.Status = Processed and then Was_Reset (Item, 0)
      and then Reset_Error (Item, 0) = 42);
   Process_Plaintext (Item, Hex ("04002b03"), Result);
   pragma Assert (Result.Status = Stream_Reset_Conflict);
   Process_Plaintext (Item, Hex ("04002a04"), Result);
   pragma Assert (Result.Status = Stream_Final_Size_Error);

   Reset (Item);
   for Stream_ID in 0 .. Max_Streams - 1 loop
      Insert
        (Item, Varint_Policy.Value_Type (4 * Stream_ID), 0, True,
         Ada.Streams.Stream_Element_Array'(1 .. 0 => 0), Status);
      pragma Assert (Status = Accepted);
   end loop;
   Insert
     (Item, Varint_Policy.Value_Type (4 * Max_Streams), 0, True,
      Ada.Streams.Stream_Element_Array'(1 .. 0 => 0), Status);
   pragma Assert
     (Status = Stream_Capacity_Exceeded
      and then Stream_Count (Item) = Max_Streams);
end Flyology.QUIC.Stream_Table_Policy.Smoke;
