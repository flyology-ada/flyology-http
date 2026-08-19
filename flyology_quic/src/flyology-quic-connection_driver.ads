with Ada.Streams;
with Flyology.QUIC.Application_Space;
with Flyology.QUIC.Crypto_OpenSSL;
with Flyology.QUIC.Handshake_Space;
with Flyology.QUIC.Initial_Space;
with Flyology.QUIC.Long_Header_Policy;
with Flyology.QUIC.Recovery_Policy;
with Flyology.QUIC.Stream_ID_Policy;
with Flyology.QUIC.TLS_Session;
with Flyology.QUIC.Transport_Parameter_Policy;
with Flyology.QUIC.Varint_Policy;

--  Internal packet-driven QUIC/TLS connection state machine.
--
--  The driver owns Initial, Handshake, and application encryption levels. It
--  produces bounded datagrams but performs no socket waits, allowing native
--  and lightweight Flyology tasks to drive the same synchronous state.
private package Flyology.QUIC.Connection_Driver is
   use type Ada.Streams.Stream_Element_Offset;
   use type Varint_Policy.Value_Type;

   Max_Datagram_Length : constant := 1_350;
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
      Peer_Closed,
      Failed);

   type Connection is limited private;

   function State (Item : Connection) return Connection_State;
   function Is_Connected (Item : Connection) return Boolean;
   function Received_Data (Item : Connection) return Varint_Policy.Value_Type;
   function Handshake_Confirmed (Item : Connection) return Boolean;
   function Peer_Close_Is_Application (Item : Connection) return Boolean
   with Pre => State (Item) = Peer_Closed;
   function Peer_Close_Error
     (Item : Connection) return Varint_Policy.Value_Type
   with Pre => State (Item) = Peer_Closed;

   procedure Initialize_Client
     (Item                    : in out Connection;
      ALPN                    : Ada.Streams.Stream_Element_Array;
      Transport_Parameters    : Ada.Streams.Stream_Element_Array;
      Pinned_Certificate      : Ada.Streams.Stream_Element_Array;
      Original_Destination_ID : Ada.Streams.Stream_Element_Array;
      Destination             : Long_Header_Policy.Connection_ID;
      Source                  : Long_Header_Policy.Connection_ID;
      Local_Parameters        :
        Transport_Parameter_Policy.Transport_Parameters)
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
      Source                  : Long_Header_Policy.Connection_ID;
      Local_Parameters        :
        Transport_Parameter_Policy.Transport_Parameters)
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
      Connection_Closed,
      Output_Capacity_Exceeded);

   type Operation_Result is record
      Status     : Operation_Status := Invalid_State;
      TLS_Status : TLS_Session.Operation_Status := TLS_Session.Invalid_State;
   end record;

   procedure Start_Client
     (Item   : in out Connection;
      Output : out Datagram_Batch;
      Result : out Operation_Result;
      Now    : Application_Space.Timestamp := 0);

   procedure Process_Datagram
     (Item   : in out Connection;
      Packet : Ada.Streams.Stream_Element_Array;
      Output : out Datagram_Batch;
      Result : out Operation_Result;
      Now    : Application_Space.Timestamp := 0)
   with Pre => Packet'Length <= Max_Datagram_Length;

   procedure Process_Datagram
     (Item                  : in out Connection;
      Packet                : Ada.Streams.Stream_Element_Array;
      Output                : out Datagram_Batch;
      Result                : out Operation_Result;
      Now                   : Application_Space.Timestamp;
      Defer_Application_ACK : Boolean;
      ACK_Deferred          : out Boolean)
   with Pre => Packet'Length <= Max_Datagram_Length;

   type Timeout_Status is
     (Probes_Ready,
      Not_Due,
      No_Pending_Recovery,
      Timeout_Invalid_State,
      Timeout_Packet_Error,
      Timeout_Output_Capacity_Exceeded);

   function Has_Recovery_Timeout (Item : Connection) return Boolean;
   function Recovery_Deadline
     (Item : Connection) return Application_Space.Timestamp
   with Pre => Has_Recovery_Timeout (Item);

   procedure Process_Timeout
     (Item   : in out Connection;
      Now    : Application_Space.Timestamp;
      Output : out Datagram_Batch;
      Status : out Timeout_Status);

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

   procedure Build_Stream_Datagram_With_ACK
     (Item         : in out Connection;
      Stream_ID    : Varint_Policy.Value_Type;
      Offset       : Varint_Policy.Value_Type;
      Fin          : Boolean;
      Data         : Ada.Streams.Stream_Element_Array;
      Now          : Application_Space.Timestamp;
      Packet       : out Datagram;
      Status       : out Application_Space.Send_Status;
      ACK_Included : out Boolean)
   with Pre => Is_Connected (Item)
     and then Data'Length <= Application_Space.Max_Stream_Payload;

   procedure Build_Stream_Batch_Datagram_With_ACK
     (Item         : in out Connection;
      Fragments    : Application_Space.Stream_Fragment_Array;
      Data         : Ada.Streams.Stream_Element_Array;
      Now          : Application_Space.Timestamp;
      Packet       : out Datagram;
      Status       : out Application_Space.Send_Status;
      ACK_Included : out Boolean)
   with Pre => Is_Connected (Item)
     and then Fragments'Length in 1 .. Application_Space.Max_Stream_Fragments
     and then Data'Length <= Application_Space.Max_Stream_Payload;

   procedure Build_Stream_Abort_Datagram
     (Item              : in out Connection;
      Stream_ID         : Varint_Policy.Value_Type;
      Application_Error : Varint_Policy.Value_Type;
      Final_Size        : Varint_Policy.Value_Type;
      Now               : Application_Space.Timestamp;
      Packet            : out Datagram;
      Status            : out Application_Space.Send_Status)
   with Pre => Is_Connected (Item);

   procedure Build_Max_Streams_Datagram
     (Item          : in out Connection;
      Bidirectional : Boolean;
      Maximum       : Varint_Policy.Value_Type;
      Now           : Application_Space.Timestamp;
      Packet        : out Datagram;
      Status        : out Application_Space.Send_Status)
   with Pre => Is_Connected (Item) and then Maximum <= 2**60;

   procedure Build_Receive_Credit_Datagram
     (Item              : in out Connection;
      Connection_Window : Varint_Policy.Value_Type;
      Bidirectional     : Boolean;
      Maximum_Streams   : Varint_Policy.Value_Type;
      Now               : Application_Space.Timestamp;
      Packet            : out Datagram;
      Status            : out Application_Space.Send_Status)
   with Pre => Is_Connected (Item) and then Maximum_Streams <= 2**60;

   procedure Build_ACK_Datagram
     (Item      : in out Connection;
      ACK_Delay : Varint_Policy.Value_Type;
      Now       : Application_Space.Timestamp;
      Packet    : out Datagram;
      Status    : out Application_Space.Send_Status)
   with Pre => Is_Connected (Item);

   procedure Build_Application_Close_Datagram
     (Item   : in out Connection;
      Application_Error : Varint_Policy.Value_Type;
      Packet : out Datagram;
      Status : out Application_Space.Send_Status)
   with Pre => Is_Connected (Item);

   --  Build a transport CONNECTION_CLOSE in the highest encryption level the
   --  connection holds before application keys exist: Handshake once the
   --  handshake space is initialized, Initial otherwise. The connection
   --  becomes Failed whether or not a packet could be produced.
   procedure Build_Handshake_Close_Datagram
     (Item       : in out Connection;
      Error_Code : Varint_Policy.Value_Type;
      Packet     : out Datagram;
      Status     : out Application_Space.Send_Status)
   with Pre => State (Item) in
     Client_Initial | Client_Handshake | Server_Initial | Server_Handshake,
     Post => State (Item) = Failed;

   function Has_Stream
     (Item : Connection; Stream_ID : Varint_Policy.Value_Type) return Boolean;

   function Is_Stream_Retired
     (Item : Connection; Stream_ID : Varint_Policy.Value_Type) return Boolean;

   function Stream_Count (Item : Connection) return Natural;

   function Stream_At
     (Item : Connection; Index : Positive) return Varint_Policy.Value_Type
   with Pre => Index <= Stream_Count (Item);

   function Available_Length
     (Item : Connection; Stream_ID : Varint_Policy.Value_Type)
      return Application_Space.Stream_Offset
   with Pre => Has_Stream (Item, Stream_ID);

   function Is_Complete
     (Item : Connection; Stream_ID : Varint_Policy.Value_Type) return Boolean
   with Pre => Has_Stream (Item, Stream_ID);

   function Was_Reset
     (Item : Connection; Stream_ID : Varint_Policy.Value_Type) return Boolean
   with Pre => Has_Stream (Item, Stream_ID);

   function Reset_Error
     (Item : Connection; Stream_ID : Varint_Policy.Value_Type)
      return Varint_Policy.Value_Type
   with Pre => Has_Stream (Item, Stream_ID)
     and then Was_Reset (Item, Stream_ID);

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

   procedure Release_Stream
     (Item      : in out Connection;
      Stream_ID : Varint_Policy.Value_Type)
   with Pre => Has_Stream (Item, Stream_ID)
     and then (Is_Complete (Item, Stream_ID)
               or else Was_Reset (Item, Stream_ID));

private
   type Connection is limited record
      Current               : Connection_State := Uninitialized;
      TLS                   : TLS_Session.Session;
      Initial               : Initial_Space.State;
      Handshake             : Handshake_Space.State;
      Application           : Application_Space.State;
      Handshake_Initialized : Boolean := False;
      Handshake_Consumed    : Natural range 0 .. 65_535 := 0;
      Application_Initialized : Boolean := False;
      Is_Handshake_Confirmed : Boolean := False;
      Is_Client             : Boolean := True;
      Peer_ACK_Exponent     : Application_Space.ACK_Delay_Exponent := 3;
      Peer_Max_ACK_Delay    : Recovery_Policy.Duration := 25_000;
      --  RFC 9002 loss recovery shared by the Initial and Handshake spaces.
      --  Their probe timeout excludes max_ack_delay and their probe count
      --  backs off together, so one path-wide state covers both.
      Handshake_Recovery    : Recovery_Policy.State;
      Has_Handshake_Sent    : Boolean := False;
      Last_Handshake_Sent   : Application_Space.Timestamp := 0;
      --  RFC 9002 PeerCompletedAddressValidation: a client that has processed
      --  a Handshake packet no longer needs the anti-deadlock probe.
      Peer_Validated        : Boolean := False;
      Local_ID              : Long_Header_Policy.Connection_ID;
      Peer_ID               : Long_Header_Policy.Connection_ID;
      Local_Parameters      : Transport_Parameter_Policy.Transport_Parameters;
      Close_Is_Application  : Boolean := False;
      Close_Error           : Varint_Policy.Value_Type := 0;
   end record;
end Flyology.QUIC.Connection_Driver;
