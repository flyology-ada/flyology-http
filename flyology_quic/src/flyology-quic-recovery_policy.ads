with Interfaces;
with Flyology.QUIC.Sent_Packet_Policy;

--  Internal, proved RFC 9002 RTT and NewReno path policy.
--
--  Loss detection remains per packet-number space in Sent_Packet_Policy.
--  RTT estimation and congestion accounting are path-wide and consume the
--  bounded packet events emitted by those spaces.
private package Flyology.QUIC.Recovery_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   use type Interfaces.Unsigned_64;

   subtype Duration is Sent_Packet_Policy.Timestamp;
   subtype Byte_Count is Interfaces.Unsigned_64 range 0 .. 2**63 - 1;

   Timer_Granularity          : constant Duration := 1_000;
   Initial_RTT                : constant Duration := 333_000;
   Maximum_Datagram_Size      : constant Byte_Count := 1_200;
   Initial_Congestion_Window  : constant Byte_Count := 12_000;
   Minimum_Congestion_Window  : constant Byte_Count := 2_400;

   type Send_Status is (Accounted, Congestion_Blocked);
   type State is private;

   procedure Reset (Item : out State)
   with
     Global => null,
     Post =>
       Bytes_In_Flight (Item) = 0
       and then Congestion_Window (Item) = Initial_Congestion_Window
       and then not Has_RTT_Sample (Item);

   function Bytes_In_Flight (Item : State) return Byte_Count
   with Global => null;

   function Congestion_Window (Item : State) return Byte_Count
   with Global => null;

   function Has_RTT_Sample (Item : State) return Boolean
   with Global => null;

   function Latest_RTT (Item : State) return Duration
   with Global => null;

   function Minimum_RTT (Item : State) return Duration
   with
     Global => null,
     Pre => Has_RTT_Sample (Item);

   function Smoothed_RTT (Item : State) return Duration
   with Global => null;

   function RTT_Variance (Item : State) return Duration
   with Global => null;

   function Loss_Delay (Item : State) return Duration
   with
     Global => null,
     Post => Loss_Delay'Result >= Timer_Granularity;

   function Can_Send
     (Item  : State;
      Bytes : Sent_Packet_Policy.Packet_Byte_Count) return Boolean
   with Global => null;

   procedure On_Packet_Sent
     (Item         : in out State;
      Packet       : Sent_Packet_Policy.Sent_Packet;
      Permit_Probe : Boolean;
      Status       : out Send_Status)
   with
     Global => null,
     Post =>
       (if Status = Congestion_Blocked then Item = Item'Old
        elsif not Packet.In_Flight then Item = Item'Old
        else Bytes_In_Flight (Item) >= Bytes_In_Flight (Item'Old));

   procedure Update_RTT
     (Item                : in out State;
      Sample              : Duration;
      ACK_Delay           : Duration;
      Maximum_ACK_Delay   : Duration;
      Handshake_Confirmed : Boolean)
   with
     Global => null,
     Post =>
       Has_RTT_Sample (Item)
       and then Latest_RTT (Item) = Sample
       and then Minimum_RTT (Item) <= Sample;

   procedure On_Packets_Resolved
     (Item                : in out State;
      Events              : Sent_Packet_Policy.Packet_Event_Array;
      Count               : Sent_Packet_Policy.Sent_Count;
      Now                 : Sent_Packet_Policy.Timestamp;
      Application_Limited : Boolean)
   with Global => null;

private
   type State is record
      Has_Sample       : Boolean := False;
      Latest           : Duration := 0;
      Minimum          : Duration := 0;
      Smoothed         : Duration := Initial_RTT;
      Variance         : Duration := Initial_RTT / 2;
      Flight           : Byte_Count := 0;
      Window           : Byte_Count := Initial_Congestion_Window;
      Slow_Start_Limit : Byte_Count := Byte_Count'Last;
      Has_Recovery     : Boolean := False;
      Recovery_Start   : Sent_Packet_Policy.Timestamp := 0;
   end record;
end Flyology.QUIC.Recovery_Policy;
