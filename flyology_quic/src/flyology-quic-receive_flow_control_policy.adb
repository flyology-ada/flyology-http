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

   function Has_Stream
     (Item : State; ID : Stream_ID_Policy.Stream_ID) return Boolean
   is
     (Find (Item, ID) /= 0);

   function Class_Of
     (ID : Stream_ID_Policy.Stream_ID) return Stream_Class
   is (Stream_Class (ID mod 4));

   function ID_For
     (Class   : Stream_Class;
      Ordinal : Stream_ID_Policy.Stream_Count)
      return Stream_ID_Policy.Stream_ID
   is
     (Stream_ID_Policy.Stream_ID ((Ordinal - 1) * 4)
      + Stream_ID_Policy.Stream_ID (Class))
   with Pre => Ordinal >= 1;

   function Is_Stream_Retired
     (Item : State; ID : Stream_ID_Policy.Stream_ID) return Boolean
   is
     (Stream_ID_Policy.Ordinal (ID) <= Item.Opened (Class_Of (ID))
      and then Find (Item, ID) = 0);

   procedure Release_Stream
     (Item : in out State; ID : Stream_ID_Policy.Stream_ID)
   is
      Index : constant Optional_Index := Find (Item, ID);
   begin
      if Index = 0 then
         return;
      end if;
      pragma Assert (Index in Stream_Index);
      pragma Assert (Has_Stream (Item, ID));
      Item.Streams (Index) := (others => <>);
      Item.Count := Item.Count - 1;
   end Release_Stream;

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

   procedure Raise_Connection_Limit
     (Item  : in out State;
      Limit : Value_Type) is
   begin
      Item.Initial.Connection :=
        Value_Type'Max (Item.Initial.Connection, Limit);
   end Raise_Connection_Limit;

   function Initial_Stream_Limit
     (Item : State; ID : Stream_ID_Policy.Stream_ID) return Value_Type
   is
     (if Stream_ID_Policy.Direction (ID) = Stream_ID_Policy.Unidirectional then
         Item.Initial.Unidirectional
      elsif Stream_ID_Policy.Is_Local (Item.Role, ID) then
         Item.Initial.Bidi_Local
      else Item.Initial.Bidi_Remote);

   function Stream_Window
     (Item : State; ID : Stream_ID_Policy.Stream_ID) return Value_Type
   is (Initial_Stream_Limit (Item, ID));

   procedure Raise_Stream_Data_Limit
     (Item  : in out State;
      ID    : Stream_ID_Policy.Stream_ID;
      Limit : Value_Type)
   is
      Index : constant Optional_Index := Find (Item, ID);
   begin
      if Index /= 0 then
         Item.Streams (Index).Limit :=
           Value_Type'Max (Item.Streams (Index).Limit, Limit);
      end if;
   end Raise_Stream_Data_Limit;

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
      if Is_Stream_Retired (Item, ID) then
         return Retired;
      elsif not Stream_ID_Policy.Can_Send (Item.Role, ID) then
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
      Class    : constant Stream_Class := Class_Of (ID);
      Ordinal  : constant Stream_ID_Policy.Stream_Count :=
        Stream_ID_Policy.Ordinal (ID);
      Needed   : Stream_ID_Policy.Stream_Count := 0;
      Previous : constant Stream_ID_Policy.Stream_Count := Item.Opened (Class);
      Created  : Boolean := False;
      Highest  : Value_Type;
      Increase : Value_Type;
      Maximum_Stream_Data : Value_Type;
   begin
      Status := Check_Receive_State
        (Item, ID, Local_Bidi_Opened, Local_Uni_Opened);
      if Status /= Reserved then
         return;
      elsif Index = 0 then
         if Ordinal <= Previous then
            Status := Retired;
            return;
         end if;
         Needed := Ordinal - Previous;
         if Needed > Stream_ID_Policy.Stream_Count (Max_Streams - Item.Count)
         then
            Status := Stream_Capacity_Exceeded;
            return;
         end if;
         Created := True;
         Highest := 0;
         Maximum_Stream_Data := Initial_Stream_Limit (Item, ID);
      else
         pragma Assert (Index in Stream_Index);
         Highest := Item.Streams (Index).Highest;
         Maximum_Stream_Data := Item.Streams (Index).Limit;
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
      elsif Ending > Maximum_Stream_Data then
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

      if Created then
         declare
            Opening_Count : constant Positive := Positive (Needed);
            subtype Opening_Index is Positive range 1 .. Opening_Count;
            type Opening_Slots is array (Opening_Index) of Stream_Index;
            Slots : Opening_Slots := (others => Stream_Index'First);
            Found : Natural range 0 .. Opening_Count := 0;
         begin
            for Candidate in Stream_Index loop
               exit when Found = Opening_Count;
               if not Item.Streams (Candidate).Occupied then
                  Found := Found + 1;
                  Slots (Opening_Index (Found)) := Candidate;
               end if;
            end loop;
            if Found /= Opening_Count then
               Status := Stream_Capacity_Exceeded;
               return;
            end if;

            for Step in Opening_Index loop
               pragma Loop_Invariant
                 (Item.Count =
                    Item.Count'Loop_Entry + Stream_Count (Step - 1));
               Index := Slots (Step);
               Item.Streams (Index) :=
                 (Occupied => True,
                  ID =>
                    (if Step = Opening_Index'Last
                     then ID
                     else ID_For
                       (Class,
                        Previous + Stream_ID_Policy.Stream_Count (Step))),
                  Highest =>
                    (if Step = Opening_Index'Last then Ending else 0),
                  Limit => Initial_Stream_Limit
                    (Item,
                     (if Step = Opening_Index'Last
                      then ID
                      else ID_For
                        (Class,
                         Previous + Stream_ID_Policy.Stream_Count (Step)))),
                  Final_Set => Step = Opening_Index'Last and then Fin,
                  Final =>
                    (if Step = Opening_Index'Last and then Fin
                     then Ending else 0));
               Item.Count := Item.Count + 1;
            end loop;
         end;
         Item.Opened (Class) := Ordinal;
      else
         pragma Assert (Index in Stream_Index);
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
         Streams => (others => (others => <>)), Count => 0,
         Opened => (others => 0));
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
