with Ada.Streams;
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

   Max_Streams : constant := 8;
   Max_Event_Data : constant := 65_535;

   type Endpoint_Role is (Client, Server);

   type Connection is limited private;

   procedure Initialize
     (Item     : in out Connection;
      Role     : Endpoint_Role;
      Settings : HTTP_3_Settings_Policy.Settings);

   type Operation_Status is
     (Succeeded,
      No_Event,
      Not_Connected,
      Already_Started,
      Stream_Limit_Reached,
      Transport_Blocked,
      Transport_Error,
      Stream_Capacity_Exceeded,
      Stream_Creation_Error,
      Closed_Critical_Stream,
      Missing_Settings,
      Frame_Unexpected,
      Settings_Error,
      Frame_Error,
      QPACK_Decompression_Failed,
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
      Headers_Received,
      Data_Received,
      Push_Promise_Received,
      QPACK_Data_Received);

   subtype Event_Data_Length is Natural range 0 .. Max_Event_Data;

   type Event is record
      Kind        : Event_Kind := No_Event;
      Stream      : QUIC.Stream_ID := 0;
      Headers     : QPACK_Field_Section_Policy.Header_Block;
      Data        : Ada.Streams.Stream_Element_Array (1 .. Max_Event_Data) :=
        (others => 0);
      Data_Length : Event_Data_Length := 0;
   end record;

   procedure Poll
     (Item      : in out Connection;
      Transport : in out QUIC.Connection;
      Output    : out Event;
      Status    : out Operation_Status);

   function Has_Peer_Settings (Item : Connection) return Boolean;

private
   subtype Slot_Index is Positive range 1 .. Max_Streams;

   type Stream_Slot is record
      Occupied : Boolean := False;
      ID       : QUIC.Stream_ID := 0;
      State    : HTTP_3_Stream_Receive_Policy.Stream_State;
      Finished : Boolean := False;
   end record;

   type Stream_Array is array (Slot_Index) of Stream_Slot;

   type Connection is limited record
      Local_Role       : Endpoint_Role := Client;
      Local_Settings   : HTTP_3_Settings_Policy.Settings;
      Receive          : HTTP_3_Stream_Receive_Policy.Connection_State;
      Streams          : Stream_Array;
      Count            : Natural range 0 .. Max_Streams := 0;
      Started          : Boolean := False;
      Local_Control_ID : QUIC.Stream_ID := 0;
      Local_Control_Offset : QUIC.Stream_Offset := 0;
   end record;
end Flyology.HTTP.HTTP_3_Connection;
