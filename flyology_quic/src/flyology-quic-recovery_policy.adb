package body Flyology.QUIC.Recovery_Policy
  with SPARK_Mode => On
is
   use type Sent_Packet_Policy.Event_Kind;

   function Saturating_Add
     (Left  : Byte_Count;
      Right : Byte_Count) return Byte_Count
   is
     (if Right > Byte_Count'Last - Left then
         Byte_Count'Last
      else Left + Right)
   with Global => null;

   function Bytes_In_Flight (Item : State) return Byte_Count is
     (Item.Flight);

   function Congestion_Window (Item : State) return Byte_Count is
     (Item.Window);

   function Has_RTT_Sample (Item : State) return Boolean is
     (Item.Has_Sample);

   function Latest_RTT (Item : State) return Duration is
     (Item.Latest);

   function Minimum_RTT (Item : State) return Duration is
     (Item.Minimum);

   function Smoothed_RTT (Item : State) return Duration is
     (Item.Smoothed);

   function RTT_Variance (Item : State) return Duration is
     (Item.Variance);

   function Loss_Delay (Item : State) return Duration is
      Base   : constant Duration :=
        Duration'Max (Item.Latest, Item.Smoothed);
      Eighth : constant Duration := Base / 8;
   begin
      if Eighth > Duration'Last - Base then
         return Duration'Last;
      else
         return Duration'Max (Base + Eighth, Timer_Granularity);
      end if;
   end Loss_Delay;

   function Can_Send
     (Item  : State;
      Bytes : Sent_Packet_Policy.Packet_Byte_Count) return Boolean
   is
     Amount : constant Byte_Count := Byte_Count (Bytes);
   begin
      return Item.Flight <= Item.Window
        and then Amount <= Item.Window - Item.Flight;
   end Can_Send;

   procedure Reset (Item : out State) is
   begin
      Item :=
        (Has_Sample       => False,
         Latest           => 0,
         Minimum          => 0,
         Smoothed         => Initial_RTT,
         Variance         => Initial_RTT / 2,
         Flight           => 0,
         Window           => Initial_Congestion_Window,
         Slow_Start_Limit => Byte_Count'Last,
         Has_Recovery     => False,
         Recovery_Start   => 0);
   end Reset;

   procedure On_Packet_Sent
     (Item         : in out State;
      Packet       : Sent_Packet_Policy.Sent_Packet;
      Permit_Probe : Boolean;
      Status       : out Send_Status)
   is
      Amount : constant Byte_Count := Byte_Count (Packet.Bytes);
   begin
      if Packet.In_Flight
        and then not Permit_Probe
        and then not Can_Send (Item, Packet.Bytes)
      then
         Status := Congestion_Blocked;
         return;
      end if;

      if Packet.In_Flight then
         Item.Flight :=
           Saturating_Add (Item.Flight, Amount);
      end if;
      Status := Accounted;
   end On_Packet_Sent;

   procedure Update_RTT
     (Item                : in out State;
      Sample              : Duration;
      ACK_Delay           : Duration;
      Maximum_ACK_Delay   : Duration;
      Handshake_Confirmed : Boolean)
   is
      Peer_Delay : Duration := ACK_Delay;
      Adjusted   : Duration := Sample;
      Variation  : Duration;
   begin
      Item.Latest := Sample;
      if not Item.Has_Sample then
         Item.Has_Sample := True;
         Item.Minimum := Sample;
         Item.Smoothed := Sample;
         Item.Variance := Sample / 2;
         return;
      end if;

      Item.Minimum := Duration'Min (Item.Minimum, Sample);
      if Handshake_Confirmed then
         Peer_Delay := Duration'Min (Peer_Delay, Maximum_ACK_Delay);
      end if;
      if Sample >= Item.Minimum
        and then Peer_Delay <= Sample - Item.Minimum
      then
         Adjusted := Sample - Peer_Delay;
      end if;

      if Item.Smoothed >= Adjusted then
         Variation := Item.Smoothed - Adjusted;
      else
         Variation := Adjusted - Item.Smoothed;
      end if;
      Item.Variance := Item.Variance - Item.Variance / 4 + Variation / 4;
      Item.Smoothed := Item.Smoothed - Item.Smoothed / 8 + Adjusted / 8;
   end Update_RTT;

   procedure On_Packets_Resolved
     (Item                : in out State;
      Events              : Sent_Packet_Policy.Packet_Event_Array;
      Count               : Sent_Packet_Policy.Sent_Count;
      Now                 : Sent_Packet_Policy.Timestamp;
      Application_Limited : Boolean)
   is
      Has_Lost_In_Flight : Boolean := False;
      Latest_Lost_At     : Sent_Packet_Policy.Timestamp := 0;
      Amount             : Byte_Count;
      Increase           : Byte_Count;
   begin
      for Index in 1 .. Count loop
         if Events (Index).Kind = Sent_Packet_Policy.Lost
           and then Events (Index).Packet.In_Flight
         then
            Amount := Byte_Count (Events (Index).Packet.Bytes);
            if Amount <= Item.Flight then
               Item.Flight := Item.Flight - Amount;
            else
               Item.Flight := 0;
            end if;
            Has_Lost_In_Flight := True;
            Latest_Lost_At := Sent_Packet_Policy.Timestamp'Max
              (Latest_Lost_At, Events (Index).Packet.Sent_At);
         end if;
      end loop;

      if Has_Lost_In_Flight
        and then
          (not Item.Has_Recovery or else Latest_Lost_At > Item.Recovery_Start)
      then
         Item.Has_Recovery := True;
         Item.Recovery_Start := Now;
         Item.Slow_Start_Limit := Item.Window / 2;
         Item.Window := Byte_Count'Max
           (Item.Slow_Start_Limit, Minimum_Congestion_Window);
      end if;

      for Index in 1 .. Count loop
         if Events (Index).Kind = Sent_Packet_Policy.Acknowledged
           and then Events (Index).Packet.In_Flight
         then
            Amount := Byte_Count (Events (Index).Packet.Bytes);
            if Amount <= Item.Flight then
               Item.Flight := Item.Flight - Amount;
            else
               Item.Flight := 0;
            end if;

            if not Application_Limited
              and then
                (not Item.Has_Recovery
                 or else Events (Index).Packet.Sent_At >
                   Item.Recovery_Start)
            then
               if Item.Window < Item.Slow_Start_Limit then
                  Item.Window := Saturating_Add (Item.Window, Amount);
               elsif Item.Window > 0 then
                  Increase :=
                    Maximum_Datagram_Size
                    * Byte_Count (Events (Index).Packet.Bytes)
                    / Item.Window;
                  Item.Window := Saturating_Add (Item.Window, Increase);
               else
                  Item.Window := Minimum_Congestion_Window;
               end if;
            end if;
         end if;
      end loop;
   end On_Packets_Resolved;
end Flyology.QUIC.Recovery_Policy;
