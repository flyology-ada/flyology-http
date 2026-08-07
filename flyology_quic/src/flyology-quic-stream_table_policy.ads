with Ada.Streams;
with Flyology.QUIC.Application_Frame_Policy;
with Flyology.QUIC.Stream_Reassembly_Policy;
with Flyology.QUIC.Varint_Policy;

--  Internal, proved bounded receive table for QUIC application streams.
--
--  The table demultiplexes STREAM and RESET_STREAM frames from decrypted
--  1-RTT plaintext. Each occupied slot owns one bounded reassembly state;
--  transport-control frames are traversed but left to their owning policies.
private package Flyology.QUIC.Stream_Table_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Ada.Streams.Stream_Element_Offset;

   Max_Streams : constant := 8;
   subtype Stream_Count_Type is Natural range 0 .. Max_Streams;
   subtype Stream_Offset is Stream_Reassembly_Policy.Stream_Offset;
   subtype Stream_Index is Stream_Reassembly_Policy.Stream_Index;

   type Stream_Table is private;

   type Insert_Status is
     (Accepted,
      Duplicate,
      Stream_Capacity_Exceeded,
      Data_Capacity_Exceeded,
      Conflicting_Overlap,
      Final_Size_Error,
      Reset_Conflict);

   function Stream_Count (Item : Stream_Table) return Stream_Count_Type
   with Global => null;

   function Has_Stream
     (Item      : Stream_Table;
      Stream_ID : Varint_Policy.Value_Type) return Boolean
   with Global => null;

   function Available_Length
     (Item      : Stream_Table;
      Stream_ID : Varint_Policy.Value_Type) return Stream_Offset
   with
     Global => null,
     Pre => Has_Stream (Item, Stream_ID);

   function Has_Final_Size
     (Item      : Stream_Table;
      Stream_ID : Varint_Policy.Value_Type) return Boolean
   with
     Global => null,
     Pre => Has_Stream (Item, Stream_ID);

   function Is_Complete
     (Item      : Stream_Table;
      Stream_ID : Varint_Policy.Value_Type) return Boolean
   with
     Global => null,
     Pre => Has_Stream (Item, Stream_ID);

   function Was_Reset
     (Item      : Stream_Table;
      Stream_ID : Varint_Policy.Value_Type) return Boolean
   with
     Global => null,
     Pre => Has_Stream (Item, Stream_ID);

   function Reset_Error
     (Item      : Stream_Table;
      Stream_ID : Varint_Policy.Value_Type) return Varint_Policy.Value_Type
   with
     Global => null,
     Pre => Has_Stream (Item, Stream_ID)
       and then Was_Reset (Item, Stream_ID);

   function Element
     (Item      : Stream_Table;
      Stream_ID : Varint_Policy.Value_Type;
      Offset    : Stream_Index) return Ada.Streams.Stream_Element
   with
     Global => null,
     Pre => Has_Stream (Item, Stream_ID)
       and then Offset < Available_Length (Item, Stream_ID);

   procedure Reset (Item : in out Stream_Table)
   with
     Global => null,
     Post => Stream_Count (Item) = 0;

   procedure Insert
     (Item        : in out Stream_Table;
      Stream_ID   : Varint_Policy.Value_Type;
      Wire_Offset : Varint_Policy.Value_Type;
      Fin         : Boolean;
      Data        : Ada.Streams.Stream_Element_Array;
      Status      : out Insert_Status)
   with
     Global => null,
     Pre => Data'Length <= Stream_Reassembly_Policy.Max_Stream_Data,
     Post => Stream_Count (Item) >= Stream_Count (Item'Old)
       and then
         (if Status in Accepted | Duplicate then
             Has_Stream (Item, Stream_ID))
       and then
         (if Status not in Accepted | Duplicate then
             Stream_Count (Item) = Stream_Count (Item'Old));

   procedure Record_Reset
     (Item              : in out Stream_Table;
      Stream_ID         : Varint_Policy.Value_Type;
      Application_Error : Varint_Policy.Value_Type;
      Final_Size        : Varint_Policy.Value_Type;
      Status            : out Insert_Status)
   with
     Global => null,
     Post => Stream_Count (Item) >= Stream_Count (Item'Old)
       and then
         (if Status not in Accepted | Duplicate then
             Stream_Count (Item) = Stream_Count (Item'Old));

   procedure Consume
     (Item      : in out Stream_Table;
      Stream_ID : Varint_Policy.Value_Type;
      Length    : Stream_Offset)
   with
     Global => null,
     Pre => Has_Stream (Item, Stream_ID)
       and then Length <= Available_Length (Item, Stream_ID),
     Post => Stream_Count (Item) = Stream_Count (Item'Old);

   type Process_Status is
     (Processed,
      Frame_Truncated,
      Unknown_Frame_Type,
      Frame_Value_Too_Large,
      Invalid_ACK_Range,
      Invalid_Connection_ID,
      Stream_Capacity_Exceeded,
      Stream_Data_Too_Large,
      Conflicting_Stream_Data,
      Stream_Final_Size_Error,
      Stream_Reset_Conflict);

   subtype Plaintext_Offset is Application_Frame_Policy.Frame_Offset;

   type Process_Result is record
      Status      : Process_Status := Processed;
      Consumed    : Plaintext_Offset := 0;
      Frame_Count : Plaintext_Offset := 0;
   end record;

   procedure Process_Plaintext
     (Item      : in out Stream_Table;
      Plaintext : Ada.Streams.Stream_Element_Array;
      Result    : out Process_Result)
   with
     Global => null,
     Pre => Plaintext'Length <= Application_Frame_Policy.Max_Frame_Data,
     Post => Result.Consumed <= Plaintext_Offset (Plaintext'Length)
       and then
         (if Result.Status = Processed then
             Result.Consumed = Plaintext_Offset (Plaintext'Length));

private
   subtype Slot_Index is Positive range 1 .. Max_Streams;
   subtype Optional_Slot is Natural range 0 .. Max_Streams;

   type Stream_Slot is record
      Occupied    : Boolean := False;
      ID          : Varint_Policy.Value_Type := 0;
      Data        : Stream_Reassembly_Policy.Reassembly_State;
      Reset_Seen  : Boolean := False;
      Reset_Code  : Varint_Policy.Value_Type := 0;
   end record;

   type Slot_Array is array (Slot_Index) of Stream_Slot;

   type Stream_Table is record
      Slots : Slot_Array;
      Count : Stream_Count_Type := 0;
   end record;
end Flyology.QUIC.Stream_Table_Policy;
