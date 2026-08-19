with Ada.Streams;
with Flyology.QUIC.Crypto_Reassembly_Policy;
with Flyology.QUIC.Handshake_Connection;
with Flyology.QUIC.Long_Header_Policy;
with Flyology.QUIC.TLS_Key_Schedule;
with Flyology.QUIC.Varint_Policy;

--  Internal composition of protected Handshake packets and their CRYPTO
--  stream. A caller fragments a TLS flight into bounded payloads and may feed
--  received datagrams in any order; only contiguous authenticated bytes are
--  exposed to TLS.
private package Flyology.QUIC.Handshake_Space is
   use type Ada.Streams.Stream_Element_Offset;

   Max_Datagram_Length : constant := 1_350;
   Max_Crypto_Payload  : constant := 1_100;

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
      Crypto_Range_Too_Large,
      Packet_Number_Exhausted,
      Packet_Number_Unrepresentable,
      Packet_Too_Large,
      Output_Too_Small);

   type Build_Result is record
      Status        : Build_Status := Output_Too_Small;
      Packet_Length : Natural range 0 .. Max_Datagram_Length := 0;
   end record;

   procedure Build_Crypto_Packet
     (Item   : in out State;
      Offset : Varint_Policy.Value_Type;
      Data   : Ada.Streams.Stream_Element_Array;
      Packet : out Ada.Streams.Stream_Element_Array;
      Result : out Build_Result)
   with
     Pre => Is_Initialized (Item)
       and then Data'Length <= Max_Crypto_Payload
       and then Packet'Length >= Max_Datagram_Length;

   procedure Build_Transport_Close_Packet
     (Item       : in out State;
      Error_Code : Varint_Policy.Value_Type;
      Frame_Type : Varint_Policy.Value_Type;
      Packet     : out Ada.Streams.Stream_Element_Array;
      Result     : out Build_Result)
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
      Conflicting_Crypto_Data,
      Crypto_Data_Too_Large);

   type Process_Result is record
      Status      : Process_Status := Envelope_Rejected;
      Frame_Count : Natural := 0;
      Peer_Closed : Boolean := False;
      Close_Error : Varint_Policy.Value_Type := 0;
   end record;

   procedure Process_Packet
     (Item   : in out State;
      Packet : Ada.Streams.Stream_Element_Array;
      Result : out Process_Result)
   with
     Pre => Is_Initialized (Item)
       and then Packet'Length <= Max_Datagram_Length;

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
      Initialized : Boolean := False;
   end record;
end Flyology.QUIC.Handshake_Space;
