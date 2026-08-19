with Ada.Streams;
with Flyology.QUIC.Sent_Packet_Policy;
with Flyology.QUIC.Varint_Policy;

--  Internal retention of the CRYPTO stream one endpoint has sent in a single
--  packet-number space.
--
--  RFC 9002 section 6.2 requires an endpoint to retransmit unacknowledged
--  Initial and Handshake CRYPTO data when a probe timeout expires. QUIC never
--  retransmits a packet verbatim, so a space retains the CRYPTO ranges it
--  built and rebinds a range to a fresh packet number every time it is sent
--  again. A range stops being pending once the packet carrying it is
--  acknowledged, either by an ACK frame or by handshake progress that can only
--  follow its delivery.
private package Flyology.QUIC.Crypto_Flight is
   use type Ada.Streams.Stream_Element_Offset;

   subtype Packet_Number is Sent_Packet_Policy.Packet_Number;

   --  Retained CRYPTO octets a space may hold. Both handshake spaces send a
   --  contiguous stream from offset zero, so one buffer of this size bounds
   --  the whole outgoing flight.
   subtype Capacity_Range is
     Ada.Streams.Stream_Element_Offset range 1 .. 32_768;

   --  Independently acknowledgeable CRYPTO ranges retained by one space.
   Max_Chunks : constant := 32;
   subtype Chunk_Count is Natural range 0 .. Max_Chunks;
   subtype Chunk_Index is Positive range 1 .. Max_Chunks;

   type Flight (Capacity : Capacity_Range) is limited private;

   --  Discard every retained range.
   procedure Reset (Item : in out Flight);

   type Retain_Status is (Retained, Capacity_Exceeded, Chunk_Table_Full);

   --  Report whether a range would fit, so a caller can refuse before it
   --  puts a packet on the wire it could not retransmit.
   function Can_Retain
     (Item   : Flight;
      Offset : Varint_Policy.Value_Type;
      Length : Ada.Streams.Stream_Element_Offset) return Boolean;

   --  Retain the CRYPTO range a freshly built packet carries.
   procedure Retain
     (Item   : in out Flight;
      Number : Packet_Number;
      Offset : Varint_Policy.Value_Type;
      Data   : Ada.Streams.Stream_Element_Array;
      Status : out Retain_Status);

   --  Stop retransmitting the range carried by an acknowledged packet.
   procedure Acknowledge (Item : in out Flight; Number : Packet_Number);

   --  Stop retransmitting every range, for progress that implies delivery of
   --  the whole flight.
   procedure Acknowledge_All (Item : in out Flight);

   --  Report whether any retained range still awaits acknowledgment.
   function Has_Pending (Item : Flight) return Boolean;

   --  Return the lowest-offset pending range, or zero when none remains.
   function First_Pending (Item : Flight) return Chunk_Count;

   --  Return the pending range after Index, or zero when none remains.
   function Next_Pending (Item : Flight; Index : Chunk_Index)
      return Chunk_Count;

   function Offset
     (Item : Flight; Index : Chunk_Index) return Varint_Policy.Value_Type;

   function Length
     (Item : Flight; Index : Chunk_Index)
      return Ada.Streams.Stream_Element_Offset;

   --  Copy one retained range into caller storage.
   procedure Copy
     (Item  : Flight;
      Index : Chunk_Index;
      Data  : out Ada.Streams.Stream_Element_Array)
   with Pre => Data'Length >= Length (Item, Index);

   --  Bind a retained range to the packet number that now carries it.
   procedure Rebind
     (Item : in out Flight; Index : Chunk_Index; Number : Packet_Number);

private
   type Chunk is record
      Occupied : Boolean := False;
      Pending  : Boolean := False;
      Number   : Packet_Number := 0;
      Offset   : Varint_Policy.Value_Type := 0;
      Length   : Ada.Streams.Stream_Element_Offset := 0;
   end record;

   type Chunk_Table is array (Chunk_Index) of Chunk;

   type Flight (Capacity : Capacity_Range) is limited record
      Data   : Ada.Streams.Stream_Element_Array (1 .. Capacity) :=
        (others => 0);
      Chunks : Chunk_Table;
      Count  : Chunk_Count := 0;
   end record;
end Flyology.QUIC.Crypto_Flight;
