with Ada.Streams;
with Flyology.QUIC.ACK_Frame_Policy;
with Flyology.QUIC.Connection_State_Policy;
with Flyology.QUIC.Crypto_OpenSSL;
with Flyology.QUIC.Handshake_Receiver;
with Flyology.QUIC.Handshake_Sender;
with Flyology.QUIC.Long_Header_Policy;
with Flyology.QUIC.Varint_Policy;
with Flyology.QUIC.TLS_Key_Schedule;

--  Internal connection state for the QUIC Handshake encryption level.
--
--  The caller supplies role-oriented directional keys from TLS. Packet-number
--  allocation and authenticated replay admission are independent of Initial
--  and application packet-number spaces.
private package Flyology.QUIC.Handshake_Connection is
   use type Ada.Streams.Stream_Element_Array;

   type Build_Status is
     (Built,
      Packet_Number_Exhausted,
      Packet_Number_Unrepresentable,
      Insufficient_Protected_Payload,
      Packet_Too_Large,
      Output_Too_Small);

   type Build_Result is record
      Status        : Build_Status := Output_Too_Small;
      Number        : Connection_State_Policy.Packet_Number := 0;
      Packet_Length : Natural range 0 .. Handshake_Sender.Max_Packet_Length :=
        0;
      Header_Length : Natural range 0 .. Handshake_Sender.Max_Packet_Length :=
        0;
      Number_Length : Long_Header_Policy.Packet_Number_Length := 1;
   end record;

   type Process_Status is
     (Processed,
      Duplicate,
      Too_Old,
      Envelope_Rejected,
      Authentication_Failed,
      Invalid_Reserved_Bits);

   type Process_Result is record
      Status : Process_Status := Envelope_Rejected;
      Packet : Handshake_Receiver.Receive_Result;
   end record;

   type Connection is limited private;

   function Is_Initialized (Item : Connection) return Boolean;

   procedure Initialize
     (Item        : in out Connection;
      Sending     : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Receiving   : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Destination : Long_Header_Policy.Connection_ID;
      Source      : Long_Header_Policy.Connection_ID)
   with
     Pre =>
       not Is_Initialized (Item)
       and then Destination.Length <=
         Long_Header_Policy.V1_Connection_ID_Length'Last
       and then Source.Length <=
         Long_Header_Policy.V1_Connection_ID_Length'Last,
     Post => Is_Initialized (Item);

   procedure Build_Handshake
     (Item      : in out Connection;
      Plaintext : Ada.Streams.Stream_Element_Array;
      Packet    : out Ada.Streams.Stream_Element_Array;
      Result    : out Build_Result)
   with
     Pre =>
       Is_Initialized (Item)
       and then Plaintext'Length <= Handshake_Sender.Max_Packet_Length,
     Post =>
       (if Result.Status /= Built then Packet = (Packet'Range => 0)
        else Result.Packet_Length <= Packet'Length);

   procedure Process_Handshake
     (Item      : in out Connection;
      Packet    : Ada.Streams.Stream_Element_Array;
      Plaintext : out Ada.Streams.Stream_Element_Array;
      Result    : out Process_Result)
   with
     Pre =>
       Is_Initialized (Item)
       and then Packet'Length <= Handshake_Sender.Max_Packet_Length
       and then Plaintext'Length >= Packet'Length,
     Post =>
       (if Result.Status /= Processed then
           Plaintext = (Plaintext'Range => 0));

   function Encode_ACK
     (Item      : Connection;
      ACK_Delay : Varint_Policy.Value_Type)
      return ACK_Frame_Policy.Encode_Result
   with Pre => Is_Initialized (Item);
private
   type Connection is limited record
      Backend     : Crypto_OpenSSL.Provider;
      Sending     : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Receiving   : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Destination : Long_Header_Policy.Connection_ID;
      Source      : Long_Header_Policy.Connection_ID;
      Send_State    : Connection_State_Policy.Connection_State;
      Receive_State : Connection_State_Policy.Connection_State;
      Initialized   : Boolean := False;
   end record;
end Flyology.QUIC.Handshake_Connection;
