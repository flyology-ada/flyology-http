package body Flyology.QUIC.Flow_Control_Policy
  with SPARK_Mode => On
is
   use type Stream_ID_Policy.Endpoint_Role;
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
         if not Item.Streams (Index).Occupied then
            return Index;
         end if;
      end loop;
      return 0;
   end Free_Slot;

   function Initial_Stream_Limit
     (Item : State; ID : Stream_ID_Policy.Stream_ID) return Value_Type
   is
     (if Stream_ID_Policy.Direction (ID) = Stream_ID_Policy.Unidirectional then
         Item.Initial.Unidirectional
      elsif Stream_ID_Policy.Is_Local (Item.Role, ID) then
         Item.Initial.Bidi_Remote
      else Item.Initial.Bidi_Local);

   function Committed_Data (Item : State) return Value_Type is
     (Item.Committed);

   function Connection_Limit (Item : State) return Value_Type is
     (Item.Maximum);

   function Stream_Count_Used (Item : State) return Stream_Count is
     (Item.Count);

   function Has_Stream
     (Item : State; ID : Stream_ID_Policy.Stream_ID) return Boolean
   is
     (Find (Item, ID) /= 0);

   function Stream_Committed
     (Item : State; ID : Stream_ID_Policy.Stream_ID) return Value_Type
   is
      Index : constant Optional_Index := Find (Item, ID);
   begin
      pragma Assert (Index in Stream_Index);
      return Item.Streams (Index).Highest;
   end Stream_Committed;

   function Stream_Limit
     (Item : State; ID : Stream_ID_Policy.Stream_ID) return Value_Type
   is
      Index : constant Optional_Index := Find (Item, ID);
   begin
      pragma Assert (Index in Stream_Index);
      return Item.Streams (Index).Limit;
   end Stream_Limit;

   function Stream_Limit_At_Least
     (Item  : State;
      ID    : Stream_ID_Policy.Stream_ID;
      Limit : Value_Type) return Boolean
   is
     (for all Index in Stream_Index =>
        not Item.Streams (Index).Occupied
        or else Item.Streams (Index).ID /= ID
        or else Item.Streams (Index).Limit >= Limit);

   function Check_Send
     (Item   : State;
      ID     : Stream_ID_Policy.Stream_ID;
      Offset : Value_Type;
      Length : Natural;
      Fin    : Boolean) return Reserve_Status
   is
      Index    : constant Optional_Index := Find (Item, ID);
      Ending   : Value_Type;
      Highest  : Value_Type;
      Limit    : Value_Type;
      Increase : Value_Type;
   begin
      if not Stream_ID_Policy.Can_Send (Item.Role, ID) then
         return Stream_Not_Sendable;
      elsif Value_Type (Length) > Value_Type'Last - Offset then
         return Stream_Range_Too_Large;
      end if;
      Ending := Offset + Value_Type (Length);

      if Index = 0 then
         if Item.Count = Max_Streams or else Free_Slot (Item) = 0 then
            return Stream_Capacity_Exceeded;
         end if;
         Highest := 0;
         Limit := Initial_Stream_Limit (Item, ID);
      else
         pragma Assert (Index in Stream_Index);
         Highest := Item.Streams (Index).Highest;
         Limit := Item.Streams (Index).Limit;
      end if;

      if Index /= 0
        and then Item.Streams (Index).Final_Set
        and then
          (Ending > Item.Streams (Index).Final
           or else (Fin and then Ending /= Item.Streams (Index).Final))
      then
         return Stream_Final_Size_Mismatch;
      elsif Fin and then Ending < Highest then
         return Stream_Final_Size_Mismatch;
      elsif Ending > Limit then
         return Stream_Flow_Blocked;
      end if;
      Increase := (if Ending > Highest then Ending - Highest else 0);
      if Increase > Item.Maximum
        or else Item.Committed > Item.Maximum - Increase
      then
         return Connection_Flow_Blocked;
      end if;
      return Reserved;
   end Check_Send;

   procedure Reset
     (Item   : out State;
      Role   : Stream_ID_Policy.Endpoint_Role;
      Limits : Send_Limits) is
   begin
      Item :=
        (Role      => Role,
         Initial   => Limits,
         Maximum   => Limits.Connection,
         Committed => 0,
         Streams   => (others => (others => <>)),
         Count     => 0);
   end Reset;

   procedure Reserve_Send
     (Item   : in out State;
      ID     : Stream_ID_Policy.Stream_ID;
      Offset : Value_Type;
      Length : Natural;
      Fin    : Boolean;
      Status : out Reserve_Status)
   is
      Index   : Optional_Index := Find (Item, ID);
      Created : Boolean := False;
      Ending  : Value_Type;
      Highest : Value_Type;
      Increase : Value_Type;
      Limit   : Value_Type;
   begin
      if not Stream_ID_Policy.Can_Send (Item.Role, ID) then
         Status := Stream_Not_Sendable;
         return;
      elsif Value_Type (Length) > Value_Type'Last - Offset then
         Status := Stream_Range_Too_Large;
         return;
      end if;
      Ending := Offset + Value_Type (Length);

      if Index = 0 then
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
         Limit := Initial_Stream_Limit (Item, ID);
      else
         pragma Assert (Index in Stream_Index);
         Highest := Item.Streams (Index).Highest;
         Limit := Item.Streams (Index).Limit;
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
      elsif Ending > Limit then
         Status := Stream_Flow_Blocked;
         return;
      end if;
      Increase := (if Ending > Highest then Ending - Highest else 0);
      if Increase > Item.Maximum
        or else Item.Committed > Item.Maximum - Increase
      then
         Status := Connection_Flow_Blocked;
         return;
      end if;

      pragma Assert (Index in Stream_Index);
      if Created then
         Item.Streams (Index) :=
           (Occupied => True, ID => ID, Limit => Limit, Highest => Ending,
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
   end Reserve_Send;

   procedure Raise_Connection_Limit
     (Item : in out State; Limit : Value_Type) is
   begin
      Item.Maximum := Value_Type'Max (Item.Maximum, Limit);
   end Raise_Connection_Limit;

   procedure Raise_Stream_Limit
     (Item   : in out State;
      ID     : Stream_ID_Policy.Stream_ID;
      Limit  : Value_Type;
      Status : out Update_Status)
   is
      Index : Optional_Index := Find (Item, ID);
   begin
      if not Stream_ID_Policy.Can_Send (Item.Role, ID) then
         Status := Stream_Not_Sendable;
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
         pragma Assert (Index in Stream_Index);
         Item.Streams (Index) :=
           (Occupied => True, ID => ID,
            Limit => Value_Type'Max (Initial_Stream_Limit (Item, ID), Limit),
            Highest => 0, Final_Set => False, Final => 0);
         Item.Count := Item.Count + 1;
      else
         for Cursor in Stream_Index loop
            if Item.Streams (Cursor).Occupied
              and then Item.Streams (Cursor).ID = ID
            then
               Item.Streams (Cursor).Limit :=
                 Value_Type'Max (Item.Streams (Cursor).Limit, Limit);
            end if;
            pragma Loop_Invariant
              (for all Checked in Stream_Index'First .. Cursor =>
                 not Item.Streams (Checked).Occupied
                 or else Item.Streams (Checked).ID /= ID
                 or else Item.Streams (Checked).Limit >= Limit);
         end loop;
      end if;
      Status := Updated;
   end Raise_Stream_Limit;
end Flyology.QUIC.Flow_Control_Policy;
