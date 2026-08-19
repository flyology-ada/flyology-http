package body Flyology.QUIC.Crypto_Flight is
   use type Varint_Policy.Value_Type;

   procedure Reset (Item : in out Flight) is
   begin
      Item.Chunks := (others => (others => <>));
      Item.Count := 0;
   end Reset;

   function Can_Retain
     (Item   : Flight;
      Offset : Varint_Policy.Value_Type;
      Length : Ada.Streams.Stream_Element_Offset) return Boolean is
     (Item.Count < Max_Chunks
      and then Offset <= Varint_Policy.Value_Type (Item.Capacity)
      and then Ada.Streams.Stream_Element_Offset (Offset) + Length <=
        Item.Capacity);

   procedure Retain
     (Item   : in out Flight;
      Number : Packet_Number;
      Offset : Varint_Policy.Value_Type;
      Data   : Ada.Streams.Stream_Element_Array;
      Status : out Retain_Status)
   is
      First : Ada.Streams.Stream_Element_Offset;
   begin
      if Offset > Varint_Policy.Value_Type (Item.Capacity)
        or else Ada.Streams.Stream_Element_Offset (Offset) + Data'Length >
          Item.Capacity
      then
         Status := Capacity_Exceeded;
         return;
      elsif Item.Count = Max_Chunks then
         Status := Chunk_Table_Full;
         return;
      end if;

      First := Ada.Streams.Stream_Element_Offset (Offset) + 1;
      if Data'Length > 0 then
         Item.Data (First .. First + Data'Length - 1) := Data;
      end if;
      Item.Count := Item.Count + 1;
      Item.Chunks (Item.Count) :=
        (Occupied => True,
         Pending  => True,
         Number   => Number,
         Offset   => Offset,
         Length   => Data'Length);
      Status := Retained;
   end Retain;

   procedure Acknowledge (Item : in out Flight; Number : Packet_Number) is
   begin
      for Index in 1 .. Item.Count loop
         if Item.Chunks (Index).Occupied
           and then Item.Chunks (Index).Number = Number
         then
            Item.Chunks (Index).Pending := False;
         end if;
      end loop;
   end Acknowledge;

   procedure Acknowledge_All (Item : in out Flight) is
   begin
      for Index in 1 .. Item.Count loop
         Item.Chunks (Index).Pending := False;
      end loop;
   end Acknowledge_All;

   function Has_Pending (Item : Flight) return Boolean is
     (First_Pending (Item) /= 0);

   function First_Pending (Item : Flight) return Chunk_Count is
   begin
      for Index in 1 .. Item.Count loop
         if Item.Chunks (Index).Occupied
           and then Item.Chunks (Index).Pending
         then
            return Index;
         end if;
      end loop;
      return 0;
   end First_Pending;

   function Next_Pending
     (Item : Flight; Index : Chunk_Index) return Chunk_Count is
   begin
      for Candidate in Index + 1 .. Item.Count loop
         if Item.Chunks (Candidate).Occupied
           and then Item.Chunks (Candidate).Pending
         then
            return Candidate;
         end if;
      end loop;
      return 0;
   end Next_Pending;

   function Offset
     (Item : Flight; Index : Chunk_Index) return Varint_Policy.Value_Type is
     (Item.Chunks (Index).Offset);

   function Length
     (Item : Flight; Index : Chunk_Index)
      return Ada.Streams.Stream_Element_Offset is
     (Item.Chunks (Index).Length);

   procedure Copy
     (Item  : Flight;
      Index : Chunk_Index;
      Data  : out Ada.Streams.Stream_Element_Array)
   is
      First : constant Ada.Streams.Stream_Element_Offset :=
        Ada.Streams.Stream_Element_Offset (Item.Chunks (Index).Offset) + 1;
      Size  : constant Ada.Streams.Stream_Element_Offset :=
        Item.Chunks (Index).Length;
   begin
      Data := (others => 0);
      if Size > 0 then
         Data (Data'First .. Data'First + Size - 1) :=
           Item.Data (First .. First + Size - 1);
      end if;
   end Copy;

   procedure Rebind
     (Item : in out Flight; Index : Chunk_Index; Number : Packet_Number) is
   begin
      Item.Chunks (Index).Number := Number;
      Item.Chunks (Index).Pending := True;
   end Rebind;
end Flyology.QUIC.Crypto_Flight;
