procedure Flyology.HTTP.Fixed_Response_Policy.Smoke is
   Item   : Tracker;
   Write_Status : Write_Result;
   End_Status   : Finish_Result;
   Five_GiB : constant Body_Size := 5 * 1_024 * 1_024 * 1_024;
begin
   Reset (Item);
   Finish (Item, End_Status);
   pragma Assert (End_Status = Finish_Inactive);

   Start (Item, 0, Suppressed => False);
   Write (Item, 0, Write_Status);
   pragma Assert (Write_Status = Accepted);
   Finish (Item, End_Status);
   pragma Assert (End_Status = Complete);

   Start (Item, 3, Suppressed => False);
   for Count in 1 .. 3 loop
      Write (Item, 1, Write_Status);
      pragma Assert (Write_Status = Accepted);
      pragma Assert (Written (Item) = Body_Size (Count));
   end loop;
   Finish (Item, End_Status);
   pragma Assert (End_Status = Complete);

   Start (Item, 2, Suppressed => False);
   Write (Item, 3, Write_Status);
   pragma Assert (Write_Status = Overrun);
   pragma Assert (Written (Item) = 0);
   pragma Assert (not Is_Active (Item));

   Start (Item, 2, Suppressed => False);
   Write (Item, 1, Write_Status);
   Finish (Item, End_Status);
   pragma Assert (End_Status = Underrun);
   pragma Assert (not Is_Active (Item));

   --  Logical accounting exercises S3-scale lengths without allocating a
   --  corresponding representation.
   Start (Item, Five_GiB + 7, Suppressed => False);
   Write (Item, Five_GiB, Write_Status);
   pragma Assert (Write_Status = Accepted);
   Write (Item, 7, Write_Status);
   pragma Assert (Write_Status = Accepted);
   Finish (Item, End_Status);
   pragma Assert (End_Status = Complete);

   Start (Item, Body_Size'Last, Suppressed => False);
   Write (Item, Body_Size'Last - 1, Write_Status);
   pragma Assert (Write_Status = Accepted);
   Write (Item, 1, Write_Status);
   pragma Assert (Write_Status = Accepted);
   Finish (Item, End_Status);
   pragma Assert (End_Status = Complete);

   --  HEAD declares the representation length but does not require the
   --  handler to generate or account body bytes.
   Start (Item, Five_GiB + 19, Suppressed => True);
   Write (Item, Body_Size'Last, Write_Status);
   pragma Assert (Write_Status = Accepted);
   pragma Assert (Written (Item) = 0);
   Finish (Item, End_Status);
   pragma Assert (End_Status = Complete);
end Flyology.HTTP.Fixed_Response_Policy.Smoke;
