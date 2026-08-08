with Ada.Finalization;
with Ada.Streams;
with Interfaces;
with System;
with Flyology.QUIC.Varint_Policy;

--  Packet-driven QUIC connections and application streams.
--
--  A connection owns the QUIC packet-number spaces, TLS 1.3 handshake, flow
--  control, loss state, and bounded stream reassembly. Socket waiting remains
--  outside this package so native and lightweight Flyology tasks use the same
--  protocol state machine.
package Flyology.QUIC.Connections is
   use type Interfaces.Unsigned_64;

   --  Largest UDP payload currently accepted or emitted by the driver.
   Max_Datagram_Length : constant := 1_200;
   --  Largest response flight emitted by one input datagram.
   Max_Output_Datagrams : constant := 20;
   --  Largest stream payload carried by one generated datagram.
   Max_Stream_Payload : constant := 1_100;
   --  Largest QUIC connection identifier accepted by version 1.
   Max_Connection_ID_Length : constant := 20;

   --  Index into fixed connection-identifier storage.
   subtype Connection_ID_Index is Ada.Streams.Stream_Element_Offset range
     1 .. Max_Connection_ID_Length;

   --  A QUIC connection identifier and the used prefix of its storage.
   --  @field Data Identifier octets
   --  @field Length Number of octets in Data that belong to the identifier
   type Connection_ID is record
      Data : Ada.Streams.Stream_Element_Array (Connection_ID_Index) :=
        (others => 0);
      Length : Natural range 0 .. Max_Connection_ID_Length := 0;
   end record;

   --  Raw Ed25519 private key used by the current server identity provider.
   subtype Ed25519_Private_Key is
     Ada.Streams.Stream_Element_Array (1 .. 32);
   --  QUIC application stream identifier.
   subtype Stream_ID is Varint_Policy.Value_Type;
   --  Absolute or relative stream octet count.
   subtype Stream_Offset is Varint_Policy.Value_Type;
   --  Monotonic microsecond timestamp used by recovery accounting.
   subtype Timestamp is Interfaces.Unsigned_64 range 0 .. 2**63 - 1;

   --  One UDP payload and the used prefix of its storage.
   --  @field Data Datagram octets
   --  @field Length Number of octets in Data to transmit
   type Datagram is record
      Data : Ada.Streams.Stream_Element_Array (1 .. Max_Datagram_Length) :=
        (others => 0);
      Length : Natural range 0 .. Max_Datagram_Length := 0;
   end record;

   --  Index into a bounded datagram batch.
   subtype Datagram_Index is Positive range 1 .. Max_Output_Datagrams;
   --  Fixed storage for a bounded datagram batch.
   type Datagram_Array is array (Datagram_Index) of Datagram;

   --  Bounded datagrams emitted by one connection transition.
   --  @field Items Output datagram storage
   --  @field Count Number of datagrams in Items
   type Datagram_Batch is record
      Items : Datagram_Array;
      Count : Natural range 0 .. Max_Output_Datagrams := 0;
   end record;

   --  Externally visible connection phase.
   --  @enum Uninitialized No endpoint configuration has been supplied
   --  @enum Client_Initial A client Initial flight is pending or in progress
   --  @enum Client_Handshake The client is processing Handshake packets
   --  @enum Server_Initial The server is awaiting a client Initial
   --  @enum Server_Handshake The server is awaiting the client Finished
   --  @enum Connected Application traffic keys are active
   --  @enum Failed A terminal protocol or TLS error occurred
   type Connection_State is
     (Uninitialized,
      Client_Initial,
      Client_Handshake,
      Server_Initial,
      Server_Handshake,
      Connected,
      Failed);

   --  Owning, noncopyable QUIC connection state.
   type Connection is limited private;

   --  Return the current connection phase.
   --  @param Item Connection to inspect
   --  @return Current phase
   function State (Item : Connection) return Connection_State;

   --  Report whether application traffic keys are active.
   --  @param Item Connection to inspect
   --  @return True when 1-RTT traffic can be exchanged
   function Is_Connected (Item : Connection) return Boolean;

   --  Configure a client connection with pinned-certificate authentication.
   --  @param Item Fresh connection
   --  @param ALPN Application protocol identifier, such as h3
   --  @param Transport_Parameters Encoded QUIC transport parameters
   --  @param Pinned_Certificate Expected peer certificate in DER form
   --  @param Original_Destination_ID Initial destination identifier octets
   --  @param Destination Initial destination connection identifier
   --  @param Source Client source connection identifier
   procedure Initialize_Client
     (Item                    : in out Connection;
      ALPN                    : Ada.Streams.Stream_Element_Array;
      Transport_Parameters    : Ada.Streams.Stream_Element_Array;
      Pinned_Certificate      : Ada.Streams.Stream_Element_Array;
      Original_Destination_ID : Ada.Streams.Stream_Element_Array;
      Destination             : Connection_ID;
      Source                  : Connection_ID)
   with Pre => State (Item) = Uninitialized
     and then ALPN'Length in 1 .. 255
     and then Transport_Parameters'Length <= 512
     and then Pinned_Certificate'Length in 1 .. 4_096
     and then Original_Destination_ID'Length <= Max_Connection_ID_Length;

   --  Configure a server connection with an Ed25519 certificate identity.
   --  @param Item Fresh connection
   --  @param ALPN Application protocol identifier, such as h3
   --  @param Transport_Parameters Encoded QUIC transport parameters
   --  @param Certificate_DER Server certificate in DER form
   --  @param Private_Key Ed25519 private key corresponding to the certificate
   --  @param Original_Destination_ID Identifier selected by the client
   --  @param Destination Client source connection identifier
   --  @param Source Server source connection identifier
   procedure Initialize_Server
     (Item                    : in out Connection;
      ALPN                    : Ada.Streams.Stream_Element_Array;
      Transport_Parameters    : Ada.Streams.Stream_Element_Array;
      Certificate_DER         : Ada.Streams.Stream_Element_Array;
      Private_Key             : Ed25519_Private_Key;
      Original_Destination_ID : Ada.Streams.Stream_Element_Array;
      Destination             : Connection_ID;
      Source                  : Connection_ID)
   with Pre => State (Item) = Uninitialized
     and then ALPN'Length in 1 .. 255
     and then Transport_Parameters'Length <= 512
     and then Certificate_DER'Length in 1 .. 4_096
     and then Original_Destination_ID'Length <= Max_Connection_ID_Length;

   --  Outcome of a packet-driven connection transition.
   --  @enum Succeeded Input was accepted
   --  @enum Waiting_For_More More handshake CRYPTO data is required
   --  @enum Invalid_State The operation is not valid in the current phase
   --  @enum Unsupported_Packet The packet form is not implemented
   --  @enum Packet_Error The packet failed parsing or authentication
   --  @enum TLS_Error The TLS handshake rejected its input
   --  @enum Output_Capacity_Exceeded The bounded output flight is too large
   type Operation_Status is
     (Succeeded,
      Waiting_For_More,
      Invalid_State,
      Unsupported_Packet,
      Packet_Error,
      TLS_Error,
      Output_Capacity_Exceeded);

   --  Build the client's first protected Initial flight.
   --  @param Item Initialized client connection
   --  @param Output Datagrams to transmit
   --  @param Status Transition outcome
   procedure Start_Client
     (Item   : in out Connection;
      Output : out Datagram_Batch;
      Status : out Operation_Status)
   with Pre => State (Item) = Client_Initial;

   --  Process one UDP payload and return any immediate response flight.
   --  @param Item Initialized connection
   --  @param Packet Complete UDP payload
   --  @param Output Datagrams to transmit in response
   --  @param Status Transition outcome
   --  @param Now Monotonic microsecond timestamp for recovery accounting
   procedure Process_Datagram
     (Item   : in out Connection;
      Packet : Ada.Streams.Stream_Element_Array;
      Output : out Datagram_Batch;
      Status : out Operation_Status;
      Now    : Timestamp := 0)
   with Pre => Packet'Length <= Max_Datagram_Length;

   --  Directionality of a locally created stream.
   --  @enum Bidirectional Both endpoints may send
   --  @enum Unidirectional Only the creating endpoint may send
   type Stream_Direction is (Bidirectional, Unidirectional);

   --  Outcome of allocating a local stream identifier.
   --  @enum Opened A stream identifier was allocated
   --  @enum Stream_Limit_Reached The peer's advertised limit is exhausted
   --  @enum Invalid_Stream_Limit The advertised limit cannot be represented
   type Open_Status is
     (Opened, Stream_Limit_Reached, Invalid_Stream_Limit);

   --  Allocate the next local stream of Direction.
   --  @param Item Connected endpoint
   --  @param Direction Bidirectional or unidirectional
   --  @param ID Allocated stream identifier when Status is Opened
   --  @param Status Allocation outcome
   procedure Open_Stream
     (Item      : in out Connection;
      Direction : Stream_Direction;
      ID        : out Stream_ID;
      Status    : out Open_Status)
   with Pre => Is_Connected (Item);

   --  Outcome of building application-space packets.
   --  @enum Sent A protected datagram was built
   --  @enum Nothing_To_ACK No received application packet requires an ACK
   --  @enum Congestion_Blocked Congestion credit is currently exhausted
   --  @enum Recovery_Capacity_Exceeded The sent-packet ledger is full
   --  @enum Stream_Not_Sendable The endpoint cannot send on this stream
   --  @enum Stream_Capacity_Exceeded Bounded stream state is full
   --  @enum Stream_Flow_Blocked The stream's send credit is exhausted
   --  @enum Connection_Flow_Blocked Connection send credit is exhausted
   --  @enum Stream_Range_Too_Large The requested range cannot be represented
   --  @enum Packet_Number_Exhausted No further packet number can be allocated
   --  @enum Packet_Number_Unrepresentable The packet number cannot be encoded
   --  @enum Insufficient_Protected_Payload Header protection needs more bytes
   --  @enum Packet_Too_Large The resulting datagram exceeds the fixed limit
   --  @enum Output_Too_Small Internal output storage is insufficient
   --  @enum Internal_State_Error A transactional invariant was not preserved
   type Send_Status is
     (Sent,
      Nothing_To_ACK,
      Congestion_Blocked,
      Recovery_Capacity_Exceeded,
      Stream_Not_Sendable,
      Stream_Capacity_Exceeded,
      Stream_Flow_Blocked,
      Connection_Flow_Blocked,
      Stream_Range_Too_Large,
      Packet_Number_Exhausted,
      Packet_Number_Unrepresentable,
      Insufficient_Protected_Payload,
      Packet_Too_Large,
      Output_Too_Small,
      Internal_State_Error);

   --  Build one protected STREAM packet.
   --  @param Item Connected endpoint
   --  @param ID QUIC stream identifier
   --  @param Offset Absolute stream offset of Data
   --  @param Fin Whether this packet sets the final stream size
   --  @param Data Stream payload
   --  @param Now Monotonic microsecond timestamp for recovery accounting
   --  @param Packet Datagram to transmit when Status is Sent
   --  @param Status Build outcome
   procedure Build_Stream_Datagram
     (Item   : in out Connection;
      ID     : Stream_ID;
      Offset : Stream_Offset;
      Fin    : Boolean;
      Data   : Ada.Streams.Stream_Element_Array;
      Now    : Timestamp;
      Packet : out Datagram;
      Status : out Send_Status)
   with Pre => Is_Connected (Item)
     and then Data'Length <= Max_Stream_Payload;

   --  Build one protected ACK-only packet for received application packets.
   --  @param Item Connected endpoint
   --  @param ACK_Delay Peer-visible encoded acknowledgment delay
   --  @param Now Monotonic microsecond timestamp for recovery accounting
   --  @param Packet Datagram to transmit when Status is Sent
   --  @param Status Build outcome
   procedure Build_ACK_Datagram
     (Item      : in out Connection;
      ACK_Delay : Varint_Policy.Value_Type;
      Now       : Timestamp;
      Packet    : out Datagram;
      Status    : out Send_Status)
   with Pre => Is_Connected (Item);

   --  Return the number of peer streams retained by the connection.
   --  @param Item Connection to inspect
   --  @return Number of retained streams
   function Stream_Count (Item : Connection) return Natural;

   --  Return one retained peer stream identifier.
   --  @param Item Connection to inspect
   --  @param Index One-based enumeration index
   --  @return Stream identifier
   function Stream_At (Item : Connection; Index : Positive) return Stream_ID
   with Pre => Index <= Stream_Count (Item);

   --  Report whether a particular peer stream is retained.
   --  @param Item Connection to inspect
   --  @param ID Stream identifier
   --  @return True when the stream has receive state
   function Has_Stream (Item : Connection; ID : Stream_ID) return Boolean;

   --  Return the contiguous readable prefix of a peer stream.
   --  @param Item Connection to inspect
   --  @param ID Stream identifier
   --  @return Number of readable octets
   function Available_Length
     (Item : Connection; ID : Stream_ID) return Stream_Offset
   with Pre => Has_Stream (Item, ID);

   --  Report whether a peer stream's final size is fully available.
   --  @param Item Connection to inspect
   --  @param ID Stream identifier
   --  @return True when all bytes through the final size are readable
   function Is_Complete
     (Item : Connection; ID : Stream_ID) return Boolean
   with Pre => Has_Stream (Item, ID);

   --  Report whether a peer reset a stream.
   --  @param Item Connection to inspect
   --  @param ID Stream identifier
   --  @return True when RESET_STREAM was received
   function Was_Reset (Item : Connection; ID : Stream_ID) return Boolean
   with Pre => Has_Stream (Item, ID);

   --  Return the application error from a peer stream reset.
   --  @param Item Connection to inspect
   --  @param ID Reset stream identifier
   --  @return Peer-supplied application error code
   function Reset_Error (Item : Connection; ID : Stream_ID) return Stream_ID
   with Pre => Has_Stream (Item, ID) and then Was_Reset (Item, ID);

   --  Return one octet from the readable stream prefix.
   --  @param Item Connection to inspect
   --  @param ID Stream identifier
   --  @param Offset Zero-based offset within the current readable prefix
   --  @return Stream octet
   function Element
     (Item   : Connection;
      ID     : Stream_ID;
      Offset : Stream_Offset) return Ada.Streams.Stream_Element
   with Pre => Has_Stream (Item, ID)
     and then Offset < Available_Length (Item, ID);

   --  Remove a prefix after the application consumes it.
   --  @param Item Connection to update
   --  @param ID Stream identifier
   --  @param Length Number of readable octets to remove
   procedure Consume
     (Item : in out Connection; ID : Stream_ID; Length : Stream_Offset)
   with Pre => Has_Stream (Item, ID)
     and then Length <= Available_Length (Item, ID);

private
   type Connection is new Ada.Finalization.Limited_Controlled with record
      Backend : System.Address := System.Null_Address;
   end record;

   --  @exclude
   overriding procedure Finalize (Item : in out Connection);
end Flyology.QUIC.Connections;
