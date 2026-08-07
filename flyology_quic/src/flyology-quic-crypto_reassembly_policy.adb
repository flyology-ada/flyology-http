package body Flyology.QUIC.Crypto_Reassembly_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element;
   use type Varint_Policy.Value_Type;

   function Contiguous_Length
     (Item : Reassembly_State) return Stream_Offset is
     (Item.Contiguous);

   function Highest_Offset
     (Item : Reassembly_State) return Stream_Offset is
     (Item.Highest);

   function Element
     (Item  : Reassembly_State;
      Index : Stream_Index) return Ada.Streams.Stream_Element is
     (Item.Bytes (Index));

   procedure Reset (Item : out Reassembly_State) is
   begin
      Item :=
        (Bytes      => (others => 0),
         Present    => (others => False),
         Contiguous => 0,
         Highest    => 0);
   end Reset;

   procedure Insert
     (Item        : in out Reassembly_State;
      Wire_Offset : Varint_Policy.Value_Type;
      Data        : Ada.Streams.Stream_Element_Array;
      Status      : out Insert_Status)
   is
      Data_Length : constant Stream_Offset := Stream_Offset (Data'Length);
      Start       : Stream_Offset;
      Ending      : Stream_Offset;
      Relative    : Stream_Offset := 0;
      Added       : Boolean := False;
   begin
      Status := Exceeds_Capacity;
      if Wire_Offset > Varint_Policy.Value_Type (Max_Crypto_Data) then
         return;
      end if;

      Start := Stream_Offset (Wire_Offset);
      if Data_Length > Max_Crypto_Data - Start then
         return;
      end if;
      Ending := Start + Data_Length;

      --  Validate every overlap before mutating state, so a conflict cannot
      --  leave a partially inserted CRYPTO frame behind.
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

      if not Added then
         Status := Duplicate;
         return;
      end if;

      if Ending > Item.Highest then
         Item.Highest := Ending;
      end if;
      while Item.Contiguous < Item.Highest
        and then Item.Present (Stream_Index (Item.Contiguous))
      loop
         pragma Loop_Invariant (Item.Contiguous <= Item.Highest);
         pragma Loop_Variant (Decreases => Item.Highest - Item.Contiguous);
         Item.Contiguous := Item.Contiguous + 1;
      end loop;
      Status := Accepted;
   end Insert;
end Flyology.QUIC.Crypto_Reassembly_Policy;
