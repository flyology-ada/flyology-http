with Ada.Streams;
with Flyology.QUIC.Varint_Policy;

--  Internal, proved bounded reassembly for one QUIC CRYPTO stream.
--
--  Matching retransmissions are idempotent. A frame that conflicts with any
--  previously received byte is rejected atomically. The caller can expose
--  bytes to TLS only below Contiguous_Length.
private package Flyology.QUIC.Crypto_Reassembly_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element_Offset;

   Max_Crypto_Data : constant := 65_536;
   subtype Stream_Offset is
     Ada.Streams.Stream_Element_Offset range 0 .. Max_Crypto_Data;
   subtype Stream_Index is Stream_Offset range 0 .. Max_Crypto_Data - 1;

   type Reassembly_State is private;
   type Insert_Status is
     (Accepted,
      Duplicate,
      Conflicting_Overlap,
      Exceeds_Capacity);

   function Contiguous_Length
     (Item : Reassembly_State) return Stream_Offset
   with Global => null;

   function Highest_Offset
     (Item : Reassembly_State) return Stream_Offset
   with Global => null;

   function Element
     (Item  : Reassembly_State;
      Index : Stream_Index) return Ada.Streams.Stream_Element
   with
     Global => null,
     Pre => Index < Contiguous_Length (Item);

   procedure Reset (Item : out Reassembly_State)
   with
     Global => null,
     Post =>
       Contiguous_Length (Item) = 0
       and then Highest_Offset (Item) = 0;

   procedure Insert
     (Item        : in out Reassembly_State;
      Wire_Offset : Varint_Policy.Value_Type;
      Data        : Ada.Streams.Stream_Element_Array;
      Status      : out Insert_Status)
   with
     Global => null,
     Pre => Data'Length <= Max_Crypto_Data,
     Post =>
       Contiguous_Length (Item) <= Highest_Offset (Item)
       and then
         (if Status /= Accepted then
             Contiguous_Length (Item) =
               Contiguous_Length (Item'Old)
             and then Highest_Offset (Item) = Highest_Offset (Item'Old));
private
   type Byte_Buffer is array (Stream_Index) of Ada.Streams.Stream_Element;
   type Presence_Map is array (Stream_Index) of Boolean;

   type Reassembly_State is record
      Bytes      : Byte_Buffer := (others => 0);
      Present    : Presence_Map := (others => False);
      Contiguous : Stream_Offset := 0;
      Highest    : Stream_Offset := 0;
   end record
   with Type_Invariant =>
     Reassembly_State.Contiguous <= Reassembly_State.Highest;
end Flyology.QUIC.Crypto_Reassembly_Policy;
