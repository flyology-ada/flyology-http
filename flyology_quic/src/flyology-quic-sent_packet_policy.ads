with Interfaces;
with Flyology.QUIC.ACK_Range_Policy;
with Flyology.QUIC.Packet_Number_Policy;

--  Internal, proved bounded sent-packet ledger for one packet-number space.
--
--  Every transmitted packet is retained until it is acknowledged, declared
--  lost, or the caller discards the packet-number space. Applying an ACK
--  emits bounded delivery and loss events for retransmission and congestion
--  accounting without retaining protocol-frame policy here.
private package Flyology.QUIC.Sent_Packet_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Interfaces.Unsigned_64;
   use type ACK_Range_Policy.Decode_Status;

   subtype Packet_Number is Packet_Number_Policy.Packet_Number;
   subtype Timestamp is Interfaces.Unsigned_64 range 0 .. 2**63 - 1;
   subtype Packet_Byte_Count is Natural range 1 .. 65_535;

   Max_Sent_Packets : constant := 64;
   subtype Sent_Count is Natural range 0 .. Max_Sent_Packets;
   subtype Sent_Index is Positive range 1 .. Max_Sent_Packets;

   type Sent_Packet is record
      Number        : Packet_Number := 0;
      Sent_At       : Timestamp := 0;
      Bytes         : Packet_Byte_Count := 1;
      ACK_Eliciting : Boolean := False;
      In_Flight     : Boolean := False;
   end record;

   type Event_Kind is (Acknowledged, Lost);

   type Packet_Event is record
      Kind   : Event_Kind := Acknowledged;
      Packet : Sent_Packet;
   end record;

   type Packet_Event_Array is array (Sent_Index) of Packet_Event;

   type Apply_Status is (Applied, Acknowledges_Unsent_Packet);

   type Apply_Result is record
      Status : Apply_Status := Applied;
      Count  : Sent_Count := 0;
      Events : Packet_Event_Array;
   end record;

   type Record_Status is
     (Recorded,
      Not_Tracked,
      Packet_Number_Not_Next,
      Table_Full);

   type Ledger is private;

   procedure Reset (Item : out Ledger)
   with
     Global => null,
     Post => Retained (Item) = 0 and then not Has_Sent (Item);

   function Retained (Item : Ledger) return Sent_Count
   with Global => null;

   function Has_Sent (Item : Ledger) return Boolean
   with Global => null;

   function Largest_Sent (Item : Ledger) return Packet_Number
   with
     Global => null,
     Pre => Has_Sent (Item);

   procedure Record_Sent
     (Item   : in out Ledger;
      Packet : Sent_Packet;
      Status : out Record_Status)
   with
     Global => null,
     Post =>
       (if Status = Recorded then
           Retained (Item) = Retained (Item'Old) + 1
           and then Has_Sent (Item)
           and then Largest_Sent (Item) = Packet.Number
        elsif Status = Not_Tracked then
           Retained (Item) = Retained (Item'Old)
           and then Has_Sent (Item)
           and then Largest_Sent (Item) = Packet.Number
        else Item = Item'Old);

   function Contains
     (Item   : Ledger;
      Number : Packet_Number) return Boolean
   with Global => null;

   procedure Apply_ACK
     (Item       : in out Ledger;
      Ranges     : ACK_Range_Policy.Decode_Result;
      Now        : Timestamp;
      Loss_Delay : Timestamp;
      Result     : out Apply_Result)
   with
     Global => null,
     Pre => Ranges.Status = ACK_Range_Policy.Decoded;

private
   type Ledger_Entry is record
      Valid  : Boolean := False;
      Packet : Sent_Packet;
   end record;

   type Ledger_Table is array (Sent_Index) of Ledger_Entry;

   type Ledger is record
      Entries           : Ledger_Table := (others => (others => <>));
      Count             : Sent_Count := 0;
      Has_Largest_Sent  : Boolean := False;
      Largest_Sent_PN   : Packet_Number := 0;
      Has_Largest_ACKed : Boolean := False;
      Largest_ACKed_PN  : Packet_Number := 0;
   end record;
end Flyology.QUIC.Sent_Packet_Policy;
