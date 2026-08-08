with Ada.Streams;
with Flyology.QUIC.Application_Connection;
with Flyology.QUIC.Flow_Control_Policy;
with Flyology.QUIC.Long_Header_Policy;
with Flyology.QUIC.Recovery_Policy;
with Flyology.QUIC.Sent_Packet_Policy;
with Flyology.QUIC.Stream_ID_Policy;
with Flyology.QUIC.Stream_Table_Policy;
with Flyology.QUIC.TLS_Key_Schedule;
with Flyology.QUIC.Transport_Parameter_Policy;
with Flyology.QUIC.Varint_Policy;

--  Internal composition of the QUIC application packet-number space.
--
--  This layer binds protected 1-RTT packets to stream reassembly, ACK
--  processing, RTT estimation, loss detection, and congestion accounting.
--  Socket waits remain outside so the same state machine can be driven by
--  native and lightweight Flyology tasks.
private package Flyology.QUIC.Application_Space is
   use type Ada.Streams.Stream_Element_Offset;

   Max_Datagram_Length : constant := 1_200;
   Max_Stream_Payload  : constant := 1_100;

   subtype Packet_Number is Sent_Packet_Policy.Packet_Number;
   subtype Timestamp is Sent_Packet_Policy.Timestamp;
   subtype Stream_Offset is Stream_Table_Policy.Stream_Offset;
   subtype Stream_Index is Stream_Table_Policy.Stream_Index;

   type State is limited private;

   function Is_Initialized (Item : State) return Boolean;

   procedure Initialize
     (Item        : in out State;
      Sending     : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Receiving   : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Destination : Long_Header_Policy.Connection_ID;
      Local_ID    : Long_Header_Policy.Connection_ID;
      Role        : Stream_ID_Policy.Endpoint_Role;
      Peer        : Transport_Parameter_Policy.Transport_Parameters)
   with
     Pre => not Is_Initialized (Item)
       and then Destination.Length <=
         Long_Header_Policy.V1_Connection_ID_Length'Last
       and then Local_ID.Length <=
         Long_Header_Policy.V1_Connection_ID_Length'Last,
     Post => Is_Initialized (Item);

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

   subtype Open_Status is Stream_ID_Policy.Open_Status;

   procedure Open_Stream
     (Item      : in out State;
      Direction : Stream_ID_Policy.Stream_Direction;
      ID        : out Varint_Policy.Value_Type;
      Status    : out Open_Status)
   with Pre => Is_Initialized (Item);

   type Send_Result is record
      Status        : Send_Status := Output_Too_Small;
      Number        : Packet_Number := 0;
      Packet_Length : Natural range 0 .. Max_Datagram_Length := 0;
   end record;

   procedure Build_Stream_Packet
     (Item      : in out State;
      Stream_ID : Varint_Policy.Value_Type;
      Offset    : Varint_Policy.Value_Type;
      Fin       : Boolean;
      Data      : Ada.Streams.Stream_Element_Array;
      Now       : Timestamp;
      Packet    : out Ada.Streams.Stream_Element_Array;
      Result    : out Send_Result)
   with
     Pre => Is_Initialized (Item)
       and then Data'Length <= Max_Stream_Payload
       and then Packet'Length >= Max_Datagram_Length;

   procedure Build_ACK_Packet
     (Item      : in out State;
      ACK_Delay : Varint_Policy.Value_Type;
      Now       : Timestamp;
      Packet    : out Ada.Streams.Stream_Element_Array;
      Result    : out Send_Result)
   with
     Pre => Is_Initialized (Item)
       and then Packet'Length >= Max_Datagram_Length;

   subtype ACK_Delay_Exponent is Natural range 0 .. 20;

   type Process_Status is
     (Processed,
      Duplicate,
      Too_Old,
      Envelope_Rejected,
      Authentication_Failed,
      Invalid_Reserved_Bits,
      Unexpected_Destination,
      Unsupported_Key_Phase,
      Frame_Truncated,
      Unknown_Frame_Type,
      Frame_Value_Too_Large,
      Invalid_ACK_Range,
      Invalid_Connection_ID,
      ACK_Range_Capacity_Exceeded,
      Acknowledges_Unsent_Packet,
      Invalid_Stream_Limit,
      Invalid_Stream_State,
      Stream_Capacity_Exceeded,
      Stream_Data_Too_Large,
      Conflicting_Stream_Data,
      Stream_Final_Size_Error,
      Stream_Reset_Conflict);

   type Process_Result is record
      Status          : Process_Status := Envelope_Rejected;
      Number          : Packet_Number := 0;
      Frame_Count     : Natural := 0;
      Resolved_Count  : Natural := 0;
      ACK_Eliciting   : Boolean := False;
   end record;

   procedure Process_Packet
     (Item                : in out State;
      Packet              : Ada.Streams.Stream_Element_Array;
      Now                 : Timestamp;
      ACK_Delay_Exponent  : Application_Space.ACK_Delay_Exponent;
      Maximum_ACK_Delay   : Recovery_Policy.Duration;
      Handshake_Confirmed : Boolean;
      Result              : out Process_Result)
   with
     Pre => Is_Initialized (Item)
       and then Packet'Length <= Max_Datagram_Length;

   function Has_Stream
     (Item      : State;
      Stream_ID : Varint_Policy.Value_Type) return Boolean;

   function Available_Length
     (Item      : State;
      Stream_ID : Varint_Policy.Value_Type) return Stream_Offset
   with Pre => Has_Stream (Item, Stream_ID);

   function Stream_Element
     (Item      : State;
      Stream_ID : Varint_Policy.Value_Type;
      Offset    : Stream_Index) return Ada.Streams.Stream_Element
   with Pre => Has_Stream (Item, Stream_ID)
     and then Offset < Available_Length (Item, Stream_ID);

   procedure Consume
     (Item      : in out State;
      Stream_ID : Varint_Policy.Value_Type;
      Length    : Stream_Offset)
   with Pre => Has_Stream (Item, Stream_ID)
     and then Length <= Available_Length (Item, Stream_ID);

   function Retained_Packets (Item : State) return Sent_Packet_Policy.Sent_Count;
   function Committed_Data (Item : State) return Varint_Policy.Value_Type;
   function Bytes_In_Flight (Item : State) return Recovery_Policy.Byte_Count;
   function Congestion_Window (Item : State) return Recovery_Policy.Byte_Count;
   function Has_RTT_Sample (Item : State) return Boolean;
   function Smoothed_RTT (Item : State) return Recovery_Policy.Duration;
   function PTO_Count (Item : State) return Recovery_Policy.PTO_Count_Type;
   function Probe_Timeout
     (Item              : State;
      Maximum_ACK_Delay : Recovery_Policy.Duration)
      return Recovery_Policy.Duration;
   procedure On_Probe_Timeout (Item : in out State);

private
   type State is limited record
      Packets     : Application_Connection.Connection;
      Streams     : Stream_Table_Policy.Stream_Table;
      Allocator   : Stream_ID_Policy.Allocator;
      Flow        : Flow_Control_Policy.State;
      Peer_Bidi   : Varint_Policy.Value_Type := 0;
      Peer_Uni    : Varint_Policy.Value_Type := 0;
      Sent        : Sent_Packet_Policy.Ledger;
      Recovery    : Recovery_Policy.State;
      Initialized : Boolean := False;
   end record;
end Flyology.QUIC.Application_Space;
