with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Flyology.Operations;
private with Ada.Exceptions;
private with Ada.Streams;
private with Flyology.HTTP.SSE_Client_Policy;
private with Flyology.IO.Timers;

--  Consumes WHATWG server-sent event streams over the protocol selected by
--  Flyology.HTTP.Client.  Parsing and reconnect state are independent of the
--  HTTP/1.1, HTTP/2, or HTTP/3 response framing used by the underlying client.
package Flyology.HTTP.Client.SSE is

   --  Raised when a response is not a valid EventSource response.
   Invalid_Event_Stream : exception;

   --  Raised before retained parser fields exceed the EventSource byte bound.
   Event_Too_Large : exception;

   --  Raised when a server retry field exceeds the caller's configured
   --  Maximum_Reconnect_Delay.
   Reconnect_Delay_Too_Large : exception;

   --  Outcome of one Read call.
   --  @enum Event_Available Item contains the next dispatched event
   --  @enum Stream_Stopped HTTP 204 permanently stopped this event source
   type Read_Result is (Event_Available, Stream_Stopped);

   --  One dispatched server-sent event.  Text values contain UTF-8 bytes;
   --  malformed input sequences are decoded as U+FFFD.
   type Event is private;

   --  Return the event data with embedded LF separators between data fields.
   --  @param Item Event to inspect
   --  @return UTF-8 event data
   function Data (Item : Event) return String;

   --  Return the event type, or `message` when no event field was supplied.
   --  @param Item Event to inspect
   --  @return UTF-8 event type
   function Event_Type (Item : Event) return String;

   --  Return the EventSource last-event id current at dispatch.
   --  @param Item Event to inspect
   --  @return UTF-8 last-event id, possibly empty
   function Last_Event_ID (Item : Event) return String;

   --  Stateful EventSource bound to an existing origin client.  The caller's
   --  byte bound covers the retained current line, event fields, and event id.
   --  @field HTTP Client borrowed for every initial and reconnect request
   --  @field Maximum_Event_Bytes Maximum retained parser-field bytes
   type Event_Source
     (HTTP                : not null access Client;
      Maximum_Event_Bytes : Positive) is limited private;

   --  Initialize or reset an EventSource without performing network I/O.
   --  The supplied request contributes its target, headers, and redirect
   --  policy.  Open makes its retained copy a bodyless GET and controls the
   --  Accept and Last-Event-ID fields.  One absolute deadline covers the
   --  initial request, every body read, reconnect wait, and later request.
   --  @param Item EventSource to initialize
   --  @param Value Request template retained by Item
   --  @param Initial_Reconnect_Delay Initial reconnection delay in seconds
   --  @param Maximum_Reconnect_Delay Largest server retry value accepted
   --  @param Deadline Absolute lifecycle deadline
   --  @exception Constraint_Error A delay is negative or initial exceeds max
   procedure Open
     (Item                    : in out Event_Source;
      Value                   : Request;
      Initial_Reconnect_Delay : Duration;
      Maximum_Reconnect_Delay : Duration;
      Deadline                : Monotonic_Deadline);

   --  Return the next event, reconnecting after clean EOF or recoverable
   --  transport failure.  HTTP 204 returns Stream_Stopped and permanently
   --  disables reconnect.  Cancellation and the absolute deadline interrupt
   --  requests, reads, and reconnect waits using their ordinary exceptions.
   --  @param Item Initialized EventSource to advance
   --  @param Result Whether an event or permanent stop was observed
   --  @param Value Next event when Result is Event_Available
   --  @param Token Optional cancellation source borrowed for this call
   --  @exception Program_Error Item was not initialized by Open
   --  @exception Invalid_Event_Stream Response status or media type violates
   --     the EventSource contract
   --  @exception Event_Too_Large Retained parser state would exceed the bound
   --  @exception Reconnect_Delay_Too_Large A retry field exceeds caller policy
   procedure Read
     (Item   : aliased in out Event_Source;
      Result : out Read_Result;
      Value  : out Event;
      Token  : access Flyology.Cancellation.Token := null);

   --  One owner-driven read through initial connection, response parsing,
   --  reconnect timers, and later connections. Item and Token are borrowed
   --  until terminal Finish or cancellation drain.
   type Read_Operation is
     new Flyology.Operations.Operation with private;

   --  Start one composable EventSource read.
   --  @param Set Owner completion set
   --  @param Item Initialized EventSource borrowed through terminal drain
   --  @param Token Optional cancellation source borrowed through drain
   --  @return Started EventSource read operation
   function Read
     (Set   : not null access Flyology.Operations.Completion_Set'Class;
      Item  : not null access Event_Source;
      Token : access Flyology.Cancellation.Token := null)
      return Read_Operation;

   --  Start or restart a composable read in an established operation.
   --  @param Item Initialized EventSource borrowed through terminal drain
   --  @param Token Optional cancellation source borrowed through drain
   --  @param Operation Inactive established operation to start
   procedure Read
     (Item      : not null access Event_Source;
      Token     : access Flyology.Cancellation.Token := null;
      Operation : in out Read_Operation)
     with Pre => not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation);

   --  Consume one terminal composable read.
   --  @param Operation Terminal read operation
   --  @param Result Whether an event or permanent stop was observed
   --  @param Value Next event when Result is Event_Available
   procedure Finish
     (Operation : in out Read_Operation;
      Result    : out Read_Result;
      Value     : out Event);

   --  Return the id that will be sent on the next reconnect request.
   --  @param Item Initialized EventSource
   --  @return Current UTF-8 last-event id
   function Last_Event_ID (Item : Event_Source) return String;

   --  Return the reconnect delay currently selected by the stream.
   --  @param Item Initialized EventSource
   --  @return Current delay in seconds
   function Reconnect_Delay (Item : Event_Source) return Duration;

private
   type Event is record
      Data_Value          : Ada.Strings.Unbounded.Unbounded_String;
      Event_Type_Value    : Ada.Strings.Unbounded.Unbounded_String;
      Last_Event_ID_Value : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Event_Source
     (HTTP                : not null access Client;
      Maximum_Event_Bytes : Positive) is limited record
         Template          : Request;
         Reply             : aliased Response;
         Initialized       : Boolean := False;
         Connected         : Boolean := False;
         Body_Finished     : Boolean := False;
         Deadline          : Monotonic_Deadline := No_Deadline;
         Maximum_Delay     : Duration := 0.0;
         Lifecycle         : Flyology.HTTP.SSE_Client_Policy.State;
         Line              : Ada.Strings.Unbounded.Unbounded_String;
         Data_Buffer       : Ada.Strings.Unbounded.Unbounded_String;
         Event_Type_Buffer : Ada.Strings.Unbounded.Unbounded_String;
         Start_Bytes       : Ada.Strings.Unbounded.Unbounded_String;
         At_Stream_Start   : Boolean := True;
         Skip_Next_LF      : Boolean := False;
         Pending           : Ada.Strings.Unbounded.Unbounded_String;
         Pending_Cursor    : Natural := 0;
         Read_Active       : Boolean := False;
   end record;

   type Event_Source_Borrow is access all Event_Source;
   type Token_Borrow is access all Flyology.Cancellation.Token;

   type Read_Phase is
     (Read_Idle, Processing_Buffered, Starting_Response_Head,
      Waiting_Reconnect,
      Waiting_Response_Head, Waiting_Response_Body, Read_Done);

   type Redirect_Target_Array is array (Redirect_Limit) of
     Ada.Strings.Unbounded.Unbounded_String;

   type Event_Sink is new Pausable_Response_Body_Sink with record
      Source    : Event_Source_Borrow := null;
      Available : Boolean := False;
      Value     : Event;
   end record;

   --  @exclude
   --  @param Item Parser sink receiving this body slice
   --  @param Data Decoded response body bytes
   overriding procedure Write
     (Item : in out Event_Sink;
      Data : Ada.Streams.Stream_Element_Array);

   --  @exclude
   --  @param Item Parser sink to inspect
   --  @return True after one complete event is available
   overriding function Pause_Requested
     (Item : Event_Sink) return Boolean;

   type Exchange_Operation_Access is access Exchange_Operation;
   type Timer_Operation_Access is access Flyology.IO.Timers.Timer_Operation;

   type Read_Operation is
     new Flyology.Operations.Operation with record
      Source      : Event_Source_Borrow := null;
      Token       : Token_Borrow := null;
      Phase       : Read_Phase := Read_Idle;
      Exchange    : Exchange_Operation_Access := null;
      Timer       : Timer_Operation_Access := null;
      Sink        : aliased Event_Sink;
      Request_Copy : aliased Request;
      Redirect_Hops : Redirect_Limit := 0;
      Seen_Targets  : Redirect_Target_Array;
      Seen_Last     : Redirect_Limit := 0;
      Result      : Read_Result := Stream_Stopped;
      Value       : Event;
      Saved_Error : Ada.Exceptions.Exception_Occurrence;
      Has_Error   : Boolean := False;
   end record;

   --  @exclude
   --  @param Item Owner-driven SSE read state
   --  @param Cause Completion-set driver event
   overriding procedure Drive
     (Item  : in out Read_Operation;
      Cause : Flyology.Operations.Driver_Event);

   --  @exclude
   --  @param Item SSE read operation to cancel and drain
   overriding procedure Request_Cancellation
     (Item : in out Read_Operation);

   --  @exclude
   --  @param Item SSE read operation to drain and release
   overriding procedure Finalize (Item : in out Read_Operation);

end Flyology.HTTP.Client.SSE;
