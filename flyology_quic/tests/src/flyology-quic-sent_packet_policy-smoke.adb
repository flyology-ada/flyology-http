procedure Flyology.QUIC.Sent_Packet_Policy.Smoke is
   Item   : Ledger;
   Status : Record_Status;
   Result : Apply_Result;
   Ranges : ACK_Range_Policy.Decode_Result;

   procedure Track
     (Number  : Packet_Number;
      Sent_At : Timestamp)
   is
   begin
      Record_Sent
        (Item,
         (Number        => Number,
          Sent_At       => Sent_At,
          Bytes         => 1_200,
          ACK_Eliciting => True,
          In_Flight     => True),
         Status);
      pragma Assert (Status = Recorded);
   end Track;
begin
   Reset (Item);
   pragma Assert (Retained (Item) = 0 and then not Has_Sent (Item));

   Track (0, 100);
   Record_Sent
     (Item,
      (Number        => 1,
       Sent_At       => 105,
       Bytes         => 32,
       ACK_Eliciting => False,
       In_Flight     => False),
      Status);
   pragma Assert
     (Status = Not_Tracked
      and then Retained (Item) = 1
      and then Largest_Sent (Item) = 1
      and then not Contains (Item, 1));
   Track (2, 110);
   Track (3, 120);
   Track (4, 130);
   pragma Assert
     (Retained (Item) = 4
      and then Largest_Sent (Item) = 4
      and then Contains (Item, 0));

   Ranges.Status := ACK_Range_Policy.Decoded;
   Ranges.Count := 1;
   Ranges.Ranges (1) := (Smallest => 4, Largest => 4);
   Apply_ACK (Item, Ranges, Now => 140, Loss_Delay => 1_000, Result => Result);
   pragma Assert
     (Result.Status = Applied
      and then Result.Count = 2
      and then Result.Events (1).Kind = Acknowledged
      and then Result.Events (1).Packet.Number = 4
      and then Result.Events (2).Kind = Lost
      and then Result.Events (2).Packet.Number = 0
      and then Retained (Item) = 2
      and then not Contains (Item, 0)
      and then Contains (Item, 2));

   Apply_ACK (Item, Ranges, Now => 2_000, Loss_Delay => 1, Result => Result);
   pragma Assert (Result.Status = Applied and then Result.Count = 0);

   Ranges.Ranges (1) := (Smallest => 5, Largest => 5);
   Apply_ACK (Item, Ranges, Now => 2_000, Loss_Delay => 1, Result => Result);
   pragma Assert
     (Result.Status = Acknowledges_Unsent_Packet
      and then Result.Count = 0
      and then Retained (Item) = 2);

   Reset (Item);
   Track (0, 100);
   Track (1, 110);
   Ranges.Ranges (1) := (Smallest => 1, Largest => 1);
   Apply_ACK (Item, Ranges, Now => 200, Loss_Delay => 50, Result => Result);
   pragma Assert
     (Result.Status = Applied
      and then Result.Count = 2
      and then Result.Events (1).Kind = Acknowledged
      and then Result.Events (2).Kind = Lost
      and then Result.Events (2).Packet.Number = 0
      and then Retained (Item) = 0);

   Reset (Item);
   for Number in Packet_Number range 0 .. Max_Sent_Packets - 1 loop
      Track (Number, Number);
   end loop;
   pragma Assert (Retained (Item) = Max_Sent_Packets);
   Record_Sent
     (Item,
      (Number        => Max_Sent_Packets,
       Sent_At       => Max_Sent_Packets,
       Bytes         => 1,
       ACK_Eliciting => False,
       In_Flight     => True),
      Status);
   pragma Assert (Status = Table_Full and then Retained (Item) = Max_Sent_Packets);

   Record_Sent
     (Item,
      (Number        => Max_Sent_Packets,
       Sent_At       => Max_Sent_Packets,
       Bytes         => 1,
       ACK_Eliciting => False,
       In_Flight     => False),
      Status);
   pragma Assert
     (Status = Not_Tracked
      and then Retained (Item) = Max_Sent_Packets
      and then Largest_Sent (Item) = Max_Sent_Packets);
end Flyology.QUIC.Sent_Packet_Policy.Smoke;
