with Interfaces;
with Flyology.QUIC.Stream_ID_Policy;
with Flyology.QUIC.Varint_Policy;

--  Internal, proved bounded QUIC receive-admission policy.
--
--  The policy validates stream direction and creation limits before tracking
--  the highest received offset. Connection credit grows only when a stream's
--  highest offset grows, including final sizes carried by RESET_STREAM.
private package Flyology.QUIC.Receive_Flow_Control_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Interfaces.Unsigned_64;

   Max_Streams : constant := 1_024;
   subtype Stream_Count is Natural range 0 .. Max_Streams;
   subtype Stream_Index is Positive range 1 .. Max_Streams;
   subtype Value_Type is Varint_Policy.Value_Type;

   type Receive_Limits is record
      Connection     : Value_Type := 0;
      Bidi_Local     : Value_Type := 0;
      Bidi_Remote    : Value_Type := 0;
      Unidirectional : Value_Type := 0;
      Streams_Bidi   : Value_Type := 0;
      Streams_Uni    : Value_Type := 0;
   end record;

   type State is private;
   type Reserve_Status is
     (Reserved,
      Retired,
      Stream_Not_Receivable,
      Stream_Not_Sendable,
      Stream_Not_Opened,
      Stream_Limit_Exceeded,
      Stream_Capacity_Exceeded,
      Stream_Flow_Exceeded,
      Connection_Flow_Exceeded,
      Stream_Range_Too_Large,
      Stream_Final_Size_Mismatch);

   procedure Reset
     (Item   : out State;
      Role   : Stream_ID_Policy.Endpoint_Role;
      Limits : Receive_Limits)
   with
     Global => null,
     Post => Committed_Data (Item) = 0 and then Stream_Count_Used (Item) = 0;

   function Committed_Data (Item : State) return Value_Type
   with Global => null;

   function Stream_Count_Used (Item : State) return Stream_Count
   with Global => null;

   function Has_Stream
     (Item : State; ID : Stream_ID_Policy.Stream_ID) return Boolean
   with Global => null;

   function Is_Stream_Retired
     (Item : State; ID : Stream_ID_Policy.Stream_ID) return Boolean
   with Global => null;

   procedure Release_Stream
     (Item : in out State; ID : Stream_ID_Policy.Stream_ID)
   with
     Global => null,
     Pre =>
       not Has_Stream (Item, ID) or else Stream_Count_Used (Item) > 0,
     Post => Stream_Count_Used (Item) <= Stream_Count_Used (Item'Old);

   procedure Raise_Stream_Limit
     (Item          : in out State;
      Bidirectional : Boolean;
      Limit         : Value_Type)
   with
     Global => null,
     Pre => Limit <= 2**60;

   procedure Reserve_Stream
     (Item               : in out State;
      ID                 : Stream_ID_Policy.Stream_ID;
      Offset             : Value_Type;
      Length             : Natural;
      Fin                : Boolean;
      Local_Bidi_Opened  : Stream_ID_Policy.Stream_Count;
      Local_Uni_Opened   : Stream_ID_Policy.Stream_Count;
      Status             : out Reserve_Status)
   with
     Global => null,
     Post =>
       (if Status = Reserved then
           Committed_Data (Item) >= Committed_Data (Item'Old)
        else Item = Item'Old);

   procedure Reserve_Reset
     (Item               : in out State;
      ID                 : Stream_ID_Policy.Stream_ID;
      Final_Size         : Value_Type;
      Local_Bidi_Opened  : Stream_ID_Policy.Stream_Count;
      Local_Uni_Opened   : Stream_ID_Policy.Stream_Count;
      Status             : out Reserve_Status)
   with
     Global => null,
     Post =>
       (if Status = Reserved then
           Committed_Data (Item) >= Committed_Data (Item'Old)
        else Item = Item'Old);

   function Check_Stop_Sending
     (Item               : State;
      ID                 : Stream_ID_Policy.Stream_ID;
      Local_Bidi_Opened  : Stream_ID_Policy.Stream_Count;
      Local_Uni_Opened   : Stream_ID_Policy.Stream_Count)
      return Reserve_Status
   with Global => null;

   function Check_Max_Stream_Data
     (Item               : State;
      ID                 : Stream_ID_Policy.Stream_ID;
      Local_Bidi_Opened  : Stream_ID_Policy.Stream_Count;
      Local_Uni_Opened   : Stream_ID_Policy.Stream_Count)
      return Reserve_Status
   with Global => null;

private
   type Stream_Slot is record
      Occupied  : Boolean := False;
      ID        : Stream_ID_Policy.Stream_ID := 0;
      Highest   : Value_Type := 0;
      Final_Set : Boolean := False;
      Final     : Value_Type := 0;
   end record;
   type Stream_Table is array (Stream_Index) of Stream_Slot;
   subtype Stream_Class is Natural range 0 .. 3;
   type Opened_Table is array (Stream_Class) of Stream_ID_Policy.Stream_Count;

   type State is record
      Role      : Stream_ID_Policy.Endpoint_Role := Stream_ID_Policy.Client;
      Initial   : Receive_Limits;
      Committed : Value_Type := 0;
      Streams   : Stream_Table := (others => (others => <>));
      Count     : Stream_Count := 0;
      Opened    : Opened_Table := (others => 0);
   end record;
end Flyology.QUIC.Receive_Flow_Control_Policy;
