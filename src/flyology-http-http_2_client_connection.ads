with Ada.Streams;
with Flyology.HTTP.Headers;
with Flyology.IO;
with Flyology.IO.Connections;

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
      Head_Refused,
      Head_Goaway_Unprocessed);

   type Body_Result is
     (Body_Progress,
      Body_Would_Block,
      Body_Finished,
      Body_Connection_Failed,
      Body_Stream_Failed);

   --  Allocate a session and start its lightweight transport pump.  Channel
   --  remains owned by the caller and must outlive Item.
   procedure Create
     (Item    : out Session_Access;
      Channel : not null access Flyology.IO.Connections.Connection);

   --  Close wakes the pump; this call waits until it has stopped and releases
   --  the session storage.  Channel itself is not closed here.
   procedure Destroy (Item : in out Session_Access);

   --  Return whether the peer still permits new locally initiated streams.
   function Is_Usable (Item : Session) return Boolean;

   --  Open one request stream.  Header_Block is a complete HPACK field
   --  section.  Retained_Body remains copied into bounded protocol state until
   --  it is emitted under peer flow control.
   procedure Open
     (Item          : in out Session;
      Header_Block  : Ada.Streams.Stream_Element_Array;
      Retained_Body : Ada.Streams.Stream_Element_Array;
      Head_Request  : Boolean;
      Handle        : out Stream_Handle;
      Accepted      : out Boolean);

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
   task type Pump_Task
     (State   : not null Session_State_Access;
      Channel : not null access Flyology.IO.Connections.Connection) is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Pump_Task;
   type Pump_Access is access Pump_Task;

   type Session is limited record
      State : Session_State_Access := null;
      Pump  : Pump_Access := null;
   end record;

end Flyology.HTTP.HTTP_2_Client_Connection;
