package body Flyology.QUIC.Connection_State_Policy
  with SPARK_Mode => On
is
   function Slot (Number : Packet_Number) return Window_Index is
     (Window_Index (Number mod Receive_Window));

   function Has_Received (Item : Connection_State) return Boolean is
     (Item.Has_Largest);

   function Largest_Received
     (Item : Connection_State) return Packet_Number is
     (Item.Largest);

   function Expected_Number
     (Item : Connection_State) return Packet_Number is
     (if not Item.Has_Largest then 0
      elsif Item.Largest < Packet_Number'Last then Item.Largest + 1
      else Packet_Number'Last);

   function Was_Received
     (Item : Connection_State;
      Number : Packet_Number) return Boolean
   is
     (Item.Has_Largest
      and then Number <= Item.Largest
      and then
        (Item.Largest < Receive_Window
         or else Number > Item.Largest - Receive_Window)
      and then Item.Received (Slot (Number)).Valid
      and then Item.Received (Slot (Number)).Number = Number);

   procedure Reset (Item : out Connection_State) is
   begin
      Item :=
        (Received       => (others => (others => <>)),
         Has_Largest    => False,
         Largest        => 0,
         Next_Send      => 0,
         Send_Exhausted => False);
   end Reset;

   procedure Record_Received
     (Item        : in out Connection_State;
      Number      : Packet_Number;
      Disposition : out Receive_Disposition)
   is
      Index : constant Window_Index := Slot (Number);
   begin
      if Item.Has_Largest
        and then Item.Largest >= Receive_Window
        and then Number <= Item.Largest - Receive_Window
      then
         Disposition := Packet_Too_Old;
         return;
      elsif Item.Received (Index).Valid
        and then Item.Received (Index).Number = Number
      then
         Disposition := Duplicate_Packet;
         return;
      end if;

      pragma Assert
        (not Item.Has_Largest
         or else Item.Largest < Receive_Window
         or else Number > Item.Largest - Receive_Window);

      Item.Received (Index) := (Valid => True, Number => Number);
      if not Item.Has_Largest or else Number > Item.Largest then
         Item.Has_Largest := True;
         Item.Largest := Number;
      end if;
      pragma Assert (Item.Has_Largest);
      pragma Assert (Number <= Item.Largest);
      pragma Assert
        (Item.Largest < Receive_Window
         or else Number > Item.Largest - Receive_Window);
      pragma Assert
        (Item.Received (Index).Valid
         and then Item.Received (Index).Number = Number);
      pragma Assert (Was_Received (Item, Number));
      Disposition := New_Packet;
   end Record_Received;

   function Can_Send (Item : Connection_State) return Boolean is
     (not Item.Send_Exhausted);

   function Next_To_Send
     (Item : Connection_State) return Packet_Number is
     (Item.Next_Send);

   procedure Commit_Sent (Item : in out Connection_State) is
   begin
      if Item.Next_Send = Packet_Number'Last then
         Item.Send_Exhausted := True;
      else
         Item.Next_Send := Item.Next_Send + 1;
      end if;
   end Commit_Sent;
end Flyology.QUIC.Connection_State_Policy;
