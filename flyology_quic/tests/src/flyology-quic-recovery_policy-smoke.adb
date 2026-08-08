procedure Flyology.QUIC.Recovery_Policy.Smoke is
   Item   : State;
   Status : Send_Status;
   Events : Sent_Packet_Policy.Packet_Event_Array;

   function Packet
     (Number  : Sent_Packet_Policy.Packet_Number;
      Sent_At : Sent_Packet_Policy.Timestamp)
      return Sent_Packet_Policy.Sent_Packet
   is
     ((Number        => Number,
       Sent_At       => Sent_At,
       Bytes         => 1_200,
       ACK_Eliciting => True,
       In_Flight     => True));
begin
   Reset (Item);
   pragma Assert
     (Bytes_In_Flight (Item) = 0
      and then Congestion_Window (Item) = 12_000
      and then not Has_RTT_Sample (Item)
      and then Loss_Delay (Item) = 374_625
      and then PTO_Count (Item) = 0
      and then Probe_Timeout (Item, 25_000, False) = 999_000
      and then Probe_Timeout (Item, 25_000, True) = 1_024_000);

   On_Probe_Timeout (Item);
   pragma Assert
     (PTO_Count (Item) = 1
      and then Probe_Timeout (Item, 25_000, True) = 2_048_000);
   for Count in 2 .. Max_PTO_Count + 2 loop
      On_Probe_Timeout (Item);
   end loop;
   pragma Assert (PTO_Count (Item) = Max_PTO_Count);
   On_ACK_Received (Item);
   pragma Assert (PTO_Count (Item) = 0);

   for Number in Sent_Packet_Policy.Packet_Number range 0 .. 9 loop
      On_Packet_Sent
        (Item, Packet (Number, Number), Permit_Probe => False,
         Status => Status);
      pragma Assert (Status = Accounted);
   end loop;
   pragma Assert
     (Bytes_In_Flight (Item) = 12_000
      and then not Can_Send (Item, 1_200));
   On_Packet_Sent
     (Item, Packet (10, 10), Permit_Probe => False, Status => Status);
   pragma Assert
     (Status = Congestion_Blocked and then Bytes_In_Flight (Item) = 12_000);

   Update_RTT
     (Item, Sample => 100, ACK_Delay => 90, Maximum_ACK_Delay => 25,
      Handshake_Confirmed => False);
   pragma Assert
     (Has_RTT_Sample (Item)
      and then Latest_RTT (Item) = 100
      and then Minimum_RTT (Item) = 100
      and then Smoothed_RTT (Item) = 100
      and then RTT_Variance (Item) = 50);
   Update_RTT
     (Item, Sample => 120, ACK_Delay => 10, Maximum_ACK_Delay => 25,
      Handshake_Confirmed => True);
   pragma Assert
     (Latest_RTT (Item) = 120
      and then Minimum_RTT (Item) = 100
      and then Smoothed_RTT (Item) = 101
      and then RTT_Variance (Item) = 40);

   Events (1) :=
     (Kind => Sent_Packet_Policy.Acknowledged, Packet => Packet (3, 1_030));
   Events (2) :=
     (Kind => Sent_Packet_Policy.Lost, Packet => Packet (0, 1_000));
   On_Packets_Resolved
     (Item, Events, Count => 2, Now => 2_000,
      Application_Limited => False);
   pragma Assert
     (Bytes_In_Flight (Item) = 9_600
      and then Congestion_Window (Item) = 6_000);

   On_Packet_Sent
     (Item, Packet (10, 2_100), Permit_Probe => True, Status => Status);
   pragma Assert
     (Status = Accounted and then Bytes_In_Flight (Item) = 10_800);

   Events (1) :=
     (Kind => Sent_Packet_Policy.Acknowledged, Packet => Packet (10, 2_100));
   On_Packets_Resolved
     (Item, Events, Count => 1, Now => 2_200,
      Application_Limited => False);
   pragma Assert
     (Bytes_In_Flight (Item) = 9_600
      and then Congestion_Window (Item) = 6_240);
end Flyology.QUIC.Recovery_Policy.Smoke;
