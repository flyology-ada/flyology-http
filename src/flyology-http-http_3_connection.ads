with Ada.Streams;
with Flyology.HTTP.HTTP_3_Message_Policy;
with Flyology.HTTP.HTTP_3_Settings_Policy;
with Flyology.HTTP.HTTP_3_Stream_Receive_Policy;
with Flyology.HTTP.QPACK_Field_Section_Policy;
with Flyology.QUIC.Connections;

--  Internal HTTP/3 session composition over public QUIC streams.
--
--  The transport owns encryption, packet recovery, flow control, and stream
--  bytes. This package owns HTTP/3 stream roles, SETTINGS, message sequencing,
--  and QPACK events.
private package Flyology.HTTP.HTTP_3_Connection is
   package QUIC renames Flyology.QUIC.Connections;

   Max_Streams : constant := 32;
   Max_Event_Data : constant := 65_535;
   Max_Message_Tombstones : constant := 1_024;

   type Endpoint_Role is (Client, Server);

   type Connection is limited private;

   procedure Initialize
     (Item     : in out Connection;
      Role     : Endpoint_Role;
      Settings : HTTP_3_Settings_Policy.Settings);

   function Is_Released_Message
     (Item      : Connection;
      Transport : QUIC.Connection;
      ID        : QUIC.Stream_ID) return Boolean;

   type Operation_Status is
     (Succeeded,
      No_Event,
      Not_Connected,
      Not_Started,
      Already_Started,
      Connection_Draining,
      Wrong_Role,
      Stream_Limit_Reached,
      Transport_Blocked,
      Transport_Error,
      Frame_Too_Large,
      Stream_Capacity_Exceeded,
      Stream_Creation_Error,
      Closed_Critical_Stream,
      Missing_Settings,
      Frame_Unexpected,
      Settings_Error,
      Frame_Error,
      ID_Error,
      QPACK_Decompression_Failed,
      QPACK_Encoder_Stream_Error,
      QPACK_Decoder_Stream_Error,
      Peer_Field_Section_Too_Large,
      Message_Error,
      Header_Error);

   procedure Start
     (Item      : in out Connection;
      Transport : in out QUIC.Connection;
      Now       : QUIC.Timestamp;
      Packet    : out QUIC.Datagram;
      Status    : out Operation_Status);

   type Event_Kind is
     (No_Event,
      Settings_Received,
      Goaway_Received,
      Headers_Received,
      Data_Received,
      Stream_Reset,
      Stream_Ended);

   subtype Event_Data_Length is Natural range 0 .. Max_Event_Data;

   type Event is record
      Kind        : Event_Kind := No_Event;
      Stream      : QUIC.Stream_ID := 0;
      Identifier  : QUIC.Stream_Offset := 0;
      Headers     : QPACK_Field_Section_Policy.Header_Block;
      Data        : Ada.Streams.Stream_Element_Array (1 .. Max_Event_Data) :=
        (others => 0);
      Data_Length : Event_Data_Length := 0;
      Application_Error : QUIC.Stream_Offset := 0;
   end record;

   procedure Poll
     (Item      : in out Connection;
      Transport : in out QUIC.Connection;
      Output    : out Event;
      Status    : out Operation_Status);

   --  Retire a server-side request after its synchronous response has been
   --  fully constructed. Client response streams retire automatically when
   --  Poll reports Stream_Ended.
   procedure Release_Request
     (Item      : in out Connection;
      Transport : in out QUIC.Connection;
      Stream    : QUIC.Stream_ID;
      Status    : out Operation_Status);

   procedure Open_Request
     (Item      : in out Connection;
      Transport : in out QUIC.Connection;
      Stream    : out QUIC.Stream_ID;
      Status    : out Operation_Status);

   procedure Build_Request_Cancellation
     (Item              : in out Connection;
      Transport         : in out QUIC.Connection;
      Stream            : QUIC.Stream_ID;
      Application_Error : QUIC.Stream_Offset;
      Now               : QUIC.Timestamp;
      Packet            : out QUIC.Datagram;
      Status            : out Operation_Status);

   procedure Build_Goaway
     (Item       : in out Connection;
      Transport  : in out QUIC.Connection;
      Identifier : QUIC.Stream_Offset;
      Now        : QUIC.Timestamp;
      Packet     : out QUIC.Datagram;
      Status     : out Operation_Status);

   procedure Build_Headers
     (Item      : in out Connection;
      Transport : in out QUIC.Connection;
      Stream    : QUIC.Stream_ID;
      Headers   : QPACK_Field_Section_Policy.Header_Block;
      Fin       : Boolean;
      Now       : QUIC.Timestamp;
      Packet    : out QUIC.Datagram;
      Status    : out Operation_Status);

   procedure Build_Response
     (Item      : in out Connection;
      Transport : in out QUIC.Connection;
      Stream    : QUIC.Stream_ID;
      Headers   : QPACK_Field_Section_Policy.Header_Block;
      Data      : Ada.Streams.Stream_Element_Array;
      Now       : QUIC.Timestamp;
      Packet    : out QUIC.Datagram;
      Status    : out Operation_Status;
      ACK_Included : out Boolean);

   procedure Build_Data
     (Item      : in out Connection;
      Transport : in out QUIC.Connection;
      Stream    : QUIC.Stream_ID;
      Data      : Ada.Streams.Stream_Element_Array;
      Fin       : Boolean;
      Now       : QUIC.Timestamp;
      Packet    : out QUIC.Datagram;
      Status    : out Operation_Status);

   function Has_Peer_Settings (Item : Connection) return Boolean;

   function Peer_Settings
     (Item : Connection) return HTTP_3_Settings_Policy.Settings
   with Pre => Has_Peer_Settings (Item);

   function Has_Peer_Goaway (Item : Connection) return Boolean;

   function Peer_Goaway_ID
     (Item : Connection) return QUIC.Stream_Offset
   with Pre => Has_Peer_Goaway (Item);

private
   subtype Message_Ordinal is Natural range 0 .. Max_Message_Tombstones - 1;
   type Message_Tombstone_Table is array (Message_Ordinal) of Boolean;

   subtype Slot_Index is Positive range 1 .. Max_Streams;

   type Stream_Slot is record
      Occupied : Boolean := False;
      ID       : QUIC.Stream_ID := 0;
      State    : HTTP_3_Stream_Receive_Policy.Stream_State;
      Finished : Boolean := False;
   end record;

   type Stream_Array is array (Slot_Index) of Stream_Slot;

   type Send_Stream_Kind is (Request_Message, Response_Message);

   type Send_Stream_Slot is record
      Occupied : Boolean := False;
      ID       : QUIC.Stream_ID := 0;
      Offset   : QUIC.Stream_Offset := 0;
      Kind     : Send_Stream_Kind := Request_Message;
      Request  : HTTP_3_Message_Policy.Request_State;
      Response : HTTP_3_Message_Policy.Response_State;
      Finished : Boolean := False;
      Cancelled : Boolean := False;
   end record;

   type Send_Stream_Array is array (Slot_Index) of Send_Stream_Slot;

   type Connection is limited record
      Local_Role       : Endpoint_Role := Client;
      Local_Settings   : HTTP_3_Settings_Policy.Settings;
      Receive          : HTTP_3_Stream_Receive_Policy.Connection_State;
      Streams          : Stream_Array;
      Count            : Natural range 0 .. Max_Streams := 0;
      Sending          : Send_Stream_Array;
      Send_Count       : Natural range 0 .. Max_Streams := 0;
      Started          : Boolean := False;
      Local_Control_ID : QUIC.Stream_ID := 0;
      Local_Control_Offset : QUIC.Stream_Offset := 0;
      Local_Goaway_Seen : Boolean := False;
      Local_Goaway      : QUIC.Stream_Offset := 0;
      Released_Messages : Message_Tombstone_Table := (others => False);
   end record;
end Flyology.HTTP.HTTP_3_Connection;
