with Ada.Streams;
with Flyology.Bytes;
with Flyology.HTTP.Headers;
with Flyology.IO;
with Flyology.IO.Connections;
with Flyology.IO.Connections.Drivers;

--  Owns the connection-scoped HTTP/2 pump and its bounded set of concurrent
--  client streams.  The public client keeps this transport detail private.
private package Flyology.HTTP.HTTP_2_Client_Connection is

   Maximum_Concurrent_Streams : constant Positive := 32;

   type Session is limited private;
   type Session_Access is access Session;

   type Stream_Handle is private;
   No_Stream : constant Stream_Handle;

   function Identifier (Handle : Stream_Handle) return Natural;

   type Head_Result is
     (Head_Ready,
      Head_Would_Block,
      Head_Connection_Failed,
      Head_Protocol_Failed,
      Head_Refused,
      Head_Goaway_Unprocessed);

   type Body_Result is
     (Body_Progress,
      Body_Would_Block,
      Body_Finished,
      Body_Connection_Failed,
      Body_Protocol_Failed,
      Body_Stream_Failed);

   type Upload_Result is
     (Upload_Accepted, Upload_Would_Block, Upload_Failed);

   --  Allocate a session whose transport is driven only by client operations
   --  on their completion-set owner's stack. No task is created.
   procedure Create (Item : out Session_Access);

   type Pump_Step_Result is
     (Pump_Progress, Pump_Need_Read, Pump_Need_Write,
      Pump_Peer_Closed, Pump_Protocol_Failed);

   type Pump_Step is record
      Result         : Pump_Step_Result := Pump_Progress;
      Sent_Bytes     : Boolean := False;
      Received_Bytes : Boolean := False;
      Outbound_Pending : Boolean := False;
   end record;

   --  Claim the shared session pump for Handle. Exactly one stream operation
   --  drives the connection at a time; every other stream remains protected
   --  by the controller and waits on its ordinary stream wake source.
   procedure Try_Claim_Pump
     (Item    : in out Session;
      Handle  : Stream_Handle;
      Claimed : out Boolean);

   function Owns_Pump
     (Item : Session; Handle : Stream_Handle) return Boolean;

   procedure Release_Pump
     (Item : in out Session; Handle : Stream_Handle);

   --  Return a wake descriptor for ownership of the shared pump. Ready_Now
   --  is true only when Handle may claim it or its stream has failed.
   procedure Pump_Wait_Source
     (Item      : in out Session;
      Handle    : Stream_Handle;
      FD        : out Flyology.IO.Descriptor;
      Ready_Now : out Boolean);

   --  Return whether a peer response event has been attributed to Handle.
   --  This is diagnostic admission certainty only; it does not imply a
   --  complete or semantically valid response.
   function Has_Response_Observation
     (Item : Session; Handle : Stream_Handle) return Boolean;

   --  Perform one bounded protocol or transport step. IO must be acquired by
   --  the claiming outer exchange operation.
   procedure Drive_Pump
     (Item   : in out Session;
      Handle : Stream_Handle;
      IO     : in out Flyology.IO.Connections.Drivers.Capability;
      Step   : out Pump_Step);

   --  Return the coalesced protocol-output wakeup used with the connection
   --  driver's composable Arm_Transport overload.
   function Outbound
     (Item : aliased in out Session)
      return not null access
        Flyology.IO.Connections.Drivers.Outbound_Wakeup;

   --  Close wakes the pump; this call waits until it has stopped and releases
   --  the session storage.  Channel itself is not closed here.
   procedure Destroy (Item : in out Session_Access);

   --  Return whether the peer still permits new locally initiated streams.
   function Is_Usable (Item : Session) return Boolean;

   --  Return whether the connection currently has both local and peer stream
   --  capacity for one more request.
   function Can_Open (Item : Session) return Boolean;

   --  Open one request stream.  Header_Block is a complete HPACK field
   --  section.  Retained_Body remains copied into bounded protocol state until
   --  it is emitted under peer flow control.
   procedure Open
     (Item          : in out Session;
      Header_Block  : Ada.Streams.Stream_Element_Array;
      Retained_Body : Flyology.Bytes.Unbounded_Bytes;
      Streaming     : Boolean;
      Head_Request  : Boolean;
      Handle        : out Stream_Handle;
      Accepted      : out Boolean);

   --  Copy one bounded source chunk into protocol-owned flow-control storage.
   --  Finished closes the request direction after Data and optional encoded
   --  trailer fields have been emitted.
   procedure Write_Request_Data
     (Item          : in out Session;
      Handle        : Stream_Handle;
      Data          : Ada.Streams.Stream_Element_Array;
      Finished      : Boolean;
      Trailer_Block : Ada.Streams.Stream_Element_Array;
      Result        : out Upload_Result);

   --  Return a wake descriptor for request-upload queue space or failure.
   procedure Upload_Wait_Source
     (Item      : in out Session;
      Handle    : Stream_Handle;
      Required  : Natural;
      FD        : out Flyology.IO.Descriptor;
      Ready_Now : out Boolean);

   --  Observe a final response head or a retry/failure classification.
   procedure Poll_Head
     (Item    : in out Session;
      Handle  : Stream_Handle;
      Result  : out Head_Result;
      Status  : out Status_Code;
      Fields  : in out Flyology.HTTP.Headers.List;
      Finished : out Boolean);

   --  Copy currently buffered representation bytes.  Consumed bytes replenish
   --  both stream and connection receive windows.
   procedure Read
     (Item     : in out Session;
      Handle   : Stream_Handle;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Result   : out Body_Result;
      Trailers : in out Flyology.HTTP.Headers.List);

   --  Return a wake descriptor for head/body progress.  Ready_Now avoids a
   --  wait when state changed before descriptor registration.
   procedure Wait_Source
     (Item      : in out Session;
      Handle    : Stream_Handle;
      FD        : out Flyology.IO.Descriptor;
      Ready_Now : out Boolean);

   --  Reset an incomplete stream without closing its multiplexed transport.
   procedure Cancel_Stream (Item : in out Session; Handle : Stream_Handle);

   --  Release completed or failed per-stream storage.
   procedure Release_Stream (Item : in out Session; Handle : Stream_Handle);

private
   type Stream_Handle is record
      Slot : Natural := 0;
      ID   : Natural := 0;
   end record;

   No_Stream : constant Stream_Handle := (others => 0);

   type Session_State;
   type Session_State_Access is access Session_State;
   type Session is limited record
      State : Session_State_Access := null;
   end record;

end Flyology.HTTP.HTTP_2_Client_Connection;
