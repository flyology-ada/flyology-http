package body Flyology.QUIC.Stream_Table_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element_Offset;
   use type Application_Frame_Policy.Frame_Kind;
   use type Application_Frame_Policy.Parse_Status;
   use type Stream_Reassembly_Policy.Insert_Status;
   use type Varint_Policy.Value_Type;

   function Find
     (Item      : Stream_Table;
      Stream_ID : Varint_Policy.Value_Type) return Optional_Slot
   with
     Post =>
       (if Find'Result = 0 then
           (for all Index in Slot_Index =>
              not Item.Slots (Index).Occupied
              or else Item.Slots (Index).ID /= Stream_ID)
        else Item.Slots (Find'Result).Occupied
          and then Item.Slots (Find'Result).ID = Stream_ID)
   is
   begin
      for Index in Slot_Index loop
         if Item.Slots (Index).Occupied
           and then Item.Slots (Index).ID = Stream_ID
         then
            return Index;
         end if;
      end loop;
      return 0;
   end Find;

   function Free_Slot (Item : Stream_Table) return Optional_Slot
   with
     Post =>
       (if Free_Slot'Result = 0 then
           (for all Index in Slot_Index => Item.Slots (Index).Occupied)
        else not Item.Slots (Free_Slot'Result).Occupied)
   is
   begin
      for Index in Slot_Index loop
         if not Item.Slots (Index).Occupied then
            return Index;
         end if;
      end loop;
      return 0;
   end Free_Slot;

   function Stream_Count (Item : Stream_Table) return Stream_Count_Type is
     (Item.Count);

   function Stream_At
     (Item  : Stream_Table;
      Index : Positive) return Varint_Policy.Value_Type
   is
      Seen : Stream_Count_Type := 0;
   begin
      for Slot in Slot_Index loop
         if Item.Slots (Slot).Occupied then
            Seen := Seen + 1;
            if Seen = Index then
               return Item.Slots (Slot).ID;
            end if;
         end if;
      end loop;
      return 0;
   end Stream_At;

   function Has_Stream
     (Item      : Stream_Table;
      Stream_ID : Varint_Policy.Value_Type) return Boolean
   is
     (Find (Item, Stream_ID) /= 0);

   function Available_Length
     (Item      : Stream_Table;
      Stream_ID : Varint_Policy.Value_Type) return Stream_Offset
   is
      Index : constant Optional_Slot := Find (Item, Stream_ID);
   begin
      pragma Assert (Index in Slot_Index);
      return Stream_Reassembly_Policy.Available_Length
        (Item.Slots (Index).Data);
   end Available_Length;

   function Has_Final_Size
     (Item      : Stream_Table;
      Stream_ID : Varint_Policy.Value_Type) return Boolean
   is
      Index : constant Optional_Slot := Find (Item, Stream_ID);
   begin
      pragma Assert (Index in Slot_Index);
      return Stream_Reassembly_Policy.Has_Final_Size (Item.Slots (Index).Data);
   end Has_Final_Size;

   function Is_Complete
     (Item      : Stream_Table;
      Stream_ID : Varint_Policy.Value_Type) return Boolean
   is
      Index : constant Optional_Slot := Find (Item, Stream_ID);
   begin
      pragma Assert (Index in Slot_Index);
      return Stream_Reassembly_Policy.Is_Complete (Item.Slots (Index).Data);
   end Is_Complete;

   function Was_Reset
     (Item      : Stream_Table;
      Stream_ID : Varint_Policy.Value_Type) return Boolean
   is
      Index : constant Optional_Slot := Find (Item, Stream_ID);
   begin
      pragma Assert (Index in Slot_Index);
      return Item.Slots (Index).Reset_Seen;
   end Was_Reset;

   function Reset_Error
     (Item      : Stream_Table;
      Stream_ID : Varint_Policy.Value_Type) return Varint_Policy.Value_Type
   is
      Index : constant Optional_Slot := Find (Item, Stream_ID);
   begin
      pragma Assert (Index in Slot_Index);
      return Item.Slots (Index).Reset_Code;
   end Reset_Error;

   function Element
     (Item      : Stream_Table;
      Stream_ID : Varint_Policy.Value_Type;
      Offset    : Stream_Index) return Ada.Streams.Stream_Element
   is
      Index : constant Optional_Slot := Find (Item, Stream_ID);
   begin
      pragma Assert (Index in Slot_Index);
      if Offset >=
        Stream_Reassembly_Policy.Available_Length (Item.Slots (Index).Data)
      then
         return 0;
      end if;
      return Stream_Reassembly_Policy.Element
        (Item.Slots (Index).Data, Offset);
   end Element;

   procedure Reset (Item : in out Stream_Table) is
   begin
      Item.Count := 0;
      for Index in Slot_Index loop
         Stream_Reassembly_Policy.Reset (Item.Slots (Index).Data);
         Item.Slots (Index).Occupied := False;
         Item.Slots (Index).ID := 0;
         Item.Slots (Index).Reset_Seen := False;
         Item.Slots (Index).Reset_Code := 0;
      end loop;
   end Reset;

   procedure Insert
     (Item        : in out Stream_Table;
      Stream_ID   : Varint_Policy.Value_Type;
      Wire_Offset : Varint_Policy.Value_Type;
      Fin         : Boolean;
      Data        : Ada.Streams.Stream_Element_Array;
      Status      : out Insert_Status)
   is
      Index       : Optional_Slot := Find (Item, Stream_ID);
      Created     : Boolean := False;
      Data_Status : Stream_Reassembly_Policy.Insert_Status;
   begin
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
         pragma Assert (Index in Slot_Index);
         Stream_Reassembly_Policy.Reset (Item.Slots (Index).Data);
         Item.Slots (Index).Reset_Seen := False;
         Item.Slots (Index).Reset_Code := 0;
         Created := True;
      end if;
      pragma Assert (Index in Slot_Index);

      Stream_Reassembly_Policy.Insert
        (Item.Slots (Index).Data, Wire_Offset, Fin, Data, Data_Status);
      case Data_Status is
         when Stream_Reassembly_Policy.Accepted =>
            Status := Accepted;
         when Stream_Reassembly_Policy.Duplicate =>
            Status := Duplicate;
         when Stream_Reassembly_Policy.Conflicting_Overlap =>
            Status := Conflicting_Overlap;
         when Stream_Reassembly_Policy.Final_Size_Error =>
            Status := Final_Size_Error;
         when Stream_Reassembly_Policy.Exceeds_Capacity =>
            Status := Data_Capacity_Exceeded;
      end case;

      if Created and then Status in Accepted | Duplicate then
         Item.Slots (Index).Occupied := True;
         Item.Slots (Index).ID := Stream_ID;
         Item.Count := Item.Count + 1;
      end if;
   end Insert;

   procedure Record_Reset
     (Item              : in out Stream_Table;
      Stream_ID         : Varint_Policy.Value_Type;
      Application_Error : Varint_Policy.Value_Type;
      Final_Size        : Varint_Policy.Value_Type;
      Status            : out Insert_Status)
   is
      Index : Optional_Slot := Find (Item, Stream_ID);
   begin
      if Index /= 0
        and then Item.Slots (Index).Reset_Seen
        and then Item.Slots (Index).Reset_Code /= Application_Error
      then
         Status := Reset_Conflict;
         return;
      end if;

      Insert
        (Item, Stream_ID, Final_Size, True,
         Ada.Streams.Stream_Element_Array'(1 .. 0 => 0), Status);
      if Status in Accepted | Duplicate then
         Index := Find (Item, Stream_ID);
         pragma Assert (Index in Slot_Index);
         Item.Slots (Index).Reset_Seen := True;
         Item.Slots (Index).Reset_Code := Application_Error;
      end if;
   end Record_Reset;

   procedure Consume
     (Item      : in out Stream_Table;
      Stream_ID : Varint_Policy.Value_Type;
      Length    : Stream_Offset)
   is
      Index : constant Optional_Slot := Find (Item, Stream_ID);
   begin
      pragma Assert (Index in Slot_Index);
      if Length >
        Stream_Reassembly_Policy.Available_Length (Item.Slots (Index).Data)
      then
         return;
      end if;
      Stream_Reassembly_Policy.Consume (Item.Slots (Index).Data, Length);
   end Consume;

   procedure Process_Plaintext
     (Item      : in out Stream_Table;
      Plaintext : Ada.Streams.Stream_Element_Array;
      Result    : out Process_Result)
   is
      Data_Length : constant Plaintext_Offset :=
        Plaintext_Offset (Plaintext'Length);
      Cursor       : Plaintext_Offset := 0;
      Frame        : Application_Frame_Policy.Parse_Result;
      Status       : Insert_Status;
   begin
      Result := (others => <>);
      while Cursor < Data_Length loop
         pragma Loop_Invariant (Cursor <= Data_Length);
         pragma Loop_Invariant (Result.Consumed = Cursor);
         pragma Loop_Invariant (Result.Frame_Count <= Cursor);
         pragma Loop_Variant (Decreases => Data_Length - Cursor);

         Frame := Application_Frame_Policy.Parse_Next (Plaintext, Cursor);
         Result.Triggering_Frame_Type := Frame.Frame_Type;
         if Frame.Status /= Application_Frame_Policy.Parsed then
            Result.Status :=
              (case Frame.Status is
                  when Application_Frame_Policy.Truncated => Frame_Truncated,
                  when Application_Frame_Policy.Unknown_Frame_Type =>
                    Unknown_Frame_Type,
                  when Application_Frame_Policy.Frame_Value_Too_Large =>
                    Frame_Value_Too_Large,
                  when Application_Frame_Policy.Invalid_ACK_Range =>
                    Invalid_ACK_Range,
                  when Application_Frame_Policy.Invalid_Connection_ID =>
                    Invalid_Connection_ID,
                  when Application_Frame_Policy.End_Of_Input => Frame_Truncated,
                  when Application_Frame_Policy.Parsed => Processed);
            return;
         end if;

         if Frame.Kind = Application_Frame_Policy.Stream then
            if Frame.Stream_Data_Offset > Data_Length
              or else Frame.Stream_Frame.Data_Length >
                Data_Length - Frame.Stream_Data_Offset
            then
               Result.Status := Frame_Truncated;
               return;
            end if;
            if Frame.Stream_Frame.Data_Length = 0 then
               Insert
                 (Item, Frame.Stream_ID, Frame.Stream_Frame.Stream_Offset,
                  Frame.Stream_Frame.Fin,
                  Ada.Streams.Stream_Element_Array'(1 .. 0 => 0), Status);
            else
               pragma Assert
                 (Frame.Stream_Data_Offset + Frame.Stream_Frame.Data_Length <=
                    Data_Length);
               pragma Assert (Plaintext'Length > 0);
               pragma Assert
                 (Ada.Streams.Stream_Element_Offset
                    (Frame.Stream_Data_Offset
                     + Frame.Stream_Frame.Data_Length - 1)
                    <= Plaintext'Last - Plaintext'First);
               Insert
                 (Item, Frame.Stream_ID, Frame.Stream_Frame.Stream_Offset,
                  Frame.Stream_Frame.Fin,
                  Plaintext
                    (Plaintext'First
                       + Ada.Streams.Stream_Element_Offset
                           (Frame.Stream_Data_Offset)
                       .. Plaintext'Last
                            - Ada.Streams.Stream_Element_Offset
                                (Data_Length
                                 - Frame.Stream_Data_Offset
                                 - Frame.Stream_Frame.Data_Length)),
                  Status);
            end if;
         elsif Frame.Kind = Application_Frame_Policy.Reset_Stream then
            Record_Reset
              (Item, Frame.Stream_ID, Frame.Application_Error,
               Frame.Final_Size, Status);
         else
            Status := Accepted;
         end if;

         case Status is
            when Accepted | Duplicate =>
               null;
            when Stream_Capacity_Exceeded =>
               Result.Status := Stream_Capacity_Exceeded;
               return;
            when Data_Capacity_Exceeded =>
               Result.Status := Stream_Data_Too_Large;
               return;
            when Conflicting_Overlap =>
               Result.Status := Conflicting_Stream_Data;
               return;
            when Final_Size_Error =>
               Result.Status := Stream_Final_Size_Error;
               return;
            when Reset_Conflict =>
               Result.Status := Stream_Reset_Conflict;
               return;
         end case;

         Cursor := Cursor + Frame.Consumed;
         Result.Consumed := Cursor;
         Result.Frame_Count := Result.Frame_Count + 1;
      end loop;
   end Process_Plaintext;
end Flyology.QUIC.Stream_Table_Policy;
