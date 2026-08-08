with Interfaces;
with Flyology.QUIC.Stream_ID_Policy;
with Flyology.QUIC.Varint_Policy;

--  Internal, proved bounded QUIC send flow-control policy.
--
--  Connection credit grows by each stream's newly highest sent offset, so
--  retransmission and overlap do not consume credit twice. Per-stream limits
--  are selected from the peer transport parameters by initiator and direction.
private package Flyology.QUIC.Flow_Control_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Interfaces.Unsigned_64;

   Max_Streams : constant := 8;
   subtype Stream_Count is Natural range 0 .. Max_Streams;
   subtype Stream_Index is Positive range 1 .. Max_Streams;
   subtype Value_Type is Varint_Policy.Value_Type;

   type Send_Limits is record
      Connection       : Value_Type := 0;
      Bidi_Local       : Value_Type := 0;
      Bidi_Remote      : Value_Type := 0;
      Unidirectional   : Value_Type := 0;
   end record;

   type State is private;
   type Reserve_Status is
     (Reserved,
      Stream_Not_Sendable,
      Stream_Capacity_Exceeded,
      Stream_Flow_Blocked,
      Connection_Flow_Blocked,
      Stream_Range_Too_Large);
   type Update_Status is (Updated, Stream_Not_Sendable, Stream_Capacity_Exceeded);

   procedure Reset
     (Item   : out State;
      Role   : Stream_ID_Policy.Endpoint_Role;
      Limits : Send_Limits)
   with
     Global => null,
     Post => Committed_Data (Item) = 0 and then Stream_Count_Used (Item) = 0;

   function Committed_Data (Item : State) return Value_Type
   with Global => null;

   function Connection_Limit (Item : State) return Value_Type
   with Global => null;

   function Stream_Count_Used (Item : State) return Stream_Count
   with Global => null;

   function Has_Stream
     (Item : State; ID : Stream_ID_Policy.Stream_ID) return Boolean
   with Global => null;

   function Stream_Committed
     (Item : State; ID : Stream_ID_Policy.Stream_ID) return Value_Type
   with Global => null,
        Pre => Has_Stream (Item, ID);

   function Stream_Limit
     (Item : State; ID : Stream_ID_Policy.Stream_ID) return Value_Type
   with Global => null,
        Pre => Has_Stream (Item, ID);

   function Stream_Limit_At_Least
     (Item  : State;
      ID    : Stream_ID_Policy.Stream_ID;
      Limit : Value_Type) return Boolean
   with Global => null;

   procedure Reserve_Send
     (Item   : in out State;
      ID     : Stream_ID_Policy.Stream_ID;
      Offset : Value_Type;
      Length : Natural;
      Status : out Reserve_Status)
   with
     Global => null,
     Post =>
       (if Status = Reserved then
           Has_Stream (Item, ID)
           and then Committed_Data (Item) >= Committed_Data (Item'Old)
        else Item = Item'Old);

   procedure Raise_Connection_Limit
     (Item : in out State; Limit : Value_Type)
   with
     Global => null,
     Post => Connection_Limit (Item) >= Connection_Limit (Item'Old);

   procedure Raise_Stream_Limit
     (Item   : in out State;
      ID     : Stream_ID_Policy.Stream_ID;
      Limit  : Value_Type;
      Status : out Update_Status)
   with
     Global => null,
     Post =>
       (if Status = Updated then
           Has_Stream (Item, ID)
           and then Stream_Limit_At_Least (Item, ID, Limit)
        else Item = Item'Old);

private
   type Stream_Slot is record
      Occupied : Boolean := False;
      ID       : Stream_ID_Policy.Stream_ID := 0;
      Limit    : Value_Type := 0;
      Highest  : Value_Type := 0;
   end record;
   type Stream_Table is array (Stream_Index) of Stream_Slot;

   type State is record
      Role       : Stream_ID_Policy.Endpoint_Role := Stream_ID_Policy.Client;
      Initial    : Send_Limits;
      Maximum    : Value_Type := 0;
      Committed  : Value_Type := 0;
      Streams    : Stream_Table := (others => (others => <>));
      Count      : Stream_Count := 0;
   end record;
end Flyology.QUIC.Flow_Control_Policy;
