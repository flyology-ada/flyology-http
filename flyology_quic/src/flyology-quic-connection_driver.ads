with Ada.Streams;
with Flyology.QUIC.Application_Space;
with Flyology.QUIC.Crypto_OpenSSL;
with Flyology.QUIC.Handshake_Space;
with Flyology.QUIC.Initial_Space;
with Flyology.QUIC.Long_Header_Policy;
with Flyology.QUIC.Recovery_Policy;
with Flyology.QUIC.Stream_ID_Policy;
with Flyology.QUIC.TLS_Session;
with Flyology.QUIC.Varint_Policy;

--  Internal packet-driven QUIC/TLS connection state machine.
--
--  The driver owns Initial, Handshake, and application encryption levels. It
--  produces bounded datagrams but performs no socket waits, allowing native
--  and lightweight Flyology tasks to drive the same synchronous state.
private package Flyology.QUIC.Connection_Driver is
   use type Ada.Streams.Stream_Element_Offset;

   Max_Datagram_Length : constant := 1_200;
   Max_Output_Datagrams : constant := 20;
   subtype Datagram_Index is Positive range 1 .. Max_Output_Datagrams;

   type Datagram is record
      Data : Ada.Streams.Stream_Element_Array (1 .. Max_Datagram_Length) :=
        (others => 0);
      Length : Natural range 0 .. Max_Datagram_Length := 0;
   end record;
   type Datagram_Array is array (Datagram_Index) of Datagram;
   type Datagram_Batch is record
      Items : Datagram_Array;
      Count : Natural range 0 .. Max_Output_Datagrams := 0;
   end record;

   type Connection_State is
     (Uninitialized,
      Client_Initial,
      Client_Handshake,
      Server_Initial,
      Server_Handshake,
      Connected,
      Failed);

   type Connection is limited private;

   function State (Item : Connection) return Connection_State;
   function Is_Connected (Item : Connection) return Boolean;

   procedure Initialize_Client
     (Item                    : in out Connection;
      ALPN                    : Ada.Streams.Stream_Element_Array;
      Transport_Parameters    : Ada.Streams.Stream_Element_Array;
      Pinned_Certificate      : Ada.Streams.Stream_Element_Array;
      Original_Destination_ID : Ada.Streams.Stream_Element_Array;
      Destination             : Long_Header_Policy.Connection_ID;
      Source                  : Long_Header_Policy.Connection_ID)
   with Pre => State (Item) = Uninitialized
     and then ALPN'Length in 1 .. 255
     and then Transport_Parameters'Length <= 512
     and then Pinned_Certificate'Length in 1 ..
       TLS_Session.Max_Certificate_DER
     and then Original_Destination_ID'Length <= 20
     and then Destination.Length <=
       Long_Header_Policy.V1_Connection_ID_Length'Last
     and then Source.Length <=
       Long_Header_Policy.V1_Connection_ID_Length'Last;

   procedure Initialize_Server
     (Item                    : in out Connection;
      ALPN                    : Ada.Streams.Stream_Element_Array;
      Transport_Parameters    : Ada.Streams.Stream_Element_Array;
      Certificate_DER         : Ada.Streams.Stream_Element_Array;
      Private_Key             : Crypto_OpenSSL.Ed25519_Private_Key;
      Original_Destination_ID : Ada.Streams.Stream_Element_Array;
      Destination             : Long_Header_Policy.Connection_ID;
      Source                  : Long_Header_Policy.Connection_ID)
   with Pre => State (Item) = Uninitialized
     and then ALPN'Length in 1 .. 255
     and then Transport_Parameters'Length <= 512
     and then Certificate_DER'Length in 1 .. TLS_Session.Max_Certificate_DER
     and then Original_Destination_ID'Length <= 20
     and then Destination.Length <=
       Long_Header_Policy.V1_Connection_ID_Length'Last
     and then Source.Length <=
       Long_Header_Policy.V1_Connection_ID_Length'Last;

   type Operation_Status is
     (Succeeded,
      Waiting_For_More,
      Invalid_State,
      Unsupported_Packet,
      Packet_Error,
      TLS_Error,
      Output_Capacity_Exceeded);

   type Operation_Result is record
      Status     : Operation_Status := Invalid_State;
      TLS_Status : TLS_Session.Operation_Status := TLS_Session.Invalid_State;
   end record;

   procedure Start_Client
     (Item   : in out Connection;
      Output : out Datagram_Batch;
      Result : out Operation_Result);

   procedure Process_Datagram
     (Item   : in out Connection;
      Packet : Ada.Streams.Stream_Element_Array;
      Output : out Datagram_Batch;
      Result : out Operation_Result;
      Now    : Application_Space.Timestamp := 0)
   with Pre => Packet'Length <= Max_Datagram_Length;

   procedure Open_Stream
     (Item      : in out Connection;
      Direction : Stream_ID_Policy.Stream_Direction;
      ID        : out Varint_Policy.Value_Type;
      Status    : out Application_Space.Open_Status)
   with Pre => Is_Connected (Item);

   procedure Build_Stream_Datagram
     (Item      : in out Connection;
      Stream_ID : Varint_Policy.Value_Type;
      Offset    : Varint_Policy.Value_Type;
      Fin       : Boolean;
      Data      : Ada.Streams.Stream_Element_Array;
      Now       : Application_Space.Timestamp;
      Packet    : out Datagram;
      Status    : out Application_Space.Send_Status)
   with Pre => Is_Connected (Item)
     and then Data'Length <= Application_Space.Max_Stream_Payload;

   procedure Build_ACK_Datagram
     (Item      : in out Connection;
      ACK_Delay : Varint_Policy.Value_Type;
      Now       : Application_Space.Timestamp;
      Packet    : out Datagram;
      Status    : out Application_Space.Send_Status)
   with Pre => Is_Connected (Item);

   function Has_Stream
     (Item : Connection; Stream_ID : Varint_Policy.Value_Type) return Boolean;

   function Available_Length
     (Item : Connection; Stream_ID : Varint_Policy.Value_Type)
      return Application_Space.Stream_Offset
   with Pre => Has_Stream (Item, Stream_ID);

   function Stream_Element
     (Item      : Connection;
      Stream_ID : Varint_Policy.Value_Type;
      Offset    : Application_Space.Stream_Index)
      return Ada.Streams.Stream_Element
   with Pre => Has_Stream (Item, Stream_ID)
     and then Offset < Available_Length (Item, Stream_ID);

   procedure Consume
     (Item      : in out Connection;
      Stream_ID : Varint_Policy.Value_Type;
      Length    : Application_Space.Stream_Offset)
   with Pre => Has_Stream (Item, Stream_ID)
     and then Length <= Available_Length (Item, Stream_ID);

private
   type Connection is limited record
      Current               : Connection_State := Uninitialized;
      TLS                   : TLS_Session.Session;
      Initial               : Initial_Space.State;
      Handshake             : Handshake_Space.State;
      Application           : Application_Space.State;
      Handshake_Initialized : Boolean := False;
      Application_Initialized : Boolean := False;
      Is_Client             : Boolean := True;
      Peer_ACK_Exponent     : Application_Space.ACK_Delay_Exponent := 3;
      Peer_Max_ACK_Delay    : Recovery_Policy.Duration := 25_000;
      Local_ID              : Long_Header_Policy.Connection_ID;
      Peer_ID               : Long_Header_Policy.Connection_ID;
   end record;
end Flyology.QUIC.Connection_Driver;
