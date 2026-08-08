package body Flyology.QUIC.Stream_Reassembly_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Varint_Policy.Value_Type;

   function Contiguous_Length (Item : Reassembly_State) return Stream_Offset is
     (Item.Contiguous);

   function Highest_Offset (Item : Reassembly_State) return Stream_Offset is
     (Item.Highest);

   function Available_Length (Item : Reassembly_State) return Stream_Offset is
     (Contiguous_Length (Item) - Item.Delivered);

   function Has_Final_Size (Item : Reassembly_State) return Boolean is
     (Item.Final_Known);

   function Final_Size (Item : Reassembly_State) return Stream_Offset is
     (Item.Final);

   function Is_Complete (Item : Reassembly_State) return Boolean is
     (Item.Final_Known and then Contiguous_Length (Item) = Item.Final);

   function Element
     (Item   : Reassembly_State;
      Offset : Stream_Index) return Ada.Streams.Stream_Element
   is
     (Item.Bytes (Stream_Index (Item.Delivered + Offset)));

   procedure Reset (Item : out Reassembly_State) is
   begin
      Item :=
        (Bytes       => (others => 0),
         Present     => (others => False),
         Contiguous  => 0,
         Highest     => 0,
         Delivered   => 0,
         Final_Known => False,
         Final       => 0);
   end Reset;

   procedure Insert
     (Item        : in out Reassembly_State;
      Wire_Offset : Varint_Policy.Value_Type;
      Fin         : Boolean;
      Data        : Ada.Streams.Stream_Element_Array;
      Status      : out Insert_Status)
   is
      Start       : Stream_Offset;
      Ending      : Stream_Offset;
      Data_Length : constant Stream_Offset := Stream_Offset (Data'Length);
      New_Final   : Boolean := False;
      Relative    : Stream_Offset := 0;
      Added       : Boolean := False;
      Initial_Contiguous : constant Stream_Offset := Item.Contiguous;
   begin
      Status := Exceeds_Capacity;
      if Wire_Offset > Varint_Policy.Value_Type (Max_Stream_Data) then
         return;
      end if;
      Start := Stream_Offset (Wire_Offset);
      if Data_Length > Max_Stream_Data - Start then
         return;
      end if;
      Ending := Start + Data_Length;

      if Item.Final_Known then
         if Ending > Item.Final or else (Fin and then Ending /= Item.Final) then
            Status := Final_Size_Error;
            return;
         end if;
      elsif Fin then
         if Highest_Offset (Item) > Ending then
            Status := Final_Size_Error;
            return;
         end if;
         New_Final := True;
      end if;

      --  Validate every overlap before mutation so conflicting retransmission
      --  cannot leave a partially inserted stream frame behind.
      while Relative < Data_Length loop
         pragma Loop_Invariant (Relative <= Data_Length);
         pragma Loop_Variant (Decreases => Data_Length - Relative);
         declare
            Target : constant Stream_Index := Stream_Index (Start + Relative);
            Source : constant Ada.Streams.Stream_Element_Offset :=
              Data'First + Relative;
         begin
            if Item.Present (Target)
              and then Item.Bytes (Target) /= Data (Source)
            then
               Status := Conflicting_Overlap;
               return;
            end if;
         end;
         Relative := Relative + 1;
      end loop;

      Relative := 0;
      while Relative < Data_Length loop
         pragma Loop_Invariant (Relative <= Data_Length);
         pragma Loop_Variant (Decreases => Data_Length - Relative);
         declare
            Target : constant Stream_Index := Stream_Index (Start + Relative);
            Source : constant Ada.Streams.Stream_Element_Offset :=
              Data'First + Relative;
         begin
            if not Item.Present (Target) then
               Item.Bytes (Target) := Data (Source);
               Item.Present (Target) := True;
               Added := True;
            end if;
         end;
         Relative := Relative + 1;
      end loop;

      if Ending > Item.Highest then
         Item.Highest := Ending;
      end if;
      while Item.Contiguous < Item.Highest
        and then Item.Present (Stream_Index (Item.Contiguous))
      loop
         pragma Loop_Invariant (Item.Contiguous <= Item.Highest);
         pragma Loop_Invariant (Item.Contiguous >= Initial_Contiguous);
         pragma Loop_Variant (Decreases => Item.Highest - Item.Contiguous);
         Item.Contiguous := Item.Contiguous + 1;
      end loop;
      pragma Assert (Item.Contiguous >= Initial_Contiguous);

      if New_Final then
         Item.Final := Ending;
         Item.Final_Known := True;
      end if;
      if Added or else New_Final then
         Status := Accepted;
      else
         Status := Duplicate;
      end if;
   end Insert;

   procedure Consume
     (Item   : in out Reassembly_State;
      Length : Stream_Offset) is
   begin
      Item.Delivered := Item.Delivered + Length;
   end Consume;
end Flyology.QUIC.Stream_Reassembly_Policy;
