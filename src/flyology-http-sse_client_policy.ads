with Ada.Strings.Unbounded;

--  Protocol-neutral EventSource reconnect state shared by the HTTP client and
--  the TLA+ conformance adapter.
private package Flyology.HTTP.SSE_Client_Policy is

   --  Lifecycle phase for one EventSource.
   --  @enum Connecting A request may be established
   --  @enum Open A valid event stream is being consumed
   --  @enum Waiting The configured reconnect delay is pending
   --  @enum Stopped Reconnect was permanently disabled
   --  @enum Failed A fatal response failure occurred
   type Phase is (Connecting, Open, Waiting, Stopped, Failed);

   --  Retry, id, and phase state for one EventSource.
   type State is private;

   --  Reset state for an initial connection.
   --  @param Item State to initialize
   --  @param Initial_Delay Caller-selected initial reconnect delay
   procedure Initialize (Item : out State; Initial_Delay : Duration);

   --  Record acceptance of a valid event-stream response.
   --  @param Item Connecting state to advance
   procedure Connection_Accepted (Item : in out State);

   --  Permanently stop after an HTTP 204 response.
   --  @param Item Connecting state to stop
   procedure Connection_No_Content (Item : in out State);

   --  Select the current retry delay after a recoverable failure.
   --  @param Item Connecting or open state to advance
   procedure Connection_Recoverable_Failure (Item : in out State);

   --  Record a fatal response failure.
   --  @param Item Connecting or open state to fail
   procedure Connection_Fatal_Failure (Item : in out State);

   --  Replace the current stream's event-id buffer.
   --  @param Item Open state to change
   --  @param Value Parsed UTF-8 id value
   procedure Set_Event_ID_Buffer
     (Item : in out State; Value : String);

   --  Replace the reconnect delay selected by a retry field.
   --  @param Item Open state to change
   --  @param Value Validated nonnegative delay
   procedure Set_Retry_Delay
     (Item : in out State; Value : Duration);

   --  Commit the stream event-id buffer at a dispatch boundary.
   --  @param Item Open state to change
   procedure Dispatch_Event (Item : in out State);

   --  Select a reconnect wait after clean end of body.
   --  @param Item Open state to advance
   procedure End_Of_Body (Item : in out State);

   --  Snapshot the last event id for the next request.
   --  @param Item Waiting state to advance
   procedure Reconnect_Wait_Elapsed (Item : in out State);

   --  Permanently stop an active lifecycle.
   --  @param Item State to stop
   procedure Stop (Item : in out State);

   --  Return the lifecycle phase.
   --  @param Item State to inspect
   --  @return Current phase
   function Current_Phase (Item : State) return Phase;

   --  Return the last event id committed at a dispatch boundary.
   --  @param Item State to inspect
   --  @return UTF-8 last event id
   function Last_Event_ID (Item : State) return String;

   --  Return the current stream's parsed event-id buffer.
   --  @param Item State to inspect
   --  @return UTF-8 buffered event id
   function Event_ID_Buffer (Item : State) return String;

   --  Return the id snapshotted for the next request.
   --  @param Item State to inspect
   --  @return UTF-8 Last-Event-ID value
   function Sent_Last_Event_ID (Item : State) return String;

   --  Return the current stream-selected reconnect delay.
   --  @param Item State to inspect
   --  @return Reconnect delay
   function Reconnect_Delay (Item : State) return Duration;

   --  Return the delay selected when entering the waiting phase.
   --  @param Item State to inspect
   --  @return Selected wait delay
   function Selected_Wait_Delay (Item : State) return Duration;

private
   type State is record
      Phase_Value        : Phase;
      Last_ID_Value      : Ada.Strings.Unbounded.Unbounded_String;
      Event_ID_Value     : Ada.Strings.Unbounded.Unbounded_String;
      Sent_ID_Value      : Ada.Strings.Unbounded.Unbounded_String;
      Retry_Delay_Value : Duration;
      Wait_Delay_Value  : Duration;
   end record;

end Flyology.HTTP.SSE_Client_Policy;
