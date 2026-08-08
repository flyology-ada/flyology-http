package body Flyology.QUIC.Receive_Flow_Control_Policy
  with SPARK_Mode => On
is
   use type Stream_ID_Policy.Stream_Count;
   use type Stream_ID_Policy.Stream_Direction;

   subtype Optional_Index is Natural range 0 .. Max_Streams;

   function Find
     (Item : State; ID : Stream_ID_Policy.Stream_ID) return Optional_Index
   with
     Post =>
       (if Find'Result = 0 then
           (for all Index in Stream_Index =>
              not Item.Streams (Index).Occupied
              or else Item.Streams (Index).ID /= ID)
        else Item.Streams (Find'Result).Occupied
          and then Item.Streams (Find'Result).ID = ID)
   is
   begin
      for Index in Stream_Index loop
         pragma Loop_Invariant
           (for all Prior in Stream_Index'First .. Index - 1 =>
              not Item.Streams (Prior).Occupied
              or else Item.Streams (Prior).ID /= ID);
         if Item.Streams (Index).Occupied
           and then Item.Streams (Index).ID = ID
         then
            return Index;
         end if;
      end loop;
      return 0;
   end Find;

   function Free_Slot (Item : State) return Optional_Index
   with
     Post =>
       (if Free_Slot'Result = 0 then
           (for all Index in Stream_Index => Item.Streams (Index).Occupied)
        else not Item.Streams (Free_Slot'Result).Occupied)
   is
   begin
      for Index in Stream_Index loop
         pragma Loop_Invariant
           (for all Prior in Stream_Index'First .. Index - 1 =>
              Item.Streams (Prior).Occupied);
         if not Item.Streams (Index).Occupied then
            return Index;
         end if;
      end loop;
      return 0;
   end Free_Slot;

   function Committed_Data (Item : State) return Value_Type is
     (Item.Committed);

   function Stream_Count_Used (Item : State) return Stream_Count is
     (Item.Count);

   procedure Raise_Stream_Limit
     (Item          : in out State;
      Bidirectional : Boolean;
      Limit         : Value_Type) is
   begin
      if Bidirectional then
         Item.Initial.Streams_Bidi :=
           Value_Type'Max (Item.Initial.Streams_Bidi, Limit);
      else
         Item.Initial.Streams_Uni :=
           Value_Type'Max (Item.Initial.Streams_Uni, Limit);
      end if;
   end Raise_Stream_Limit;

   function Initial_Stream_Limit
     (Item : State; ID : Stream_ID_Policy.Stream_ID) return Value_Type
   is
     (if Stream_ID_Policy.Direction (ID) = Stream_ID_Policy.Unidirectional then
         Item.Initial.Unidirectional
      elsif Stream_ID_Policy.Is_Local (Item.Role, ID) then
         Item.Initial.Bidi_Local
      else Item.Initial.Bidi_Remote);

   function Opened_Locally
     (ID                : Stream_ID_Policy.Stream_ID;
      Local_Bidi_Opened : Stream_ID_Policy.Stream_Count;
      Local_Uni_Opened  : Stream_ID_Policy.Stream_Count) return Boolean
   is
     (Stream_ID_Policy.Ordinal (ID) <=
        (if Stream_ID_Policy.Direction (ID) = Stream_ID_Policy.Bidirectional
         then Local_Bidi_Opened else Local_Uni_Opened));

   function Within_Peer_Limit
     (Item : State; ID : Stream_ID_Policy.Stream_ID) return Boolean
   is
     (Value_Type (Stream_ID_Policy.Ordinal (ID)) <=
        (if Stream_ID_Policy.Direction (ID) = Stream_ID_Policy.Bidirectional
         then Item.Initial.Streams_Bidi else Item.Initial.Streams_Uni));

   function Check_Receive_State
     (Item               : State;
      ID                 : Stream_ID_Policy.Stream_ID;
      Local_Bidi_Opened  : Stream_ID_Policy.Stream_Count;
      Local_Uni_Opened   : Stream_ID_Policy.Stream_Count)
      return Reserve_Status
   is
   begin
      if not Stream_ID_Policy.Can_Receive (Item.Role, ID) then
         return Stream_Not_Receivable;
      elsif Stream_ID_Policy.Is_Local (Item.Role, ID) then
         if not Opened_Locally
           (ID, Local_Bidi_Opened, Local_Uni_Opened)
         then
            return Stream_Not_Opened;
         end if;
      elsif not Within_Peer_Limit (Item, ID) then
         return Stream_Limit_Exceeded;
      end if;
      return Reserved;
   end Check_Receive_State;

   function Check_Send_State
     (Item               : State;
      ID                 : Stream_ID_Policy.Stream_ID;
      Local_Bidi_Opened  : Stream_ID_Policy.Stream_Count;
      Local_Uni_Opened   : Stream_ID_Policy.Stream_Count)
      return Reserve_Status
   is
   begin
      if not Stream_ID_Policy.Can_Send (Item.Role, ID) then
         return Stream_Not_Sendable;
      elsif Stream_ID_Policy.Is_Local (Item.Role, ID) then
         if not Opened_Locally
           (ID, Local_Bidi_Opened, Local_Uni_Opened)
         then
            return Stream_Not_Opened;
         end if;
      elsif not Within_Peer_Limit (Item, ID) then
         return Stream_Limit_Exceeded;
      end if;
      return Reserved;
   end Check_Send_State;

   procedure Reserve_Ending
     (Item               : in out State;
      ID                 : Stream_ID_Policy.Stream_ID;
      Ending             : Value_Type;
      Fin                : Boolean;
      Local_Bidi_Opened  : Stream_ID_Policy.Stream_Count;
      Local_Uni_Opened   : Stream_ID_Policy.Stream_Count;
      Status             : out Reserve_Status)
   is
      Index    : Optional_Index := Find (Item, ID);
      Created  : Boolean := False;
      Highest  : Value_Type;
      Increase : Value_Type;
   begin
      Status := Check_Receive_State
        (Item, ID, Local_Bidi_Opened, Local_Uni_Opened);
      if Status /= Reserved then
         return;
      elsif Index = 0 then
         if Item.Count = Max_Streams then
            Status := Stream_Capacity_Exceeded;
            return;
         end if;
         Index := Free_Slot (Item);
         if Index = 0 then
            Status := Stream_Capacity_Exceeded;
            return;
         end if;
         Created := True;
         Highest := 0;
      else
         pragma Assert (Index in Stream_Index);
         Highest := Item.Streams (Index).Highest;
      end if;

      if Index /= 0
        and then Item.Streams (Index).Final_Set
        and then
          (Ending > Item.Streams (Index).Final
           or else (Fin and then Ending /= Item.Streams (Index).Final))
      then
         Status := Stream_Final_Size_Mismatch;
         return;
      elsif Fin and then Ending < Highest then
         Status := Stream_Final_Size_Mismatch;
         return;
      elsif Ending > Initial_Stream_Limit (Item, ID) then
         Status := Stream_Flow_Exceeded;
         return;
      end if;

      Increase := (if Ending > Highest then Ending - Highest else 0);
      if Increase > Item.Initial.Connection
        or else Item.Committed > Item.Initial.Connection - Increase
      then
         Status := Connection_Flow_Exceeded;
         return;
      end if;

      pragma Assert (Index in Stream_Index);
      if Created then
         Item.Streams (Index) :=
           (Occupied => True, ID => ID, Highest => Ending,
            Final_Set => Fin, Final => (if Fin then Ending else 0));
         Item.Count := Item.Count + 1;
      else
         Item.Streams (Index).Highest := Value_Type'Max (Highest, Ending);
         if Fin then
            Item.Streams (Index).Final_Set := True;
            Item.Streams (Index).Final := Ending;
         end if;
      end if;
      Item.Committed := Item.Committed + Increase;
      Status := Reserved;
   end Reserve_Ending;

   procedure Reset
     (Item   : out State;
      Role   : Stream_ID_Policy.Endpoint_Role;
      Limits : Receive_Limits) is
   begin
      Item :=
        (Role => Role, Initial => Limits, Committed => 0,
         Streams => (others => (others => <>)), Count => 0);
   end Reset;

   procedure Reserve_Stream
     (Item               : in out State;
      ID                 : Stream_ID_Policy.Stream_ID;
      Offset             : Value_Type;
      Length             : Natural;
      Fin                : Boolean;
      Local_Bidi_Opened  : Stream_ID_Policy.Stream_Count;
      Local_Uni_Opened   : Stream_ID_Policy.Stream_Count;
      Status             : out Reserve_Status) is
   begin
      if Value_Type (Length) > Value_Type'Last - Offset then
         Status := Stream_Range_Too_Large;
         return;
      end if;
      Reserve_Ending
        (Item, ID, Offset + Value_Type (Length), Fin,
         Local_Bidi_Opened, Local_Uni_Opened, Status);
   end Reserve_Stream;

   procedure Reserve_Reset
     (Item               : in out State;
      ID                 : Stream_ID_Policy.Stream_ID;
      Final_Size         : Value_Type;
      Local_Bidi_Opened  : Stream_ID_Policy.Stream_Count;
      Local_Uni_Opened   : Stream_ID_Policy.Stream_Count;
      Status             : out Reserve_Status) is
   begin
      Reserve_Ending
        (Item, ID, Final_Size, True,
         Local_Bidi_Opened, Local_Uni_Opened, Status);
   end Reserve_Reset;

   function Check_Stop_Sending
     (Item               : State;
      ID                 : Stream_ID_Policy.Stream_ID;
      Local_Bidi_Opened  : Stream_ID_Policy.Stream_Count;
      Local_Uni_Opened   : Stream_ID_Policy.Stream_Count)
      return Reserve_Status
   is (Check_Send_State
         (Item, ID, Local_Bidi_Opened, Local_Uni_Opened));

   function Check_Max_Stream_Data
     (Item               : State;
      ID                 : Stream_ID_Policy.Stream_ID;
      Local_Bidi_Opened  : Stream_ID_Policy.Stream_Count;
      Local_Uni_Opened   : Stream_ID_Policy.Stream_Count)
      return Reserve_Status
   is (Check_Send_State
         (Item, ID, Local_Bidi_Opened, Local_Uni_Opened));
end Flyology.QUIC.Receive_Flow_Control_Policy;
