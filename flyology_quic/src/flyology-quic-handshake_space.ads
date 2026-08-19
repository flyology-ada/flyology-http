with Ada.Streams;
with Flyology.QUIC.Crypto_Flight;
with Flyology.QUIC.Crypto_Reassembly_Policy;
with Flyology.QUIC.Handshake_Connection;
with Flyology.QUIC.Long_Header_Policy;
with Flyology.QUIC.Sent_Packet_Policy;
with Flyology.QUIC.TLS_Key_Schedule;
with Flyology.QUIC.Varint_Policy;

--  Internal composition of protected Handshake packets and their CRYPTO
--  stream. A caller fragments a TLS flight into bounded payloads and may feed
--  received datagrams in any order; only contiguous authenticated bytes are
--  exposed to TLS.
--
--  The space also owns the RFC 9002 sent-packet ledger for the Handshake
--  packet-number space. Sent CRYPTO ranges are retained until a peer ACK or
--  handshake progress retires them, so a probe timeout can retransmit them
--  under a fresh packet number. RTT estimation and probe-timeout backoff are
--  path-wide and remain with the caller.
private package Flyology.QUIC.Handshake_Space is
   use type Ada.Streams.Stream_Element_Offset;

   Max_Datagram_Length : constant := 1_350;
   Max_Crypto_Payload  : constant := 1_100;

   --  Retained outgoing CRYPTO octets. The largest flight is a server's
   --  EncryptedExtensions through Finished, bounded by the TLS session's
   --  18,000-octet authentication limit.
   Max_Retained_Crypto : constant := 18_432;

   subtype Packet_Number is Sent_Packet_Policy.Packet_Number;
   subtype Timestamp is Sent_Packet_Policy.Timestamp;

   type State is limited private;

   function Is_Initialized (Item : State) return Boolean;

   procedure Initialize
     (Item        : in out State;
      Sending     : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Receiving   : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Destination : Long_Header_Policy.Connection_ID;
      Source      : Long_Header_Policy.Connection_ID)
   with
     Pre => not Is_Initialized (Item)
       and then Destination.Length <=
         Long_Header_Policy.V1_Connection_ID_Length'Last
       and then Source.Length <=
         Long_Header_Policy.V1_Connection_ID_Length'Last,
     Post => Is_Initialized (Item);

   type Build_Status is
     (Built,
      Nothing_To_ACK,
      Crypto_Range_Too_Large,
      Crypto_Retention_Exceeded,
      Recovery_Capacity_Exceeded,
      Packet_Number_Exhausted,
      Packet_Number_Unrepresentable,
      Packet_Too_Large,
      Output_Too_Small);

   type Build_Result is record
      Status        : Build_Status := Output_Too_Small;
      Number        : Packet_Number := 0;
      Packet_Length : Natural range 0 .. Max_Datagram_Length := 0;
   end record;

   --  Build a protected Handshake packet carrying one CRYPTO range, preceded
   --  by an ACK for anything this space still owes the peer.
   --  @param Now Monotonic microsecond timestamp for recovery accounting
   procedure Build_Crypto_Packet
     (Item   : in out State;
      Offset : Varint_Policy.Value_Type;
      Data   : Ada.Streams.Stream_Element_Array;
      Now    : Timestamp;
      Packet : out Ada.Streams.Stream_Element_Array;
      Result : out Build_Result)
   with
     Pre => Is_Initialized (Item)
       and then Data'Length <= Max_Crypto_Payload
       and then Packet'Length >= Max_Datagram_Length;

   --  Build an ACK-only Handshake packet. The packet is not ack-eliciting and
   --  does not arm the probe timer.
   procedure Build_ACK_Packet
     (Item   : in out State;
      Now    : Timestamp;
      Packet : out Ada.Streams.Stream_Element_Array;
      Result : out Build_Result)
   with
     Pre => Is_Initialized (Item)
       and then Packet'Length >= Max_Datagram_Length;

   --  Retransmit one retained CRYPTO range under a fresh packet number. Index
   --  selects among the ranges still awaiting acknowledgment, in offset order,
   --  and Nothing_To_ACK reports that no such range exists.
   procedure Build_Probe_Packet
     (Item   : in out State;
      Index  : Positive;
      Now    : Timestamp;
      Packet : out Ada.Streams.Stream_Element_Array;
      Result : out Build_Result)
   with
     Pre => Is_Initialized (Item)
       and then Packet'Length >= Max_Datagram_Length;

   --  Build an ack-eliciting PING. RFC 9002 section 6.2.2.1 requires this
   --  anti-deadlock probe when a probe timeout expires with no unacknowledged
   --  CRYPTO data left to retransmit.
   procedure Build_Ping_Packet
     (Item   : in out State;
      Now    : Timestamp;
      Packet : out Ada.Streams.Stream_Element_Array;
      Result : out Build_Result)
   with
     Pre => Is_Initialized (Item)
       and then Packet'Length >= Max_Datagram_Length;

   type Process_Status is
     (Processed,
      Duplicate_Packet,
      Packet_Too_Old,
      Envelope_Rejected,
      Authentication_Failed,
      Invalid_Reserved_Bits,
      Frame_Truncated,
      Frame_Not_Allowed,
      Frame_Value_Too_Large,
      Invalid_ACK_Range,
      ACK_Range_Capacity_Exceeded,
      Acknowledges_Unsent_Packet,
      Conflicting_Crypto_Data,
      Crypto_Data_Too_Large);

   type Process_Result is record
      Status        : Process_Status := Envelope_Rejected;
      Frame_Count   : Natural := 0;
      Peer_Closed   : Boolean := False;
      Close_Error   : Varint_Policy.Value_Type := 0;
      --  The packet must be acknowledged.
      ACK_Eliciting : Boolean := False;
      --  Packets this space resolved from the peer's ACK frames.
      Resolved      : Sent_Packet_Policy.Apply_Result;
      --  An ACK-eliciting packet of ours was newly acknowledged.
      ACKed_Eliciting : Boolean := False;
      --  A usable RTT sample was produced by the newest acknowledgment.
      Has_Sample    : Boolean := False;
      Sample        : Timestamp := 0;
   end record;

   --  Process one protected Handshake packet.
   --  @param Now Monotonic microsecond timestamp for recovery accounting
   --  @param Loss_Delay Path loss-detection delay from RTT estimation
   procedure Process_Packet
     (Item       : in out State;
      Packet     : Ada.Streams.Stream_Element_Array;
      Now        : Timestamp;
      Loss_Delay : Timestamp;
      Result     : out Process_Result)
   with
     Pre => Is_Initialized (Item)
       and then Packet'Length <= Max_Datagram_Length;

   --  Report whether an ACK-eliciting packet of ours is still unacknowledged.
   function Has_Unacknowledged (Item : State) return Boolean;

   --  Report whether this space owes the peer an acknowledgment.
   function Needs_ACK (Item : State) return Boolean;

   --  Retire every retained CRYPTO range after progress that could only
   --  follow its delivery.
   procedure Acknowledge_Flight (Item : in out State);

   procedure Build_Transport_Close_Packet
     (Item       : in out State;
      Error_Code : Varint_Policy.Value_Type;
      Frame_Type : Varint_Policy.Value_Type;
      Packet     : out Ada.Streams.Stream_Element_Array;
      Result     : out Build_Result)
   with
     Pre => Is_Initialized (Item)
       and then Packet'Length >= Max_Datagram_Length;

   function Contiguous_Length
     (Item : State) return Crypto_Reassembly_Policy.Stream_Offset;

   function Crypto_Element
     (Item  : State;
      Index : Crypto_Reassembly_Policy.Stream_Index)
      return Ada.Streams.Stream_Element
   with Pre => Index < Contiguous_Length (Item);

private
   type State is limited record
      Packets     : Handshake_Connection.Connection;
      Crypto      : Crypto_Reassembly_Policy.Reassembly_State;
      Sent        : Sent_Packet_Policy.Ledger;
      Outgoing    : Crypto_Flight.Flight (Max_Retained_Crypto);
      ACK_Owed    : Boolean := False;
      Ping_Sent   : Boolean := False;
      Initialized : Boolean := False;
   end record;
end Flyology.QUIC.Handshake_Space;
