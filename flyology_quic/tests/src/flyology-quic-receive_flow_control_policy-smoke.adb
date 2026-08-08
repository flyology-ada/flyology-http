procedure Flyology.QUIC.Receive_Flow_Control_Policy.Smoke is
   Item   : State;
   Status : Reserve_Status;
begin
   Reset
     (Item, Stream_ID_Policy.Server,
      (Connection => 10, Bidi_Local => 2, Bidi_Remote => 3,
       Unidirectional => 4, Streams_Bidi => 1, Streams_Uni => 1));
   pragma Assert
     (Committed_Data (Item) = 0 and then Stream_Count_Used (Item) = 0);

   Reserve_Stream
     (Item, ID => 0, Offset => 0, Length => 3, Fin => False,
      Local_Bidi_Opened => 0, Local_Uni_Opened => 0, Status => Status);
   pragma Assert (Status = Reserved and then Committed_Data (Item) = 3);
   Reserve_Stream
     (Item, ID => 0, Offset => 1, Length => 2, Fin => False,
      Local_Bidi_Opened => 0, Local_Uni_Opened => 0, Status => Status);
   pragma Assert (Status = Reserved and then Committed_Data (Item) = 3);
   Reserve_Stream
     (Item, ID => 0, Offset => 3, Length => 1, Fin => False,
      Local_Bidi_Opened => 0, Local_Uni_Opened => 0, Status => Status);
   pragma Assert (Status = Stream_Flow_Exceeded);

   Reserve_Stream
     (Item, ID => 4, Offset => 0, Length => 1, Fin => False,
      Local_Bidi_Opened => 0, Local_Uni_Opened => 0, Status => Status);
   pragma Assert (Status = Stream_Limit_Exceeded);
   Reserve_Stream
     (Item, ID => 3, Offset => 0, Length => 1, Fin => False,
      Local_Bidi_Opened => 0, Local_Uni_Opened => 0, Status => Status);
   pragma Assert (Status = Stream_Not_Receivable);
   Reserve_Stream
     (Item, ID => 1, Offset => 0, Length => 1, Fin => False,
      Local_Bidi_Opened => 0, Local_Uni_Opened => 0, Status => Status);
   pragma Assert (Status = Stream_Not_Opened);
   Reserve_Stream
     (Item, ID => 1, Offset => 0, Length => 2, Fin => True,
      Local_Bidi_Opened => 1, Local_Uni_Opened => 0, Status => Status);
   pragma Assert (Status = Reserved and then Committed_Data (Item) = 5);

   Reserve_Reset
     (Item, ID => 0, Final_Size => 3,
      Local_Bidi_Opened => 1, Local_Uni_Opened => 0, Status => Status);
   pragma Assert (Status = Reserved);
   Reserve_Reset
     (Item, ID => 0, Final_Size => 2,
      Local_Bidi_Opened => 1, Local_Uni_Opened => 0, Status => Status);
   pragma Assert (Status = Stream_Final_Size_Mismatch);

   Status := Check_Stop_Sending
     (Item, ID => 3, Local_Bidi_Opened => 1, Local_Uni_Opened => 0);
   pragma Assert (Status = Stream_Not_Opened);
   Status := Check_Stop_Sending
     (Item, ID => 3, Local_Bidi_Opened => 1, Local_Uni_Opened => 1);
   pragma Assert (Status = Reserved);
   Status := Check_Stop_Sending
     (Item, ID => 2, Local_Bidi_Opened => 1, Local_Uni_Opened => 1);
   pragma Assert (Status = Stream_Not_Sendable);
end Flyology.QUIC.Receive_Flow_Control_Policy.Smoke;
