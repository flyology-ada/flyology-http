procedure Flyology.QUIC.Flow_Control_Policy.Smoke is
   Item   : State;
   Status : Reserve_Status;
   Update : Update_Status;
begin
   Reset
     (Item, Stream_ID_Policy.Client,
      (Connection => 12, Bidi_Local => 4, Bidi_Remote => 8,
       Unidirectional => 6));
   pragma Assert
     (Committed_Data (Item) = 0
      and then Connection_Limit (Item) = 12
      and then Stream_Count_Used (Item) = 0);

   Reserve_Send
     (Item, 0, Offset => 0, Length => 5, Fin => False, Status => Status);
   pragma Assert
     (Status = Reserved
      and then Stream_Committed (Item, 0) = 5
      and then Stream_Limit (Item, 0) = 8
      and then Committed_Data (Item) = 5);
   Reserve_Send
     (Item, 0, Offset => 2, Length => 3, Fin => False, Status => Status);
   pragma Assert (Status = Reserved and then Committed_Data (Item) = 5);
   Reserve_Send
     (Item, 0, Offset => 5, Length => 4, Fin => False, Status => Status);
   pragma Assert (Status = Stream_Flow_Blocked);
   Raise_Stream_Limit (Item, 0, 10, Update);
   pragma Assert (Update = Updated and then Stream_Limit (Item, 0) = 10);
   Reserve_Send
     (Item, 0, Offset => 5, Length => 4, Fin => True, Status => Status);
   pragma Assert (Status = Reserved and then Committed_Data (Item) = 9);
   Reserve_Send
     (Item, 0, Offset => 9, Length => 1, Fin => False, Status => Status);
   pragma Assert
     (Status = Stream_Final_Size_Mismatch
      and then Committed_Data (Item) = 9);
   Reserve_Send
     (Item, 0, Offset => 5, Length => 4, Fin => True, Status => Status);
   pragma Assert (Status = Reserved and then Committed_Data (Item) = 9);
   Reserve_Send
     (Item, 0, Offset => 4, Length => 4, Fin => True, Status => Status);
   pragma Assert (Status = Stream_Final_Size_Mismatch);

   Reserve_Send
     (Item, 2, Offset => 0, Length => 4, Fin => False, Status => Status);
   pragma Assert (Status = Connection_Flow_Blocked);
   Raise_Connection_Limit (Item, 20);
   Reserve_Send
     (Item, 2, Offset => 0, Length => 4, Fin => False, Status => Status);
   pragma Assert
     (Status = Reserved
      and then Stream_Limit (Item, 2) = 6
      and then Committed_Data (Item) = 13);

   Reserve_Send
     (Item, 3, Offset => 0, Length => 1, Fin => False, Status => Status);
   pragma Assert (Status = Stream_Not_Sendable);
   Reserve_Send
     (Item, 4, Offset => Value_Type'Last, Length => 1, Fin => False,
      Status => Status);
   pragma Assert (Status = Stream_Range_Too_Large);

   Raise_Stream_Limit (Item, 1, 9, Update);
   pragma Assert
     (Update = Updated
      and then Has_Stream (Item, 1)
      and then Stream_Limit (Item, 1) = 9);
end Flyology.QUIC.Flow_Control_Policy.Smoke;
