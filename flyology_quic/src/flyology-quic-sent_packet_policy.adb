package body Flyology.QUIC.Sent_Packet_Policy
  with SPARK_Mode => On
is
   function Retained (Item : Ledger) return Sent_Count is
     (Item.Count);

   function Has_Sent (Item : Ledger) return Boolean is
     (Item.Has_Largest_Sent);

   function Largest_Sent (Item : Ledger) return Packet_Number is
     (Item.Largest_Sent_PN);

   function Contains
     (Item   : Ledger;
      Number : Packet_Number) return Boolean
   is
   begin
      for Index in Sent_Index loop
         if Item.Entries (Index).Valid
           and then Item.Entries (Index).Packet.Number = Number
         then
            return True;
         end if;
      end loop;
      return False;
   end Contains;

   procedure Reset (Item : out Ledger) is
   begin
      Item :=
        (Entries           => (others => (others => <>)),
         Count             => 0,
         Has_Largest_Sent  => False,
         Largest_Sent_PN   => 0,
         Has_Largest_ACKed => False,
         Largest_ACKed_PN  => 0);
   end Reset;

   procedure Record_Sent
     (Item   : in out Ledger;
      Packet : Sent_Packet;
      Status : out Record_Status)
   is
      Target : Sent_Index := Sent_Index'First;
      Found  : Boolean := False;
   begin
      if (not Item.Has_Largest_Sent and then Packet.Number /= 0)
        or else
          (Item.Has_Largest_Sent
           and then
             (Item.Largest_Sent_PN = Packet_Number'Last
              or else Packet.Number /= Item.Largest_Sent_PN + 1))
      then
         Status := Packet_Number_Not_Next;
         return;
      elsif Item.Count = Max_Sent_Packets then
         Status := Table_Full;
         return;
      end if;

      for Index in Sent_Index loop
         pragma Loop_Invariant (not Found or else not Item.Entries (Target).Valid);
         if not Found and then not Item.Entries (Index).Valid then
            Target := Index;
            Found := True;
         end if;
      end loop;
      if not Found then
         Status := Table_Full;
         return;
      end if;

      Item.Entries (Target) := (Valid => True, Packet => Packet);
      Item.Count := Item.Count + 1;
      Item.Has_Largest_Sent := True;
      Item.Largest_Sent_PN := Packet.Number;
      Status := Recorded;
   end Record_Sent;

   procedure Apply_ACK
     (Item       : in out Ledger;
      Ranges     : ACK_Range_Policy.Decode_Result;
      Now        : Timestamp;
      Loss_Delay : Timestamp;
      Result     : out Apply_Result)
   is
      Newly_ACKed : Boolean := False;

      procedure Emit
        (Kind   : Event_Kind;
         Packet : Sent_Packet)
      with
        Pre => Result.Count < Max_Sent_Packets,
        Post => Result.Count = Result.Count'Old + 1;

      procedure Emit
        (Kind   : Event_Kind;
         Packet : Sent_Packet)
      is
      begin
         Result.Count := Result.Count + 1;
         Result.Events (Result.Count) := (Kind => Kind, Packet => Packet);
      end Emit;
   begin
      Result := (Status => Applied, Count => 0, Events => (others => <>));

      if not Item.Has_Largest_Sent
        or else Ranges.Ranges (1).Largest > Item.Largest_Sent_PN
      then
         Result.Status := Acknowledges_Unsent_Packet;
         pragma Assert (Result.Count = 0);
         return;
      end if;

      if not Item.Has_Largest_ACKed
        or else Ranges.Ranges (1).Largest > Item.Largest_ACKed_PN
      then
         Item.Has_Largest_ACKed := True;
         Item.Largest_ACKed_PN := Ranges.Ranges (1).Largest;
      end if;

      for Index in Sent_Index loop
         pragma Loop_Invariant (Result.Count <= Index - 1);
         pragma Loop_Invariant (Item.Count + Result.Count <= Item.Count'Loop_Entry);
         if Item.Count > 0
           and then Item.Entries (Index).Valid
           and then ACK_Range_Policy.Acknowledges
             (Ranges, Item.Entries (Index).Packet.Number)
         then
            Emit (Acknowledged, Item.Entries (Index).Packet);
            Item.Entries (Index).Valid := False;
            Item.Count := Item.Count - 1;
            Newly_ACKed := True;
         end if;
      end loop;

      if Newly_ACKed then
         pragma Assert (Item.Count + Result.Count <= Max_Sent_Packets);
         for Index in Sent_Index loop
            pragma Loop_Invariant (Result.Count <= Max_Sent_Packets);
            pragma Loop_Invariant
              (Item.Count + Result.Count <= Max_Sent_Packets);
            if Item.Count > 0
              and then Item.Entries (Index).Valid
              and then Item.Entries (Index).Packet.Number <=
                Item.Largest_ACKed_PN
              and then
                ((Item.Largest_ACKed_PN >= 3
                  and then Item.Entries (Index).Packet.Number <=
                    Item.Largest_ACKed_PN - 3)
                 or else
                   (Now >= Item.Entries (Index).Packet.Sent_At
                    and then Now - Item.Entries (Index).Packet.Sent_At >=
                      Loss_Delay))
            then
               Emit (Lost, Item.Entries (Index).Packet);
               Item.Entries (Index).Valid := False;
               Item.Count := Item.Count - 1;
            end if;
         end loop;
      end if;
   end Apply_ACK;
end Flyology.QUIC.Sent_Packet_Policy;
