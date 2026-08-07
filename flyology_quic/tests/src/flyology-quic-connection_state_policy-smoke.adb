procedure Flyology.QUIC.Connection_State_Policy.Smoke is
   Item        : Connection_State;
   Disposition : Receive_Disposition;
begin
   Reset (Item);
   pragma Assert
     (not Has_Received (Item)
      and then Expected_Number (Item) = 0
      and then Can_Send (Item)
      and then Next_To_Send (Item) = 0);

   Record_Received (Item, 5, Disposition);
   pragma Assert
     (Disposition = New_Packet
      and then Largest_Received (Item) = 5
      and then Expected_Number (Item) = 6
      and then Was_Received (Item, 5));
   Record_Received (Item, 5, Disposition);
   pragma Assert (Disposition = Duplicate_Packet);

   Record_Received (Item, 3, Disposition);
   pragma Assert
     (Disposition = New_Packet
      and then Largest_Received (Item) = 5
      and then Was_Received (Item, 3));
   Record_Received (Item, 261, Disposition);
   pragma Assert
     (Disposition = New_Packet
      and then Largest_Received (Item) = 261
      and then not Was_Received (Item, 5));
   Record_Received (Item, 5, Disposition);
   pragma Assert (Disposition = Packet_Too_Old);
   Record_Received (Item, 6, Disposition);
   pragma Assert
     (Disposition = New_Packet
      and then Was_Received (Item, 6));

   Record_Received (Item, 1_000, Disposition);
   Record_Received (Item, 744, Disposition);
   pragma Assert (Disposition = Packet_Too_Old);
   Record_Received (Item, 745, Disposition);
   pragma Assert
     (Disposition = New_Packet
      and then Was_Received (Item, 745)
      and then Expected_Number (Item) = 1_001);

   Commit_Sent (Item);
   pragma Assert (Can_Send (Item) and then Next_To_Send (Item) = 1);
   Commit_Sent (Item);
   pragma Assert (Can_Send (Item) and then Next_To_Send (Item) = 2);
end Flyology.QUIC.Connection_State_Policy.Smoke;
