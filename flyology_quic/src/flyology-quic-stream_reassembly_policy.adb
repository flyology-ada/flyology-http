package body Flyology.QUIC.Stream_Reassembly_Policy
  with SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element_Offset;
   use type Crypto_Reassembly_Policy.Insert_Status;
   use type Varint_Policy.Value_Type;

   function Contiguous_Length (Item : Reassembly_State) return Stream_Offset is
     (Crypto_Reassembly_Policy.Contiguous_Length (Item.Core));

   function Highest_Offset (Item : Reassembly_State) return Stream_Offset is
     (Crypto_Reassembly_Policy.Highest_Offset (Item.Core));

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
     (Crypto_Reassembly_Policy.Element
        (Item.Core, Crypto_Reassembly_Policy.Stream_Index
           (Item.Delivered + Offset)));

   procedure Reset (Item : out Reassembly_State) is
   begin
      Crypto_Reassembly_Policy.Reset (Item.Core);
      Item.Delivered := 0;
      Item.Final_Known := False;
      Item.Final := 0;
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
      Core_Status : Crypto_Reassembly_Policy.Insert_Status;
      New_Final   : Boolean := False;
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

      Crypto_Reassembly_Policy.Insert
        (Item.Core, Wire_Offset, Data, Core_Status);
      case Core_Status is
         when Crypto_Reassembly_Policy.Conflicting_Overlap =>
            Status := Conflicting_Overlap;
            return;
         when Crypto_Reassembly_Policy.Exceeds_Capacity =>
            Status := Exceeds_Capacity;
            return;
         when Crypto_Reassembly_Policy.Accepted | Crypto_Reassembly_Policy.Duplicate =>
            null;
      end case;

      if New_Final then
         Item.Final := Ending;
         Item.Final_Known := True;
      end if;
      if Core_Status = Crypto_Reassembly_Policy.Accepted or else New_Final then
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
