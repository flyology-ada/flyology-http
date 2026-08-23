with Ada.Streams;
with Flyology.QUIC.Varint_Policy;

--  Internal, proved bounded reassembly for one QUIC application stream.
--
--  The byte overlap rules match CRYPTO reassembly. This layer uses a smaller
--  application-stream buffer and adds STREAM final-size consistency plus a
--  consumption cursor so an HTTP/3 parser can advance across received data.
private package Flyology.QUIC.Stream_Reassembly_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element_Offset;
   use type Varint_Policy.Value_Type;

   --  Match the default per-stream transport credit without making every
   --  tracked application stream carry the larger TLS CRYPTO buffer.
   Max_Stream_Data : constant := 16_384;

   subtype Stream_Offset is
     Ada.Streams.Stream_Element_Offset range 0 .. Max_Stream_Data;
   subtype Stream_Index is Stream_Offset range 0 .. Max_Stream_Data - 1;
   subtype Absolute_Offset is Varint_Policy.Value_Type;

   type Reassembly_State is private;
   type Insert_Status is
     (Accepted,
      Duplicate,
      Conflicting_Overlap,
      Final_Size_Error,
      Exceeds_Capacity);

   function Contiguous_Length (Item : Reassembly_State) return Absolute_Offset
   with Global => null;

   function Highest_Offset (Item : Reassembly_State) return Absolute_Offset
   with Global => null;

   function Consumed_Offset (Item : Reassembly_State) return Absolute_Offset
   with Global => null;

   function Available_Length (Item : Reassembly_State) return Stream_Offset
   with Global => null;

   function Has_Final_Size (Item : Reassembly_State) return Boolean
   with Global => null;

   function Final_Size (Item : Reassembly_State) return Absolute_Offset
   with Global => null,
        Pre => Has_Final_Size (Item);

   function Is_Complete (Item : Reassembly_State) return Boolean
   with Global => null;

   function Element
     (Item   : Reassembly_State;
      Offset : Stream_Index) return Ada.Streams.Stream_Element
   with
     Global => null,
     Pre => Offset < Available_Length (Item);

   procedure Reset (Item : out Reassembly_State)
   with
     Global => null,
     Post => Contiguous_Length (Item) = 0
       and then Highest_Offset (Item) = 0
       and then Available_Length (Item) = 0
       and then not Has_Final_Size (Item);

   procedure Insert
     (Item        : in out Reassembly_State;
      Wire_Offset : Varint_Policy.Value_Type;
      Fin         : Boolean;
      Data        : Ada.Streams.Stream_Element_Array;
      Status      : out Insert_Status)
   with
     Global => null,
     Pre => Data'Length <= Max_Stream_Data,
     Post =>
       Contiguous_Length (Item) <= Highest_Offset (Item)
       and then Absolute_Offset (Available_Length (Item)) <=
         Contiguous_Length (Item)
       and then
         (if Status not in Accepted | Duplicate then
             Contiguous_Length (Item) = Contiguous_Length (Item'Old)
             and then Highest_Offset (Item) = Highest_Offset (Item'Old)
             and then Has_Final_Size (Item) = Has_Final_Size (Item'Old));

   procedure Consume
     (Item   : in out Reassembly_State;
      Length : Stream_Offset)
   with
     Global => null,
     Pre => Length <= Available_Length (Item),
     Post => Available_Length (Item) = Available_Length (Item'Old) - Length
       and then Contiguous_Length (Item) = Contiguous_Length (Item'Old)
       and then Highest_Offset (Item) = Highest_Offset (Item'Old);
private
   type Byte_Buffer is array (Stream_Index) of Ada.Streams.Stream_Element;
   type Presence_Map is array (Stream_Index) of Boolean;

   type Reassembly_State is record
      Bytes       : Byte_Buffer := (others => 0);
      Present     : Presence_Map := (others => False);
      Base        : Absolute_Offset := 0;
      Contiguous  : Absolute_Offset := 0;
      Highest     : Absolute_Offset := 0;
      Final_Known : Boolean := False;
      Final       : Absolute_Offset := 0;
   end record
   with Type_Invariant =>
     Reassembly_State.Base <= Reassembly_State.Contiguous
     and then Reassembly_State.Contiguous <= Reassembly_State.Highest
     and then Reassembly_State.Highest - Reassembly_State.Base <=
       Absolute_Offset (Max_Stream_Data)
     and then
       (if Reassembly_State.Final_Known then
           Reassembly_State.Highest <= Reassembly_State.Final);
end Flyology.QUIC.Stream_Reassembly_Policy;
