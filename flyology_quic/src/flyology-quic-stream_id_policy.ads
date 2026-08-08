with Interfaces;
with Flyology.QUIC.Varint_Policy;

--  Internal, proved QUIC stream identifier and local allocation policy.
--
--  The low two stream-ID bits encode initiator and direction. Allocation is
--  monotonic per direction and rejects peer limits outside QUIC's 2^60 stream
--  count domain before arithmetic can exceed the variable-integer range.
private package Flyology.QUIC.Stream_ID_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Interfaces.Unsigned_64;

   subtype Stream_ID is Varint_Policy.Value_Type;
   subtype Stream_Count is Interfaces.Unsigned_64 range 0 .. 2**60;

   type Endpoint_Role is (Client, Server);
   type Stream_Initiator is (Client_Initiated, Server_Initiated);
   type Stream_Direction is (Bidirectional, Unidirectional);

   function Initiator (ID : Stream_ID) return Stream_Initiator
   with Global => null;

   function Direction (ID : Stream_ID) return Stream_Direction
   with Global => null;

   function Ordinal (ID : Stream_ID) return Stream_Count
   with
     Global => null,
     Post => Ordinal'Result >= 1;

   function Is_Local (Role : Endpoint_Role; ID : Stream_ID) return Boolean
   with Global => null;

   function Can_Send (Role : Endpoint_Role; ID : Stream_ID) return Boolean
   with Global => null;

   function Can_Receive (Role : Endpoint_Role; ID : Stream_ID) return Boolean
   with Global => null;

   type Open_Status is (Opened, Stream_Limit_Reached, Invalid_Stream_Limit);
   type Allocator is private;

   procedure Reset (Item : out Allocator; Role : Endpoint_Role)
   with
     Global => null,
     Post => Local_Role (Item) = Role
       and then Opened_Count (Item, Bidirectional) = 0
       and then Opened_Count (Item, Unidirectional) = 0;

   function Local_Role (Item : Allocator) return Endpoint_Role
   with Global => null;

   function Opened_Count
     (Item      : Allocator;
      Direction : Stream_Direction) return Stream_Count
   with Global => null;

   procedure Open_Local
     (Item       : in out Allocator;
      Direction  : Stream_Direction;
      Peer_Limit : Varint_Policy.Value_Type;
      ID         : out Stream_ID;
      Status     : out Open_Status)
   with
     Global => null,
     Post =>
       (if Status = Opened then
           Is_Local (Local_Role (Item), ID)
           and then Stream_ID_Policy.Direction (ID) = Direction
           and then Opened_Count (Item, Direction) =
             Opened_Count (Item'Old, Direction) + 1
        else Item = Item'Old and then ID = 0);

private
   type Allocator is record
      Role      : Endpoint_Role := Client;
      Next_Bidi : Stream_Count := 0;
      Next_Uni  : Stream_Count := 0;
   end record;
end Flyology.QUIC.Stream_ID_Policy;
