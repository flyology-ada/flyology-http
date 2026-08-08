with Ada.Finalization;
with Ada.Streams;
with System;
with Flyology.QUIC.Connections;

--  HTTP/3 session framing over an Ada-native QUIC connection.
--
--  The caller owns UDP I/O and the QUIC connection. This package owns HTTP/3
--  control streams, SETTINGS, request and response sequencing, and the
--  static-table QPACK profile. Every operation is synchronous and returns
--  packets for the caller to send through Flyology.QUIC.Connections.IO.
package Flyology.HTTP.HTTP_3 is
   package QUIC renames Flyology.QUIC.Connections;

   --  Largest field name retained by the bounded QPACK profile.
   Max_Name_Length : constant := 256;
   --  Largest field value retained by the bounded QPACK profile.
   Max_Value_Length : constant := 4_096;
   --  Largest number of fields retained in one field section.
   Max_Fields : constant := 32;
   --  Largest DATA payload surfaced by one event.
   Max_Event_Data : constant := 65_535;

   --  HTTP/3 endpoint behavior.
   --  @enum Client Opens request streams and receives responses
   --  @enum Server Receives request streams and sends responses
   type Endpoint_Role is (Client, Server);

   --  Local HTTP/3 SETTINGS sent on the mandatory control stream. The current
   --  profile keeps QPACK dynamic-table capacity and blocked streams at zero.
   --  @field Has_Max_Field_Size Whether Max_Field_Size is advertised
   --  @field Max_Field_Size Maximum accepted field-section size
   type Settings is record
      Has_Max_Field_Size : Boolean := False;
      Max_Field_Size     : QUIC.Stream_Offset := 0;
   end record;

   --  One HTTP field with bounded name and value storage.
   type Header_Field is private;

   --  Construct one field while preserving its wire spelling.
   --  @param Name Lowercase field name or a recognized pseudo-field
   --  @param Value Field value
   --  @return Bounded field value
   function Make_Field (Name, Value : String) return Header_Field
   with Pre => Name'Length in 1 .. Max_Name_Length
     and then Value'Length <= Max_Value_Length;

   --  Return a field name.
   --  @param Item Field to inspect
   --  @return Exact field name
   function Field_Name (Item : Header_Field) return String;

   --  Return a field value.
   --  @param Item Field to inspect
   --  @return Exact field value
   function Field_Value (Item : Header_Field) return String;

   --  Bounded ordered HTTP field section.
   type Header_Block is private;

   --  Append one field to a field section.
   --  @param Item Field section to update
   --  @param Value Field appended at the end
   procedure Append (Item : in out Header_Block; Value : Header_Field)
   with Pre => Header_Count (Item) < Max_Fields;

   --  Return the number of fields in a field section.
   --  @param Item Field section to inspect
   --  @return Number of retained fields
   function Header_Count (Item : Header_Block) return Natural;

   --  Return a field by one-based position.
   --  @param Item Field section to inspect
   --  @param Index One-based field position
   --  @return Selected field
   function Field_At
     (Item : Header_Block; Index : Positive) return Header_Field
   with Pre => Index <= Header_Count (Item);

   --  Owning, noncopyable HTTP/3 session state.
   type Session is limited private;

   --  Report whether an endpoint role and local settings were installed.
   --  @param Item Session to inspect
   --  @return True after Initialize succeeds
   function Is_Initialized (Item : Session) return Boolean;

   --  Configure a fresh HTTP/3 session.
   --  @param Item Fresh session
   --  @param Role Client or server behavior
   --  @param Local_Settings SETTINGS sent to the peer
   procedure Initialize
     (Item           : in out Session;
      Role           : Endpoint_Role;
      Local_Settings : Settings := (others => <>))
   with Pre => not Is_Initialized (Item);

   --  Outcome of one HTTP/3 session operation.
   --  @enum Succeeded Operation completed and any packet is ready
   --  @enum No_Event No complete application event is currently buffered
   --  @enum Uninitialized Initialize has not been called
   --  @enum Not_Connected QUIC application keys are not active
   --  @enum Already_Started The local control stream already exists
   --  @enum Wrong_Role The operation is not valid for this endpoint role
   --  @enum Stream_Limit_Reached The peer permits no additional stream
   --  @enum Transport_Blocked QUIC flow or congestion credit is unavailable
   --  @enum Transport_Error QUIC could not encode the requested stream data
   --  @enum Frame_Too_Large The frame exceeds bounded packet storage
   --  @enum Stream_Capacity_Exceeded HTTP/3 stream storage is exhausted
   --  @enum Stream_Creation_Error The stream role or identifier is invalid
   --  @enum Closed_Critical_Stream A mandatory peer stream ended
   --  @enum Missing_Settings Peer control stream did not begin with SETTINGS
   --  @enum Frame_Unexpected The frame is forbidden in its current context
   --  @enum Settings_Error Peer SETTINGS are malformed
   --  @enum Frame_Error A frame is malformed or unsupported
   --  @enum QPACK_Decompression_Failed A field section cannot be decoded
   --  @enum Peer_Field_Section_Too_Large Fields exceed the peer's advertised
   --    maximum field-section size
   --  @enum Message_Error HTTP message sequencing is invalid
   --  @enum Header_Error HTTP field semantics are invalid
   type Operation_Status is
     (Succeeded,
      No_Event,
      Uninitialized,
      Not_Connected,
      Already_Started,
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
      QPACK_Decompression_Failed,
      Peer_Field_Section_Too_Large,
      Message_Error,
      Header_Error);

   --  Create the mandatory local control stream and SETTINGS frame.
   --  @param Item Initialized HTTP/3 session
   --  @param Transport Connected QUIC connection
   --  @param Now Monotonic microsecond timestamp
   --  @param Packet Datagram to send when Status is Succeeded
   --  @param Status Operation outcome
   procedure Start
     (Item      : in out Session;
      Transport : in out QUIC.Connection;
      Now       : QUIC.Timestamp;
      Packet    : out QUIC.Datagram;
      Status    : out Operation_Status);

   --  Kind of complete HTTP/3 input returned by Poll.
   --  @enum No_Event No complete input is available
   --  @enum Settings_Received Peer SETTINGS were accepted
   --  @enum Headers_Received A HEADERS field section was decoded
   --  @enum Data_Received A DATA frame payload was decoded
   --  @enum Push_Promise_Received A PUSH_PROMISE was decoded
   --  @enum QPACK_Data_Received Peer QPACK stream data is available
   --  @enum Stream_Ended A complete request or response reached stream FIN
   type Event_Kind is
     (No_Event,
      Settings_Received,
      Headers_Received,
      Data_Received,
      Push_Promise_Received,
      QPACK_Data_Received,
      Stream_Ended);

   --  Length of the DATA payload retained by an event.
   subtype Event_Data_Length is Natural range 0 .. Max_Event_Data;

   --  One decoded HTTP/3 application event.
   --  @field Kind Event classification
   --  @field Stream QUIC stream carrying the event
   --  @field Headers Decoded field section for a HEADERS event
   --  @field Data Bounded payload storage for a DATA event
   --  @field Data_Length Number of meaningful octets in Data
   type Event is record
      Kind        : Event_Kind := No_Event;
      Stream      : QUIC.Stream_ID := 0;
      Headers     : Header_Block;
      Data        : Ada.Streams.Stream_Element_Array (1 .. Max_Event_Data) :=
        (others => 0);
      Data_Length : Event_Data_Length := 0;
   end record;

   --  Decode at most one complete event from QUIC stream buffers.
   --  @param Item Initialized HTTP/3 session
   --  @param Transport Connected QUIC connection
   --  @param Output Decoded event when Status is Succeeded
   --  @param Status Operation outcome
   procedure Poll
     (Item      : in out Session;
      Transport : in out QUIC.Connection;
      Output    : out Event;
      Status    : out Operation_Status);

   --  Allocate a client-initiated bidirectional request stream.
   --  @param Item Initialized client session
   --  @param Transport Connected QUIC connection
   --  @param Stream Allocated stream identifier on success
   --  @param Status Operation outcome
   procedure Open_Request
     (Item      : in out Session;
      Transport : in out QUIC.Connection;
      Stream    : out QUIC.Stream_ID;
      Status    : out Operation_Status);

   --  Encode and protect a request, response, or trailer HEADERS frame.
   --  @param Item Initialized HTTP/3 session
   --  @param Transport Connected QUIC connection
   --  @param Stream Request stream identifier
   --  @param Headers Field section to encode
   --  @param Fin Whether this closes the sending direction
   --  @param Now Monotonic microsecond timestamp
   --  @param Packet Datagram to send when Status is Succeeded
   --  @param Status Operation outcome
   procedure Send_Headers
     (Item      : in out Session;
      Transport : in out QUIC.Connection;
      Stream    : QUIC.Stream_ID;
      Headers   : Header_Block;
      Fin       : Boolean;
      Now       : QUIC.Timestamp;
      Packet    : out QUIC.Datagram;
      Status    : out Operation_Status);

   --  Encode and protect one DATA frame.
   --  @param Item Initialized HTTP/3 session
   --  @param Transport Connected QUIC connection
   --  @param Stream Request stream identifier
   --  @param Data Frame payload
   --  @param Fin Whether this closes the sending direction
   --  @param Now Monotonic microsecond timestamp
   --  @param Packet Datagram to send when Status is Succeeded
   --  @param Status Operation outcome
   procedure Send_Data
     (Item      : in out Session;
      Transport : in out QUIC.Connection;
      Stream    : QUIC.Stream_ID;
      Data      : Ada.Streams.Stream_Element_Array;
      Fin       : Boolean;
      Now       : QUIC.Timestamp;
      Packet    : out QUIC.Datagram;
      Status    : out Operation_Status);

   --  Report whether the peer's mandatory SETTINGS frame was accepted.
   --  @param Item Session to inspect
   --  @return True after a Settings_Received event
   function Has_Peer_Settings (Item : Session) return Boolean;

   --  Return the SETTINGS advertised by the peer.
   --  @param Item Session whose peer SETTINGS were accepted
   --  @return Peer settings used for subsequent sends
   function Peer_Settings (Item : Session) return Settings
   with Pre => Has_Peer_Settings (Item);

private
   subtype Name_Length is Natural range 0 .. Max_Name_Length;
   subtype Value_Length is Natural range 0 .. Max_Value_Length;
   subtype Field_Count is Natural range 0 .. Max_Fields;

   type Header_Field is record
      Name_Size  : Name_Length := 0;
      Name       : String (1 .. Max_Name_Length) :=
        (others => Character'Val (0));
      Value_Size : Value_Length := 0;
      Value      : String (1 .. Max_Value_Length) :=
        (others => Character'Val (0));
   end record;

   type Header_Field_Array is
     array (Positive range 1 .. Max_Fields) of Header_Field;

   type Header_Block is record
      Count  : Field_Count := 0;
      Fields : Header_Field_Array;
   end record;

   type Session is new Ada.Finalization.Limited_Controlled with record
      Backend : System.Address := System.Null_Address;
   end record;

   --  @exclude
   overriding procedure Finalize (Item : in out Session);
end Flyology.HTTP.HTTP_3;
