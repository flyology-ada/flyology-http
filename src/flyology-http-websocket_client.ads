with Ada.Finalization;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Flyology.Bytes;
with Flyology.Cancellation;
with Flyology.HTTP.Headers;
with Flyology.IO.Connections;
with Flyology.IO.TLS;

--  Provides an origin-bound synchronous RFC 6455 client. Calls preserve the
--  same native and lightweight task semantics as Flyology.HTTP.Client. One
--  Client owns at most one WebSocket transport and serializes its lifecycle;
--  applications must not invoke operations on the same Client concurrently.
package Flyology.HTTP.WebSocket_Client is

   --  Default application receive bound: one MiB after reassembly.
   Default_Max_Message : constant := 1_024 * 1_024;
   --  Absolute supported data-frame and reassembled-message bound: 16 MiB.
   Max_Frame_Length     : constant := 16 * 1_024 * 1_024;
   --  Maximum number of subprotocol tokens retained by one request.
   Max_Protocol_Count   : constant := 16;
   --  Maximum byte length of one offered subprotocol token.
   Max_Protocol_Length  : constant := 256;
   --  Maximum serialized bytes retained by all subprotocol offers.
   Max_Protocol_Offer_Bytes : constant := 4 * 1_024;
   --  Maximum serialized HTTP upgrade request head: 48 KiB.
   Max_Handshake_Bytes  : constant := 48 * 1_024;

   --  Raised when resolution or every address attempt fails before upgrade.
   Connection_Error : exception;
   --  Raised when a received message exceeds the caller's explicit bound.
   Message_Too_Large : exception;

   --  Application data message kind.
   --  @enum Text_Message UTF-8 text data
   --  @enum Binary_Message Opaque binary data
   type Data_Kind is (Text_Message, Binary_Message);

   --  Mutable WebSocket handshake request. The default target is slash.
   type Request is private;

   --  Replace the origin-form handshake target. Fragments, absolute-form,
   --  controls, spaces, non-ASCII bytes, and values over 8 KiB are rejected.
   --  @param Item Request to change
   --  @param Value Origin-form target
   --  @exception Constraint_Error Value is not a supported target
   procedure Set_Target (Item : in out Request; Value : String);

   --  Set the optional browser-style Origin field, or clear it with an empty
   --  value. The client does not derive this value automatically. Invalid or
   --  oversized field content is rejected before it is retained.
   --  @param Item Request to change
   --  @param Value Origin field value or empty string
   --  @exception Constraint_Error Value is not valid field content
   procedure Set_Origin (Item : in out Request; Value : String);

   --  Append one case-sensitive WebSocket subprotocol token. Individual,
   --  aggregate, and count limits are exposed by the Max_Protocol constants.
   --  The server may select at most one offered token.
   --  @param Item Request to change
   --  @param Value Nonempty HTTP token not already offered
   --  @exception Constraint_Error Value is invalid, repeated, or oversized
   procedure Offer_Protocol (Item : in out Request; Value : String);

   --  Append one handshake field such as Authorization or Cookie. Host,
   --  framing, connection, upgrade, and every Sec-WebSocket field are owned
   --  by the client and rejected.
   --  @param Item Request to change
   --  @param Name End-to-end field name
   --  @param Value Field value
   --  @exception Constraint_Error Field syntax or ownership is invalid
   --  @exception Flyology.HTTP.Headers.Headers_Too_Large Storage is exhausted
   procedure Add_Header
     (Item : in out Request; Name : String; Value : String);

   --  One configured origin and at most one active WebSocket session.
   type Client is limited private;

   --  Bind an unconfigured client to a cleartext ws origin represented by an
   --  HTTP Origin. No DNS or socket work occurs here. HTTPS requires the TLS
   --  overload.
   --  @param Item Unconfigured client
   --  @param Origin_Value HTTP origin used as ws
   --  @exception Program_Error Item is configured or Origin_Value is HTTPS
   procedure Configure (Item : in out Client; Origin_Value : Origin);

   --  Bind a client and retain independent TLS provider state. This overload
   --  is required for wss and is accepted for ws.
   --  @param Item Unconfigured client
   --  @param Origin_Value HTTP or HTTPS origin used as ws or wss
   --  @param Backend Initialized provider retained by Item
   --  @exception Program_Error Item is already configured
   --  @exception Flyology.IO.TLS.TLS_Error Backend cannot be retained
   procedure Configure
     (Item         : in out Client;
      Origin_Value : Origin;
      Backend      : not null access Flyology.IO.TLS.Provider'Class);

   --  Establish TCP, optional authenticated TLS, and a strict HTTP/1.1
   --  WebSocket upgrade under one monotonic deadline. Redirects, proxying,
   --  extension negotiation, and challenge retries are not performed.
   --  @param Item Configured inactive client
   --  @param Value Handshake request
   --  @param Timeout Whole-connect deadline; negative is unlimited
   --  @param Token Optional cancellation source
   --  @exception Connection_Error Resolution or every address attempt fails
   --  @exception Constraint_Error Serialized request head exceeds its bound
   --  @exception Protocol_Error Upgrade response is malformed or unacceptable
   --  @exception Flyology.IO.Timeout_Error Deadline expires
   --  @exception Flyology.Cancellation.Operation_Cancelled Token is requested
   procedure Connect
     (Item    : in out Client;
      Value   : Request;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null);

   --  Report whether application data may be sent or received.
   --  @param Item Client to inspect
   --  @return True after Connect and before either close handshake begins
   function Is_Open (Item : Client) return Boolean;

   --  Return the selected subprotocol, or an empty string when none was
   --  negotiated.
   --  @param Item Connected client
   --  @return Selected case-sensitive subprotocol
   --  @exception Program_Error No successful handshake is retained
   function Negotiated_Protocol (Item : Client) return String;

   --  Return the number of physical upgrade-response fields.
   --  @param Item Connected client
   --  @return Retained field count
   --  @exception Program_Error No successful handshake is retained
   function Header_Count (Item : Client) return Natural;

   --  Count case-insensitive upgrade-response field occurrences.
   --  @param Item Connected client
   --  @param Name Field name
   --  @return Matching physical occurrence count
   --  @exception Program_Error No successful handshake is retained
   function Header_Count (Item : Client; Name : String) return Natural;

   --  Return one upgrade-response field name in wire order.
   --  @param Item Connected client
   --  @param Index One-based physical index
   --  @return Preserved field name
   --  @exception Program_Error No successful handshake is retained
   --  @exception Constraint_Error Index exceeds Header_Count
   function Header_Name (Item : Client; Index : Positive) return String;

   --  Return one upgrade-response field value in wire order.
   --  @param Item Connected client
   --  @param Index One-based physical index
   --  @return Preserved field value
   --  @exception Program_Error No successful handshake is retained
   --  @exception Constraint_Error Index exceeds Header_Count
   function Header_Value (Item : Client; Index : Positive) return String;

   --  Return one named upgrade-response field occurrence or an empty string.
   --  @param Item Connected client
   --  @param Name Field name
   --  @param Occurrence One-based occurrence
   --  @return Matching value or empty string
   --  @exception Program_Error No successful handshake is retained
   function Header
     (Item : Client; Name : String; Occurrence : Positive := 1) return String;

   --  Send one final masked data frame. Text bytes must be valid UTF-8 and all
   --  data frames are bounded by Max_Frame_Length.
   --  @param Item Open client
   --  @param Kind Text or binary message kind
   --  @param Data Message payload
   --  @param Timeout Whole-frame deadline
   --  @param Token Optional cancellation source
   --  @exception Program_Error Item is not open
   --  @exception Constraint_Error Data is too large or invalid UTF-8
   --  @exception Connection_Error Masking entropy is unavailable
   --  @exception Flyology.IO.Timeout_Error Deadline expires
   --  @exception Flyology.Cancellation.Operation_Cancelled Token is requested
   procedure Send
     (Item    : in out Client;
      Kind    : Data_Kind;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null);

   --  Send one final masked UTF-8 text message of at most Max_Frame_Length.
   --  @param Item Open client
   --  @param Data UTF-8 encoded octets
   --  @param Timeout Whole-frame deadline
   --  @param Token Optional cancellation source
   --  @exception Program_Error Item is not open
   --  @exception Constraint_Error Data is too large or invalid UTF-8
   --  @exception Connection_Error Masking entropy is unavailable
   --  @exception Flyology.IO.Timeout_Error Deadline expires
   --  @exception Flyology.Cancellation.Operation_Cancelled Token is requested
   procedure Send
     (Item    : in out Client;
      Data    : String;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null);

   --  Receive and reassemble one data message. Ping is answered and pong is
   --  ignored. A valid peer close is acknowledged, retained for Close_Code and
   --  Close_Reason, and reported through Closed. Server frames must be
   --  unmasked. Max_Message is capped by Max_Frame_Length.
   --  Timeout or cancellation terminates the session because a partially
   --  consumed frame cannot be exposed as a resumable application value.
   --  @param Item Connected client
   --  @param Kind Returned data kind; Text_Message when Closed is True
   --  @param Data Complete message payload; empty when Closed is True
   --  @param Closed Whether a valid close frame completed the session
   --  @param Max_Message Application message bound
   --  @param Timeout Whole-message deadline
   --  @param Token Optional cancellation source
   --  @exception Message_Too_Large Message exceeds Max_Message
   --  @exception Program_Error Item is not active
   --  @exception Constraint_Error Max_Message exceeds Max_Frame_Length
   --  @exception Connection_Error Control-frame masking entropy is unavailable
   --  @exception Protocol_Error Peer framing or content is invalid
   --  @exception Flyology.IO.Timeout_Error Deadline expires
   --  @exception Flyology.Cancellation.Operation_Cancelled Token is requested
   procedure Receive
     (Item        : in out Client;
      Kind        : out Data_Kind;
      Data        : out Flyology.Bytes.Unbounded_Bytes;
      Closed      : out Boolean;
      Max_Message : Natural := Default_Max_Message;
      Timeout     : Duration := 30.0;
      Token       : access Flyology.Cancellation.Token := null);

   --  Return the received close status, or 1005 when the peer sent no status.
   --  @param Item Client whose peer close was received
   --  @return Peer close status or 1005
   --  @exception Program_Error No peer close has been received
   function Close_Code (Item : Client) return Natural;

   --  Return the received UTF-8 close reason.
   --  @param Item Client whose peer close was received
   --  @return Peer close reason, possibly empty
   --  @exception Program_Error No peer close has been received
   function Close_Reason (Item : Client) return String;

   --  Send a masked close and wait for the peer close under one monotonic
   --  deadline. Timeout or cancellation terminates the session. Code and
   --  Reason are validated before transmission.
   --  A successful wss close also completes TLS close-notify before releasing
   --  the transport.
   --  @param Item Open or close-pending client
   --  @param Code RFC 6455 close status permitted on the wire
   --  @param Reason UTF-8 reason of at most 123 bytes
   --  @param Timeout Whole-close deadline
   --  @param Token Optional cancellation source
   --  @exception Program_Error Item is not active
   --  @exception Constraint_Error Code or Reason is invalid
   --  @exception Connection_Error Masking entropy is unavailable
   --  @exception Flyology.IO.Timeout_Error Deadline expires
   --  @exception Flyology.Cancellation.Operation_Cancelled Token is requested
   procedure Close
     (Item    : in out Client;
      Code    : Positive := 1_000;
      Reason  : String := "";
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null);

   --  Close the transport without a WebSocket close handshake. The configured
   --  client may subsequently Connect again.
   --  @param Item Client whose transport is discarded
   procedure Abort_Connection (Item : in out Client);

private
   use Ada.Strings.Unbounded;

   subtype Protocol_Count is Natural range 0 .. Max_Protocol_Count;
   type Protocol_Array is
     array (Positive range 1 .. Max_Protocol_Count) of Unbounded_String;

   type Request is record
      Target    : Unbounded_String := To_Unbounded_String ("/");
      Origin    : Unbounded_String;
      Protocols : Protocol_Array;
      Last_Protocol : Protocol_Count := 0;
      Protocol_Bytes : Natural range 0 .. Max_Protocol_Offer_Bytes := 0;
      Fields    : Flyology.HTTP.Headers.List;
   end record;

   type Client_Phase is
     (Unconfigured, Inactive, Connecting, Open, Close_Pending, Closed);

   type Client is limited new Ada.Finalization.Limited_Controlled with record
      Manager     : aliased Flyology.IO.Connections.Server (Capacity => 1);
      Channel     : Flyology.IO.Connections.Connection;
      Backend     : Flyology.IO.TLS.Provider_Access := null;
      Origin_Value : Origin;
      Phase       : Client_Phase := Unconfigured;
      Fields      : Flyology.HTTP.Headers.List;
      Pending     : Unbounded_String;
      Protocol_Value : Unbounded_String;
      Peer_Close_Received : Boolean := False;
      Peer_Close_Code : Natural := 1_005;
      Peer_Close_Reason : Unbounded_String;
      Handshake_Complete : Boolean := False;
   end record;

   --  @exclude
   --  @param Item Controlled client state to release
   overriding procedure Finalize (Item : in out Client);

end Flyology.HTTP.WebSocket_Client;
