procedure Flyology.QUIC.Stream_ID_Policy.Smoke is
   Client_Streams : Allocator;
   Server_Streams : Allocator;
   ID             : Stream_ID;
   Status         : Open_Status;
begin
   pragma Assert
     (Initiator (0) = Client_Initiated
      and then Direction (0) = Bidirectional
      and then Initiator (1) = Server_Initiated
      and then Direction (2) = Unidirectional
      and then Ordinal (0) = 1
      and then Ordinal (7) = 2
      and then Can_Send (Client, 0)
      and then Can_Receive (Client, 0)
      and then Can_Send (Client, 2)
      and then not Can_Receive (Client, 2)
      and then not Can_Send (Client, 3)
      and then Can_Receive (Client, 3));

   Reset (Client_Streams, Client);
   Open_Local (Client_Streams, Bidirectional, 2, ID, Status);
   pragma Assert (Status = Opened and then ID = 0);
   Open_Local (Client_Streams, Bidirectional, 2, ID, Status);
   pragma Assert (Status = Opened and then ID = 4);
   Open_Local (Client_Streams, Bidirectional, 2, ID, Status);
   pragma Assert
     (Status = Stream_Limit_Reached
      and then ID = 0
      and then Opened_Count (Client_Streams, Bidirectional) = 2);
   Open_Local (Client_Streams, Unidirectional, 3, ID, Status);
   pragma Assert (Status = Opened and then ID = 2);

   Reset (Server_Streams, Server);
   Open_Local (Server_Streams, Bidirectional, 1, ID, Status);
   pragma Assert (Status = Opened and then ID = 1);
   Open_Local (Server_Streams, Unidirectional, 1, ID, Status);
   pragma Assert (Status = Opened and then ID = 3);
   Open_Local
     (Server_Streams, Unidirectional,
      Varint_Policy.Value_Type'Last, ID, Status);
   pragma Assert (Status = Invalid_Stream_Limit and then ID = 0);
end Flyology.QUIC.Stream_ID_Policy.Smoke;
