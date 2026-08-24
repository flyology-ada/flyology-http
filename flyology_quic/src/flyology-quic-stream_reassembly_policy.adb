package body Flyology.QUIC.Stream_Reassembly_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Varint_Policy.Value_Type;

   function Contiguous_Length (Item : Reassembly_State) return Absolute_Offset is
     (Item.Contiguous);

   function Highest_Offset (Item : Reassembly_State) return Absolute_Offset is
     (Item.Highest);

   function Consumed_Offset (Item : Reassembly_State) return Absolute_Offset is
     (Item.Base);

   function Available_Length (Item : Reassembly_State) return Stream_Offset is
     (Stream_Offset (Contiguous_Length (Item) - Item.Base));

   function Has_Final_Size (Item : Reassembly_State) return Boolean is
     (Item.Final_Known);

   function Final_Size (Item : Reassembly_State) return Absolute_Offset is
     (Item.Final);

   function Is_Complete (Item : Reassembly_State) return Boolean is
     (Item.Final_Known and then Contiguous_Length (Item) = Item.Final);

   function Element
     (Item   : Reassembly_State;
      Offset : Stream_Index) return Ada.Streams.Stream_Element
   is
     (Item.Bytes
        (Stream_Index
           ((Item.Base + Absolute_Offset (Offset)) mod
              Absolute_Offset (Max_Stream_Data))));

   procedure Reset (Item : out Reassembly_State) is
   begin
      Item :=
        (Bytes       => (others => 0),
         Present     => (others => False),
         Base        => 0,
         Contiguous  => 0,
         Highest     => 0,
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
      Start       : Absolute_Offset;
      Ending      : Absolute_Offset;
      Effective_Start : Absolute_Offset;
      Data_Length : constant Absolute_Offset := Absolute_Offset (Data'Length);
      New_Final   : Boolean := False;
      Relative    : Absolute_Offset := 0;
      Added       : Boolean := False;
      Initial_Contiguous : constant Absolute_Offset := Item.Contiguous;
   begin
      Status := Exceeds_Capacity;
      if Data_Length > Absolute_Offset'Last - Wire_Offset then
         return;
      end if;
      Start := Wire_Offset;
      Ending := Start + Data_Length;
      if Ending > Item.Base
        and then Ending - Item.Base > Absolute_Offset (Max_Stream_Data)
      then
         return;
      end if;

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

      if Ending <= Item.Base then
         if New_Final then
            Item.Final := Ending;
            Item.Final_Known := True;
            Status := Accepted;
         else
            Status := Duplicate;
         end if;
         return;
      end if;

      Effective_Start := Absolute_Offset'Max (Start, Item.Base);

      --  Validate every retained overlap before mutation. Bytes below Base
      --  were already delivered and may be retransmitted without retention.
      while Relative < Ending - Effective_Start loop
         pragma Loop_Invariant (Relative <= Ending - Effective_Start);
         pragma Loop_Variant (Decreases => Ending - Effective_Start - Relative);
         declare
            Absolute : constant Absolute_Offset := Effective_Start + Relative;
            Target : constant Stream_Index := Stream_Index
              (Absolute mod Absolute_Offset (Max_Stream_Data));
            Source : constant Ada.Streams.Stream_Element_Offset :=
              Data'First + Ada.Streams.Stream_Element_Offset
                (Absolute - Start);
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
      while Relative < Ending - Effective_Start loop
         pragma Loop_Invariant (Relative <= Ending - Effective_Start);
         pragma Loop_Variant (Decreases => Ending - Effective_Start - Relative);
         declare
            Absolute : constant Absolute_Offset := Effective_Start + Relative;
            Target : constant Stream_Index := Stream_Index
              (Absolute mod Absolute_Offset (Max_Stream_Data));
            Source : constant Ada.Streams.Stream_Element_Offset :=
              Data'First + Ada.Streams.Stream_Element_Offset
                (Absolute - Start);
         begin
            if not Item.Present (Target) then
               Item.Bytes (Target) := Data (Source);
               Item.Present (Target) := True;
               Added := True;
            end if;
         end;
         Relative := Relative + 1;
      end loop;

      --  The capacity guard above bounds the candidate ending, while the
      --  state invariant bounds the retained high-water mark. State the two
      --  branches explicitly so the invariant proof does not have to recover
      --  this maximum through the preceding byte-array loops.
      if Ending > Item.Highest then
         pragma Assert (Ending > Item.Base);
         pragma Assert
           (Ending - Item.Base <= Absolute_Offset (Max_Stream_Data));
         Item.Highest := Ending;
      else
         pragma Assert
           (Item.Highest - Item.Base <=
              Absolute_Offset (Max_Stream_Data));
      end if;
      pragma Assert
        (Item.Highest - Item.Base <= Absolute_Offset (Max_Stream_Data));
      while Item.Contiguous < Item.Highest
        and then Item.Present
          (Stream_Index
             (Item.Contiguous mod Absolute_Offset (Max_Stream_Data)))
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
      Length : Stream_Offset)
   is
      Relative : Stream_Offset := 0;
   begin
      while Relative < Length loop
         pragma Loop_Invariant (Relative <= Length);
         pragma Loop_Variant (Decreases => Length - Relative);
         declare
            Target : constant Stream_Index := Stream_Index
              ((Item.Base + Absolute_Offset (Relative)) mod
                 Absolute_Offset (Max_Stream_Data));
         begin
            Item.Present (Target) := False;
            Item.Bytes (Target) := 0;
         end;
         Relative := Relative + 1;
      end loop;
      Item.Base := Item.Base + Absolute_Offset (Length);
   end Consume;
end Flyology.QUIC.Stream_Reassembly_Policy;
