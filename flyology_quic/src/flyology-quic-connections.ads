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
   Max_Datagram_Length : constant := 1_350;
   --  Largest response flight emitted by one input datagram.
   Max_Output_Datagrams : constant := 20;
   --  Largest stream payload carried by one generated datagram.
   Max_Stream_Payload : constant := 1_100;
   --  Largest number of independent STREAM frames combined in one generated
   --  1-RTT packet. The aggregate encoded packet remains bounded by
   --  Max_Datagram_Length.
   Max_Stream_Fragments : constant Positive := 8;
   --  Lifetime stream accounting retained by one bounded QUIC connection.
   --  Large byte reassembly buffers remain separately bounded to 32 active
   --  streams and are recycled after protocol completion.
   Max_Tracked_Streams : constant Positive := 1_024;
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

   --  Raised when the configured cryptographic provider cannot supply random
   --  bytes for a connection identifier.
   Randomness_Error : exception;

   --  Generate an unpredictable connection identifier with the configured
   --  cryptographic provider.
   --  @param Length Number of identifier octets
   --  @return Fresh QUIC connection identifier
   --  @exception Randomness_Error Secure random generation failed
   function Random_Connection_ID
     (Length : Positive := 8) return Connection_ID
   with Pre => Length <= Max_Connection_ID_Length;

   --  Invariant header information needed by a UDP connection dispatcher.
   --  @field Valid The datagram begins with a supported QUIC v1 header
   --  @field Is_Initial The datagram begins with a client Initial packet
   --  @field Destination Destination connection identifier from that header
   type Datagram_Header is record
      Valid       : Boolean := False;
      Is_Initial  : Boolean := False;
      Destination : Connection_ID;
   end record;

   --  Inspect the invariant portion of the first QUIC packet in a datagram.
   --  Short headers do not encode their destination identifier length, so a
   --  dispatcher supplies the fixed length it assigned to local identifiers.
   --  This operation does not authenticate or otherwise process the packet.
   --  @param Data UDP datagram payload
   --  @param Short_Header_Destination_Length Locally assigned CID length
   --  @return Bounded routing information, or Valid False for malformed input
   function Inspect_Datagram_Header
     (Data : Ada.Streams.Stream_Element_Array;
      Short_Header_Destination_Length : Positive := 8)
      return Datagram_Header
   with Pre =>
     Short_Header_Destination_Length <= Max_Connection_ID_Length;

   --  Raw Ed25519 private key used by the current server identity provider.
   subtype Ed25519_Private_Key is
     Ada.Streams.Stream_Element_Array (1 .. 32);
   --  QUIC application stream identifier.
   subtype Stream_ID is Varint_Policy.Value_Type;
   --  Absolute or relative stream octet count.
   subtype Stream_Offset is Varint_Policy.Value_Type;
   --  Monotonic microsecond timestamp used by recovery accounting.
   subtype Timestamp is Interfaces.Unsigned_64 range 0 .. 2**63 - 1;

   --  Initial flow-control and stream limits advertised to a peer.
   --  @field Max_UDP_Payload_Size Largest accepted QUIC UDP payload
   --  @field Max_Data Connection-level receive credit
   --  @field Max_Stream_Data_Bidi_Local Receive credit on local bidi streams
   --  @field Max_Stream_Data_Bidi_Remote Receive credit on peer bidi streams
   --  @field Max_Stream_Data_Uni Receive credit on peer unidirectional streams
   --  @field Max_Streams_Bidi Maximum peer-created bidirectional streams
   --  @field Max_Streams_Uni Maximum peer-created unidirectional streams
   type Transport_Settings is record
      Max_UDP_Payload_Size        : Stream_Offset := Max_Datagram_Length;
      Max_Data                    : Stream_Offset := 524_288;
      Max_Stream_Data_Bidi_Local  : Stream_Offset := 16_384;
      Max_Stream_Data_Bidi_Remote : Stream_Offset := 16_384;
      Max_Stream_Data_Uni         : Stream_Offset := 16_384;
      Max_Streams_Bidi            : Stream_Offset := 29;
      Max_Streams_Uni             : Stream_Offset := 3;
   end record;

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

   --  Description of one slice in the aggregate Data argument supplied to
   --  Build_Stream_Batch_Datagram_With_ACK.
   --  @field ID QUIC stream identifier
   --  @field Offset Absolute stream offset of the slice
   --  @field Length Number of aggregate Data octets belonging to this stream
   --  @field Fin Whether the slice sets the stream final size
   type Stream_Fragment is record
      ID     : Stream_ID := 0;
      Offset : Stream_Offset := 0;
      Length : Natural range 0 .. Max_Stream_Payload := 0;
      Fin    : Boolean := False;
   end record;

   --  Bounded descriptions for STREAM frames combined into one packet.
   type Stream_Fragment_Array is
     array (Positive range <>) of Stream_Fragment;

   --  Return the aggregate payload length described by Fragments, capped one
   --  past Max_Stream_Payload so callers can validate without overflow.
   function Total_Length
     (Fragments : Stream_Fragment_Array) return Natural;

   --  Externally visible connection phase.
   --  @enum Uninitialized No endpoint configuration has been supplied
   --  @enum Client_Initial A client Initial flight is pending or in progress
   --  @enum Client_Handshake The client is processing Handshake packets
   --  @enum Server_Initial The server is awaiting a client Initial
   --  @enum Server_Handshake The server is awaiting the client Finished
   --  @enum Connected Application traffic keys are active
   --  @enum Peer_Closed The peer sent a valid CONNECTION_CLOSE frame
   --  @enum Failed A terminal protocol or TLS error occurred
   type Connection_State is
     (Uninitialized,
      Client_Initial,
      Client_Handshake,
      Server_Initial,
      Server_Handshake,
      Connected,
      Peer_Closed,
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

   --  Return the cumulative application stream bytes committed by the peer.
   --  @param Item Connection to inspect
   --  @return Monotonic connection-level receive-flow-control consumption
   function Received_Data (Item : Connection) return Stream_Offset;

   --  Report whether the TLS handshake has QUIC-level confirmation.
   --  Servers confirm after accepting client Finished; clients confirm only
   --  after receiving HANDSHAKE_DONE.
   --  @param Item Connection to inspect
   --  @return True after role-specific handshake confirmation
   function Handshake_Confirmed (Item : Connection) return Boolean;

   --  Report whether the peer used an application CONNECTION_CLOSE frame.
   --  @param Item Peer-closed connection
   --  @return True for application close and False for transport close
   function Peer_Close_Is_Application (Item : Connection) return Boolean
   with Pre => State (Item) = Peer_Closed;

   --  Return the error code carried by the peer CONNECTION_CLOSE frame.
   --  @param Item Peer-closed connection
   --  @return Application or transport error code selected by the peer
   function Peer_Close_Error (Item : Connection) return Stream_Offset
   with Pre => State (Item) = Peer_Closed;

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

   --  Configure a client and encode its transport settings internally.
   --  @param Item Fresh connection
   --  @param ALPN Application protocol identifier, such as h3
   --  @param Settings Initial flow-control and stream limits
   --  @param Pinned_Certificate Expected peer certificate in DER form
   --  @param Original_Destination_ID Initial destination identifier octets
   --  @param Destination Initial destination connection identifier
   --  @param Source Client source connection identifier
   procedure Initialize_Client
     (Item                    : in out Connection;
      ALPN                    : Ada.Streams.Stream_Element_Array;
      Settings                : Transport_Settings;
      Pinned_Certificate      : Ada.Streams.Stream_Element_Array;
      Original_Destination_ID : Ada.Streams.Stream_Element_Array;
      Destination             : Connection_ID;
      Source                  : Connection_ID)
   with Pre => State (Item) = Uninitialized
     and then ALPN'Length in 1 .. 255
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

   --  Outcome of deriving server connection state from a first datagram.
   --  @enum Initialized The v1 Initial was accepted as server configuration
   --  @enum Invalid_Initial The first packet is not a complete QUIC v1 Initial
   --  @enum Invalid_Transport_Settings Settings could not be encoded
   type Server_Initialize_Status is
     (Initialized, Invalid_Initial, Invalid_Transport_Settings);

   --  Configure a server from connection identifiers in a peer Initial.
   --  The caller still passes First_Datagram to Process_Datagram afterward.
   --  @param Item Fresh connection
   --  @param ALPN Application protocol identifier, such as h3
   --  @param Settings Initial flow-control and stream limits
   --  @param Certificate_DER Server certificate in DER form
   --  @param Private_Key Ed25519 private key corresponding to the certificate
   --  @param Source Server source connection identifier
   --  @param First_Datagram UDP payload whose first packet is a v1 Initial
   --  @param Status Configuration outcome
   procedure Initialize_Server_From_Initial
     (Item            : in out Connection;
      ALPN            : Ada.Streams.Stream_Element_Array;
      Settings        : Transport_Settings;
      Certificate_DER : Ada.Streams.Stream_Element_Array;
      Private_Key     : Ed25519_Private_Key;
      Source          : Connection_ID;
      First_Datagram  : Ada.Streams.Stream_Element_Array;
      Status          : out Server_Initialize_Status)
   with Pre => State (Item) = Uninitialized
     and then ALPN'Length in 1 .. 255
     and then Certificate_DER'Length in 1 .. 4_096
     and then First_Datagram'Length <= Max_Datagram_Length;

   --  Outcome of a packet-driven connection transition.
   --  @enum Succeeded Input was accepted
   --  @enum Waiting_For_More More handshake CRYPTO data is required
   --  @enum Invalid_State The operation is not valid in the current phase
   --  @enum Unsupported_Packet The packet form is not implemented
   --  @enum Packet_Error The packet failed parsing or authentication
   --  @enum TLS_Error The TLS handshake rejected its input
   --  @enum Connection_Closed The peer sent a valid CONNECTION_CLOSE frame
   --  @enum Output_Capacity_Exceeded The bounded output flight is too large
   type Operation_Status is
     (Succeeded,
      Waiting_For_More,
      Invalid_State,
      Unsupported_Packet,
      Packet_Error,
      TLS_Error,
      Connection_Closed,
      Output_Capacity_Exceeded);

   --  Build the client's first protected Initial flight.
   --  @param Item Initialized client connection
   --  @param Output Datagrams to transmit
   --  @param Status Transition outcome
   --  @param Now Monotonic microsecond timestamp for recovery accounting
   procedure Start_Client
     (Item   : in out Connection;
      Output : out Datagram_Batch;
      Status : out Operation_Status;
      Now    : Timestamp := 0)
   with Pre => State (Item) = Client_Initial;

   --  Process one UDP payload and return any immediate response flight,
   --  including an ACK for newly accepted ACK-eliciting application data.
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

   --  Process one UDP payload while allowing a newly required application
   --  ACK to be carried by the caller's next response packet.
   --  @param Item Initialized connection
   --  @param Packet Complete UDP payload
   --  @param Output Immediate non-deferred response datagrams
   --  @param Status Transition outcome
   --  @param Now Monotonic microsecond timestamp for recovery accounting
   --  @param Defer_Application_ACK Whether an application ACK may be deferred
   --  @param ACK_Deferred True when the caller must send or coalesce that ACK
   procedure Process_Datagram
     (Item                  : in out Connection;
      Packet                : Ada.Streams.Stream_Element_Array;
      Output                : out Datagram_Batch;
      Status                : out Operation_Status;
      Now                   : Timestamp;
      Defer_Application_ACK : Boolean;
      ACK_Deferred          : out Boolean)
   with Pre => Packet'Length <= Max_Datagram_Length;

   --  Outcome of processing a recovery timer expiration.
   --  @enum Probes_Ready Output contains ACK-eliciting PTO probes
   --  @enum Not_Due The current recovery deadline is still in the future
   --  @enum No_Pending_Recovery No in-flight packet needs a timer
   --  @enum Invalid_Timeout_State No packet-number space is active
   --  @enum Timeout_Packet_Error A protected probe could not be built
   --  @enum Timeout_Output_Capacity_Exceeded Probe output did not fit
   type Timeout_Status is
     (Probes_Ready,
      Not_Due,
      No_Pending_Recovery,
      Invalid_Timeout_State,
      Timeout_Packet_Error,
      Timeout_Output_Capacity_Exceeded);

   --  Report whether a recovery timer is armed in any packet-number space.
   --  Initial and Handshake spaces arm an RFC 9002 section 6.2 probe timeout
   --  until the handshake is confirmed; the application space arms one while
   --  an ACK-eliciting 1-RTT packet remains in flight.
   --  @param Item Connection to inspect
   --  @return True while a probe timeout is armed
   function Has_Recovery_Timeout (Item : Connection) return Boolean;

   --  Return the absolute monotonic deadline for the earliest armed recovery
   --  timer.
   --  @param Item Connection with an armed recovery timer
   --  @return Monotonic microsecond deadline
   function Recovery_Deadline (Item : Connection) return Timestamp
   with Pre => Has_Recovery_Timeout (Item);

   --  Process an expired PTO and produce bounded probes. A handshake-space
   --  probe retransmits unacknowledged CRYPTO data, or carries the client's
   --  anti-deadlock PING when none remains. An application-space probe
   --  retransmits retained STREAM or control data and otherwise carries PING.
   --  @param Item Initialized endpoint
   --  @param Now Current monotonic microsecond timestamp
   --  @param Output Probe datagrams when Status is Probes_Ready
   --  @param Status Timer transition outcome
   procedure Process_Timeout
     (Item   : in out Connection;
      Now    : Timestamp;
      Output : out Datagram_Batch;
      Status : out Timeout_Status);

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
   --  @enum Stream_Final_Size_Mismatch Reset size differs from committed data
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
      Stream_Final_Size_Mismatch,
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

   --  Build one protected STREAM packet and include the current application
   --  ACK when both frames fit. ACK_Included is false when no ACK is pending
   --  or the combined plaintext is too large.
   --  @param Item Connected endpoint
   --  @param ID QUIC stream identifier
   --  @param Offset Absolute stream offset of Data
   --  @param Fin Whether this packet sets the final stream size
   --  @param Data Stream payload
   --  @param Now Monotonic microsecond timestamp for recovery accounting
   --  @param Packet Datagram to transmit when Status is Sent
   --  @param Status Build outcome
   --  @param ACK_Included Whether the datagram carries an ACK frame
   procedure Build_Stream_Datagram_With_ACK
     (Item         : in out Connection;
      ID           : Stream_ID;
      Offset       : Stream_Offset;
      Fin          : Boolean;
      Data         : Ada.Streams.Stream_Element_Array;
      Now          : Timestamp;
      Packet       : out Datagram;
      Status       : out Send_Status;
      ACK_Included : out Boolean)
   with Pre => Is_Connected (Item)
     and then Data'Length <= Max_Stream_Payload;

   --  Build one protected packet containing STREAM frames for several
   --  independent streams and include the current application ACK when it
   --  fits. All stream-flow reservations commit together only when Status is
   --  Sent. Packet_Too_Large leaves every stream unsent so callers can fall
   --  back to individual packets.
   --  @param Item Connected endpoint
   --  @param Fragments Ordered stream slice descriptions
   --  @param Data Concatenated slice payloads in Fragments order
   --  @param Now Monotonic microsecond timestamp for recovery accounting
   --  @param Packet Datagram to transmit when Status is Sent
   --  @param Status Build outcome
   --  @param ACK_Included Whether the datagram carries an ACK frame
   procedure Build_Stream_Batch_Datagram_With_ACK
     (Item         : in out Connection;
      Fragments    : Stream_Fragment_Array;
      Data         : Ada.Streams.Stream_Element_Array;
      Now          : Timestamp;
      Packet       : out Datagram;
      Status       : out Send_Status;
      ACK_Included : out Boolean)
   with Pre => Is_Connected (Item)
     and then Fragments'Length in 1 .. Max_Stream_Fragments
     and then Total_Length (Fragments) = Data'Length
     and then Data'Length <= Max_Stream_Payload;

   --  Build one protected cancellation packet for both directions of a
   --  bidirectional application stream.
   --  @param Item Connected endpoint
   --  @param ID QUIC bidirectional stream identifier
   --  @param Application_Error Application protocol error code
   --  @param Final_Size Number of stream octets committed for transmission
   --  @param Now Monotonic microsecond timestamp for recovery accounting
   --  @param Packet Datagram to transmit when Status is Sent
   --  @param Status Build outcome
   procedure Build_Stream_Abort_Datagram
     (Item              : in out Connection;
      ID                : Stream_ID;
      Application_Error : Varint_Policy.Value_Type;
      Final_Size        : Stream_Offset;
      Now               : Timestamp;
      Packet            : out Datagram;
      Status            : out Send_Status)
   with Pre => Is_Connected (Item);

   --  Return peer concurrency credit after retiring streams. Maximum is the
   --  new cumulative stream-count limit carried by MAX_STREAMS.
   --  @param Item Connected endpoint
   --  @param Direction Stream direction whose cumulative limit is raised
   --  @param Maximum New cumulative stream-count limit
   --  @param Now Monotonic microsecond timestamp for recovery accounting
   --  @param Packet Datagram to transmit when Status is Sent
   --  @param Status Build outcome
   procedure Build_Max_Streams_Datagram
     (Item      : in out Connection;
      Direction : Stream_Direction;
      Maximum   : Stream_Offset;
      Now       : Timestamp;
      Packet    : out Datagram;
      Status    : out Send_Status)
   with Pre => Is_Connected (Item) and then Maximum <= 2**60;

   --  Return both connection data credit and stream-concurrency credit in one
   --  protected packet. Connection_Window is maintained beyond all bytes
   --  received so far; Maximum_Streams is the cumulative MAX_STREAMS limit.
   --  @param Item Connected endpoint
   --  @param Connection_Window Receive bytes kept available beyond committed data
   --  @param Direction Stream direction whose cumulative limit is raised
   --  @param Maximum_Streams New cumulative stream-count limit
   --  @param Now Monotonic microsecond timestamp for recovery accounting
   --  @param Packet Datagram to transmit when Status is Sent
   --  @param Status Build outcome
   procedure Build_Receive_Credit_Datagram
     (Item              : in out Connection;
      Connection_Window : Stream_Offset;
      Direction         : Stream_Direction;
      Maximum_Streams   : Stream_Offset;
      Now               : Timestamp;
      Packet            : out Datagram;
      Status            : out Send_Status)
   with Pre => Is_Connected (Item) and then Maximum_Streams <= 2**60;

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

   --  Build a protected application CONNECTION_CLOSE carrying application
   --  error zero and an empty reason phrase.
   --  @param Item Connected endpoint
   --  @param Packet Datagram to transmit when Status is Sent
   --  @param Status Build outcome
   procedure Build_Application_Close_Datagram
     (Item   : in out Connection;
      Packet : out Datagram;
      Status : out Send_Status)
   with Pre => Is_Connected (Item);

   --  Build a protected application CONNECTION_CLOSE carrying Error_Code and
   --  an empty reason phrase.
   --  @param Item Connected endpoint
   --  @param Error_Code HTTP/3 or other application protocol error
   --  @param Packet Datagram to transmit when Status is Sent
   --  @param Status Build outcome
   procedure Build_Application_Close_Datagram
     (Item       : in out Connection;
      Error_Code : Stream_Offset;
      Packet     : out Datagram;
      Status     : out Send_Status)
   with Pre => Is_Connected (Item);

   --  Build a transport CONNECTION_CLOSE for a connection abandoned before
   --  application keys exist. An application CONNECTION_CLOSE cannot be sent
   --  in the Initial or Handshake space, so this carries the transport
   --  APPLICATION_ERROR code that RFC 9000 10.2.3 reserves for that case. The
   --  packet uses Handshake protection once the handshake space is available
   --  and Initial protection otherwise; a peer that reached either level can
   --  read it. The connection becomes Failed whether or not a packet could be
   --  produced, because an endpoint that has started closing must not send
   --  anything else.
   --  @param Item Endpoint that has not completed its handshake
   --  @param Packet Datagram to transmit when Status is Sent
   --  @param Status Build outcome
   procedure Build_Handshake_Close_Datagram
     (Item   : in out Connection;
      Packet : out Datagram;
      Status : out Send_Status)
   with Pre => State (Item) in
     Client_Initial | Client_Handshake | Server_Initial | Server_Handshake,
     Post => State (Item) = Failed;

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

   --  Return whether a receive stream was completed and released. This lets
   --  protocol layers discard late retransmissions without retaining one
   --  tombstone for every stream in the connection lifetime.
   --  @param Item Connection to inspect
   --  @param ID Stream identifier
   --  @return True when the stream was previously released
   function Is_Stream_Retired
     (Item : Connection; ID : Stream_ID) return Boolean;

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

   --  Return completed receive reassembly storage to the concurrent-stream
   --  pool. Callers must retain protocol-level completion tombstones so late
   --  retransmissions cannot be delivered twice.
   --  @param Item Connection to update
   --  @param ID Completed or reset stream identifier
   procedure Release_Stream
     (Item : in out Connection; ID : Stream_ID)
   with Pre => Has_Stream (Item, ID)
     and then (Is_Complete (Item, ID) or else Was_Reset (Item, ID));

private
   type Connection is new Ada.Finalization.Limited_Controlled with record
      Backend : System.Address := System.Null_Address;
   end record;

   --  @exclude
   overriding procedure Finalize (Item : in out Connection);
end Flyology.QUIC.Connections;
