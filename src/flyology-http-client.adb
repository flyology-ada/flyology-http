with Ada.Characters.Handling;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;
with System.Address_To_Access_Conversions;
with System.Storage_Elements;
with Flyology.Buffers.Drivers;
with Flyology.HTTP.Client_Policy;
with Flyology.HTTP.HTTP_2_Client_Connection;
with Flyology.HTTP.HTTP_2_Requests;
with Flyology.HTTP.HTTP_3;
with Flyology.HTTP.HTTP_3_Client_Connection;
with Flyology.IO.Connections;
with Flyology.IO.Connections.Drivers;
with Flyology.IO.Connections.TLS;
with Flyology.IO.DNS;
with Flyology.IO.Sockets;
with Flyology.Operations.Drivers;
with Flyology.Time_Math;
with Flyology.IO.TLS.ALPN;
with Flyology.Wake_Sources;
with Flyology.QUIC.Connections;
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
with Interfaces.C;
#end if;

package body Flyology.HTTP.Client is
   use Ada.Strings.Unbounded;
   use Flyology.HTTP.Client_Policy;
   use type Ada.Exceptions.Exception_Id;
   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type Flyology.IO.Descriptor;
   use type Flyology.IO.Connections.Drivers.Acquisition_Result;
   use type Flyology.Operations.Driver_Event;
   use type System.Storage_Elements.Storage_Offset;

#if FLYOLOGY_CONNECTION_TEST_HOOKS then
   function Test_Barrier_Arrive
     (Point : Interfaces.C.int) return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_test_connection_barrier_arrive";
   function Test_Barrier_Released
     (Point : Interfaces.C.int) return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_test_connection_barrier_released";
   function Test_Receive_Limit
     (Requested : Interfaces.C.int) return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name => "flyology_http_test_connection_receive_limit";
   procedure Test_Receive_Observed
     with Import,
          Convention => C,
          External_Name => "flyology_http_test_connection_receive_observed";

   procedure Client_Test_Barrier (Point : Natural) is
      Position : constant Interfaces.C.int := Interfaces.C.int (Point);
   begin
      if Test_Barrier_Arrive (Position) /= 0 then
         while Test_Barrier_Released (Position) = 0 loop
            delay 0.0;
         end loop;
      end if;
   end Client_Test_Barrier;

   function Client_Test_Receive_Limit (Requested : Positive) return Positive
   is (Positive (Test_Receive_Limit (Interfaces.C.int (Requested))));
   procedure Client_Test_Receive_Observed renames Test_Receive_Observed;
#else
   procedure Client_Test_Barrier (Point : Natural) is null;
   function Client_Test_Receive_Limit (Requested : Positive) return Positive
   is (Requested);
   procedure Client_Test_Receive_Observed is null;
#end if;

   package Connections renames Flyology.IO.Connections;
   package Connection_Drivers renames
     Flyology.IO.Connections.Drivers;
   package H2_Connections renames
     Flyology.HTTP.HTTP_2_Client_Connection;
   package H2_Requests renames Flyology.HTTP.HTTP_2_Requests;
   package H3 renames Flyology.HTTP.HTTP_3;
   package H3_Connections renames
     Flyology.HTTP.HTTP_3_Client_Connection;
   package QUIC renames Flyology.QUIC.Connections;
   package Sockets renames Flyology.IO.Sockets;
   use type Sockets.Address_Family;
   use type H2_Connections.Session_Access;
   use type H2_Connections.Stream_Handle;
   use type H2_Connections.Head_Result;
   use type H2_Connections.Pump_Step_Result;
   use type H2_Connections.Upload_Result;
   use type H3.Event_Kind;
   use type H3.Operation_Status;
   use type H3_Connections.Stream_Handle;
   use type QUIC.Connection_State;
   use type QUIC.Operation_Status;
   use type QUIC.Send_Status;
   use type QUIC.Stream_ID;
   use type QUIC.Timeout_Status;

   CRLF : constant String := Character'Val (13) & Character'Val (10);
   Receive_Buffer_Size : constant Positive := 8 * 1_024;

   --  An intermediate redirect body is never delivered to the caller, so it
   --  is read only to leave the transport reusable. Past this bound the
   --  transport costs more than it saves and is destroyed instead.
   Max_Redirect_Drain_Bytes : constant Natural := 64 * 1_024;

   type Transport_Protocol is
     (HTTP_1_Transport, HTTP_2_Transport, HTTP_3_Transport);

   type Connect_Transport is (Internet_Transport, Unix_Domain_Transport);

   --  Match the server's generous default lifetime while completed stream
   --  storage is recycled inside the bounded concurrent-stream profile.
   HTTP_3_Requests_Per_Connection : constant Positive := 100_000;

   HTTP_3_Transport_Settings : constant QUIC.Transport_Settings :=
     (others => <>);
   HTTP_3_Data_Credit_Interval : constant QUIC.Stream_Offset :=
     QUIC.Stream_Offset'Max (1, HTTP_3_Transport_Settings.Max_Data / 2);

   type HTTP_3_Event_Access is access H3.Event;
   procedure Free_HTTP_3_Event is new Ada.Unchecked_Deallocation
     (H3.Event, HTTP_3_Event_Access);

   type Pooled_Connection is limited record
      Channel  : aliased Connections.Connection;
      UDP      : aliased Sockets.Socket_Type;
      Protocol : Transport_Protocol := HTTP_1_Transport;
      HTTP_2   : H2_Connections.Session_Access := null;
      QUIC_Transport : QUIC.Connection;
      HTTP_3         : H3.Session;
      HTTP_3_Epoch   : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      HTTP_3_Goaway  : Boolean := False;
      HTTP_3_Event   : HTTP_3_Event_Access := null;
      HTTP_3_Streams : H3_Connections.Session;
      HTTP_3_Last_Credit_Data : QUIC.Stream_Offset := 0;
   end record;
   type Pooled_Connection_Access is access Pooled_Connection;

   procedure Free_Connection is new Ada.Unchecked_Deallocation
     (Pooled_Connection, Pooled_Connection_Access);

   type Slot_Phase is
     (Empty, Connecting, Leased, Idle, Shared, Draining, Closing);

   type Slot is record
      Phase       : Slot_Phase := Empty;
      Connection  : Pooled_Connection_Access := null;
      Born         : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Last_Used    : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Request_Count : Natural := 0;
      Active_Streams : Natural := 0;
      Interrupting : Boolean := False;
      Interrupt_Sent : Boolean := False;
      Owner_Done   : Boolean := False;
      Verify_On_Reuse : Boolean := False;
      Connecting_HTTP_3 : Boolean := False;
   end record;
   type Slot_Array is array (Positive range <>) of Slot;

   type Checkout_Result is
     (Checkout_Idle, Checkout_Create, Checkout_Discard, Checkout_Busy,
      Checkout_Closed);
   type Return_Result is
     (Returned_Idle, Returned_Shared, Return_Close,
      Return_Close_Deferred);
   type Failure_Result is (Failure_Free, Failure_Free_Deferred);

   protected type Pool_Controller (Capacity : Positive) is
      procedure Configure (Value : Pool_Configuration);
      procedure Try_Checkout
        (Now        : Ada.Real_Time.Time;
         Prefer_HTTP_3 : Boolean;
         Allow_TCP_Fallback : Boolean;
         Result     : out Checkout_Result;
         Slot_Index : out Natural;
         Connection : out Pooled_Connection_Access;
         Verify     : out Boolean);
      procedure Install
        (Slot_Index : Positive;
         Connection : Pooled_Connection_Access;
         Now        : Ada.Real_Time.Time);
      procedure Publish_Connecting
        (Slot_Index : Positive; Connection : Pooled_Connection_Access);
      procedure Creation_Failed
        (Slot_Index : Positive; Result : out Failure_Result);
      procedure Return_Lease
        (Slot_Index : Positive;
         Reusable   : Boolean;
         Verify     : Boolean;
         Now        : Ada.Real_Time.Time;
         Result     : out Return_Result;
         Connection : out Pooled_Connection_Access);
      procedure Finish_Close (Slot_Index : Positive);
      procedure Take_Idle
        (Found      : out Boolean;
         Slot_Index : out Natural;
         Connection : out Pooled_Connection_Access);
      procedure Request_Shutdown;
      procedure Take_Active_For_Interrupt
        (Found      : out Boolean;
         Slot_Index : out Natural;
         Connection : out Pooled_Connection_Access);
      procedure Finish_Interrupt
        (Slot_Index : Positive;
         Release_Ownership : out Boolean;
         Connection : out Pooled_Connection_Access);
      entry Await_Drained;
      procedure Wait_Source
        (FD : out Flyology.IO.Descriptor;
         Can_Checkout : out Boolean);
      procedure Shutdown_Source
        (FD : out Flyology.IO.Descriptor; Requested : out Boolean);
      procedure Register_Waiter;
      procedure Unregister_Waiter;
      procedure Record_Admission_Timeout;
      procedure Record_Stale_Retry;
      function Snapshot return Client_Diagnostics;
      function Is_Stopping return Boolean;
   private
      Policy       : Pool_Configuration := Default_Pool_Configuration;
      Slots        : Slot_Array (1 .. Capacity);
      Is_Configured : Boolean := False;
      Stopping     : Boolean := False;
      Connecting_Count : Natural := 0;
      Leased_Count : Natural := 0;
      Idle_Count   : Natural := 0;
      Shared_Count : Natural := 0;
      Closing_Count : Natural := 0;
      Waiter_Count : Natural := 0;
      Created_Count : Natural := 0;
      Reused_Count : Natural := 0;
      Closed_Count : Natural := 0;
      Timeout_Count : Natural := 0;
      Stale_Retry_Count : Natural := 0;
      Checkout_Wake : Flyology.Wake_Sources.Source;
      Checkout_Signalled : Boolean := False;
      Shutdown_Wake : Flyology.Wake_Sources.Source;
   end Pool_Controller;

   protected type State_Lifetime is
      procedure Retain_Response;
      procedure Release_Response (Final_Reference : out Boolean);
      procedure Release_Client (Final_Reference : out Boolean);
   private
      Client_Live : Boolean := True;
      Responses   : Natural := 0;
   end State_Lifetime;

   protected type HTTP_3_Discovery is
      procedure Remember (Port : Port_Number; Max_Age : Duration);
      procedure Clear;
      procedure Preferred
        (Now     : Ada.Real_Time.Time;
         Present : out Boolean;
         Port    : out Port_Number);
   private
      Available : Boolean := False;
      UDP_Port  : Port_Number := 443;
      Expires   : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
   end HTTP_3_Discovery;

   protected body Pool_Controller is separate;

   protected body State_Lifetime is separate;

   protected body HTTP_3_Discovery is
      procedure Remember (Port : Port_Number; Max_Age : Duration) is
      begin
         if Max_Age <= 0.0 then
            Available := False;
         else
            UDP_Port := Port;
            Expires := Ada.Real_Time.Clock +
              Ada.Real_Time.To_Time_Span (Max_Age);
            Available := True;
         end if;
      end Remember;

      procedure Clear is
      begin
         Available := False;
      end Clear;

      procedure Preferred
        (Now     : Ada.Real_Time.Time;
         Present : out Boolean;
         Port    : out Port_Number)
      is
      begin
         if Available and then Now >= Expires then
            Available := False;
         end if;
         Present := Available;
         Port := UDP_Port;
      end Preferred;
   end HTTP_3_Discovery;

   type Resolver_Configuration_Access is access
     Flyology.IO.DNS.Resolver_Configuration;

   type Client_State (Capacity : Positive) is limited record
      Manager       : aliased Connections.Server (Capacity => Capacity);
      Pool          : Pool_Controller (Capacity);
      Lifetime      : State_Lifetime;
      Backend       : Flyology.IO.TLS.Provider_Access := null;
      Origin_Value  : Origin;
      Protocol_Policy : Protocol_Mode := HTTP_1_Only;
      HTTP_3_Certificate : Flyology.Bytes.Unbounded_Bytes;
      HTTP_3_Alternative : HTTP_3_Discovery;
      Connect_Policy : Connect_Target_Filter := null;
      Transport      : Connect_Transport := Internet_Transport;
      Unix_Path      : Unbounded_String;
      Resolver       : Resolver_Configuration_Access := null;
      Is_Configured : Boolean := False;
   end record;

   type Body_Mode is (No_Body, Fixed_Body, Chunked_Body, Until_Close_Body);
   type Response_Engine is
     (HTTP_1_Response, HTTP_2_Response, HTTP_3_Response);

   type Response_Data is record
      Owner          : Client_State_Access := null;
      Connection     : Pooled_Connection_Access := null;
      Slot_Index     : Natural := 0;
      Engine         : Response_Engine := HTTP_1_Response;
      HTTP_2_Stream  : H2_Connections.Stream_Handle :=
        H2_Connections.No_Stream;
      HTTP_3_Stream  : QUIC.Stream_ID := 0;
      HTTP_3_Handle  : H3_Connections.Stream_Handle :=
        H3_Connections.No_Stream;
      HTTP_3_Decoded_Length : QUIC.Stream_Offset := 0;
      HTTP_3_Last_Stream_Credit : QUIC.Stream_Offset := 0;
      Status_Value   : Status_Code := 200;
      Reason_Value   : Unbounded_String;
      Protocol_Value : Protocol := HTTP_1_1_Protocol;
      Version_Value  : HTTP_Version := HTTP_1_1;
      Fields         : Flyology.HTTP.Headers.List;
      Trailers       : Flyology.HTTP.Headers.List;
      Pending        : Unbounded_String;
      Mode           : Body_Mode := No_Body;
      Remaining_Body : Natural := 0;
      Chunk_Remaining : Natural := 0;
      Need_Chunk_CRLF : Boolean := False;
      Reading_Trailers : Boolean := False;
      Complete       : Boolean := False;
      Reusable       : Boolean := False;
      Verify_On_Reuse : Boolean := False;
      Request_Incomplete : Boolean := False;
      Saw_Response_Bytes : Boolean := False;
      Source_Failed      : Boolean := False;
      Informational_Count : Client_Policy.Informational_Count := 0;
      Retains_Owner  : Boolean := False;
      Started        : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Timeout        : Duration := 0.0;
   end record;

   type Client_Borrow is access all Client;
   type Request_Borrow is access constant Request;
   type Source_Borrow is access all Operation_Request_Body_Source'Class;
   type Sink_Borrow is access all Response_Body_Sink'Class;
   type Token_Borrow is access all Flyology.Cancellation.Token;
   type Completion_Set_Borrow is access all
     Flyology.Operations.Completion_Set'Class;

   type Legacy_Source_Borrow is access all Request_Body_Source'Class;
   type Synchronous_Source_Adapter is
     new Operation_Request_Body_Source with record
      Source   : Legacy_Source_Borrow := null;
      Length   : Body_Length := Unknown_Length;
      Deadline : Monotonic_Deadline := No_Deadline;
      Token    : Token_Borrow := null;
      Released : Boolean := False;
      Finish_Pending : Boolean := False;
   end record;

   overriding function Declared_Length
     (Item : Synchronous_Source_Adapter) return Body_Length;
   overriding procedure Read_Now
     (Item   : in out Synchronous_Source_Adapter;
      Data   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Source_Step_Kind);
   overriding procedure Source_Wait_Source
     (Item       : in out Synchronous_Source_Adapter;
      Required   : Source_Wait_Kind;
      Descriptor : out Flyology.IO.Descriptor;
      Ready_Now  : out Boolean);
   overriding procedure Release_Source
     (Item : in out Synchronous_Source_Adapter);

   type Exchange_Target is (Buffer_Target, Sink_Target, Response_Head_Target);
   type Exchange_Child_Kind is (No_Exchange_Child, Connect_Exchange_Child,
                                TLS_Exchange_Child,
                                DNS_Exchange_Child,
                                UDP_Send_Exchange_Child,
                                UDP_Receive_Exchange_Child);

   type HTTP_2_Exchange_Stage is
     (HTTP_2_Upload, HTTP_2_Response_Head, HTTP_2_Response_Body);

   type HTTP_3_Exchange_Stage is
     (HTTP_3_Handshake,
      HTTP_3_Start_Control,
      HTTP_3_Open_Request,
      HTTP_3_Send_Head,
      HTTP_3_Prepare_Retained,
      HTTP_3_Send_Retained,
      HTTP_3_Pull_Source,
      HTTP_3_Send_Source,
      HTTP_3_Send_Trailers,
      HTTP_3_Probe_Upload_Response,
      HTTP_3_Wait_Response_Head,
      HTTP_3_Read_Response_Body,
      HTTP_3_Return_Response_Credit,
      HTTP_3_Finish_Response_Body,
      HTTP_3_Cancel_Request,
      HTTP_3_Cancel_Complete,
      HTTP_3_Send_Flight);

   type Exchange_Driver_State is
     (Exchange_Idle,
      Waiting_For_Pool,
      Preparing_Connect,
      Preparing_Resolved_Address,
      Waiting_For_DNS,
      Waiting_For_Connect,
      Installing_Connection,
      Waiting_For_TLS,
      Starting_Reused_Verification,
      Waiting_For_Reused_Verification_Lease,
      Reading_Reused_Verification,
      Preparing_Verified_Request,
      Waiting_For_Connection_Lease,
      Sending_Head,
      Sending_Retained_Content,
      Pulling_Source,
      Sending_Source_Prefix,
      Sending_Source_Content,
      Sending_Source_Suffix,
      Sending_Source_End,
      Probing_Early_Response,
      Receiving_Head,
      Receiving_Content,
      HTTP_2_Protocol_Step,
      HTTP_2_Waiting_For_Pump,
      HTTP_2_Waiting_For_Connection_Lease,
      HTTP_2_Driving_Pump,
      HTTP_3_Starting,
      HTTP_3_Sending_Datagram,
      HTTP_3_Receiving_Datagram,
      HTTP_3_Protocol_Step,
      HTTP_3_Waiting_For_Pump,
      Cancelling_Child,
      Exchange_Done);

   subtype Exchange_Buffer_Index is Ada.Streams.Stream_Element_Offset range
     1 .. Ada.Streams.Stream_Element_Offset (Receive_Buffer_Size);
   subtype Exchange_Buffer is
     Ada.Streams.Stream_Element_Array (Exchange_Buffer_Index);
   Max_Resolved_Addresses : constant Positive := 16;
   type Resolved_Address_Array is array
     (Positive range 1 .. Max_Resolved_Addresses) of Sockets.IP_Address;
   type Stream_Element_Array_Access is access all
     Ada.Streams.Stream_Element_Array;

   type Exchange_State
     (Set : not null access Flyology.Operations.Completion_Set'Class)
   is limited record
      Result             : Exchange_Result;
      Saved_Error        : Ada.Exceptions.Exception_Occurrence;
      Has_Saved_Error    : Boolean := False;
      Failure_Cause      : Ada.Exceptions.Exception_Id :=
        Ada.Exceptions.Null_Id;
      Deadline           : Monotonic_Deadline := No_Deadline;
      Target             : Exchange_Target := Sink_Target;
      Driver_State       : Exchange_Driver_State := Exchange_Idle;
      Drain_Active       : Boolean := False;
      Active_Child       : Exchange_Child_Kind := No_Exchange_Child;
      Start_Rejected     : Boolean := False;
      Pending_Result     : Exchange_Result_Kind := Response_Complete;
      Client_Item        : Client_Borrow := null;
      Request_Item       : Request_Borrow := null;
      Source_Item        : Source_Borrow := null;
      Sink_Item          : Sink_Borrow := null;
      Token_Item         : Token_Borrow := null;
      Destination        : Flyology.Buffers.Drivers.Detached_Buffer;
      Destination_Moved  : Boolean := False;
      Source_Attached    : Boolean := False;
      Response_Length    : Natural := 0;
      Reply_Data         : Response_Data_Access := null;
      Connection         : Pooled_Connection_Access := null;
      Slot_Index         : Natural := 0;
      Was_Reused         : Boolean := False;
      Safe_Retry_Used    : Boolean := False;
      Pool_Waiter        : Boolean := False;
      Admission_Timeout_Recorded : Boolean := False;
      Creating           : Boolean := False;
      Resolved_Addresses : Resolved_Address_Array;
      Resolved_Count     : Natural range 0 .. Max_Resolved_Addresses := 0;
      Resolved_Next      : Natural range 1 .. Max_Resolved_Addresses + 1 := 1;
      Retry_Address_Pending : Boolean := False;
      Connection_Port    : Port_Number := Port_Number'First;
      Socket             : aliased Sockets.Socket_Type;
      Connect_Child      : Sockets.Connect_Operation (Set);
      DNS_Child          : Flyology.IO.DNS.Resolve_Operation (Set);
      TLS_Child          :
        Flyology.IO.Connections.TLS.Upgrade_Operation (Set);
      UDP_Send_Child     : Sockets.Send_Operation (Set);
      UDP_Receive_Child  : Sockets.Receive_Datagram_Operation (Set);
      IO                 : Connection_Drivers.Capability;
      HTTP_2_Stage       : HTTP_2_Exchange_Stage := HTTP_2_Response_Head;
      HTTP_2_Finished    : Boolean := False;
      HTTP_2_Upload_End  : Boolean := False;
      HTTP_2_Source_Waiting : Boolean := False;
      HTTP_2_Source_Wait : Source_Wait_Kind := Source_Needs_Read;
      HTTP_2_Cancelling : Boolean := False;
      HTTP_2_Settling   : Boolean := False;
      HTTP_2_Flush_Pending : Boolean := False;
      HTTP_2_Retryable_Refusal : Boolean := False;
      Metadata           : Response_Data;
      Request_Head       : Unbounded_String;
      Output_Cursor      : Natural := 0;
      Output_Limit       : Natural := 0;
      Buffer             : Exchange_Buffer := (others => 0);
      Buffer_First       : Natural := 1;
      Buffer_Last        : Natural := 0;
      Source_Length      : Body_Length := Unknown_Length;
      Source_Transferred : Body_Size := 0;
      Request_Content_Length : Natural := 0;
      Peer_Closed        : Boolean := False;
      Resume_After_Probe : Exchange_Driver_State := Receiving_Head;
      Expect_Waiting     : Boolean := False;
      HTTP_3_Flight      : QUIC.Datagram_Batch;
      HTTP_3_Flight_Next : Natural := 1;
      HTTP_3_Output      : aliased Ada.Streams.Stream_Element_Array
        (1 .. QUIC.Max_Datagram_Length) := (others => 0);
      HTTP_3_Output_Last : Natural := 0;
      HTTP_3_Output_Item : Stream_Element_Array_Access := null;
      HTTP_3_Input_Item  : Stream_Element_Array_Access := null;
      HTTP_3_Stage       : HTTP_3_Exchange_Stage := HTTP_3_Handshake;
      HTTP_3_After_Send  : HTTP_3_Exchange_Stage := HTTP_3_Handshake;
      HTTP_3_After_Flight : HTTP_3_Exchange_Stage := HTTP_3_Handshake;
      HTTP_3_After_Probe : HTTP_3_Exchange_Stage := HTTP_3_Handshake;
      HTTP_3_After_Credit : HTTP_3_Exchange_Stage := HTTP_3_Handshake;
      HTTP_3_Receive_Probe : Boolean := False;
      HTTP_3_Headers     : H3.Header_Block;
      HTTP_3_Send_Final  : Boolean := False;
      HTTP_3_Finished    : Boolean := False;
      HTTP_3_Cancelling  : Boolean := False;
      HTTP_3_Source_Waiting : Boolean := False;
      HTTP_3_Source_Wait_FD : Flyology.IO.Descriptor;
      HTTP_3_Source_Wait_For_Write : Boolean := False;
      HTTP_3_Body_Forbidden : Boolean := False;
      HTTP_3_Expected_Length : Length_Requirement := (others => <>);
      HTTP_3_Decoded_Length : Body_Size := 0;
      HTTP_3_Last_Stream_Credit : QUIC.Stream_Offset := 0;
      Creating_HTTP_3    : Boolean := False;
   end record;

   procedure Free_State is new Ada.Unchecked_Deallocation
     (Client_State, Client_State_Access);
   procedure Free_Resolver is new Ada.Unchecked_Deallocation
     (Flyology.IO.DNS.Resolver_Configuration,
      Resolver_Configuration_Access);
   procedure Free_Response_Data is new Ada.Unchecked_Deallocation
     (Response_Data, Response_Data_Access);
   procedure Free_Exchange_State is new Ada.Unchecked_Deallocation
     (Exchange_State, Exchange_State_Access);
   procedure Free_Stream_Element_Array is new Ada.Unchecked_Deallocation
     (Ada.Streams.Stream_Element_Array, Stream_Element_Array_Access);

   procedure Release_State (Item : in out Client_State_Access) is
   begin
      if Item /= null then
         Free_Resolver (Item.Resolver);
         Flyology.IO.TLS.Release (Item.Backend);
         Free_State (Item);
      end if;
   end Release_State;

   function Remaining
     (Started : Ada.Real_Time.Time; Timeout : Duration) return Duration is
   begin
      if Timeout < 0.0 then
         return Flyology.IO.Infinite;
      end if;
      return Flyology.Time_Math.Remaining
        (Timeout,
         Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started));
   end Remaining;

   function Deadline_After (Timeout : Duration) return Monotonic_Deadline is
   begin
      if Timeout < 0.0 then
         return No_Deadline;
      end if;
      return
        (Is_Limited => True,
         Value      =>
           Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Timeout));
   end Deadline_After;

   function Expired (Value : Monotonic_Deadline) return Boolean is
     (Value.Is_Limited and then Ada.Real_Time.Clock >= Value.Value);

   function Kind (Item : Exchange_Result) return Exchange_Result_Kind is
     (Item.Result_Kind);

   function Certainty (Item : Exchange_Result) return Admission_Certainty is
     (Item.Admission);

   function Phase (Item : Exchange_Result) return Exchange_Phase is
     (Item.Last_Phase);

   function Required_Body_Length
     (Item : Exchange_Result) return Length_Requirement is
     (Item.Required);

   function Failure_Detail (Item : Exchange_Result) return String is
     (To_String (Item.Detail));

   procedure Validate_Request (Value : Request);
   procedure Validate_Scoped_Encoding
     (Owner         : Client_State;
      Value         : Request;
      Has_Source    : Boolean;
      Source_Length : Body_Length);
   procedure Drive_Exchange_Engine
     (Item  : in out Exchange_Operation;
      Event : Flyology.Operations.Driver_Event);
   procedure Dispose_Connection
     (Connection : in out Pooled_Connection_Access);
   procedure Close_And_Finish
     (Owner      : not null Client_State_Access;
      Slot_Index : Positive;
      Connection : in out Pooled_Connection_Access);
   procedure Release_Lease
     (Data     : in out Response_Data;
      Reusable : Boolean;
      Verify   : Boolean := False);

   function Remaining (Value : Monotonic_Deadline) return Duration is
   begin
      if not Value.Is_Limited then
         return Flyology.IO.Infinite;
      elsif Ada.Real_Time.Clock >= Value.Value then
         return 0.0;
      else
         return Ada.Real_Time.To_Duration
           (Value.Value - Ada.Real_Time.Clock);
      end if;
   end Remaining;

   overriding function Declared_Length
     (Item : Synchronous_Source_Adapter) return Body_Length is
     (Item.Length);

   overriding procedure Read_Now
     (Item   : in out Synchronous_Source_Adapter;
      Data   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Result : out Source_Step_Kind)
   is
      Finished : Boolean;
   begin
      if Item.Source = null or else Item.Released then
         raise Program_Error with "synchronous source adapter is released";
      elsif Item.Finish_Pending then
         Last := Data'First - 1;
         Result := Source_Finished;
         Item.Finish_Pending := False;
         return;
      end if;
      Read
        (Item.Source.all, Data, Last, Finished, Remaining (Item.Deadline),
         Item.Token);
      if Finished and then Last < Data'First then
         Result := Source_Finished;
      else
         Result := Source_Progress;
         Item.Finish_Pending := Finished;
      end if;
   end Read_Now;

   overriding procedure Source_Wait_Source
     (Item       : in out Synchronous_Source_Adapter;
      Required   : Source_Wait_Kind;
      Descriptor : out Flyology.IO.Descriptor;
      Ready_Now  : out Boolean) is
   begin
      pragma Unreferenced (Item, Required, Descriptor, Ready_Now);
      raise Program_Error with
        "blocking synchronous source unexpectedly requested readiness";
   end Source_Wait_Source;

   overriding procedure Release_Source
     (Item : in out Synchronous_Source_Adapter) is
   begin
      Item.Released := True;
      Item.Source := null;
      Item.Token := null;
      Item.Finish_Pending := False;
   end Release_Source;

   procedure Remember_Failure
     (State : in out Exchange_State;
      Error : Ada.Exceptions.Exception_Occurrence)
   is
      Message : constant String := Ada.Exceptions.Exception_Name (Error);
      Last    : constant Natural := Natural'Min
        (Message'Length, Max_Failure_Detail_Bytes);
   begin
      if State.Failure_Cause = Ada.Exceptions.Null_Id then
         State.Failure_Cause := Ada.Exceptions.Exception_Identity (Error);
      end if;
      if Last = 0 then
         State.Result.Detail := Null_Unbounded_String;
      else
         State.Result.Detail := To_Unbounded_String
           (Message (Message'First .. Message'First + Last - 1));
      end if;
   end Remember_Failure;

   procedure Release_Exchange_Transport
     (State    : in out Exchange_State;
      Reusable : Boolean := False)
   is
      Failure : Failure_Result;
      Released : Pooled_Connection_Access := null;
      May_Reuse : Boolean := Reusable;

      procedure Save (Error : Ada.Exceptions.Exception_Occurrence) is
      begin
         if not State.Has_Saved_Error then
            Ada.Exceptions.Save_Occurrence (State.Saved_Error, Error);
            State.Has_Saved_Error := True;
         end if;
         Remember_Failure (State, Error);
      end Save;
   begin
      if Connection_Drivers.Is_Engaged (State.IO) then
         begin
            Connection_Drivers.Release (State.IO);
         exception
            when Error : others =>
               May_Reuse := False;
               Save (Error);
         end;
      end if;
      if State.Metadata.Engine = HTTP_2_Response
        and then State.Metadata.Connection /= null
        and then State.Metadata.Connection.HTTP_2 /= null
        and then State.Metadata.HTTP_2_Stream /= H2_Connections.No_Stream
      then
         if H2_Connections.Owns_Pump
           (State.Metadata.Connection.HTTP_2.all,
            State.Metadata.HTTP_2_Stream)
         then
            begin
               H2_Connections.Release_Pump
                 (State.Metadata.Connection.HTTP_2.all,
                  State.Metadata.HTTP_2_Stream);
            exception
               when Error : others =>
                  May_Reuse := False;
                  Save (Error);
            end;
         end if;
         if not State.HTTP_2_Finished then
            begin
               H2_Connections.Cancel_Stream
                 (State.Metadata.Connection.HTTP_2.all,
                  State.Metadata.HTTP_2_Stream);
               May_Reuse := False;
            exception
               when Error : others =>
                  May_Reuse := False;
                  Save (Error);
            end;
         end if;
         begin
            H2_Connections.Release_Stream
              (State.Metadata.Connection.HTTP_2.all,
               State.Metadata.HTTP_2_Stream);
            State.Metadata.HTTP_2_Stream := H2_Connections.No_Stream;
         exception
            when Error : others =>
               May_Reuse := False;
               Save (Error);
         end;
      end if;
      if State.Metadata.Engine = HTTP_3_Response
        and then State.Metadata.Connection /= null
        and then State.Metadata.HTTP_3_Handle /= H3_Connections.No_Stream
      then
         if H3_Connections.Owns_Pump
           (State.Metadata.Connection.HTTP_3_Streams,
            State.Metadata.HTTP_3_Handle)
         then
            begin
               H3_Connections.Release_Pump
                 (State.Metadata.Connection.HTTP_3_Streams,
                  State.Metadata.HTTP_3_Handle);
            exception
               when Error : others =>
                  May_Reuse := False;
                  Save (Error);
            end;
         end if;
         if not State.HTTP_3_Finished then
            begin
               H3_Connections.Cancel_Stream
                 (State.Metadata.Connection.HTTP_3_Streams,
                  State.Metadata.HTTP_3_Handle);
               May_Reuse := False;
            exception
               when Error : others =>
                  May_Reuse := False;
                  Save (Error);
            end;
         end if;
         begin
            H3_Connections.Release_Stream
              (State.Metadata.Connection.HTTP_3_Streams,
               State.Metadata.HTTP_3_Handle);
            State.Metadata.HTTP_3_Handle := H3_Connections.No_Stream;
         exception
            when Error : others =>
               May_Reuse := False;
               Save (Error);
         end;
      end if;
      if State.Pool_Waiter and then State.Client_Item /= null
        and then State.Client_Item.Control.State /= null
      then
         begin
            State.Client_Item.Control.State.Pool.Unregister_Waiter;
            State.Pool_Waiter := False;
         exception
            when Error : others => Save (Error);
         end;
      end if;
      if State.Creating and then State.Slot_Index > 0
        and then State.Client_Item /= null
        and then State.Client_Item.Control.State /= null
      then
         begin
            Released := State.Connection;
            State.Client_Item.Control.State.Pool.Creation_Failed
              (Positive (State.Slot_Index), Failure);
            State.Metadata.Connection := null;
            if Failure = Failure_Free and then Released /= null then
               Dispose_Connection (Released);
            end if;
            State.Connection := null;
            State.Slot_Index := 0;
            State.Creating := False;
         exception
            when Error : others => Save (Error);
         end;
      elsif State.Metadata.Connection /= null then
         begin
            Release_Lease
              (State.Metadata, May_Reuse,
               State.Metadata.Verify_On_Reuse);
            State.Connection := null;
            State.Slot_Index := 0;
            State.Creating := False;
         exception
            when Error : others => Save (Error);
         end;
      end if;
      if Sockets.Is_Open (State.Socket) then
         begin
            Sockets.Close_Socket (State.Socket);
         exception
            when others => null;
         end;
      end if;
   end Release_Exchange_Transport;

   procedure Release_Exchange_Borrows (State : in out Exchange_State) is
      Transport_Resolved : constant Boolean :=
        not State.Creating
          and then not State.Pool_Waiter
          and then State.Connection = null
          and then State.Metadata.Connection = null;
   begin
      if State.Source_Attached and then State.Source_Item /= null then
         begin
            Release_Source (State.Source_Item.all);
         exception
            when Error : others =>
               if not State.Has_Saved_Error then
                  Ada.Exceptions.Save_Occurrence
                    (State.Saved_Error, Error);
                  State.Has_Saved_Error := True;
               end if;
               Remember_Failure (State, Error);
         end;
      end if;
      State.Source_Attached := False;
      State.Request_Item := null;
      State.Source_Item := null;
      State.Sink_Item := null;
      State.Token_Item := null;
      State.Request_Head := Null_Unbounded_String;
      H3.Clear (State.HTTP_3_Headers);
      if Transport_Resolved then
         State.Client_Item := null;
         Flyology.HTTP.Headers.Clear (State.Metadata.Fields);
         Flyology.HTTP.Headers.Clear (State.Metadata.Trailers);
         State.Metadata.Reason_Value := Null_Unbounded_String;
         State.Metadata.Pending := Null_Unbounded_String;
         State.Metadata := (others => <>);
      end if;
      State.Buffer := (others => 0);
      State.HTTP_3_Output := (others => 0);
      Free_Stream_Element_Array (State.HTTP_3_Output_Item);
      Free_Stream_Element_Array (State.HTTP_3_Input_Item);
   end Release_Exchange_Borrows;

   procedure Complete_Exchange
     (Item    : in out Exchange_Operation;
      Kind    : Exchange_Result_Kind;
      Outcome : Flyology.Operations.Terminal_Outcome)
   is
   begin
      Item.State.Result.Result_Kind := Kind;
      Item.State.Driver_State := Exchange_Done;
      Item.State.Drain_Active := False;
      Release_Exchange_Borrows (Item.State.all);
      Flyology.Operations.Drivers.Complete (Item, Outcome);
   end Complete_Exchange;

   procedure Finish_Success (Item : in out Exchange_Operation);
   procedure Finish_Response_Head (Item : in out Exchange_Operation);
   procedure Observe_HTTP_3_Alternative
     (Item : in out Client; Fields : Flyology.HTTP.Headers.List);

   procedure Fail_Exchange
     (Item : in out Exchange_Operation;
      Kind : Exchange_Result_Kind;
      Outcome : Flyology.Operations.Terminal_Outcome :=
        Flyology.Operations.Failed)
   is
   begin
      if Item.State.Target = Response_Head_Target
        and then Item.State.Result.Admission = Possibly_Admitted
        and then Item.State.Was_Reused
        and then not Item.State.Safe_Retry_Used
        and then Item.State.Source_Item = null
        and then Is_Safe (Item.State.Request_Item.Method_Value)
        and then Kind in Connection_Failed | Transport_Failed |
          Response_Invalid
        and then not Item.State.Metadata.Saw_Response_Bytes
      then
         --  Ordinary synchronous GET/HEAD compatibility retains the legacy
         --  one-shot stale-connection recovery.  Only safe methods qualify:
         --  conditional PUT and every other mutation remain ambiguous after
         --  first handoff and are never replayed.
         Release_Exchange_Transport (Item.State.all, Reusable => False);
         Item.State.Client_Item.Control.State.Pool.Record_Stale_Retry;
         Item.State.Safe_Retry_Used := True;
         Item.State.Was_Reused := False;
         --  The replacement is allowed only for a safe method, but the first
         --  transport handoff remains observable: admission certainty is
         --  monotonic across an internal stale-connection retry.
         Item.State.Peer_Closed := False;
         Item.State.Metadata := (others => <>);
         Item.State.Request_Head := Null_Unbounded_String;
         Item.State.Output_Cursor := 0;
         Item.State.Output_Limit := 0;
         Item.State.Driver_State := Exchange_Idle;
         Flyology.Operations.Drivers.Reschedule (Item);
         return;
      end if;
      if Item.State.Result.Admission = Not_Admitted
        and then Item.State.Was_Reused
        and then Kind in Connection_Failed | Transport_Failed
      then
         --  A pooled transport can become stale between checkout and the
         --  first request handoff.  Replacing it is safe only while admission
         --  still proves that no request byte, frame, or datagram was handed
         --  off and therefore no source state was consumed.
         Release_Exchange_Transport (Item.State.all, Reusable => False);
         Item.State.Client_Item.Control.State.Pool.Record_Stale_Retry;
         Item.State.Was_Reused := False;
         Item.State.Peer_Closed := False;
         Item.State.Driver_State := Exchange_Idle;
         Flyology.Operations.Drivers.Reschedule (Item);
         return;
      end if;
      if Item.State.Result.Admission = Not_Admitted
        and then Item.State.Creating
        and then Kind in Connection_Failed | Transport_Failed |
          Response_Invalid
        and then
          (Item.State.Resolved_Next <= Item.State.Resolved_Count
             or else
               (Item.State.Creating_HTTP_3
                  and then Item.State.Client_Item /= null
                  and then Item.State.Client_Item.Control.State /= null
                  and then
                    Item.State.Client_Item.Control.State.Protocol_Policy =
                      Negotiate_HTTP_3))
      then
         Release_Exchange_Transport (Item.State.all, Reusable => False);
         if Item.State.Resolved_Next > Item.State.Resolved_Count then
            Item.State.Client_Item.Control.State.HTTP_3_Alternative.Clear;
            Item.State.Creating_HTTP_3 := False;
            Item.State.Connection_Port :=
              Port (Item.State.Client_Item.Control.State.Origin_Value);
            Item.State.Resolved_Next := 1;
         end if;
         Item.State.Retry_Address_Pending := True;
         Item.State.Driver_State := Exchange_Idle;
         Flyology.Operations.Drivers.Reschedule (Item);
         return;
      end if;
      if Kind = Transport_Failed
        and then Item.State.Metadata.Engine = HTTP_3_Response
        and then Item.State.Metadata.Connection /= null
      then
         H3_Connections.Fail_All
           (Item.State.Metadata.Connection.HTTP_3_Streams);
      end if;
      if Item.State.HTTP_3_Cancelling then
         Item.State.HTTP_3_Cancelling := False;
         Item.State.HTTP_3_Finished := True;
         if Item.State.Pending_Result = Response_Complete then
            Item.State.Metadata.Reusable := False;
            Finish_Success (Item);
         else
            Release_Exchange_Transport (Item.State.all, Reusable => False);
            Complete_Exchange
              (Item, Item.State.Pending_Result,
               (if Item.State.Pending_Result = Cancelled
                then Flyology.Operations.Cancelled
                else Flyology.Operations.Failed));
         end if;
         return;
      end if;
      if Item.State.HTTP_2_Cancelling then
         Item.State.HTTP_2_Cancelling := False;
         Item.State.HTTP_2_Finished := True;
         if Item.State.Pending_Result = Response_Complete then
            Item.State.Metadata.Reusable := False;
            Finish_Success (Item);
         else
            Release_Exchange_Transport (Item.State.all, Reusable => False);
            Complete_Exchange
              (Item, Item.State.Pending_Result,
               (if Item.State.Pending_Result = Cancelled
                then Flyology.Operations.Cancelled
                else Flyology.Operations.Failed));
         end if;
         return;
      end if;
      if Item.State.Metadata.Engine = HTTP_2_Response
        and then Item.State.Metadata.Connection /= null
        and then Item.State.Metadata.Connection.HTTP_2 /= null
        and then Item.State.Metadata.HTTP_2_Stream /=
          H2_Connections.No_Stream
        and then not Item.State.HTTP_2_Finished
        and then Kind /= Transport_Failed
        and then H2_Connections.Is_Usable
          (Item.State.Metadata.Connection.HTTP_2.all)
      then
         Item.State.Pending_Result := Kind;
         Item.State.Drain_Active := True;
         Item.State.HTTP_2_Cancelling := True;
         --  A cancellation can arrive while the owner pump's connection
         --  capability is armed. Disarm and relinquish that claim before the
         --  reset-drain pass reacquires it on this same owner stack.
         if H2_Connections.Owns_Pump
           (Item.State.Metadata.Connection.HTTP_2.all,
            Item.State.Metadata.HTTP_2_Stream)
         then
            H2_Connections.Release_Pump
              (Item.State.Metadata.Connection.HTTP_2.all,
               Item.State.Metadata.HTTP_2_Stream);
         end if;
         if Connection_Drivers.Is_Engaged (Item.State.IO) then
            Connection_Drivers.Release (Item.State.IO);
         end if;
         H2_Connections.Cancel_Stream
           (Item.State.Metadata.Connection.HTTP_2.all,
            Item.State.Metadata.HTTP_2_Stream);
         Item.State.Driver_State := HTTP_2_Waiting_For_Pump;
         Flyology.Operations.Drivers.Reschedule (Item);
         return;
      end if;
      if Item.State.Metadata.Engine = HTTP_3_Response
        and then Item.State.Metadata.Connection /= null
        and then Item.State.Metadata.HTTP_3_Handle /=
          H3_Connections.No_Stream
        and then not Item.State.HTTP_3_Finished
        and then not Item.State.HTTP_3_Cancelling
        and then Kind /= Transport_Failed
        and then H3_Connections.Is_Usable
          (Item.State.Metadata.Connection.HTTP_3_Streams)
      then
         Item.State.Pending_Result := Kind;
         Item.State.Drain_Active := True;
         Item.State.HTTP_3_Cancelling := True;
         Item.State.HTTP_3_Stage := HTTP_3_Cancel_Request;
         H3_Connections.Signal_Outbound
           (Item.State.Metadata.Connection.HTTP_3_Streams,
            Item.State.Metadata.HTTP_3_Handle);
         Item.State.Driver_State := HTTP_3_Waiting_For_Pump;
         Flyology.Operations.Drivers.Reschedule (Item);
         return;
      end if;
      Release_Exchange_Transport (Item.State.all, Reusable => False);
      Complete_Exchange (Item, Kind, Outcome);
   end Fail_Exchange;

   procedure Finish_Success (Item : in out Exchange_Operation) is
      State : Exchange_State renames Item.State.all;
   begin
      if State.Client_Item /= null then
         Observe_HTTP_3_Alternative
           (State.Client_Item.all, State.Metadata.Fields);
      end if;
      State.Reply_Data := new Response_Data;
      State.Reply_Data.Status_Value := State.Metadata.Status_Value;
      State.Reply_Data.Reason_Value := State.Metadata.Reason_Value;
      State.Reply_Data.Protocol_Value := State.Metadata.Protocol_Value;
      State.Reply_Data.Version_Value := State.Metadata.Version_Value;
      State.Reply_Data.Fields := State.Metadata.Fields;
      State.Reply_Data.Trailers := State.Metadata.Trailers;
      State.Reply_Data.Complete := True;
      Release_Exchange_Transport
        (State, Reusable => State.Metadata.Reusable);
      Complete_Exchange
        (Item, Response_Complete, Flyology.Operations.Succeeded);
   exception
      when Error : others =>
         Remember_Failure (State, Error);
         Fail_Exchange (Item, Transport_Failed);
   end Finish_Success;

   procedure Finish_Response_Head (Item : in out Exchange_Operation) is
      State : Exchange_State renames Item.State.all;
      Candidate : Response_Data_Access := null;
   begin
      --  The private synchronous adapter terminalizes its operation at the
      --  final response head, transferring the live response stream and pool
      --  lease into Response.  The ordinary public scoped operations never
      --  use this target and still terminalize only after the complete body.
      if State.Client_Item /= null then
         Observe_HTTP_3_Alternative
           (State.Client_Item.all, State.Metadata.Fields);
      end if;
      if Connection_Drivers.Is_Engaged (State.IO) then
         Connection_Drivers.Release (State.IO);
      end if;
      if State.Metadata.Engine = HTTP_2_Response
        and then State.Metadata.Connection /= null
        and then State.Metadata.Connection.HTTP_2 /= null
        and then State.Metadata.HTTP_2_Stream /= H2_Connections.No_Stream
        and then H2_Connections.Owns_Pump
          (State.Metadata.Connection.HTTP_2.all,
           State.Metadata.HTTP_2_Stream)
      then
         H2_Connections.Release_Pump
           (State.Metadata.Connection.HTTP_2.all,
            State.Metadata.HTTP_2_Stream);
      elsif State.Metadata.Engine = HTTP_3_Response
        and then State.Metadata.Connection /= null
        and then State.Metadata.HTTP_3_Handle /= H3_Connections.No_Stream
        and then H3_Connections.Owns_Pump
          (State.Metadata.Connection.HTTP_3_Streams,
           State.Metadata.HTTP_3_Handle)
      then
         H3_Connections.Release_Pump
           (State.Metadata.Connection.HTTP_3_Streams,
            State.Metadata.HTTP_3_Handle);
      end if;

      Candidate := new Response_Data'(State.Metadata);
      Candidate.Started := Ada.Real_Time.Clock;
      Candidate.Timeout := Remaining (State.Deadline);
      Candidate.Owner.Lifetime.Retain_Response;
      Candidate.Retains_Owner := True;
      State.Reply_Data := Candidate;
      Candidate := null;

      --  Ownership is now exclusively in Reply_Data.  Clearing these aliases
      --  before Complete_Exchange prevents terminal borrow cleanup from
      --  returning or resetting the transferred stream.
      State.Connection := null;
      State.Slot_Index := 0;
      State.Creating := False;
      State.Metadata := (others => <>);
      Complete_Exchange
        (Item, Response_Complete, Flyology.Operations.Succeeded);
   exception
      when Error : others =>
         if Candidate /= null then
            Candidate.Connection := null;
            if Candidate.Retains_Owner and then Candidate.Owner /= null then
               declare
                  Owner : Client_State_Access := Candidate.Owner;
                  Final_Reference : Boolean := False;
               begin
                  Owner.Lifetime.Release_Response (Final_Reference);
                  if Final_Reference then
                     Release_State (Owner);
                  end if;
               end;
               Candidate.Retains_Owner := False;
            end if;
            Free_Response_Data (Candidate);
         end if;
         Remember_Failure (State, Error);
         Fail_Exchange (Item, Transport_Failed);
   end Finish_Response_Head;

   procedure Start_Exchange
     (Operation : in out Exchange_Operation;
      Item      : not null access Client;
      Value     : not null access constant Request;
      Source    : access Operation_Request_Body_Source'Class;
      Sink      : access Response_Body_Sink'Class;
      Target    : Exchange_Target;
      Deadline  : Monotonic_Deadline;
      Token     : access Flyology.Cancellation.Token;
      Defer_Drive : Boolean := False)
   is
      Validation_Failed : Boolean := False;
   begin
      if Operation.State = null then
         Operation.State := new Exchange_State
           (Completion_Set_Borrow'(Operation.Set.all'Unchecked_Access));
      elsif Flyology.Buffers.Drivers.Has_Buffer
           (Operation.State.Destination)
      then
         raise Program_Error with
           "exchange operation still owns a response buffer";
      end if;

      Operation.State.Result :=
        (Result_Kind => Pre_Admission_Rejected,
         Admission   => Not_Admitted,
         Last_Phase  => Not_Started,
         Required    => (others => <>),
         Detail      => Null_Unbounded_String);
      Operation.State.Has_Saved_Error := False;
      Operation.State.Failure_Cause := Ada.Exceptions.Null_Id;
      Operation.State.Deadline := Deadline;
      Operation.State.Target := Target;
      Operation.State.Driver_State := Exchange_Idle;
      Operation.State.Drain_Active := False;
      Operation.State.Active_Child := No_Exchange_Child;
      Operation.State.Start_Rejected := False;
      Operation.State.Pending_Result := Response_Complete;
      Operation.State.Client_Item :=
        Client_Borrow'(Item.all'Unchecked_Access);
      Operation.State.Request_Item :=
        Request_Borrow'(Value.all'Unchecked_Access);
      Operation.State.Source_Item :=
        (if Source = null
         then null
         else Source_Borrow'(Source.all'Unchecked_Access));
      Operation.State.Sink_Item :=
        (if Sink = null
         then null
         else Sink_Borrow'(Sink.all'Unchecked_Access));
      Operation.State.Token_Item :=
        (if Token = null
         then null
         else Token_Borrow'(Token.all'Unchecked_Access));
      Operation.State.Destination_Moved := False;
      Operation.State.Source_Attached := False;
      Operation.State.Response_Length := 0;
      Operation.State.Admission_Timeout_Recorded := False;
      Operation.State.Safe_Retry_Used := False;
      Operation.State.Request_Head := Null_Unbounded_String;
      Operation.State.Output_Cursor := 0;
      Operation.State.Output_Limit := 0;
      Operation.State.Buffer_First := 1;
      Operation.State.Buffer_Last := 0;
      Operation.State.Source_Transferred := 0;
      Operation.State.Request_Content_Length := 0;
      Operation.State.Peer_Closed := False;
      Operation.State.Resolved_Count := 0;
      Operation.State.Resolved_Next := 1;
      Operation.State.Retry_Address_Pending := False;
      Operation.State.Connection_Port := Port_Number'First;
      Operation.State.Resume_After_Probe := Receiving_Head;
      Operation.State.Expect_Waiting := False;
      Operation.State.HTTP_2_Stage := HTTP_2_Response_Head;
      Operation.State.HTTP_2_Finished := False;
      Operation.State.HTTP_2_Upload_End := False;
      Operation.State.HTTP_2_Source_Waiting := False;
      Operation.State.HTTP_2_Source_Wait := Source_Needs_Read;
      Operation.State.HTTP_2_Cancelling := False;
      Operation.State.HTTP_2_Settling := False;
      Operation.State.HTTP_2_Flush_Pending := False;
      Operation.State.HTTP_2_Retryable_Refusal := False;
      Operation.State.HTTP_3_Stage := HTTP_3_Handshake;
      Operation.State.HTTP_3_Flight.Count := 0;
      Operation.State.HTTP_3_Flight_Next := 1;
      Operation.State.HTTP_3_Output_Last := 0;
      Operation.State.HTTP_3_Receive_Probe := False;
      Free_Stream_Element_Array (Operation.State.HTTP_3_Output_Item);
      if Operation.State.HTTP_3_Input_Item = null then
         Operation.State.HTTP_3_Input_Item := new
           Ada.Streams.Stream_Element_Array
             (1 .. Ada.Streams.Stream_Element_Offset
               (QUIC.Max_Datagram_Length));
      end if;
      Operation.State.HTTP_3_Finished := False;
      Operation.State.HTTP_3_Cancelling := False;
      Operation.State.HTTP_3_Source_Waiting := False;
      Operation.State.HTTP_3_Body_Forbidden := False;
      Operation.State.HTTP_3_Expected_Length := (others => <>);
      Operation.State.HTTP_3_Decoded_Length := 0;
      Operation.State.HTTP_3_Last_Stream_Credit := 0;
      Operation.State.Creating_HTTP_3 := False;
      H3.Clear (Operation.State.HTTP_3_Headers);

      if Item.Control.State = null
        or else not Item.Control.State.Is_Configured
      then
         Operation.State.Result.Result_Kind := Client_Unavailable;
         Operation.State.Start_Rejected := True;
      elsif Token /= null and then Token.Requested then
         Operation.State.Result.Result_Kind := Cancelled;
         Operation.State.Start_Rejected := True;
      elsif Expired (Deadline) then
         Operation.State.Result.Result_Kind := Timed_Out;
         Operation.State.Start_Rejected := True;
      else
         begin
            Validate_Request (Value.all);
            if Value.Redirects.Mode /= Return_Redirects then
               raise Constraint_Error with
                 "scoped exchanges do not follow redirects";
            elsif Value.Expect_Continue
              and then Target /= Response_Head_Target
            then
               raise Constraint_Error with
                 "scoped exchanges do not support Expect: 100-continue";
            elsif Value.Expect_Continue
              and then Item.Control.State.Protocol_Policy /= HTTP_1_Only
            then
               raise Constraint_Error with
                 "Expect: 100-continue is HTTP/1.1-only";
            elsif Value.Expect_Continue
              and then Flyology.Bytes.Length (Value.Body_Value) = 0
              and then
                (Source = null
                   or else
                     (Operation.State.Source_Length.Is_Known
                        and then Operation.State.Source_Length.Bytes = 0))
            then
               raise Constraint_Error with
                 "Expect: 100-continue requires a nonempty request body";
            end if;
            if Source /= null then
               Operation.State.Source_Length := Declared_Length (Source.all);
               if Flyology.Bytes.Length (Value.Body_Value) /= 0 then
                  raise Constraint_Error with
                    "a scoped request source cannot accompany a retained body";
               elsif Operation.State.Source_Length.Is_Known
                 and then Flyology.HTTP.Headers.Count
                   (Value.Trailer_Fields) > 0
               then
                  raise Constraint_Error with
                    "known-length scoped sources cannot carry trailers";
               end if;
            else
               Operation.State.Source_Length := Unknown_Length;
               if Flyology.HTTP.Headers.Count (Value.Trailer_Fields) > 0 then
                  raise Constraint_Error with
                    "retained scoped bodies cannot carry trailers";
               end if;
            end if;
            if Value.Expect_Continue
              and then Flyology.Bytes.Length (Value.Body_Value) = 0
              and then Source /= null
              and then Operation.State.Source_Length.Is_Known
              and then Operation.State.Source_Length.Bytes = 0
            then
               raise Constraint_Error with
                 "Expect: 100-continue requires a nonempty request body";
            end if;
            Validate_Scoped_Encoding
              (Item.Control.State.all, Value.all, Source /= null,
               Operation.State.Source_Length);
         exception
            when Constraint_Error | Request_Body_Error =>
               Validation_Failed := True;
         end;
         if Validation_Failed then
            Operation.State.Result.Result_Kind :=
              Pre_Admission_Rejected;
            Operation.State.Start_Rejected := True;
         end if;
      end if;
      Flyology.Operations.Drivers.Start (Operation);
      if Operation.State.Start_Rejected or else not Defer_Drive then
         Flyology.Operations.Drive
           (Flyology.Operations.Operation'Class (Operation),
            Flyology.Operations.Start_Operation);
      end if;
   exception
      when others =>
         if Operation.State /= null then
            Release_Exchange_Borrows (Operation.State.all);
         end if;
         if Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         raise;
   end Start_Exchange;

   package body Scoped is
      function Exchange_To_Buffer
        (Set         : not null access
           Flyology.Operations.Completion_Set'Class;
         Item        : not null access Client;
         Value       : not null access constant Request;
         Destination : in out Flyology.Buffers.Unique_Buffer;
         Deadline    : Monotonic_Deadline;
         Token       : access Flyology.Cancellation.Token := null)
         return Exchange_Operation
      is
      begin
         return Result : Exchange_Operation (Set) do
            Start (Result, Item, Value, Destination, Deadline, Token);
         end return;
      end Exchange_To_Buffer;

      function Exchange_To_Buffer
        (Set         : not null access
           Flyology.Operations.Completion_Set'Class;
         Item        : not null access Client;
         Value       : not null access constant Request;
         Source      : not null access Operation_Request_Body_Source'Class;
         Destination : in out Flyology.Buffers.Unique_Buffer;
         Deadline    : Monotonic_Deadline;
         Token       : access Flyology.Cancellation.Token := null)
         return Exchange_Operation
      is
      begin
         return Result : Exchange_Operation (Set) do
            Start
              (Result, Item, Value, Source, Destination, Deadline, Token);
         end return;
      end Exchange_To_Buffer;

      function Exchange_To_Sink
        (Set      : not null access
           Flyology.Operations.Completion_Set'Class;
         Item     : not null access Client;
         Value    : not null access constant Request;
         Sink     : not null access Response_Body_Sink'Class;
         Deadline : Monotonic_Deadline;
         Token    : access Flyology.Cancellation.Token := null)
         return Exchange_Operation
      is
      begin
         return Result : Exchange_Operation (Set) do
            Start (Result, Item, Value, Sink, Deadline, Token);
         end return;
      end Exchange_To_Sink;

      function Exchange_To_Sink
        (Set      : not null access
           Flyology.Operations.Completion_Set'Class;
         Item     : not null access Client;
         Value    : not null access constant Request;
         Source   : not null access Operation_Request_Body_Source'Class;
         Sink     : not null access Response_Body_Sink'Class;
         Deadline : Monotonic_Deadline;
         Token    : access Flyology.Cancellation.Token := null)
         return Exchange_Operation
      is
      begin
         return Result : Exchange_Operation (Set) do
            Start (Result, Item, Value, Source, Sink, Deadline, Token);
         end return;
      end Exchange_To_Sink;

      procedure Start
        (Operation   : in out Exchange_Operation;
         Item        : not null access Client;
         Value       : not null access constant Request;
         Destination : in out Flyology.Buffers.Unique_Buffer;
         Deadline    : Monotonic_Deadline;
         Token       : access Flyology.Cancellation.Token := null)
      is
      begin
         Start_Exchange
           (Operation, Item, Value, null, null, Buffer_Target, Deadline,
            Token, Defer_Drive => True);
         if Operation.State.Start_Rejected then
            return;
         end if;
         begin
            Flyology.Buffers.Drivers.Move_From
              (Destination, Operation.State.Destination);
            Operation.State.Destination_Moved := True;
            Flyology.Operations.Drive
              (Flyology.Operations.Operation'Class (Operation),
               Flyology.Operations.Start_Operation);
         exception
            when others =>
               if Operation.State.Destination_Moved then
                  Flyology.Buffers.Drivers.Move_To
                    (Operation.State.Destination, Destination);
                  Operation.State.Destination_Moved := False;
               end if;
               if Flyology.Operations.Is_Active (Operation) then
                  Flyology.Operations.Drivers.Rollback_Start (Operation);
               end if;
               Release_Exchange_Borrows (Operation.State.all);
               raise;
         end;
      end Start;

      procedure Start
        (Operation   : in out Exchange_Operation;
         Item        : not null access Client;
         Value       : not null access constant Request;
         Source      : not null access Operation_Request_Body_Source'Class;
         Destination : in out Flyology.Buffers.Unique_Buffer;
         Deadline    : Monotonic_Deadline;
         Token       : access Flyology.Cancellation.Token := null)
      is
      begin
         Start_Exchange
           (Operation, Item, Value, Source, null, Buffer_Target, Deadline,
            Token, Defer_Drive => True);
         if Operation.State.Start_Rejected then
            return;
         end if;
         begin
            Flyology.Buffers.Drivers.Move_From
              (Destination, Operation.State.Destination);
            Operation.State.Destination_Moved := True;
            Operation.State.Source_Attached := True;
            Flyology.Operations.Drive
              (Flyology.Operations.Operation'Class (Operation),
               Flyology.Operations.Start_Operation);
         exception
            when others =>
               if Operation.State.Destination_Moved then
                  Flyology.Buffers.Drivers.Move_To
                    (Operation.State.Destination, Destination);
                  Operation.State.Destination_Moved := False;
               end if;
               Release_Exchange_Borrows (Operation.State.all);
               if Flyology.Operations.Is_Active (Operation) then
                  Flyology.Operations.Drivers.Rollback_Start (Operation);
               end if;
               raise;
         end;
      end Start;

      procedure Start
        (Operation : in out Exchange_Operation;
         Item      : not null access Client;
         Value     : not null access constant Request;
         Sink      : not null access Response_Body_Sink'Class;
         Deadline  : Monotonic_Deadline;
         Token     : access Flyology.Cancellation.Token := null)
      is
      begin
         Start_Exchange
           (Operation, Item, Value, null, Sink, Sink_Target, Deadline, Token);
      end Start;

      procedure Start
        (Operation : in out Exchange_Operation;
         Item      : not null access Client;
         Value     : not null access constant Request;
         Source    : not null access Operation_Request_Body_Source'Class;
         Sink      : not null access Response_Body_Sink'Class;
         Deadline  : Monotonic_Deadline;
         Token     : access Flyology.Cancellation.Token := null)
      is
      begin
         Start_Exchange
           (Operation, Item, Value, Source, Sink, Sink_Target, Deadline,
            Token, Defer_Drive => True);
         if Operation.State.Start_Rejected then
            return;
         end if;
         Operation.State.Source_Attached := True;
         begin
            Flyology.Operations.Drive
              (Flyology.Operations.Operation'Class (Operation),
               Flyology.Operations.Start_Operation);
         exception
            when others =>
               Release_Exchange_Borrows (Operation.State.all);
               if Flyology.Operations.Is_Active (Operation) then
                  Flyology.Operations.Drivers.Rollback_Start (Operation);
               end if;
               raise;
         end;
      end Start;

      function Admission
        (Operation : Exchange_Operation) return Admission_Certainty is
        (if Operation.State = null
         then Not_Admitted
         else Operation.State.Result.Admission);

      function Raw_Phase
        (Operation : Exchange_Operation) return Exchange_Phase is
        (if Operation.State = null
         then Not_Started
         elsif Operation.State.Drain_Active
         then Draining
         else Operation.State.Result.Last_Phase);

      procedure Finish
        (Operation : in out Exchange_Operation;
         Result    : out Exchange_Result;
         Reply     : out Response)
      is
      begin
         if Operation.State = null then
            raise Flyology.Operations.Operation_Error with
              "exchange operation has no state";
         elsif Operation.State.Target not in
           Sink_Target | Response_Head_Target
         then
            raise Program_Error with "buffer exchange requires buffer Finish";
         end if;
         Result := Operation.State.Result;
         Reply.Data := Operation.State.Reply_Data;
         Operation.State.Reply_Data := null;
         Flyology.Operations.Consume (Operation);
         if Operation.State.Has_Saved_Error then
            Ada.Exceptions.Raise_Exception
              (Ada.Exceptions.Exception_Identity
                 (Operation.State.Saved_Error),
               Ada.Exceptions.Exception_Message
                 (Operation.State.Saved_Error));
         end if;
      end Finish;

      procedure Finish
        (Operation   : in out Exchange_Operation;
         Result      : out Exchange_Result;
         Reply       : out Response;
         Destination : in out Flyology.Buffers.Unique_Buffer)
      is
      begin
         if Operation.State = null then
            raise Flyology.Operations.Operation_Error with
              "exchange operation has no state";
         elsif Operation.State.Target /= Buffer_Target then
            raise Program_Error with "sink exchange requires sink Finish";
         elsif Operation.State.Destination_Moved
           and then
             (Flyology.Buffers.Has_Buffer (Destination)
              or else not Flyology.Buffers.Drivers.Same_Pool
                (Operation.State.Destination, Destination))
         then
            raise Program_Error with
              "response destination is not vacant in the original pool";
         end if;

         Result := Operation.State.Result;
         Reply.Data := Operation.State.Reply_Data;
         Operation.State.Reply_Data := null;
         Flyology.Operations.Consume (Operation);
         if Operation.State.Destination_Moved then
            Flyology.Buffers.Drivers.Set_Length
              (Operation.State.Destination,
               (if Result.Result_Kind = Response_Complete
                then Operation.State.Response_Length
                else 0));
            Flyology.Buffers.Drivers.Move_To
              (Operation.State.Destination, Destination);
            Operation.State.Destination_Moved := False;
         end if;
         if Operation.State.Has_Saved_Error then
            Ada.Exceptions.Raise_Exception
              (Ada.Exceptions.Exception_Identity
                 (Operation.State.Saved_Error),
               Ada.Exceptions.Exception_Message
                 (Operation.State.Saved_Error));
         end if;
      end Finish;
   end Scoped;

   overriding procedure Drive
     (Item  : in out Exchange_Operation;
      Event : Flyology.Operations.Driver_Event)
   is
      function Active_Child_Is_Terminal return Boolean is
        (case Item.State.Active_Child is
            when Connect_Exchange_Child =>
               Flyology.Operations.Is_Terminal (Item.State.Connect_Child),
            when TLS_Exchange_Child =>
               Flyology.Operations.Is_Terminal (Item.State.TLS_Child),
            when DNS_Exchange_Child =>
               Flyology.Operations.Is_Terminal (Item.State.DNS_Child),
            when UDP_Send_Exchange_Child =>
               Flyology.Operations.Is_Terminal (Item.State.UDP_Send_Child),
            when UDP_Receive_Exchange_Child =>
               Flyology.Operations.Is_Terminal
                 (Item.State.UDP_Receive_Child),
            when No_Exchange_Child => False);
   begin
      if Item.State = null then
         raise Program_Error with "exchange operation has no state";
      elsif Item.State.Start_Rejected then
         Complete_Exchange
           (Item,
            Item.State.Result.Result_Kind,
            (if Item.State.Result.Result_Kind = Cancelled
             then Flyology.Operations.Cancelled
             else Flyology.Operations.Failed));
      elsif Item.State.Token_Item /= null
        and then Item.State.Token_Item.Requested
        and then not Item.State.HTTP_3_Cancelling
        and then not Item.State.HTTP_2_Cancelling
      then
         if Item.State.Active_Child /= No_Exchange_Child
           and then Event = Flyology.Operations.Dependency_Changed
           and then Active_Child_Is_Terminal
         then
            Item.State.Pending_Result := Cancelled;
            Item.State.Drain_Active := True;
            Item.State.Driver_State := Cancelling_Child;
            Drive_Exchange_Engine (Item, Event);
         else
            Request_Cancellation (Item);
         end if;
      elsif Expired (Item.State.Deadline)
        and then not Item.State.HTTP_3_Cancelling
        and then not Item.State.HTTP_2_Cancelling
      then
         if Item.State.Result.Last_Phase = Admission_Wait
           and then not Item.State.Admission_Timeout_Recorded
           and then Item.State.Client_Item /= null
           and then Item.State.Client_Item.Control.State /= null
         then
            Item.State.Client_Item.Control.State.Pool.Record_Admission_Timeout;
            Item.State.Admission_Timeout_Recorded := True;
         end if;
         if Item.State.Active_Child /= No_Exchange_Child then
            Item.State.Pending_Result := Timed_Out;
            Item.State.Drain_Active := True;
            Item.State.Driver_State := Cancelling_Child;
            if Event = Flyology.Operations.Dependency_Changed
              and then Active_Child_Is_Terminal
            then
               Drive_Exchange_Engine (Item, Event);
               return;
            end if;
            if Item.State.Active_Child = Connect_Exchange_Child then
               Flyology.Operations.Cancel (Item.State.Connect_Child);
            elsif Item.State.Active_Child = TLS_Exchange_Child then
               Flyology.Operations.Cancel (Item.State.TLS_Child);
            elsif Item.State.Active_Child = DNS_Exchange_Child then
               Flyology.Operations.Cancel (Item.State.DNS_Child);
            elsif Item.State.Active_Child = UDP_Send_Exchange_Child then
               Flyology.Operations.Cancel (Item.State.UDP_Send_Child);
            else
               Flyology.Operations.Cancel (Item.State.UDP_Receive_Child);
            end if;
         else
            Fail_Exchange (Item, Timed_Out);
         end if;
      else
         Drive_Exchange_Engine (Item, Event);
      end if;
   end Drive;

   overriding procedure Request_Cancellation
     (Item : in out Exchange_Operation)
   is
   begin
      if Item.State /= null and then Flyology.Operations.Is_Active (Item) then
         Item.State.Pending_Result := Cancelled;
         Item.State.Drain_Active := True;
         if Item.State.Active_Child = Connect_Exchange_Child then
            Item.State.Driver_State := Cancelling_Child;
            Flyology.Operations.Cancel (Item.State.Connect_Child);
         elsif Item.State.Active_Child = TLS_Exchange_Child then
            Item.State.Driver_State := Cancelling_Child;
            Flyology.Operations.Cancel (Item.State.TLS_Child);
         elsif Item.State.Active_Child = DNS_Exchange_Child then
            Item.State.Driver_State := Cancelling_Child;
            Flyology.Operations.Cancel (Item.State.DNS_Child);
         elsif Item.State.Active_Child = UDP_Send_Exchange_Child then
            Item.State.Driver_State := Cancelling_Child;
            Flyology.Operations.Cancel (Item.State.UDP_Send_Child);
         elsif Item.State.Active_Child = UDP_Receive_Exchange_Child then
            Item.State.Driver_State := Cancelling_Child;
            Flyology.Operations.Cancel (Item.State.UDP_Receive_Child);
         else
            Fail_Exchange
              (Item, Cancelled, Flyology.Operations.Cancelled);
         end if;
      end if;
   exception
      when others =>
         null;
   end Request_Cancellation;

   overriding procedure Finalize (Item : in out Exchange_Operation) is
   begin
      begin
         Flyology.Operations.Finalize
           (Flyology.Operations.Operation (Item));
      exception
         when others => null;
      end;
      if Item.State /= null then
         Release_Exchange_Transport (Item.State.all, Reusable => False);
         if Item.State.Connection /= null
           or else Item.State.Metadata.Connection /= null
           or else Item.State.Creating
           or else Item.State.Pool_Waiter
         then
            --  Retry idempotent cleanup once after all operation children
            --  have been finalized. Never erase an unresolved pool lease.
            Release_Exchange_Transport
              (Item.State.all, Reusable => False);
         end if;
         Release_Exchange_Borrows (Item.State.all);
         if Item.State.Reply_Data /= null then
            Free_Response_Data (Item.State.Reply_Data);
         end if;
         Free_Stream_Element_Array (Item.State.HTTP_3_Output_Item);
         Free_Stream_Element_Array (Item.State.HTTP_3_Input_Item);
         if Item.State.Connection = null
           and then Item.State.Metadata.Connection = null
           and then not Item.State.Creating
           and then not Item.State.Pool_Waiter
         then
            Free_Exchange_State (Item.State);
         end if;
      end if;
   end Finalize;

   function Byte_Array (Value : String)
      return Ada.Streams.Stream_Element_Array
   is
      Result : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Value'Length));
   begin
      if Value'Length > 0 then
         for Offset in 0 .. Value'Length - 1 loop
            Result
              (Result'First + Ada.Streams.Stream_Element_Offset (Offset)) :=
              Ada.Streams.Stream_Element
                (Character'Pos (Value (Value'First + Offset)));
         end loop;
      end if;
      return Result;
   end Byte_Array;

   function Byte_String (Value : Ada.Streams.Stream_Element_Array)
      return String
   is
      Result : String (1 .. Natural (Value'Length));
      Cursor : Natural := 0;
   begin
      for Item of Value loop
         Cursor := Cursor + 1;
         Result (Cursor) := Character'Val (Item);
      end loop;
      return Result;
   end Byte_String;

   function Decimal (Value : Natural) return String is
      Text : constant String := Natural'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Decimal;

   function Decimal (Value : Body_Size) return String is
      Text : constant String := Body_Size'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Decimal;

   function Hexadecimal (Value : Natural) return String is
      Hex_Digits : constant String := "0123456789abcdef";
      Buffer : String (1 .. (Natural'Size + 3) / 4);
      Cursor : Natural := Buffer'Last;
      Rest   : Natural := Value;
   begin
      loop
         Buffer (Cursor) := Hex_Digits (Rest mod 16 + 1);
         Rest := Rest / 16;
         exit when Rest = 0;
         Cursor := Cursor - 1;
      end loop;
      return Buffer (Cursor .. Buffer'Last);
   end Hexadecimal;

   function Is_Default_Port (Value : Origin) return Boolean is
     ((Scheme (Value) = Plain_HTTP and then Port (Value) = 80)
        or else
      (Scheme (Value) = Secure_HTTPS and then Port (Value) = 443));

   function Host_Field (Value : Origin) return String is
      Name : constant String := Host (Value);
      Bracketed : constant String :=
        (if Ada.Strings.Fixed.Index (Name, ":") = 0
         then Name else "[" & Name & "]");
   begin
      return Bracketed &
        (if Is_Default_Port (Value) then ""
         else ":" & Decimal (Natural (Port (Value))));
   end Host_Field;

   procedure Dispose_Connection
     (Connection : in out Pooled_Connection_Access) is
   begin
      if Connection = null then
         return;
      end if;
      begin
         Connections.Close (Connection.Channel);
      exception
         when others => null;
      end;
      begin
         if Sockets.Is_Open (Connection.UDP) then
            if Connection.Protocol = HTTP_3_Transport then
               declare
                  Packet : QUIC.Datagram;
                  Status : QUIC.Send_Status := QUIC.Internal_State_Error;
                  Last   : Ada.Streams.Stream_Element_Offset;
               begin
                  if QUIC.Is_Connected (Connection.QUIC_Transport) then
                     QUIC.Build_Application_Close_Datagram
                       (Connection.QUIC_Transport, Packet, Status);
                  elsif QUIC.State (Connection.QUIC_Transport) in
                    QUIC.Client_Initial | QUIC.Client_Handshake
                  then
                     --  A connection abandoned mid-handshake still owes the
                     --  peer a close. Without it the server holds its
                     --  connection slot for the whole handshake timeout.
                     QUIC.Build_Handshake_Close_Datagram
                       (Connection.QUIC_Transport, Packet, Status);
                  end if;
                  if Status = QUIC.Sent and then Packet.Length > 0 then
                     Sockets.Send_Socket
                       (Connection.UDP,
                        Packet.Data
                          (1 .. Ada.Streams.Stream_Element_Offset
                            (Packet.Length)),
                        Last);
                  end if;
               exception
                  when others => null;
               end;
            end if;
            Sockets.Close_Socket (Connection.UDP);
         end if;
      exception
         when others => null;
      end;
      if Connection.HTTP_2 /= null then
         H2_Connections.Destroy (Connection.HTTP_2);
      end if;
      if Connection.HTTP_3_Event /= null then
         Free_HTTP_3_Event (Connection.HTTP_3_Event);
      end if;
      Free_Connection (Connection);
   end Dispose_Connection;

   procedure Close_And_Finish
     (Owner      : not null Client_State_Access;
      Slot_Index : Positive;
      Connection : in out Pooled_Connection_Access) is
   begin
      if Connection /= null then
         if Scheme (Owner.Origin_Value) = Secure_HTTPS
           and then Connection.Protocol = HTTP_1_Transport
         then
            begin
               Flyology.IO.Connections.TLS.Shutdown
                 (Connection.Channel, Timeout => 0.0);
            exception
               when others => null;
            end;
         end if;
         Dispose_Connection (Connection);
      end if;
      Owner.Pool.Finish_Close (Slot_Index);
   end Close_And_Finish;

   procedure Interrupt_Active (Owner : not null Client_State_Access) is
      Found       : Boolean;
      Slot_Index  : Natural;
      Connection  : Pooled_Connection_Access;
      Release_Ownership : Boolean;
      Released    : Pooled_Connection_Access;
   begin
      loop
         Owner.Pool.Take_Active_For_Interrupt
           (Found, Slot_Index, Connection);
         exit when not Found;
         begin
            if Connection.Protocol = HTTP_3_Transport then
               if Sockets.Is_Open (Connection.UDP) then
                  Sockets.Close_Socket (Connection.UDP);
               end if;
            else
               Connections.Close (Connection.Channel);
            end if;
         exception
            when others => null;
         end;
         Owner.Pool.Finish_Interrupt
           (Positive (Slot_Index), Release_Ownership, Released);
         if Release_Ownership and then Released /= null then
            Dispose_Connection (Released);
         end if;
      end loop;
   end Interrupt_Active;

   --  Verify marks a returned transport whose quiescence the response
   --  framing could not establish, so the next exchange probes it before
   --  writing a request onto it.
   procedure Release_Lease
     (Data     : in out Response_Data;
      Reusable : Boolean;
      Verify   : Boolean := False)
   is
      Result : Return_Result;
      Value  : Pooled_Connection_Access;
      Index  : constant Natural := Data.Slot_Index;
      Keep : constant Boolean := Reusable;
   begin
      if Data.Connection = null then
         Data.Complete := True;
         return;
      end if;
      Data.Owner.Pool.Return_Lease
        (Positive (Data.Slot_Index), Keep, Verify, Ada.Real_Time.Clock,
         Result, Value);
      Data.Connection := null;
      Data.Slot_Index := 0;
      Data.Complete := True;
      if Result = Return_Close then
         Close_And_Finish (Data.Owner, Positive (Index), Value);
      end if;
   end Release_Lease;

   procedure Abandon_Response (Data : in out Response_Data) is
      Reusable : Boolean := False;
   begin
      if Data.Connection = null then
         return;
      elsif Data.Engine = HTTP_2_Response then
         Reusable := H2_Connections.Is_Usable (Data.Connection.HTTP_2.all);
         if Data.HTTP_2_Stream /= H2_Connections.No_Stream then
            H2_Connections.Cancel_Stream
              (Data.Connection.HTTP_2.all, Data.HTTP_2_Stream);
            H2_Connections.Release_Stream
              (Data.Connection.HTTP_2.all, Data.HTTP_2_Stream);
            Data.HTTP_2_Stream := H2_Connections.No_Stream;
         end if;
      elsif Data.Engine = HTTP_3_Response then
         Reusable := False;
      end if;
      Release_Lease
        (Data, Reusable => Data.Engine = HTTP_2_Response and then Reusable);
   end Abandon_Response;

   procedure Set_Method (Item : in out Request; Value : Method) is
   begin
      Item.Method_Value := Value;
   end Set_Method;

   procedure Set_Target (Item : in out Request; Value : String) is
   begin
      if Value /= "*" and then
        (Value'Length = 0
        or else Value'Length > Max_Request_Target_Bytes
        or else Value (Value'First) /= '/'
        or else Ada.Strings.Fixed.Index (Value, "#") /= 0
        or else
          (for some Character_Value of Value =>
             Character_Value = ' '
               or else Character'Pos (Character_Value) < 32
               or else Character'Pos (Character_Value) > 126))
      then
         raise Constraint_Error with "invalid HTTP client request target";
      end if;
      Item.Target_Value := To_Unbounded_String (Value);
   end Set_Target;

   procedure Set_Redirects
     (Item : in out Request; Value : Redirect_Configuration) is
   begin
      Item.Redirects := Value;
   end Set_Redirects;

   procedure Add_Header
     (Item : in out Request; Name : String; Value : String)
   is
      Lower : constant String := Ada.Characters.Handling.To_Lower (Name);
   begin
      if Lower in
        "connection" | "content-length" | "expect" | "host" |
        "keep-alive" | "proxy-connection" | "te" | "trailer" |
        "transfer-encoding" | "upgrade"
      then
         raise Constraint_Error with
           "HTTP client controls framing and connection fields";
      end if;
      Flyology.HTTP.Headers.Add (Item.Fields, Name, Value);
   end Add_Header;

   procedure Set_Expect_Continue
     (Item         : in out Request;
      Enabled      : Boolean := True;
      Wait_Timeout : Duration := 1.0) is
   begin
      Item.Expect_Continue := Enabled;
      Item.Continue_Wait := Wait_Timeout;
   end Set_Expect_Continue;

   procedure Add_Trailer
     (Item : in out Request; Name : String; Value : String)
   is
      Lower : constant String := Ada.Characters.Handling.To_Lower (Name);
   begin
      if Lower in
        "authorization" | "connection" | "content-encoding" |
        "content-length" | "content-range" | "content-type" | "cookie" |
        "expect" | "host" | "if-match" | "if-modified-since" |
        "if-none-match" | "if-range" | "if-unmodified-since" |
        "keep-alive" | "max-forwards" | "proxy-authorization" |
        "proxy-connection" | "range" | "te" | "trailer" |
        "transfer-encoding" | "upgrade"
      then
         raise Constraint_Error with
           "field is prohibited in HTTP request trailers";
      elsif Flyology.HTTP.Headers.Count (Item.Trailer_Fields, Name) > 0 then
         raise Constraint_Error with
           "duplicate HTTP request trailer field";
      end if;
      Flyology.HTTP.Headers.Add (Item.Trailer_Fields, Name, Value);
   end Add_Trailer;

   procedure Set_Body (Item : in out Request; Value : String) is
   begin
      Item.Body_Value := Flyology.Bytes.From_Byte_String (Value);
   end Set_Body;

   procedure Set_Body
     (Item : in out Request; Value : Ada.Streams.Stream_Element_Array) is
   begin
      Item.Body_Value := Flyology.Bytes.To_Unbounded_Bytes (Value);
   end Set_Body;

   function Known_Length (Bytes : Body_Size) return Body_Length is
     (Is_Known => True, Bytes => Bytes);

   function Unix_Socket (Path : String) return Unix_Socket_Transport is
      Validated : constant Sockets.Unix_Path := Sockets.Unix_Pathname (Path);
   begin
      return (Path => To_Unbounded_String (Sockets.Image (Validated)));
   end Unix_Socket;

   procedure Load_Resolver (State : not null Client_State_Access) is
   begin
      State.Resolver := new Flyology.IO.DNS.Resolver_Configuration'
        (Flyology.IO.DNS.Load_Configuration);
   end Load_Resolver;

   procedure Configure
     (Item         : in out Client;
      Origin_Value : Origin;
      Pool         : Pool_Configuration := Default_Pool_Configuration;
      Connect_Policy : Connect_Target_Filter := null) is
   begin
      Configure (Item, Origin_Value, HTTP_1_Only, Pool, Connect_Policy);
   end Configure;

   procedure Configure
     (Item         : in out Client;
      Origin_Value : Origin;
      Mode         : Protocol_Mode;
      Pool         : Pool_Configuration := Default_Pool_Configuration;
      Connect_Policy : Connect_Target_Filter := null) is
   begin
      if Item.Control.State /= null then
         raise Program_Error with "HTTP client is already configured";
      elsif Scheme (Origin_Value) = Secure_HTTPS then
         raise Program_Error with "HTTPS client requires a TLS backend";
      elsif Mode in Negotiate_HTTP_2 | Require_HTTP_2 then
         raise Program_Error with
           "HTTP/2 negotiation requires an HTTPS origin";
      elsif Mode in Negotiate_HTTP_3 | Require_HTTP_3 then
         raise Program_Error with
           "HTTP/3 requires a pinned certificate Configure overload";
      end if;
      Item.Control.State := new Client_State (Item.Capacity);
      Load_Resolver (Item.Control.State);
      Item.Control.State.Origin_Value := Origin_Value;
      Item.Control.State.Protocol_Policy := Mode;
      Item.Control.State.Connect_Policy := Connect_Policy;
      Item.Control.State.Pool.Configure (Pool);
      Item.Control.State.Is_Configured := True;
   exception
      when others =>
         if Item.Control.State /= null
           and then not Item.Control.State.Is_Configured
         then
            Release_State (Item.Control.State);
         end if;
         raise;
   end Configure;

   procedure Configure
     (Item         : in out Client;
      Origin_Value : Origin;
      Transport    : Unix_Socket_Transport;
      Pool         : Pool_Configuration := Default_Pool_Configuration) is
   begin
      Configure (Item, Origin_Value, Transport, HTTP_1_Only, Pool);
   end Configure;

   procedure Configure
     (Item         : in out Client;
      Origin_Value : Origin;
      Transport    : Unix_Socket_Transport;
      Mode         : Protocol_Mode;
      Pool         : Pool_Configuration := Default_Pool_Configuration) is
   begin
      if Item.Control.State /= null then
         raise Program_Error with "HTTP client is already configured";
      elsif Scheme (Origin_Value) /= Plain_HTTP then
         raise Program_Error with
           "Unix socket HTTP transport requires a cleartext origin";
      elsif Mode not in HTTP_1_Only | HTTP_2_Prior_Knowledge then
         raise Program_Error with
           "Unix socket transport supports HTTP/1.1 or HTTP/2 prior knowledge";
      elsif Length (Transport.Path) = 0 then
         raise Program_Error with "Unix socket transport is not initialized";
      end if;
      Item.Control.State := new Client_State (Item.Capacity);
      Item.Control.State.Origin_Value := Origin_Value;
      Item.Control.State.Protocol_Policy := Mode;
      Item.Control.State.Transport := Unix_Domain_Transport;
      Item.Control.State.Unix_Path := Transport.Path;
      Item.Control.State.Pool.Configure (Pool);
      Item.Control.State.Is_Configured := True;
   exception
      when others =>
         if Item.Control.State /= null
           and then not Item.Control.State.Is_Configured
         then
            Release_State (Item.Control.State);
         end if;
         raise;
   end Configure;

   procedure Configure
     (Item         : in out Client;
      Origin_Value : Origin;
      Backend      : not null access Flyology.IO.TLS.Provider'Class;
      Pool         : Pool_Configuration := Default_Pool_Configuration;
      Connect_Policy : Connect_Target_Filter := null)
   is
   begin
      Configure
        (Item, Origin_Value, Backend, HTTP_1_Only, Pool, Connect_Policy);
   end Configure;

   procedure Configure
     (Item         : in out Client;
      Origin_Value : Origin;
      Backend      : not null access Flyology.IO.TLS.Provider'Class;
      Mode         : Protocol_Mode;
      Pool         : Pool_Configuration := Default_Pool_Configuration;
      Connect_Policy : Connect_Target_Filter := null)
   is
      Retained : Flyology.IO.TLS.Provider_Access := null;
   begin
      if Item.Control.State /= null then
         raise Program_Error with "HTTP client is already configured";
      elsif Mode in Negotiate_HTTP_2 | Require_HTTP_2
        and then Scheme (Origin_Value) /= Secure_HTTPS
      then
         raise Program_Error with
           "HTTP/2 negotiation requires an HTTPS origin";
      elsif Mode = HTTP_2_Prior_Knowledge
        and then Scheme (Origin_Value) /= Plain_HTTP
      then
         raise Program_Error with
           "HTTP/2 prior knowledge requires a cleartext HTTP origin";
      elsif Mode in Negotiate_HTTP_2 | Require_HTTP_2
        and then Backend.all not in Flyology.IO.TLS.ALPN.Provider'Class
      then
         raise Program_Error with
           "HTTP/2 negotiation requires an ALPN-capable TLS backend";
      elsif Mode in Negotiate_HTTP_3 | Require_HTTP_3 then
         raise Program_Error with
           "HTTP/3 requires a pinned certificate Configure overload";
      end if;
      Retained := Flyology.IO.TLS.Retain (Backend.all);
      Item.Control.State := new Client_State (Item.Capacity);
      Item.Control.State.Backend := Retained;
      Load_Resolver (Item.Control.State);
      Retained := null;
      Item.Control.State.Origin_Value := Origin_Value;
      Item.Control.State.Protocol_Policy := Mode;
      Item.Control.State.Connect_Policy := Connect_Policy;
      Item.Control.State.Pool.Configure (Pool);
      Item.Control.State.Is_Configured := True;
   exception
      when others =>
         Flyology.IO.TLS.Release (Retained);
         if Item.Control.State /= null
           and then not Item.Control.State.Is_Configured
         then
            Release_State (Item.Control.State);
         end if;
         raise;
   end Configure;

   procedure Configure
     (Item                   : in out Client;
      Origin_Value           : Origin;
      Mode                   : Protocol_Mode;
      HTTP_3_Certificate_DER : Ada.Streams.Stream_Element_Array;
      Pool                   : Pool_Configuration :=
        Default_Pool_Configuration;
      Connect_Policy         : Connect_Target_Filter := null) is
   begin
      if Item.Control.State /= null then
         raise Program_Error with "HTTP client is already configured";
      elsif Mode /= Require_HTTP_3 then
         raise Program_Error with
           "HTTP/3 without a TCP TLS backend requires Require_HTTP_3";
      elsif Scheme (Origin_Value) /= Secure_HTTPS then
         raise Program_Error with "HTTP/3 requires an HTTPS origin";
      elsif HTTP_3_Certificate_DER'Length not in 1 .. 4_096 then
         raise Program_Error with
           "HTTP/3 pinned certificate must contain 1 through 4096 bytes";
      end if;
      Item.Control.State := new Client_State (Item.Capacity);
      Load_Resolver (Item.Control.State);
      Item.Control.State.Origin_Value := Origin_Value;
      Item.Control.State.Protocol_Policy := Mode;
      Item.Control.State.HTTP_3_Certificate :=
        Flyology.Bytes.To_Unbounded_Bytes (HTTP_3_Certificate_DER);
      Item.Control.State.Connect_Policy := Connect_Policy;
      Item.Control.State.Pool.Configure (Pool);
      Item.Control.State.Is_Configured := True;
   exception
      when others =>
         if Item.Control.State /= null
           and then not Item.Control.State.Is_Configured
         then
            Release_State (Item.Control.State);
         end if;
         raise;
   end Configure;

   procedure Configure
     (Item                   : in out Client;
      Origin_Value           : Origin;
      Backend                : not null access Flyology.IO.TLS.Provider'Class;
      Mode                   : Protocol_Mode;
      HTTP_3_Certificate_DER : Ada.Streams.Stream_Element_Array;
      Pool                   : Pool_Configuration :=
        Default_Pool_Configuration;
      Connect_Policy         : Connect_Target_Filter := null)
   is
      Retained : Flyology.IO.TLS.Provider_Access := null;
   begin
      if Item.Control.State /= null then
         raise Program_Error with "HTTP client is already configured";
      elsif Mode not in Negotiate_HTTP_3 | Require_HTTP_3 then
         raise Program_Error with
           "HTTP/3 certificate overload requires an HTTP/3 mode";
      elsif Scheme (Origin_Value) /= Secure_HTTPS then
         raise Program_Error with "HTTP/3 requires an HTTPS origin";
      elsif HTTP_3_Certificate_DER'Length not in 1 .. 4_096 then
         raise Program_Error with
           "HTTP/3 pinned certificate must contain 1 through 4096 bytes";
      elsif Mode = Negotiate_HTTP_3
        and then Backend.all not in Flyology.IO.TLS.ALPN.Provider'Class
      then
         raise Program_Error with
           "HTTP/3 discovery requires an ALPN-capable TLS backend";
      end if;
      Retained := Flyology.IO.TLS.Retain (Backend.all);
      Item.Control.State := new Client_State (Item.Capacity);
      Item.Control.State.Backend := Retained;
      Load_Resolver (Item.Control.State);
      Retained := null;
      Item.Control.State.Origin_Value := Origin_Value;
      Item.Control.State.Protocol_Policy := Mode;
      Item.Control.State.HTTP_3_Certificate :=
        Flyology.Bytes.To_Unbounded_Bytes (HTTP_3_Certificate_DER);
      Item.Control.State.Connect_Policy := Connect_Policy;
      Item.Control.State.Pool.Configure (Pool);
      Item.Control.State.Is_Configured := True;
   exception
      when others =>
         Flyology.IO.TLS.Release (Retained);
         if Item.Control.State /= null
           and then not Item.Control.State.Is_Configured
         then
            Release_State (Item.Control.State);
         end if;
         raise;
   end Configure;

   function HTTP_3_Receive_Credit_Due
     (Connection         : Pooled_Connection;
      Stream_Consumed    : QUIC.Stream_Offset;
      Last_Stream_Credit : QUIC.Stream_Offset) return Boolean
   is
      Current : constant QUIC.Stream_Offset :=
        QUIC.Received_Data (Connection.QUIC_Transport);
   begin
      return Current - Connection.HTTP_3_Last_Credit_Data >=
        HTTP_3_Data_Credit_Interval
        or else
          (Stream_Consumed >= Last_Stream_Credit
           and then Stream_Consumed - Last_Stream_Credit >=
             HTTP_3_Transport_Settings.Max_Stream_Data_Bidi_Local / 2);
   end HTTP_3_Receive_Credit_Due;

   procedure Build_HTTP_3_Receive_Credit
     (Connection : in out Pooled_Connection;
      Stream_Consumed : QUIC.Stream_Offset;
      Last_Stream_Credit : in out QUIC.Stream_Offset;
      Now        : QUIC.Timestamp;
      Packet     : out QUIC.Datagram;
      Status     : out QUIC.Send_Status) is
   begin
      QUIC.Build_Receive_Credit_Datagram
        (Connection.QUIC_Transport,
         Connection_Window => HTTP_3_Transport_Settings.Max_Data,
         Direction => QUIC.Bidirectional,
         Maximum_Streams => HTTP_3_Transport_Settings.Max_Streams_Bidi,
         Now => Now, Packet => Packet, Status => Status);
      if Status = QUIC.Sent then
         Connection.HTTP_3_Last_Credit_Data :=
           QUIC.Received_Data (Connection.QUIC_Transport);
         Last_Stream_Credit := Stream_Consumed;
      end if;
   end Build_HTTP_3_Receive_Credit;

   package HTTP_3_Internals is
      procedure Read_Response_Body
        (Item     : in out Response;
         Data     : out Ada.Streams.Stream_Element_Array;
         Last     : out Ada.Streams.Stream_Element_Offset;
         Finished : out Boolean;
         Token    : access Flyology.Cancellation.Token);

      function Is_Usable
        (Connection : Pooled_Connection_Access) return Boolean;
   end HTTP_3_Internals;

   package body HTTP_3_Internals is separate;

   procedure Validate_Request (Value : Request) is
      Body_Length : constant Natural :=
        Flyology.Bytes.Length (Value.Body_Value);
   begin
      if Image (Value.Method_Value) = "CONNECT" then
         raise Constraint_Error with "CONNECT requests are unsupported";
      elsif Image (Value.Method_Value) = "TRACE" and then Body_Length > 0 then
         raise Constraint_Error with "TRACE requests cannot contain a body";
      elsif To_String (Value.Target_Value) = "*"
        and then Image (Value.Method_Value) /= "OPTIONS"
      then
         raise Constraint_Error with "asterisk target requires OPTIONS";
      end if;
   end Validate_Request;

   package HTTP_1_Internals is
      function Request_Head
        (State         : Client_State;
         Value         : Request;
         Streaming     : Boolean;
         Stream_Length : Body_Length;
         Use_Expectation : Boolean) return String;

      procedure Parse_Available_Final_Head
        (Data     : in out Response_Data;
         Complete : out Boolean);

      procedure Select_Body_Mode
        (Data                : in out Response_Data;
         Request_Method      : Method;
         Release_Immediately : Boolean := True);

      procedure Consume_Available_Content
        (Data       : in out Response_Data;
         Output     : out Ada.Streams.Stream_Element_Array;
         Last       : out Ada.Streams.Stream_Element_Offset;
         Complete   : out Boolean;
         Need_Input : out Boolean;
         Peer_Closed : Boolean := False);

      procedure Validate_Response
        (Value : Ada.Streams.Stream_Element_Array);

      procedure Read_Response_Body
        (Item     : in out Response;
         Data     : out Ada.Streams.Stream_Element_Array;
         Last     : out Ada.Streams.Stream_Element_Offset;
         Finished : out Boolean;
         Token    : access Flyology.Cancellation.Token);
   end HTTP_1_Internals;

   package body HTTP_1_Internals is separate;

   procedure Validate_Scoped_Encoding
     (Owner         : Client_State;
      Value         : Request;
      Has_Source    : Boolean;
      Source_Length : Body_Length)
   is
      Retained_Length : constant Natural :=
        Flyology.Bytes.Length (Value.Body_Value);
      Has_Content_Length : constant Boolean :=
        Retained_Length > 0
          or else (Has_Source and then Source_Length.Is_Known);
      Content_Length : constant Body_Size :=
        (if Retained_Length > 0 then Body_Size (Retained_Length)
         elsif Has_Source and then Source_Length.Is_Known
         then Source_Length.Bytes
         else 0);

      procedure Validate_H1 is
         Head : constant String := HTTP_1_Internals.Request_Head
           (Owner, Value, Streaming => Has_Source,
            Stream_Length => Source_Length, Use_Expectation => False);
         pragma Unreferenced (Head);
      begin
         null;
      end Validate_H1;

      procedure Validate_H2 is
         Head : constant Flyology.Bytes.Unbounded_Bytes :=
           H2_Requests.Encode_Head
             (Method_Text => Image (Value.Method_Value),
              Scheme_Text =>
                (if Scheme (Owner.Origin_Value) = Secure_HTTPS
                 then "https" else "http"),
              Authority => Host_Field (Owner.Origin_Value),
              Target => To_String (Value.Target_Value),
              Fields => Value.Fields,
              Has_Content_Length => Has_Content_Length,
              Content_Length => Long_Long_Integer (Content_Length),
              Expect_Continue => False);
         pragma Unreferenced (Head);
      begin
         if Has_Source
           and then Flyology.HTTP.Headers.Count (Value.Trailer_Fields) > 0
         then
            declare
               Trailers : constant Flyology.Bytes.Unbounded_Bytes :=
                 H2_Requests.Encode_Trailers (Value.Trailer_Fields);
               pragma Unreferenced (Trailers);
            begin
               null;
            end;
         end if;
      end Validate_H2;

      procedure Validate_H3_Fields
        (Fields : Flyology.HTTP.Headers.List) is
      begin
         if Flyology.HTTP.Headers.Count (Fields) > H3.Max_Fields then
            raise Constraint_Error with "too many HTTP/3 fields";
         end if;
         for Index in 1 .. Flyology.HTTP.Headers.Count (Fields) loop
            declare
               Name : constant String := Ada.Characters.Handling.To_Lower
                 (Flyology.HTTP.Headers.Name (Fields, Index));
               Field_Value : constant String :=
                 Flyology.HTTP.Headers.Value (Fields, Index);
            begin
               if Name'Length not in 1 .. H3.Max_Name_Length
                 or else Field_Value'Length > H3.Max_Value_Length
               then
                  raise Constraint_Error with "HTTP/3 field exceeds bound";
               elsif Name in
                 "connection" | "host" | "keep-alive" |
                 "proxy-connection" | "transfer-encoding" | "upgrade"
                 or else
                   (Name = "te"
                      and then Ada.Characters.Handling.To_Lower
                        (Field_Value) /= "trailers")
               then
                  raise Constraint_Error with
                    "connection-specific field cannot be encoded for HTTP/3";
               end if;
            end;
         end loop;
      end Validate_H3_Fields;

      procedure Validate_H3 is
         Automatic_Fields : constant Natural :=
           4 + (if Has_Content_Length then 1 else 0);
      begin
         if Image (Value.Method_Value)'Length > H3.Max_Value_Length
           or else Host_Field (Owner.Origin_Value)'Length > H3.Max_Value_Length
           or else To_String (Value.Target_Value)'Length > H3.Max_Value_Length
           or else Flyology.HTTP.Headers.Count (Value.Fields) +
             Automatic_Fields > H3.Max_Fields
         then
            raise Constraint_Error with
              "request pseudo-fields exceed scoped HTTP/3 bounds";
         end if;
         Validate_H3_Fields (Value.Fields);
         if Has_Source then
            Validate_H3_Fields (Value.Trailer_Fields);
         end if;
      end Validate_H3;
   begin
      case Owner.Protocol_Policy is
         when HTTP_1_Only =>
            Validate_H1;
         when HTTP_2_Prior_Knowledge | Require_HTTP_2 =>
            Validate_H2;
         when Negotiate_HTTP_2 =>
            Validate_H1;
            Validate_H2;
         when Require_HTTP_3 =>
            Validate_H3;
         when Negotiate_HTTP_3 =>
            Validate_H1;
            Validate_H2;
            Validate_H3;
      end case;
   end Validate_Scoped_Encoding;

   procedure Drive_Exchange_Engine
     (Item  : in out Exchange_Operation;
      Event : Flyology.Operations.Driver_Event)
   is
      State : Exchange_State renames Item.State.all;
      Owner : Client_State_Access renames State.Client_Item.Control.State;

      package Byte_Pointers is new System.Address_To_Access_Conversions
        (Ada.Streams.Stream_Element);

      procedure Reschedule is
      begin
         Flyology.Operations.Drivers.Reschedule (Item);
      end Reschedule;

      procedure Fail_HTTP_3_Connection
        (Kind : Exchange_Result_Kind := Transport_Failed) is
      begin
         if State.Metadata.Connection /= null then
            H3_Connections.Fail_All
              (State.Metadata.Connection.HTTP_3_Streams);
         end if;
         Fail_Exchange (Item, Kind);
      end Fail_HTTP_3_Connection;

      procedure Arm_Operation_Deadline is
      begin
         if State.Deadline.Is_Limited then
            Flyology.Operations.Drivers.Arm_Deadline
              (Item, Remaining (State.Deadline));
         end if;
      end Arm_Operation_Deadline;

      procedure Arm_Pool is
         Sources : Flyology.Operations.Drivers.Readiness_Source_Array
           (1 .. 3);
         Count     : Natural := 0;
         FD        : Flyology.IO.Descriptor;
         Requested : Boolean;
      begin
         Owner.Pool.Wait_Source (FD => FD, Can_Checkout => Requested);
         if Requested then
            Reschedule;
            return;
         end if;
         Count := Count + 1;
         Sources (Count) := (Descriptor => FD, For_Write => False);
         Owner.Pool.Shutdown_Source (FD, Requested);
         if Requested then
            Fail_Exchange (Item, Client_Unavailable);
            return;
         end if;
         Count := Count + 1;
         Sources (Count) := (Descriptor => FD, For_Write => False);
         if State.Token_Item /= null then
            State.Token_Item.Wait_Source (FD, Requested);
            if Requested then
               Fail_Exchange
                 (Item, Cancelled, Flyology.Operations.Cancelled);
               return;
            end if;
            Count := Count + 1;
            Sources (Count) := (Descriptor => FD, For_Write => False);
         end if;
         Flyology.Operations.Drivers.Arm_Readiness
           (Item, Sources (1 .. Count));
         Arm_Operation_Deadline;
      end Arm_Pool;

      procedure Arm_Transport
        (Required : Connection_Drivers.Step_Result) is
      begin
         Connection_Drivers.Arm_Transport (State.IO, Item, Required);
         Connection_Drivers.Arm_Deadline (State.IO, Item);
      end Arm_Transport;

      function HTTP_3_Now return QUIC.Timestamp is
         Elapsed : constant Duration := Ada.Real_Time.To_Duration
           (Ada.Real_Time.Clock - State.Connection.HTTP_3_Epoch);
      begin
         return QUIC.Timestamp
           (Long_Long_Integer (Duration'Max (0.0, Elapsed) * 1_000_000.0));
      end HTTP_3_Now;

      procedure Release_HTTP_3_Pump is
      begin
         if State.Connection /= null
           and then State.Metadata.HTTP_3_Handle /= H3_Connections.No_Stream
           and then H3_Connections.Owns_Pump
             (State.Connection.HTTP_3_Streams,
              State.Metadata.HTTP_3_Handle)
         then
            H3_Connections.Release_Pump
              (State.Connection.HTTP_3_Streams,
               State.Metadata.HTTP_3_Handle);
         end if;
      end Release_HTTP_3_Pump;

      procedure Arm_HTTP_3_Pump_Wait is
         Sources : Flyology.Operations.Drivers.Readiness_Source_Array
           (1 .. 3);
         Count : Natural := 0;
         FD : Flyology.IO.Descriptor;
         Ready : Boolean;
      begin
         H3_Connections.Wait_Source
           (State.Connection.HTTP_3_Streams,
            State.Metadata.HTTP_3_Handle, FD, Ready);
         if Ready then
            Reschedule;
            return;
         end if;
         H3_Connections.Pump_Wait_Source
           (State.Connection.HTTP_3_Streams,
            State.Metadata.HTTP_3_Handle, FD, Ready);
         if Ready then
            Reschedule;
            return;
         end if;
         Count := Count + 1;
         Sources (Count) := (Descriptor => FD, For_Write => False);
         Owner.Pool.Shutdown_Source (FD, Ready);
         if Ready then
            Fail_Exchange (Item, Client_Unavailable);
            return;
         end if;
         Count := Count + 1;
         Sources (Count) := (Descriptor => FD, For_Write => False);
         if State.Token_Item /= null then
            State.Token_Item.Wait_Source (FD, Ready);
            if Ready then
               Fail_Exchange
                 (Item, Cancelled, Flyology.Operations.Cancelled);
               return;
            end if;
            Count := Count + 1;
            Sources (Count) := (Descriptor => FD, For_Write => False);
         end if;
         Flyology.Operations.Drivers.Arm_Readiness
           (Item, Sources (1 .. Count));
         Arm_Operation_Deadline;
      end Arm_HTTP_3_Pump_Wait;

      procedure Need_HTTP_3_Pump is
         Claimed : Boolean;
         FD : Flyology.IO.Descriptor;
         Stream_Ready : Boolean;
      begin
         H3_Connections.Wait_Source
           (State.Connection.HTTP_3_Streams,
            State.Metadata.HTTP_3_Handle, FD, Stream_Ready);
         if Stream_Ready then
            State.Driver_State := HTTP_3_Protocol_Step;
            Reschedule;
            return;
         end if;
         H3_Connections.Try_Claim_Pump
           (State.Connection.HTTP_3_Streams,
            State.Metadata.HTTP_3_Handle, Claimed);
         if Claimed then
            H3_Connections.Consume_Outbound
              (State.Connection.HTTP_3_Streams,
               State.Metadata.HTTP_3_Handle);
            State.Driver_State := HTTP_3_Protocol_Step;
            Reschedule;
         else
            State.Driver_State := HTTP_3_Waiting_For_Pump;
            Arm_HTTP_3_Pump_Wait;
         end if;
      end Need_HTTP_3_Pump;

      procedure Yield_HTTP_3_Pump is
      begin
         Release_HTTP_3_Pump;
         State.Driver_State := HTTP_3_Waiting_For_Pump;
         Arm_HTTP_3_Pump_Wait;
      end Yield_HTTP_3_Pump;

      procedure Queue_HTTP_3_Packet
        (Packet : QUIC.Datagram;
         After_Send : HTTP_3_Exchange_Stage) is
      begin
         if Packet.Length = 0 then
            State.HTTP_3_Stage := After_Send;
            Reschedule;
            return;
         end if;
         State.HTTP_3_Output_Last := Packet.Length;
         Free_Stream_Element_Array (State.HTTP_3_Output_Item);
         State.HTTP_3_Output_Item := new
           Ada.Streams.Stream_Element_Array'
             (Packet.Data
                (1 .. Ada.Streams.Stream_Element_Offset (Packet.Length)));
         State.HTTP_3_After_Send := After_Send;
         Sockets.Send
           (Socket    => State.Connection.UDP'Unchecked_Access,
            Item      => State.HTTP_3_Output_Item,
            Timeout   => Remaining (State.Deadline),
            Operation => State.UDP_Send_Child);
         State.Active_Child := UDP_Send_Exchange_Child;
         State.Driver_State := HTTP_3_Sending_Datagram;
         Flyology.Operations.Continue_After (Item, State.UDP_Send_Child);
      end Queue_HTTP_3_Packet;

      procedure Queue_HTTP_3_Flight
        (Flight : QUIC.Datagram_Batch;
         After_Flight : HTTP_3_Exchange_Stage) is
      begin
         State.HTTP_3_Flight := Flight;
         State.HTTP_3_Flight_Next := 1;
         State.HTTP_3_After_Flight := After_Flight;
         State.HTTP_3_Stage := HTTP_3_Send_Flight;
         State.Driver_State := HTTP_3_Protocol_Step;
         Reschedule;
      end Queue_HTTP_3_Flight;

      procedure Prepare_HTTP_2_Request is
         Header_Block : Flyology.Bytes.Unbounded_Bytes;
         Handle       : H2_Connections.Stream_Handle;
         Accepted     : Boolean;
         Retained_Length : constant Natural := Flyology.Bytes.Length
           (State.Request_Item.Body_Value);
         Has_Content_Length : constant Boolean :=
           Retained_Length > 0
             or else
               (State.Source_Item /= null
                  and then State.Source_Length.Is_Known);
         Content_Length : constant Body_Size :=
           (if Retained_Length > 0
            then Body_Size (Retained_Length)
            elsif State.Source_Item /= null
              and then State.Source_Length.Is_Known
            then State.Source_Length.Bytes
            else 0);
      begin
         if State.Connection.HTTP_2 = null then
            Fail_Exchange (Item, Client_Unavailable);
            return;
         end if;
         Header_Block := H2_Requests.Encode_Head
           (Method_Text => Image (State.Request_Item.Method_Value),
            Scheme_Text =>
              (if Scheme (Owner.Origin_Value) = Secure_HTTPS
               then "https" else "http"),
            Authority => Host_Field (Owner.Origin_Value),
            Target => To_String (State.Request_Item.Target_Value),
            Fields => State.Request_Item.Fields,
            Has_Content_Length => Has_Content_Length,
            Content_Length => Long_Long_Integer (Content_Length),
            Expect_Continue => False);
         H2_Connections.Open
           (State.Connection.HTTP_2.all,
            Flyology.Bytes.To_Array (Header_Block),
            Flyology.Bytes.Empty,
            Streaming => State.Source_Item /= null or else Retained_Length > 0,
            Head_Request => Image (State.Request_Item.Method_Value) = "HEAD",
            Handle => Handle,
            Accepted => Accepted);
         if not Accepted then
            Fail_Exchange (Item, Client_Unavailable);
            return;
         end if;
         State.Metadata.Engine := HTTP_2_Response;
         State.Metadata.HTTP_2_Stream := Handle;
         State.Metadata.Protocol_Value := HTTP_2_Protocol;
         State.Metadata.Version_Value := HTTP_1_1;
         State.Result.Admission := Possibly_Admitted;
         State.Result.Last_Phase :=
           (if State.Source_Item = null and then Retained_Length = 0
            then Waiting_Response_Head else Sending_Request_Body);
         State.Source_Transferred := 0;
         State.Request_Content_Length := Retained_Length;
         State.Output_Cursor := 1;
         State.HTTP_2_Stage :=
           (if State.Source_Item = null and then Retained_Length = 0
            then HTTP_2_Response_Head else HTTP_2_Upload);
         State.Driver_State := HTTP_2_Protocol_Step;
         Reschedule;
      end Prepare_HTTP_2_Request;

      procedure Prepare_HTTP_3_Request is
         Handle : H3_Connections.Stream_Handle;
         Accepted : Boolean;
         Retained_Length : constant Natural := Flyology.Bytes.Length
           (State.Request_Item.Body_Value);

         procedure Add (Name, Value : String) is
         begin
            if H3.Header_Count (State.HTTP_3_Headers) = H3.Max_Fields then
               raise Flyology.HTTP.Headers.Headers_Too_Large;
            end if;
            H3.Append
              (State.HTTP_3_Headers, H3.Make_Field (Name, Value));
         end Add;
      begin
         State.Metadata := (others => <>);
         State.Metadata.Owner := Owner;
         State.Metadata.Connection := State.Connection;
         State.Metadata.Slot_Index := State.Slot_Index;
         State.Metadata.Engine := HTTP_3_Response;
         State.Metadata.Protocol_Value := HTTP_3_Protocol;
         State.Metadata.Started := Ada.Real_Time.Clock;
         State.Metadata.Timeout := Remaining (State.Deadline);
         H3.Clear (State.HTTP_3_Headers);
         Add (":method", Image (State.Request_Item.Method_Value));
         Add (":scheme", "https");
         Add (":path", To_String (State.Request_Item.Target_Value));
         Add (":authority", Host_Field (Owner.Origin_Value));
         for Index in 1 .. Flyology.HTTP.Headers.Count
           (State.Request_Item.Fields)
         loop
            Add
              (Ada.Characters.Handling.To_Lower
                 (Flyology.HTTP.Headers.Name
                    (State.Request_Item.Fields, Index)),
               Flyology.HTTP.Headers.Value
                 (State.Request_Item.Fields, Index));
         end loop;
         if Retained_Length > 0 then
            Add ("content-length", Decimal (Retained_Length));
         elsif State.Source_Item /= null
           and then State.Source_Length.Is_Known
         then
            Add ("content-length", Decimal (State.Source_Length.Bytes));
         end if;
         H3_Connections.Reserve
           (State.Connection.HTTP_3_Streams, Handle, Accepted,
            Head_Request => Image (State.Request_Item.Method_Value) = "HEAD");
         if not Accepted then
            Fail_Exchange (Item, Client_Unavailable);
            return;
         end if;
         State.Metadata.HTTP_3_Handle := Handle;
         State.Request_Content_Length := Retained_Length;
         State.Source_Transferred := 0;
         State.Output_Cursor := 1;
         State.HTTP_3_Stage := HTTP_3_Open_Request;
         State.Result.Last_Phase := Sending_Request_Head;
         H3_Connections.Signal_Outbound
           (State.Connection.HTTP_3_Streams, Handle);
         Need_HTTP_3_Pump;
      end Prepare_HTTP_3_Request;

      procedure Prepare_Request is
         Acquisition : Connection_Drivers.Acquisition_Result;
      begin
         if State.Connection.Protocol = HTTP_2_Transport then
            State.Metadata := (others => <>);
            State.Metadata.Owner := Owner;
            State.Metadata.Connection := State.Connection;
            State.Metadata.Slot_Index := State.Slot_Index;
            State.Metadata.Started := Ada.Real_Time.Clock;
            State.Metadata.Timeout := Remaining (State.Deadline);
            Prepare_HTTP_2_Request;
            return;
         elsif State.Connection.Protocol = HTTP_3_Transport then
            Prepare_HTTP_3_Request;
            return;
         elsif State.Connection.Protocol /= HTTP_1_Transport then
            Fail_Exchange (Item, Response_Invalid);
            return;
         end if;
         State.Metadata := (others => <>);
         State.Metadata.Owner := Owner;
         State.Metadata.Connection := State.Connection;
         State.Metadata.Slot_Index := State.Slot_Index;
         State.Metadata.Started := Ada.Real_Time.Clock;
         State.Metadata.Timeout := Remaining (State.Deadline);
         State.Request_Head := To_Unbounded_String
           (HTTP_1_Internals.Request_Head
              (Owner.all,
               State.Request_Item.all,
               Streaming       => State.Source_Item /= null,
               Stream_Length   => State.Source_Length,
               Use_Expectation =>
                 State.Target = Response_Head_Target
                   and then State.Request_Item.Expect_Continue));
         State.Output_Cursor := 1;
         State.Output_Limit := Length (State.Request_Head);
         State.Request_Content_Length := Flyology.Bytes.Length
           (State.Request_Item.Body_Value);
         State.Source_Transferred := 0;
         Connection_Drivers.Start
           (State.IO, State.Connection.Channel'Unchecked_Access,
            Acquisition, Remaining (State.Deadline), State.Token_Item);
         if Acquisition = Connection_Drivers.Acquired then
            State.Driver_State := Sending_Head;
            State.Result.Last_Phase := Sending_Request_Head;
            Reschedule;
         else
            State.Driver_State := Waiting_For_Connection_Lease;
            Connection_Drivers.Arm_Acquisition (State.IO, Item);
            Connection_Drivers.Arm_Deadline (State.IO, Item);
         end if;
      end Prepare_Request;

      procedure Start_Reused_Verification is
         Result : Connection_Drivers.Acquisition_Result;
      begin
         Connection_Drivers.Start
           (State.IO, State.Connection.Channel'Unchecked_Access,
            Result, Remaining (State.Deadline), State.Token_Item);
         if Result = Connection_Drivers.Acquired then
            State.Driver_State := Reading_Reused_Verification;
            Reschedule;
         else
            State.Driver_State := Waiting_For_Reused_Verification_Lease;
            Connection_Drivers.Arm_Acquisition (State.IO, Item);
            Connection_Drivers.Arm_Deadline (State.IO, Item);
         end if;
      end Start_Reused_Verification;

      procedure Verify_Reused_Transport is
         Last   : Ada.Streams.Stream_Element_Offset;
         Result : Connection_Drivers.Step_Result;
      begin
         Connection_Drivers.Receive (State.IO, State.Buffer, Last, Result);
         case Result is
            when Connection_Drivers.Need_Read =>
               --  No delayed response octet is currently queued. The next
               --  owner step may encode and send the request on this lease.
               Connection_Drivers.Release (State.IO);
               State.Driver_State := Preparing_Verified_Request;
               Reschedule;
            when Connection_Drivers.Need_Write =>
               Connection_Drivers.Arm_Transport
                 (State.IO, Item, Connection_Drivers.Need_Write);
               Connection_Drivers.Arm_Deadline (State.IO, Item);
            when Connection_Drivers.Made_Progress |
                 Connection_Drivers.Peer_Closed =>
               --  Any octet before a request is a delayed/stray response;
               --  EOF is the ordinary stale-idle case. Neither transport can
               --  safely receive the caller's request.
               Connection_Drivers.Release (State.IO);
               Release_Exchange_Transport (State, Reusable => False);
               State.Was_Reused := False;
               State.Peer_Closed := False;
               State.Driver_State := Exchange_Idle;
               Reschedule;
         end case;
      end Verify_Reused_Transport;

      procedure Install_Connected_Socket is
      begin
         State.Connection := new Pooled_Connection;
         Connections.Take
           (Owner.Manager, State.Socket, State.Connection.Channel);
         Owner.Pool.Publish_Connecting
           (Positive (State.Slot_Index), State.Connection);
         if Scheme (Owner.Origin_Value) = Secure_HTTPS then
            State.Result.Last_Phase := Securing;
            if Owner.Protocol_Policy = HTTP_1_Only then
               Flyology.IO.Connections.TLS.Upgrade
                 (Item        => State.Connection.Channel'Unchecked_Access,
                  Backend     => Owner.Backend,
                  Side        => Flyology.IO.TLS.Client,
                  Server_Name => Host (Owner.Origin_Value),
                  Timeout     => Remaining (State.Deadline),
                  Token       => State.Token_Item,
                  Operation   => State.TLS_Child);
            else
               declare
                  use Flyology.IO.TLS.ALPN;
                  Protocols : Protocol_List := Offer ("h2");
               begin
                  if Owner.Protocol_Policy in
                    Negotiate_HTTP_2 | Negotiate_HTTP_3
                  then
                     Append (Protocols, "http/1.1");
                  end if;
                  Flyology.IO.Connections.TLS.Upgrade
                    (Item => State.Connection.Channel'Unchecked_Access,
                     Backend => Flyology.IO.TLS.ALPN.Provider'Class
                       (Owner.Backend.all)'Unchecked_Access,
                     Side => Flyology.IO.TLS.Client,
                     Server_Name => Host (Owner.Origin_Value),
                     Protocols => Protocols,
                     Timeout => Remaining (State.Deadline),
                     Token => State.Token_Item,
                     Operation => State.TLS_Child);
               end;
            end if;
            State.Driver_State := Waiting_For_TLS;
            State.Active_Child := TLS_Exchange_Child;
            Flyology.Operations.Continue_After (Item, State.TLS_Child);
         else
            State.Connection.Protocol :=
              (if Owner.Protocol_Policy = HTTP_2_Prior_Knowledge
               then HTTP_2_Transport else HTTP_1_Transport);
            if State.Connection.Protocol = HTTP_2_Transport then
               H2_Connections.Create
                 (State.Connection.HTTP_2);
            end if;
            Owner.Pool.Install
              (Positive (State.Slot_Index), State.Connection,
               Ada.Real_Time.Clock);
            State.Creating := False;
            Prepare_Request;
         end if;
      end Install_Connected_Socket;

      procedure Start_HTTP_3_Connection
        (Address : Sockets.IP_Address) is
         Destination : constant QUIC.Connection_ID :=
           QUIC.Random_Connection_ID;
         Source : constant QUIC.Connection_ID :=
           QUIC.Random_Connection_ID;
         Flight : QUIC.Datagram_Batch;
         Status : QUIC.Operation_Status;
         Server : constant Sockets.Endpoint :=
           (Family  => Address.Family,
            Address => Address,
            Port    => Sockets.Port (State.Connection_Port),
            Scope   => 0);
      begin
         Sockets.Create_Socket
           (State.Socket, Address.Family, Sockets.Socket_Datagram);
         Sockets.Prepare (State.Socket);
         Sockets.Connect_Socket (State.Socket, Server);
         State.Connection := new Pooled_Connection;
         State.Connection.HTTP_3_Event := new H3.Event;
         Sockets.Move (State.Socket, State.Connection.UDP);
         State.Connection.Protocol := HTTP_3_Transport;
         State.Connection.HTTP_3_Epoch := Ada.Real_Time.Clock;
         State.Metadata := (others => <>);
         State.Metadata.Owner := Owner;
         State.Metadata.Connection := State.Connection;
         State.Metadata.Slot_Index := State.Slot_Index;
         State.Metadata.Engine := HTTP_3_Response;
         Owner.Pool.Publish_Connecting
           (Positive (State.Slot_Index), State.Connection);
         QUIC.Initialize_Client
           (State.Connection.QUIC_Transport,
            Byte_Array ("h3"),
            QUIC.Transport_Settings'(others => <>),
            Flyology.Bytes.To_Array (Owner.HTTP_3_Certificate),
            Destination.Data
              (1 .. Ada.Streams.Stream_Element_Offset
                (Destination.Length)),
            Destination,
            Source);
         QUIC.Start_Client
           (State.Connection.QUIC_Transport, Flight, Status,
            HTTP_3_Now);
         if Status /= QUIC.Succeeded then
            raise Protocol_Error with
              "QUIC client start failed: " &
              QUIC.Operation_Status'Image (Status);
         end if;
         State.HTTP_3_Stage := HTTP_3_Handshake;
         Queue_HTTP_3_Flight (Flight, HTTP_3_Handshake);
      end Start_HTTP_3_Connection;

      procedure Start_Resolved_Address is
         Sources : Flyology.IO.Interrupt_Set (1 .. 2);
         Count : Natural := 0;
         FD : Flyology.IO.Descriptor;
         Requested : Boolean;
      begin
         State.Retry_Address_Pending := False;
         Owner.Pool.Shutdown_Source (FD, Requested);
         if Requested then
            Fail_Exchange (Item, Client_Unavailable);
            return;
         end if;
         Count := Count + 1;
         Sources (Count) := FD;
         if State.Token_Item /= null then
            State.Token_Item.Wait_Source (FD, Requested);
            if Requested then
               Fail_Exchange
                 (Item, Cancelled, Flyology.Operations.Cancelled);
               return;
            end if;
            Count := Count + 1;
            Sources (Count) := FD;
         end if;

         while State.Resolved_Next <= State.Resolved_Count loop
            declare
               Address : constant Sockets.IP_Address :=
                 State.Resolved_Addresses (State.Resolved_Next);
            begin
               State.Resolved_Next := State.Resolved_Next + 1;
               if Owner.Connect_Policy = null
                 or else Owner.Connect_Policy.all
                   (Host (Owner.Origin_Value), Sockets.Image (Address),
                    State.Connection_Port)
               then
                  --  The test seam widens this exact handoff boundary. Recheck
                  --  caller interruption afterward before creating a socket
                  --  or starting the retained connect/QUIC child.
                  Client_Test_Barrier (16);
                  if State.Token_Item /= null
                    and then State.Token_Item.Requested
                  then
                     Fail_Exchange
                       (Item, Cancelled, Flyology.Operations.Cancelled);
                     return;
                  elsif Expired (State.Deadline) then
                     Fail_Exchange (Item, Timed_Out);
                     return;
                  end if;
                  if State.Creating_HTTP_3 then
                     Start_HTTP_3_Connection (Address);
                  else
                     declare
                        Server : constant Sockets.Endpoint :=
                          (Family  => Address.Family,
                           Address => Address,
                           Port    => Sockets.Port (State.Connection_Port),
                           Scope   => 0);
                     begin
                        Sockets.Create_Socket
                          (State.Socket, Address.Family,
                           Sockets.Socket_Stream);
                        Sockets.Connect
                          (Socket     => State.Socket'Unchecked_Access,
                           Server     => Server,
                           Timeout    => Remaining (State.Deadline),
                           Operation  => State.Connect_Child,
                           Interrupts => Sources (1 .. Count));
                        State.Result.Last_Phase := Connecting;
                        State.Driver_State := Waiting_For_Connect;
                        State.Active_Child := Connect_Exchange_Child;
                        Flyology.Operations.Continue_After
                          (Item, State.Connect_Child);
                     end;
                  end if;
                  return;
               end if;
            end;
         end loop;
         Fail_Exchange (Item, Connection_Failed);
      end Start_Resolved_Address;

      procedure Start_Connect is
         Sources : Flyology.IO.Interrupt_Set (1 .. 2);
         Count     : Natural := 0;
         FD        : Flyology.IO.Descriptor;
         Requested : Boolean;
      begin
         Owner.Pool.Shutdown_Source (FD, Requested);
         if Requested then
            Fail_Exchange (Item, Client_Unavailable);
            return;
         end if;
         Count := Count + 1;
         Sources (Count) := FD;
         if State.Token_Item /= null then
            State.Token_Item.Wait_Source (FD, Requested);
            if Requested then
               Fail_Exchange
                 (Item, Cancelled, Flyology.Operations.Cancelled);
               return;
            end if;
            Count := Count + 1;
            Sources (Count) := FD;
         end if;

         State.Result.Last_Phase := Connecting;
         if Owner.Transport = Unix_Domain_Transport then
            Sockets.Create_Unix_Stream_Socket (State.Socket);
            Sockets.Connect
              (Socket     => State.Socket'Unchecked_Access,
               Server     => Sockets.Unix_Pathname
                 (To_String (Owner.Unix_Path)),
               Timeout    => Remaining (State.Deadline),
               Operation  => State.Connect_Child,
               Interrupts => Sources (1 .. Count));
         else
            declare
               Name    : constant String := Host (Owner.Origin_Value);
               Is_Numeric : constant Boolean :=
                 Name = "localhost"
                   or else Sockets.Is_IP_Address (Name, Sockets.IPv4)
                   or else Sockets.Is_IP_Address (Name, Sockets.IPv6);
               Address : Sockets.IP_Address := Sockets.Loopback_IPv4;
            begin
               if not Is_Numeric then
                  State.Result.Last_Phase := Resolving;
                  Client_Test_Barrier (15);
                  if State.Token_Item /= null
                    and then State.Token_Item.Requested
                  then
                     Fail_Exchange
                       (Item, Cancelled, Flyology.Operations.Cancelled);
                     return;
                  elsif Expired (State.Deadline) then
                     Fail_Exchange (Item, Timed_Out);
                     return;
                  end if;
                  Flyology.IO.DNS.Resolve
                    (Name          => Name,
                     Configuration => Owner.Resolver,
                     Deadline      =>
                       (if State.Deadline.Is_Limited then
                          State.Deadline.Value
                        else Ada.Real_Time.Time_Last),
                     Token         => State.Token_Item,
                     Operation     => State.DNS_Child);
                  State.Driver_State := Waiting_For_DNS;
                  State.Active_Child := DNS_Exchange_Child;
                  Flyology.Operations.Continue_After
                    (Item, State.DNS_Child);
                  return;
               elsif Name /= "localhost" then
                  Address := Sockets.Parse_IP_Address (Name);
               end if;
               State.Resolved_Count := 1;
               State.Resolved_Next := 1;
               State.Resolved_Addresses (1) := Address;
               Start_Resolved_Address;
               return;
            end;
         end if;
         State.Driver_State := Waiting_For_Connect;
         State.Active_Child := Connect_Exchange_Child;
         Flyology.Operations.Continue_After (Item, State.Connect_Child);
      end Start_Connect;

      procedure Send_Bytes
        (Data : Ada.Streams.Stream_Element_Array;
         Next : Exchange_Driver_State)
      is
         Last   : Ada.Streams.Stream_Element_Offset;
         Result : Connection_Drivers.Step_Result;
      begin
         Connection_Drivers.Send (State.IO, Data, Last, Result);
         case Result is
            when Connection_Drivers.Made_Progress =>
               if Last >= Data'First then
                  State.Result.Admission := Possibly_Admitted;
                  State.Output_Cursor := State.Output_Cursor
                    + Natural (Last - Data'First + 1);
                  Client_Test_Barrier (2);
                  if State.Token_Item /= null
                    and then State.Token_Item.Requested
                  then
                     Fail_Exchange
                       (Item, Cancelled, Flyology.Operations.Cancelled);
                     return;
                  elsif Expired (State.Deadline) then
                     Fail_Exchange (Item, Timed_Out);
                     return;
                  end if;
               end if;
               if State.Output_Cursor > State.Output_Limit then
                  State.Driver_State := Next;
               end if;
               Reschedule;
            when Connection_Drivers.Need_Read |
                 Connection_Drivers.Need_Write =>
               Arm_Transport (Result);
            when Connection_Drivers.Peer_Closed =>
               Fail_Exchange (Item, Transport_Failed);
         end case;
      end Send_Bytes;

      procedure Send_Head is
         Text : constant String := To_String (State.Request_Head);
         Next : constant Exchange_Driver_State :=
           (if State.Source_Item /= null
            then Pulling_Source
            elsif State.Request_Content_Length > 0
            then Sending_Retained_Content
            else Receiving_Head);
      begin
         Send_Bytes
           (Byte_Array (Text (State.Output_Cursor .. State.Output_Limit)),
            Next);
         if not Flyology.Operations.Is_Active (Item) then
            return;
         end if;
         if State.Driver_State /= Sending_Head then
            State.Output_Cursor := 1;
            if State.Target = Response_Head_Target
              and then State.Request_Item.Expect_Continue
              and then Next /= Receiving_Head
            then
               State.Expect_Waiting := True;
               State.Resume_After_Probe := Next;
               State.Metadata.Request_Incomplete := True;
               State.Driver_State := Probing_Early_Response;
               State.Result.Last_Phase := Waiting_Response_Head;
            else
               State.Result.Last_Phase :=
                 (if State.Driver_State = Receiving_Head
                  then Waiting_Response_Head else Sending_Request_Body);
            end if;
         end if;
      end Send_Head;

      procedure Send_Retained is
         Total : constant Natural := State.Request_Content_Length;
         Count : constant Natural := Natural'Min
           (Natural (State.Buffer'Length), Total - State.Output_Cursor + 1);
         Next  : constant Exchange_Driver_State :=
           (if State.Output_Cursor + Count - 1 = Total
            then Receiving_Head else Sending_Retained_Content);
      begin
         for Offset in 0 .. Count - 1 loop
            State.Buffer
              (State.Buffer'First
                 + Ada.Streams.Stream_Element_Offset (Offset)) :=
              Flyology.Bytes.Element
                (State.Request_Item.Body_Value,
                 State.Output_Cursor + Offset);
         end loop;
         State.Output_Limit := State.Output_Cursor + Count - 1;
         Send_Bytes
            (State.Buffer
              (State.Buffer'First ..
                 State.Buffer'First
                   + Ada.Streams.Stream_Element_Offset (Count) - 1),
            Next);
         if not Flyology.Operations.Is_Active (Item) then
            return;
         end if;
         if State.Output_Cursor > State.Output_Limit then
            State.Resume_After_Probe := Next;
            State.Driver_State := Probing_Early_Response;
         end if;
      end Send_Retained;

      procedure Pull_Source is
         Last   : Ada.Streams.Stream_Element_Offset;
         Result : Source_Step_Kind;
         Count  : Natural;
      begin
         Read_Now (State.Source_Item.all, State.Buffer, Last, Result);
         Count :=
           (if Last < State.Buffer'First then 0
            else Natural (Last - State.Buffer'First + 1));
         case Result is
            when Source_Progress =>
               if Count = 0
                 or else Last > State.Buffer'Last
                 or else
                   (State.Source_Length.Is_Known
                      and then State.Source_Transferred + Body_Size (Count) >
                        State.Source_Length.Bytes)
               then
                  State.Metadata.Request_Incomplete := True;
                  Fail_Exchange (Item, Request_Source_Failed);
                  return;
               end if;
               State.Buffer_First := 1;
               State.Buffer_Last := Count;
               State.Output_Cursor := 1;
               if State.Source_Length.Is_Known then
                  State.Output_Limit := Count;
                  State.Driver_State := Sending_Source_Content;
               else
                  State.Request_Head := To_Unbounded_String
                    (Hexadecimal (Count) & CRLF);
                  State.Output_Limit := Length (State.Request_Head);
                  State.Driver_State := Sending_Source_Prefix;
               end if;
               Reschedule;
            when Source_Finished =>
               if Count /= 0
                 or else
                   (State.Source_Length.Is_Known
                      and then State.Source_Transferred /=
                        State.Source_Length.Bytes)
               then
                  State.Metadata.Request_Incomplete := True;
                  Fail_Exchange (Item, Request_Source_Failed);
               elsif State.Source_Length.Is_Known then
                  State.Driver_State := Receiving_Head;
                  State.Result.Last_Phase := Waiting_Response_Head;
                  Reschedule;
               else
                  State.Request_Head := To_Unbounded_String ("0" & CRLF);
                  for Index in 1 .. Flyology.HTTP.Headers.Count
                    (State.Request_Item.Trailer_Fields)
                  loop
                     Append
                       (State.Request_Head,
                        Flyology.HTTP.Headers.Name
                          (State.Request_Item.Trailer_Fields, Index)
                          & ": "
                          & Flyology.HTTP.Headers.Value
                            (State.Request_Item.Trailer_Fields, Index)
                          & CRLF);
                  end loop;
                  Append (State.Request_Head, CRLF);
                  State.Output_Cursor := 1;
                  State.Output_Limit := Length (State.Request_Head);
                  State.Driver_State := Sending_Source_End;
                  Reschedule;
               end if;
            when Source_Needs_Read | Source_Needs_Write =>
               if Count /= 0 then
                  State.Metadata.Request_Incomplete := True;
                  Fail_Exchange (Item, Request_Source_Failed);
               else
                  declare
                     Descriptor : Flyology.IO.Descriptor;
                     Ready : Boolean;
                     Required : constant Source_Wait_Kind :=
                       Source_Wait_Kind (Result);
                  begin
                     Source_Wait_Source
                       (State.Source_Item.all, Required,
                        Descriptor, Ready);
                     if Ready then
                        Reschedule;
                     else
                        State.Resume_After_Probe := Pulling_Source;
                        State.Driver_State := Probing_Early_Response;
                        Connection_Drivers.Arm_Transport
                          (State.IO, Item, Connection_Drivers.Need_Read,
                           Additional => Descriptor,
                           Additional_For_Write =>
                             Required = Source_Needs_Write);
                        Connection_Drivers.Arm_Deadline (State.IO, Item);
                     end if;
                  end;
               end if;
         end case;
      exception
         when Error : others =>
            Remember_Failure (State, Error);
            if State.Target = Response_Head_Target then
               Ada.Exceptions.Save_Occurrence (State.Saved_Error, Error);
               State.Has_Saved_Error := True;
            end if;
            State.Metadata.Request_Incomplete := True;
            Fail_Exchange (Item, Request_Source_Failed);
      end Pull_Source;

      procedure Send_Source is
         Last   : Ada.Streams.Stream_Element_Offset;
         Result : Connection_Drivers.Step_Result;
         First  : constant Ada.Streams.Stream_Element_Offset :=
           State.Buffer'First
             + Ada.Streams.Stream_Element_Offset (State.Buffer_First - 1);
         Final  : constant Ada.Streams.Stream_Element_Offset :=
           State.Buffer'First
             + Ada.Streams.Stream_Element_Offset (State.Buffer_Last - 1);
      begin
         Connection_Drivers.Send
           (State.IO, State.Buffer (First .. Final), Last, Result);
         case Result is
            when Connection_Drivers.Made_Progress =>
               if Last >= First then
                  declare
                     Count : constant Natural := Natural (Last - First + 1);
                  begin
                     State.Result.Admission := Possibly_Admitted;
                     State.Source_Transferred := State.Source_Transferred
                       + Body_Size (Count);
                     State.Buffer_First := State.Buffer_First + Count;
                  end;
               end if;
               if State.Buffer_First > State.Buffer_Last then
                  if State.Source_Length.Is_Known then
                     State.Resume_After_Probe := Pulling_Source;
                  else
                     State.Request_Head := To_Unbounded_String (CRLF);
                     State.Output_Cursor := 1;
                     State.Output_Limit := CRLF'Length;
                     State.Resume_After_Probe := Sending_Source_Suffix;
                  end if;
                  State.Driver_State := Probing_Early_Response;
               end if;
               Reschedule;
            when Connection_Drivers.Need_Read |
                 Connection_Drivers.Need_Write =>
               Arm_Transport (Result);
            when Connection_Drivers.Peer_Closed =>
               Fail_Exchange (Item, Transport_Failed);
         end case;
      end Send_Source;

      procedure Send_Source_Control
        (Next : Exchange_Driver_State) is
         Text : constant String := To_String (State.Request_Head);
      begin
         Send_Bytes
           (Byte_Array (Text (State.Output_Cursor .. State.Output_Limit)),
            Next);
         if not Flyology.Operations.Is_Active (Item) then
            return;
         end if;
         if State.Driver_State = Receiving_Head then
            State.Result.Last_Phase := Waiting_Response_Head;
         end if;
      end Send_Source_Control;

      procedure Probe_Early_Response is
         Last   : Ada.Streams.Stream_Element_Offset;
         Result : Connection_Drivers.Step_Result;
      begin
         Connection_Drivers.Receive (State.IO, State.Buffer, Last, Result);
         case Result is
            when Connection_Drivers.Made_Progress =>
               if Last >= State.Buffer'First then
                  State.Result.Admission := Response_Observed;
                  State.Metadata.Saw_Response_Bytes := True;
                  State.Metadata.Request_Incomplete :=
                    State.Resume_After_Probe /= Receiving_Head
                      and then not
                        (State.Source_Item /= null
                           and then State.Source_Length.Is_Known
                           and then State.Source_Transferred =
                             State.Source_Length.Bytes);
                  Append
                    (State.Metadata.Pending,
                     Byte_String (State.Buffer (State.Buffer'First .. Last)));
                  State.Driver_State := Receiving_Head;
                  State.Result.Last_Phase := Waiting_Response_Head;
               else
                  State.Driver_State := State.Resume_After_Probe;
               end if;
               Reschedule;
            when Connection_Drivers.Need_Read =>
               if State.Expect_Waiting
                 and then Event /= Flyology.Operations.Deadline_Reached
               then
                  Connection_Drivers.Arm_Transport
                    (State.IO, Item, Connection_Drivers.Need_Read);
                  if State.Deadline.Is_Limited then
                     Flyology.Operations.Drivers.Arm_Deadline
                       (Item,
                        Duration'Min
                          (State.Request_Item.Continue_Wait,
                           Remaining (State.Deadline)));
                  else
                     Flyology.Operations.Drivers.Arm_Deadline
                       (Item, State.Request_Item.Continue_Wait);
                  end if;
               else
                  State.Expect_Waiting := False;
                  State.Metadata.Request_Incomplete := False;
                  State.Driver_State := State.Resume_After_Probe;
                  if State.Driver_State = Receiving_Head then
                     State.Result.Last_Phase := Waiting_Response_Head;
                  else
                     State.Result.Last_Phase := Sending_Request_Body;
                  end if;
                  Reschedule;
               end if;
            when Connection_Drivers.Need_Write =>
               Arm_Transport (Result);
            when Connection_Drivers.Peer_Closed =>
               Fail_Exchange (Item, Transport_Failed);
         end case;
      end Probe_Early_Response;

      procedure Receive_One is
         Last   : Ada.Streams.Stream_Element_Offset;
         Result : Connection_Drivers.Step_Result;
         Limit  : constant Positive :=
           Client_Test_Receive_Limit (State.Buffer'Length);
      begin
         Client_Test_Barrier (3);
         if State.Token_Item /= null and then State.Token_Item.Requested then
            Fail_Exchange
              (Item, Cancelled, Flyology.Operations.Cancelled);
            return;
         elsif Expired (State.Deadline) then
            Fail_Exchange (Item, Timed_Out);
            return;
         end if;
         Connection_Drivers.Receive
           (State.IO,
            State.Buffer
              (State.Buffer'First .. State.Buffer'First +
                 Ada.Streams.Stream_Element_Offset (Limit) - 1),
            Last, Result);
         case Result is
            when Connection_Drivers.Made_Progress =>
               Client_Test_Receive_Observed;
               if Last >= State.Buffer'First then
                  State.Result.Admission := Response_Observed;
                  State.Metadata.Saw_Response_Bytes := True;
                  Append
                    (State.Metadata.Pending,
                     Byte_String (State.Buffer (State.Buffer'First .. Last)));
               end if;
               Reschedule;
            when Connection_Drivers.Need_Read |
                 Connection_Drivers.Need_Write =>
               Arm_Transport (Result);
            when Connection_Drivers.Peer_Closed =>
               State.Peer_Closed := True;
               Reschedule;
         end case;
      end Receive_One;

      procedure Deliver
        (Data : Ada.Streams.Stream_Element_Array) is
         Count : constant Natural := Natural (Data'Length);
      begin
         if Count = 0 or else State.Pending_Result /= Response_Complete then
            return;
         elsif State.Metadata.Engine = HTTP_3_Response
           and then
             (State.HTTP_3_Body_Forbidden
              or else
                (State.HTTP_3_Expected_Length.Known
                 and then State.HTTP_3_Decoded_Length + Body_Size (Count) >
                   State.HTTP_3_Expected_Length.Bytes))
         then
            State.Pending_Result := Response_Invalid;
            return;
         elsif State.Metadata.Engine = HTTP_3_Response then
            State.HTTP_3_Decoded_Length :=
              State.HTTP_3_Decoded_Length + Body_Size (Count);
         end if;
         if State.Target = Sink_Target then
            begin
               Write (State.Sink_Item.all, Data);
            exception
               when Error : others =>
                  Remember_Failure (State, Error);
                  State.Pending_Result := Response_Sink_Failed;
            end;
         elsif State.Response_Length + Count >
           Flyology.Buffers.Drivers.Capacity (State.Destination)
         then
            State.Pending_Result := Response_Body_Too_Large;
         else
            for Offset in 0 .. Count - 1 loop
               Byte_Pointers.To_Pointer
                 (Flyology.Buffers.Drivers.Address (State.Destination)
                    + System.Storage_Elements.Storage_Offset
                      (State.Response_Length + Offset)).all :=
                 Data
                   (Data'First
                      + Ada.Streams.Stream_Element_Offset (Offset));
            end loop;
            State.Response_Length := State.Response_Length + Count;
         end if;
      end Deliver;

      procedure Finish_Decoded_Body is
      begin
         if State.Pending_Result = Response_Complete
           and then State.Metadata.Engine = HTTP_3_Response
           and then not State.HTTP_3_Body_Forbidden
           and then State.HTTP_3_Expected_Length.Known
           and then State.HTTP_3_Decoded_Length /=
             State.HTTP_3_Expected_Length.Bytes
         then
            State.Pending_Result := Response_Invalid;
         end if;
         if State.Pending_Result = Response_Complete then
            if State.Metadata.Engine = HTTP_1_Response
              and then State.Metadata.Request_Incomplete
            then
               --  HTTP/1 has no stream-local reset.  A final response that
               --  wins while the request source is incomplete therefore
               --  makes the whole transport non-reusable; close it before
               --  releasing the source or publishing completion.
               State.Metadata.Reusable := False;
               Finish_Success (Item);
            elsif State.Metadata.Engine = HTTP_2_Response
              and then State.Metadata.Request_Incomplete
              and then not State.HTTP_2_Cancelling
            then
               --  A complete early response does not close the local request
               --  direction. Commit RST_STREAM to the shared transport before
               --  releasing the source or publishing terminal completion.
               State.HTTP_2_Finished := False;
               State.Drain_Active := True;
               State.HTTP_2_Cancelling := True;
               H2_Connections.Cancel_Stream
                 (State.Metadata.Connection.HTTP_2.all,
                  State.Metadata.HTTP_2_Stream);
               State.Driver_State := HTTP_2_Waiting_For_Pump;
               Reschedule;
            elsif State.Metadata.Engine = HTTP_3_Response
              and then State.Metadata.Request_Incomplete
              and then not State.HTTP_3_Cancelling
            then
               --  STOP_SENDING and RESET_STREAM must reach QUIC before the
               --  source borrow is released or completion becomes visible.
               State.HTTP_3_Finished := False;
               State.Drain_Active := True;
               State.HTTP_3_Cancelling := True;
               State.HTTP_3_Stage := HTTP_3_Cancel_Request;
               H3_Connections.Signal_Outbound
                 (State.Metadata.Connection.HTTP_3_Streams,
                  State.Metadata.HTTP_3_Handle);
               State.Driver_State := HTTP_3_Waiting_For_Pump;
               Reschedule;
            elsif State.Metadata.Engine = HTTP_2_Response
              and then not State.HTTP_2_Settling
            then
               --  A response END_STREAM can share a transport read with
               --  connection control frames. Give the owner-driven pump one
               --  bounded drain cycle so already-observed PING/SETTINGS and
               --  receive-credit output reaches the peer before this stream
               --  releases its pump claim.
               State.HTTP_2_Settling := True;
               State.Driver_State := HTTP_2_Waiting_For_Pump;
               Reschedule;
            else
               Finish_Success (Item);
            end if;
         else
            Release_Exchange_Transport
              (State, Reusable => State.Metadata.Reusable);
            Complete_Exchange
              (Item, State.Pending_Result, Flyology.Operations.Failed);
         end if;
      end Finish_Decoded_Body;

      procedure Receive_Head is
         Complete       : Boolean;
         Before_Interim : constant Client_Policy.Informational_Count :=
           State.Metadata.Informational_Count;
      begin
         HTTP_1_Internals.Parse_Available_Final_Head
           (State.Metadata, Complete);
         if Complete then
            HTTP_1_Internals.Select_Body_Mode
              (State.Metadata, State.Request_Item.Method_Value,
               Release_Immediately => False);
            State.Result.Last_Phase := Receiving_Response_Body;
            if State.Target = Response_Head_Target then
               if State.Metadata.Mode = No_Body then
                  State.Metadata.Complete := True;
                  Finish_Success (Item);
               else
                  Finish_Response_Head (Item);
               end if;
               return;
            end if;
            if State.Target = Buffer_Target
              and then State.Metadata.Mode = Fixed_Body
              and then State.Metadata.Remaining_Body >
                Flyology.Buffers.Drivers.Capacity (State.Destination)
            then
               State.Pending_Result := Response_Body_Too_Large;
               State.Result.Required :=
                 (Known => True,
                  Bytes => Body_Size (State.Metadata.Remaining_Body));
            end if;
            State.Driver_State := Receiving_Content;
            Reschedule;
         elsif State.Peer_Closed then
            Fail_Exchange (Item, Response_Invalid);
         elsif State.Metadata.Informational_Count > Before_Interim
           and then Length (State.Metadata.Pending) = 0
           and then State.Metadata.Request_Incomplete
         then
            State.Expect_Waiting := False;
            State.Metadata.Request_Incomplete := False;
            State.Driver_State := State.Resume_After_Probe;
            State.Result.Last_Phase := Sending_Request_Body;
            Reschedule;
         else
            Receive_One;
         end if;
      end Receive_Head;

      procedure Receive_Content_Step is
         Last       : Ada.Streams.Stream_Element_Offset;
         Complete   : Boolean;
         Need_Input : Boolean;
      begin
         HTTP_1_Internals.Consume_Available_Content
           (State.Metadata, State.Buffer, Last, Complete, Need_Input,
            State.Peer_Closed);
         if Last >= State.Buffer'First then
            Deliver (State.Buffer (State.Buffer'First .. Last));
         end if;
         if Complete then
            Finish_Decoded_Body;
         elsif Need_Input then
            Receive_One;
         else
            Reschedule;
         end if;
      end Receive_Content_Step;

      procedure Arm_HTTP_2_Pump_Wait is
         Sources : Flyology.Operations.Drivers.Readiness_Source_Array
           (1 .. 3);
         Count     : Natural := 0;
         FD        : Flyology.IO.Descriptor;
         Ready_Now : Boolean;
      begin
         H2_Connections.Pump_Wait_Source
           (State.Connection.HTTP_2.all,
            State.Metadata.HTTP_2_Stream, FD, Ready_Now);
         if Ready_Now then
            Reschedule;
            return;
         end if;
         Count := Count + 1;
         Sources (Count) := (Descriptor => FD, For_Write => False);
         Owner.Pool.Shutdown_Source (FD, Ready_Now);
         if Ready_Now then
            Fail_Exchange (Item, Client_Unavailable);
            return;
         end if;
         Count := Count + 1;
         Sources (Count) := (Descriptor => FD, For_Write => False);
         if State.Token_Item /= null then
            State.Token_Item.Wait_Source (FD, Ready_Now);
            if Ready_Now then
               Fail_Exchange
                 (Item, Cancelled, Flyology.Operations.Cancelled);
               return;
            end if;
            Count := Count + 1;
            Sources (Count) := (Descriptor => FD, For_Write => False);
         end if;
         Flyology.Operations.Drivers.Arm_Readiness
           (Item, Sources (1 .. Count));
         Arm_Operation_Deadline;
      end Arm_HTTP_2_Pump_Wait;

      procedure Release_HTTP_2_Pump is
      begin
         if State.Connection /= null
           and then State.Connection.HTTP_2 /= null
           and then State.Metadata.HTTP_2_Stream /= H2_Connections.No_Stream
           and then H2_Connections.Owns_Pump
             (State.Connection.HTTP_2.all,
              State.Metadata.HTTP_2_Stream)
         then
            H2_Connections.Release_Pump
              (State.Connection.HTTP_2.all,
               State.Metadata.HTTP_2_Stream);
         end if;
         if Connection_Drivers.Is_Engaged (State.IO) then
            Connection_Drivers.Release (State.IO);
         end if;
      end Release_HTTP_2_Pump;

      procedure Need_HTTP_2_Pump is
         Claimed : Boolean;
         Result  : Connection_Drivers.Acquisition_Result;
      begin
         H2_Connections.Try_Claim_Pump
           (State.Connection.HTTP_2.all,
            State.Metadata.HTTP_2_Stream, Claimed);
         if not Claimed then
            State.Driver_State := HTTP_2_Waiting_For_Pump;
            Arm_HTTP_2_Pump_Wait;
            return;
         end if;
         Connection_Drivers.Start
           (State.IO, State.Connection.Channel'Unchecked_Access,
            Result,
            --  After timeout, allow only the pump's immediate reset-send
            --  probe. Pump_Need_Write observes the expired deadline below
            --  and closes instead of arming or waiting past the budget.
            (if State.HTTP_2_Cancelling
             then Flyology.IO.Infinite else Remaining (State.Deadline)),
            (if State.HTTP_2_Cancelling then null else State.Token_Item));
         if Result = Connection_Drivers.Acquired then
            State.Driver_State := HTTP_2_Driving_Pump;
            Reschedule;
         else
            State.Driver_State := HTTP_2_Waiting_For_Connection_Lease;
            Connection_Drivers.Arm_Acquisition (State.IO, Item);
            Connection_Drivers.Arm_Deadline (State.IO, Item);
         end if;
      exception
         when others =>
            Release_HTTP_2_Pump;
            raise;
      end Need_HTTP_2_Pump;

      procedure Complete_HTTP_2_Head
        (Status   : Status_Code;
         Fields   : Flyology.HTTP.Headers.List;
         Finished : Boolean;
         Early    : Boolean)
      is
         Body_Forbidden : constant Boolean :=
           Image (State.Request_Item.Method_Value) = "HEAD"
             or else Status in 204 | 205 | 304;
      begin
         State.Result.Admission := Response_Observed;
         State.Metadata.Saw_Response_Bytes := True;
         State.Metadata.Status_Value := Status;
         State.Metadata.Reason_Value := Null_Unbounded_String;
         State.Metadata.Protocol_Value := HTTP_2_Protocol;
         State.Metadata.Version_Value := HTTP_1_1;
         State.Metadata.Fields := Fields;
         State.Metadata.Request_Incomplete := Early;
         State.Result.Last_Phase := Receiving_Response_Body;
         if State.Target = Response_Head_Target and then not Finished then
            Finish_Response_Head (Item);
            return;
         end if;
         if State.Target = Buffer_Target
           and then not Body_Forbidden
           and then Flyology.HTTP.Headers.Count
             (Fields, "content-length") = 1
         then
            declare
               Required : constant Body_Size := Body_Size'Value
                 (Flyology.HTTP.Headers.Value (Fields, "content-length"));
            begin
               if Required > Body_Size
                 (Flyology.Buffers.Drivers.Capacity (State.Destination))
               then
                  State.Pending_Result := Response_Body_Too_Large;
                  State.Result.Required :=
                    (Known => True, Bytes => Required);
               end if;
            end;
         end if;
         if Finished then
            State.HTTP_2_Finished := True;
            State.Metadata.Reusable := H2_Connections.Is_Usable
              (State.Connection.HTTP_2.all);
            Finish_Decoded_Body;
         else
            State.HTTP_2_Stage := HTTP_2_Response_Body;
            State.Driver_State := HTTP_2_Protocol_Step;
            Reschedule;
         end if;
      end Complete_HTTP_2_Head;

      procedure Complete_HTTP_2_Unprocessed is
         Reusable : constant Boolean := H2_Connections.Is_Usable
           (State.Connection.HTTP_2.all);
      begin
         --  REFUSED_STREAM and a GOAWAY last-stream boundary are terminal for
         --  this stream but not transport failures. Detach the failed stream
         --  while retaining the usable shared session so the synchronous
         --  compatibility adapter can apply its guarded one-shot replay.
         State.HTTP_2_Retryable_Refusal := True;
         State.Failure_Cause := Protocol_Error'Identity;
         State.HTTP_2_Finished := True;
         State.Metadata.Reusable := Reusable;
         Release_Exchange_Transport (State, Reusable => Reusable);
         Complete_Exchange
           (Item, Transport_Failed, Flyology.Operations.Failed);
      end Complete_HTTP_2_Unprocessed;

      procedure Poll_HTTP_2_Head (Early : Boolean) is
         Result   : H2_Connections.Head_Result;
         Status   : Status_Code;
         Fields   : Flyology.HTTP.Headers.List;
         Finished : Boolean;
      begin
         H2_Connections.Poll_Head
           (State.Connection.HTTP_2.all,
            State.Metadata.HTTP_2_Stream,
            Result, Status, Fields, Finished);
         case Result is
            when H2_Connections.Head_Ready =>
               Complete_HTTP_2_Head (Status, Fields, Finished, Early);
            when H2_Connections.Head_Would_Block =>
               Need_HTTP_2_Pump;
            when H2_Connections.Head_Connection_Failed =>
               Fail_Exchange (Item, Transport_Failed);
            when H2_Connections.Head_Protocol_Failed =>
               Fail_Exchange (Item, Response_Invalid);
            when H2_Connections.Head_Refused |
                 H2_Connections.Head_Goaway_Unprocessed =>
               --  Scoped sources are never replayed. Even an explicit peer
               --  refusal is reported against the already queued request.
               --  The synchronous adapter may apply its historical one-shot
               --  replay policy after typed terminal cleanup.
               Complete_HTTP_2_Unprocessed;
         end case;
      end Poll_HTTP_2_Head;

      procedure Upload_HTTP_2_Source is
         Head_Result   : H2_Connections.Head_Result;
         Head_Status   : Status_Code;
         Head_Fields   : Flyology.HTTP.Headers.List;
         Head_Finished : Boolean;
         Upload        : H2_Connections.Upload_Result;
         Last          : Ada.Streams.Stream_Element_Offset;
         Source_Result : Source_Step_Kind;
         Count         : Natural;
         Empty         : Ada.Streams.Stream_Element_Array (1 .. 0);
      begin
         --  A final response suppresses further reads from a borrowed source.
         H2_Connections.Poll_Head
           (State.Connection.HTTP_2.all,
            State.Metadata.HTTP_2_Stream,
            Head_Result, Head_Status, Head_Fields, Head_Finished);
         if Head_Result = H2_Connections.Head_Ready then
            Complete_HTTP_2_Head
              (Head_Status, Head_Fields, Head_Finished, Early => True);
            return;
         elsif Head_Result = H2_Connections.Head_Connection_Failed then
            Fail_Exchange (Item, Transport_Failed);
            return;
         elsif Head_Result = H2_Connections.Head_Protocol_Failed then
            Fail_Exchange (Item, Response_Invalid);
            return;
         elsif Head_Result in H2_Connections.Head_Refused |
           H2_Connections.Head_Goaway_Unprocessed
         then
            Complete_HTTP_2_Unprocessed;
            return;
         end if;

         if State.HTTP_2_Source_Waiting then
            Need_HTTP_2_Pump;
            return;
         end if;

         if State.Buffer_First <= State.Buffer_Last then
            declare
               First : constant Ada.Streams.Stream_Element_Offset :=
                 State.Buffer'First
                   + Ada.Streams.Stream_Element_Offset
                     (State.Buffer_First - 1);
               Final : constant Ada.Streams.Stream_Element_Offset :=
                 State.Buffer'First
                   + Ada.Streams.Stream_Element_Offset
                     (State.Buffer_Last - 1);
               No_Trailers : Ada.Streams.Stream_Element_Array (1 .. 0);
            begin
               H2_Connections.Write_Request_Data
                 (State.Connection.HTTP_2.all,
                  State.Metadata.HTTP_2_Stream,
                  State.Buffer (First .. Final),
                  Finished => False,
                  Trailer_Block => No_Trailers,
                  Result => Upload);
            end;
            case Upload is
               when H2_Connections.Upload_Accepted =>
                  Count := State.Buffer_Last - State.Buffer_First + 1;
                  State.Source_Transferred := State.Source_Transferred
                    + Body_Size (Count);
                  State.Buffer_First := 1;
                  State.Buffer_Last := 0;
                  Need_HTTP_2_Pump;
               when H2_Connections.Upload_Would_Block =>
                  Need_HTTP_2_Pump;
               when H2_Connections.Upload_Failed =>
                  Fail_Exchange (Item, Request_Source_Failed);
            end case;
            return;
         elsif State.HTTP_2_Upload_End then
            declare
               Trailers : constant Flyology.Bytes.Unbounded_Bytes :=
                 H2_Requests.Encode_Trailers
                   (State.Request_Item.Trailer_Fields);
            begin
               H2_Connections.Write_Request_Data
                 (State.Connection.HTTP_2.all,
                  State.Metadata.HTTP_2_Stream, Empty,
                  Finished => True,
                  Trailer_Block => Flyology.Bytes.To_Array (Trailers),
                  Result => Upload);
            end;
            case Upload is
               when H2_Connections.Upload_Accepted =>
                  State.HTTP_2_Upload_End := False;
                  State.HTTP_2_Stage := HTTP_2_Response_Head;
                  State.Result.Last_Phase := Waiting_Response_Head;
                  Need_HTTP_2_Pump;
               when H2_Connections.Upload_Would_Block =>
                  Need_HTTP_2_Pump;
               when H2_Connections.Upload_Failed =>
                  Fail_Exchange (Item, Request_Source_Failed);
            end case;
            return;
         end if;

         if State.Source_Item = null then
            if State.Output_Cursor <= State.Request_Content_Length then
               Count := Natural'Min
                 (Natural (State.Buffer'Length),
                  State.Request_Content_Length - State.Output_Cursor + 1);
               for Offset in 0 .. Count - 1 loop
                  State.Buffer
                    (State.Buffer'First
                       + Ada.Streams.Stream_Element_Offset (Offset)) :=
                    Flyology.Bytes.Element
                      (State.Request_Item.Body_Value,
                       State.Output_Cursor + Offset);
               end loop;
               State.Output_Cursor := State.Output_Cursor + Count;
               State.Buffer_First := 1;
               State.Buffer_Last := Count;
            else
               State.HTTP_2_Upload_End := True;
            end if;
            Reschedule;
            return;
         end if;

         Read_Now (State.Source_Item.all, State.Buffer, Last, Source_Result);
         Count :=
           (if Last < State.Buffer'First then 0
            else Natural (Last - State.Buffer'First + 1));
         case Source_Result is
            when Source_Progress =>
               if Count = 0
                 or else Last > State.Buffer'Last
                 or else
                   (State.Source_Length.Is_Known
                      and then State.Source_Transferred + Body_Size (Count) >
                        State.Source_Length.Bytes)
               then
                  State.Metadata.Request_Incomplete := True;
                  Fail_Exchange (Item, Request_Source_Failed);
               else
                  State.Buffer_First := 1;
                  State.Buffer_Last := Count;
                  Reschedule;
               end if;
            when Source_Finished =>
               if Count /= 0
                 or else
                   (State.Source_Length.Is_Known
                      and then State.Source_Transferred /=
                        State.Source_Length.Bytes)
               then
                  State.Metadata.Request_Incomplete := True;
                  Fail_Exchange (Item, Request_Source_Failed);
               else
                  State.HTTP_2_Upload_End := True;
                  Reschedule;
               end if;
            when Source_Needs_Read | Source_Needs_Write =>
               if Count /= 0 then
                  State.Metadata.Request_Incomplete := True;
                  Fail_Exchange (Item, Request_Source_Failed);
               else
                  State.HTTP_2_Source_Waiting := True;
                  State.HTTP_2_Source_Wait :=
                    Source_Wait_Kind (Source_Result);
                  Need_HTTP_2_Pump;
               end if;
         end case;
      exception
         when Error : others =>
            Remember_Failure (State, Error);
            if State.Target = Response_Head_Target then
               Ada.Exceptions.Save_Occurrence (State.Saved_Error, Error);
               State.Has_Saved_Error := True;
            end if;
            State.Metadata.Request_Incomplete := True;
            Fail_Exchange (Item, Request_Source_Failed);
      end Upload_HTTP_2_Source;

      procedure Read_HTTP_2_Body is
         Result   : H2_Connections.Body_Result;
         Last     : Ada.Streams.Stream_Element_Offset;
         Finished : Boolean;
         Trailers : Flyology.HTTP.Headers.List;
      begin
         H2_Connections.Read
           (State.Connection.HTTP_2.all,
            State.Metadata.HTTP_2_Stream,
            State.Buffer, Last, Finished, Result, Trailers);
         case Result is
            when H2_Connections.Body_Progress =>
               if Last >= State.Buffer'First then
                  Deliver (State.Buffer (State.Buffer'First .. Last));
               end if;
               if Finished then
                  State.Metadata.Trailers := Trailers;
                  State.HTTP_2_Finished := True;
                  State.Metadata.Reusable := H2_Connections.Is_Usable
                    (State.Connection.HTTP_2.all);
                  Finish_Decoded_Body;
               else
                  Reschedule;
               end if;
            when H2_Connections.Body_Finished =>
               State.Metadata.Trailers := Trailers;
               State.HTTP_2_Finished := True;
               State.Metadata.Reusable := H2_Connections.Is_Usable
                 (State.Connection.HTTP_2.all);
               Finish_Decoded_Body;
            when H2_Connections.Body_Would_Block =>
               Need_HTTP_2_Pump;
            when H2_Connections.Body_Connection_Failed =>
               Fail_Exchange (Item, Transport_Failed);
            when H2_Connections.Body_Protocol_Failed =>
               Fail_Exchange (Item, Response_Invalid);
            when H2_Connections.Body_Stream_Failed =>
               Fail_Exchange (Item, Response_Invalid);
         end case;
      end Read_HTTP_2_Body;

      procedure Drive_HTTP_2_Pump is
         Step : H2_Connections.Pump_Step;

         procedure Arm_Source_And_Transport
           (Required : Connection_Drivers.Step_Result) is
            Descriptor : Flyology.IO.Descriptor;
            Ready : Boolean;
         begin
            Source_Wait_Source
              (State.Source_Item.all, State.HTTP_2_Source_Wait,
               Descriptor, Ready);
            if Ready then
               Release_HTTP_2_Pump;
               State.HTTP_2_Source_Waiting := False;
               State.Driver_State := HTTP_2_Protocol_Step;
               Reschedule;
            else
               Connection_Drivers.Arm_Transport
                 (State.IO, Item, Required,
                  H2_Connections.Outbound
                    (State.Connection.HTTP_2.all).all,
                  Additional => Descriptor,
                  Additional_For_Write =>
                    State.HTTP_2_Source_Wait = Source_Needs_Write);
               Connection_Drivers.Arm_Deadline (State.IO, Item);
            end if;
         end Arm_Source_And_Transport;

         procedure Finish_Cancellation is
         begin
            Release_HTTP_2_Pump;
            State.HTTP_2_Finished := True;
            State.HTTP_2_Cancelling := False;
            if State.Pending_Result = Response_Complete then
               Finish_Success (Item);
            else
               Release_Exchange_Transport (State, Reusable => True);
               Complete_Exchange
                 (Item, State.Pending_Result,
                  (if State.Pending_Result = Cancelled
                   then Flyology.Operations.Cancelled
                   else Flyology.Operations.Failed));
            end if;
         end Finish_Cancellation;

         procedure Finish_Settlement is
         begin
            Release_HTTP_2_Pump;
            State.HTTP_2_Settling := False;
            Finish_Success (Item);
         end Finish_Settlement;

         procedure Arm_Closing_Drain
           (Required : Connection_Drivers.Step_Result) is
            Wait : Duration := Step.Drain_Remaining;
         begin
            Connection_Drivers.Arm_Transport
              (State.IO, Item, Required,
               H2_Connections.Outbound
                 (State.Connection.HTTP_2.all).all);
            if State.Deadline.Is_Limited then
               Wait := Duration'Min (Wait, Remaining (State.Deadline));
            end if;
            Flyology.Operations.Drivers.Arm_Deadline (Item, Wait);
         end Arm_Closing_Drain;
      begin
         H2_Connections.Drive_Pump
           (State.Connection.HTTP_2.all,
            State.Metadata.HTTP_2_Stream, State.IO, Step);
         if H2_Connections.Has_Response_Observation
           (State.Connection.HTTP_2.all, State.Metadata.HTTP_2_Stream)
         then
            State.Result.Admission := Response_Observed;
            State.Metadata.Saw_Response_Bytes := True;
         end if;
         case Step.Result is
            when H2_Connections.Pump_Progress =>
               State.HTTP_2_Flush_Pending := Step.Outbound_Pending;
               if Step.Closing_Drain then
                  State.Driver_State := HTTP_2_Driving_Pump;
               else
                  Release_HTTP_2_Pump;
                  State.Driver_State :=
                    (if Step.Outbound_Pending
                     then HTTP_2_Waiting_For_Pump
                     elsif State.HTTP_2_Cancelling
                     then HTTP_2_Waiting_For_Pump
                     elsif State.HTTP_2_Settling
                     then HTTP_2_Waiting_For_Pump
                     else HTTP_2_Protocol_Step);
               end if;
               Reschedule;
            when H2_Connections.Pump_Need_Read =>
               if Step.Closing_Drain then
                  Arm_Closing_Drain (Connection_Drivers.Need_Read);
               elsif State.HTTP_2_Cancelling
                 and then not Step.Outbound_Pending
               then
                  Finish_Cancellation;
               elsif State.HTTP_2_Settling
                 and then not Step.Outbound_Pending
               then
                  Finish_Settlement;
               elsif State.HTTP_2_Cancelling
                 and then Expired (State.Deadline)
               then
                  Fail_Exchange (Item, Transport_Failed);
               elsif State.HTTP_2_Source_Waiting
                 and then not Step.Outbound_Pending
               then
                  Arm_Source_And_Transport
                    (Connection_Drivers.Need_Read);
               else
                  Connection_Drivers.Arm_Transport
                    (State.IO, Item, Connection_Drivers.Need_Read,
                     H2_Connections.Outbound
                       (State.Connection.HTTP_2.all).all);
                  Connection_Drivers.Arm_Deadline (State.IO, Item);
               end if;
            when H2_Connections.Pump_Need_Write =>
               if Step.Closing_Drain then
                  Arm_Closing_Drain (Connection_Drivers.Need_Write);
               elsif State.HTTP_2_Cancelling
                 and then Expired (State.Deadline)
               then
                  Fail_Exchange (Item, Transport_Failed);
               elsif State.HTTP_2_Source_Waiting then
                  Arm_Source_And_Transport
                    (Connection_Drivers.Need_Write);
               else
                  Connection_Drivers.Arm_Transport
                    (State.IO, Item, Connection_Drivers.Need_Write,
                     H2_Connections.Outbound
                       (State.Connection.HTTP_2.all).all);
                  Connection_Drivers.Arm_Deadline (State.IO, Item);
               end if;
            when H2_Connections.Pump_Peer_Closed =>
               Release_HTTP_2_Pump;
               Fail_Exchange (Item, Transport_Failed);
            when H2_Connections.Pump_Protocol_Failed =>
               Release_HTTP_2_Pump;
               --  The peer supplied bytes that violate HTTP/2 framing or
               --  compression rules. Preserve synchronous Protocol_Error
               --  semantics while scoped callers receive the typed invalid
               --  response outcome and unchanged admission certainty.
               Fail_Exchange (Item, Response_Invalid);
         end case;
      end Drive_HTTP_2_Pump;

      procedure Start_HTTP_3_Receive (Probe : Boolean := False) is
         Sources : Flyology.IO.Interrupt_Set (1 .. 3);
         Count : Natural := 0;
         FD : Flyology.IO.Descriptor;
         Pending : Boolean;
         Wait : Duration := Remaining (State.Deadline);
      begin
         State.HTTP_3_Receive_Probe := Probe;
         if Probe then
            Wait := 0.0;
            State.HTTP_3_Stage := State.HTTP_3_After_Probe;
         end if;
         Owner.Pool.Shutdown_Source (FD, Pending);
         if Pending then
            Fail_Exchange (Item, Client_Unavailable);
            return;
         end if;
         Count := Count + 1;
         Sources (Count) := FD;
         if State.Token_Item /= null then
            State.Token_Item.Wait_Source (FD, Pending);
            if Pending then
               Fail_Exchange
                 (Item, Cancelled, Flyology.Operations.Cancelled);
               return;
            end if;
            Count := Count + 1;
            Sources (Count) := FD;
         end if;
         if State.Metadata.HTTP_3_Handle /= H3_Connections.No_Stream then
            H3_Connections.Outbound_Wait_Source
              (State.Connection.HTTP_3_Streams, FD, Pending);
            if Pending then
               Yield_HTTP_3_Pump;
               return;
            end if;
            Count := Count + 1;
            Sources (Count) := FD;
         end if;
         if QUIC.Has_Recovery_Timeout (State.Connection.QUIC_Transport) then
            declare
               Deadline : constant QUIC.Timestamp := QUIC.Recovery_Deadline
                 (State.Connection.QUIC_Transport);
               Current : constant QUIC.Timestamp := HTTP_3_Now;
               Recovery : constant Duration :=
                 (if Deadline <= Current then 0.0
                  else Duration (Deadline - Current) / 1_000_000.0);
            begin
               if Wait < 0.0 or else Recovery < Wait then
                  Wait := Recovery;
               end if;
            end;
         end if;
         if State.HTTP_3_Source_Waiting then
            Sockets.Receive_Datagram
              (Socket               =>
                 State.Connection.UDP'Unchecked_Access,
               Item                 => State.HTTP_3_Input_Item,
               Timeout              => Wait,
               Operation            => State.UDP_Receive_Child,
               Interrupts           => Sources (1 .. Count),
               Additional           => State.HTTP_3_Source_Wait_FD,
               Additional_For_Write =>
                 State.HTTP_3_Source_Wait_For_Write);
         else
            Sockets.Receive_Datagram
              (Socket     => State.Connection.UDP'Unchecked_Access,
               Item       => State.HTTP_3_Input_Item,
               Timeout    => Wait,
               Operation  => State.UDP_Receive_Child,
               Interrupts => Sources (1 .. Count));
         end if;
         State.Active_Child := UDP_Receive_Exchange_Child;
         State.Driver_State := HTTP_3_Receiving_Datagram;
         Flyology.Operations.Continue_After
           (Item, State.UDP_Receive_Child);
      end Start_HTTP_3_Receive;

      procedure Observe_HTTP_3_Head
        (Ready : out Boolean) is
         Result : H3_Connections.Head_Result;
         Status : Status_Code;
         Fields : Flyology.HTTP.Headers.List;
         Finished : Boolean;
      begin
         Ready := False;
         if State.Metadata.HTTP_3_Handle = H3_Connections.No_Stream then
            return;
         end if;
         H3_Connections.Poll_Head
           (State.Connection.HTTP_3_Streams,
            State.Metadata.HTTP_3_Handle,
            Result, Status, Fields, Finished);
         case Result is
            when H3_Connections.Head_Ready =>
               State.Result.Admission := Response_Observed;
               State.Metadata.Saw_Response_Bytes := True;
               State.Metadata.Status_Value := Status;
               State.Metadata.Fields := Fields;
               State.Metadata.Protocol_Value := HTTP_3_Protocol;
               State.Metadata.Reason_Value := Null_Unbounded_String;
               State.Result.Last_Phase := Receiving_Response_Body;
               State.HTTP_3_Body_Forbidden :=
                 Image (State.Request_Item.Method_Value) = "HEAD"
                   or else Status in 204 | 205 | 304;
               declare
                  Length_Count : constant Natural :=
                    Flyology.HTTP.Headers.Count
                      (Fields, "content-length");
               begin
                  if Length_Count > 1
                    or else (Status = 204 and then Length_Count /= 0)
                  then
                     State.Pending_Result := Response_Invalid;
                  elsif Length_Count = 1 then
                     declare
                        Text : constant String :=
                          Flyology.HTTP.Headers.Value
                            (Fields, "content-length");
                        Required : Body_Size;
                     begin
                        if Text'Length = 0
                          or else
                            (for some Character_Value of Text =>
                               Character_Value not in '0' .. '9')
                        then
                           raise Constraint_Error;
                        end if;
                        Required := Body_Size'Value (Text);
                        State.HTTP_3_Expected_Length :=
                          (Known => True, Bytes => Required);
                        if not State.HTTP_3_Body_Forbidden
                          and then State.Target = Buffer_Target
                          and then Required > Body_Size
                          (Flyology.Buffers.Drivers.Capacity
                             (State.Destination))
                        then
                           State.Pending_Result := Response_Body_Too_Large;
                           State.Result.Required :=
                             (Known => True, Bytes => Required);
                        end if;
                     exception
                        when Constraint_Error =>
                           State.Pending_Result := Response_Invalid;
                     end;
                  end if;
               end;
               State.Metadata.Request_Incomplete :=
                 State.HTTP_3_Stage not in HTTP_3_Wait_Response_Head |
                   HTTP_3_Read_Response_Body;
               State.HTTP_3_Stage := HTTP_3_Read_Response_Body;
               Ready := True;
               if Finished then
                  State.HTTP_3_Finished := True;
               elsif State.Target = Response_Head_Target then
                  Finish_Response_Head (Item);
               end if;
            when H3_Connections.Head_Would_Block => null;
            when H3_Connections.Head_Connection_Failed =>
               Fail_Exchange (Item, Transport_Failed);
            when H3_Connections.Head_Stream_Failed =>
               Fail_Exchange (Item, Response_Invalid);
         end case;
      end Observe_HTTP_3_Head;

      procedure Drive_HTTP_3_Protocol is
         Packet : QUIC.Datagram;
         Status : H3.Operation_Status;
         Stream : QUIC.Stream_ID;
         Accepted : Boolean;
         Head_Ready : Boolean := False;

         procedure Transport_Blocked is
         begin
            Start_HTTP_3_Receive;
         end Transport_Blocked;
      begin
         if H3_Connections.Owns_Pump
           (State.Connection.HTTP_3_Streams,
            State.Metadata.HTTP_3_Handle)
           and then State.HTTP_3_Stage /= HTTP_3_Send_Flight
           and then QUIC.Is_Connected (State.Connection.QUIC_Transport)
           and then H3.Is_Initialized (State.Connection.HTTP_3)
         then
            H3.Poll
              (State.Connection.HTTP_3,
               State.Connection.QUIC_Transport,
               State.Connection.HTTP_3_Event.all, Status);
            if Status = H3.Succeeded then
               H3_Connections.Publish
                 (State.Connection.HTTP_3_Streams,
                  State.Connection.HTTP_3_Event.all, Accepted);
               if H3_Connections.Has_Response_Observation
                 (State.Connection.HTTP_3_Streams,
                  State.Metadata.HTTP_3_Handle)
               then
                  State.Result.Admission := Response_Observed;
                  State.Metadata.Saw_Response_Bytes := True;
               end if;
               if not Accepted then
                  Fail_Exchange (Item, Response_Invalid);
                  return;
               end if;
               if not State.HTTP_3_Cancelling then
                  Observe_HTTP_3_Head (Head_Ready);
               end if;
               if State.Driver_State = Exchange_Done then
                  return;
               end if;
               if not State.HTTP_3_Cancelling then
                  Release_HTTP_3_Pump;
                  State.Driver_State := HTTP_3_Waiting_For_Pump;
                  Reschedule;
                  return;
               end if;
            elsif Status /= H3.No_Event then
               --  Poll failures are connection-level H3/QPACK failures after
               --  peer protocol input was observed, not a malformed response
               --  confined to this stream.
               State.Result.Admission := Response_Observed;
               State.Metadata.Saw_Response_Bytes := True;
               Fail_HTTP_3_Connection (Transport_Failed);
               return;
            end if;
         end if;

         if not State.HTTP_3_Cancelling then
            Observe_HTTP_3_Head (Head_Ready);
         end if;
         if State.Driver_State = Exchange_Done then
            return;
         elsif Head_Ready and then State.HTTP_3_Finished then
            State.Metadata.Reusable := H3_Connections.Is_Usable
              (State.Connection.HTTP_3_Streams);
            Finish_Decoded_Body;
            return;
         end if;

         case State.HTTP_3_Stage is
            when HTTP_3_Send_Flight =>
               if State.HTTP_3_Flight_Next <= State.HTTP_3_Flight.Count then
                  declare
                     Index : constant Positive :=
                       Positive (State.HTTP_3_Flight_Next);
                  begin
                     State.HTTP_3_Flight_Next :=
                       State.HTTP_3_Flight_Next + 1;
                     Queue_HTTP_3_Packet
                       (State.HTTP_3_Flight.Items (Index),
                        HTTP_3_Send_Flight);
                  end;
               else
                  State.HTTP_3_Flight.Count := 0;
                  State.HTTP_3_Stage := State.HTTP_3_After_Flight;
                  Reschedule;
               end if;

            when HTTP_3_Handshake =>
               if QUIC.Is_Connected (State.Connection.QUIC_Transport) then
                  State.HTTP_3_Stage := HTTP_3_Start_Control;
                  Reschedule;
               else
                  Start_HTTP_3_Receive;
               end if;

            when HTTP_3_Start_Control =>
               if not H3.Is_Initialized (State.Connection.HTTP_3) then
                  H3.Initialize (State.Connection.HTTP_3, H3.Client);
               end if;
               H3.Start
                 (State.Connection.HTTP_3,
                  State.Connection.QUIC_Transport,
                  HTTP_3_Now, Packet, Status);
               if Status = H3.Succeeded then
                  Queue_HTTP_3_Packet (Packet, HTTP_3_Open_Request);
               elsif Status = H3.Transport_Blocked then
                  Transport_Blocked;
               else
                  Fail_Exchange
                    (Item,
                     (if Owner.Pool.Is_Stopping
                      then Client_Unavailable else Connection_Failed));
               end if;

            when HTTP_3_Open_Request =>
               if State.Creating then
                  Owner.Pool.Install
                    (Positive (State.Slot_Index), State.Connection,
                     Ada.Real_Time.Clock);
                  State.Creating := False;
                  Prepare_HTTP_3_Request;
                  return;
               end if;
               H3.Open_Request
                 (State.Connection.HTTP_3,
                  State.Connection.QUIC_Transport, Stream, Status);
               if Status = H3.Succeeded then
                  H3_Connections.Bind
                    (State.Connection.HTTP_3_Streams,
                     State.Metadata.HTTP_3_Handle, Stream);
                  State.Metadata.HTTP_3_Stream := Stream;
                  State.HTTP_3_Stage := HTTP_3_Send_Head;
                  Reschedule;
               elsif Status in H3.Stream_Limit_Reached |
                   H3.Transport_Blocked
               then
                  Transport_Blocked;
               else
                  Fail_Exchange (Item, Transport_Failed);
               end if;

            when HTTP_3_Send_Head =>
               H3.Send_Headers
                 (State.Connection.HTTP_3,
                  State.Connection.QUIC_Transport,
                  State.Metadata.HTTP_3_Stream,
                  State.HTTP_3_Headers,
                  Fin => State.Source_Item = null
                    and then State.Request_Content_Length = 0,
                  Now => HTTP_3_Now,
                  Packet => Packet,
                  Status => Status);
               if Status = H3.Succeeded then
                  State.Result.Admission := Possibly_Admitted;
                  State.Result.Last_Phase :=
                    (if State.Source_Item = null
                       and then State.Request_Content_Length = 0
                     then Waiting_Response_Head else Sending_Request_Body);
                  Queue_HTTP_3_Packet
                    (Packet,
                     (if State.Source_Item /= null then HTTP_3_Pull_Source
                      elsif State.Request_Content_Length > 0 then
                        HTTP_3_Prepare_Retained
                      else HTTP_3_Wait_Response_Head));
               elsif Status = H3.Transport_Blocked then
                  Transport_Blocked;
               else
                  Fail_Exchange (Item, Transport_Failed);
               end if;

            when HTTP_3_Prepare_Retained =>
               declare
                  Remaining_Bytes : constant Natural :=
                    State.Request_Content_Length - State.Output_Cursor + 1;
                  Count : constant Natural := Natural'Min
                    (Remaining_Bytes, 1_024);
               begin
                  for Offset in 0 .. Count - 1 loop
                     State.Buffer
                       (State.Buffer'First +
                          Ada.Streams.Stream_Element_Offset (Offset)) :=
                       Flyology.Bytes.Element
                         (State.Request_Item.Body_Value,
                          State.Output_Cursor + Offset);
                  end loop;
                  State.Buffer_First := 1;
                  State.Buffer_Last := Count;
                  State.HTTP_3_Send_Final := Count = Remaining_Bytes;
                  State.HTTP_3_Stage := HTTP_3_Send_Retained;
                  Reschedule;
               end;

            when HTTP_3_Send_Retained =>
               H3.Send_Data
                 (State.Connection.HTTP_3,
                  State.Connection.QUIC_Transport,
                  State.Metadata.HTTP_3_Stream,
                  State.Buffer
                    (State.Buffer'First .. State.Buffer'First +
                       Ada.Streams.Stream_Element_Offset
                         (State.Buffer_Last - 1)),
                  State.HTTP_3_Send_Final, HTTP_3_Now, Packet, Status);
               if Status = H3.Succeeded then
                  State.Output_Cursor :=
                    State.Output_Cursor + State.Buffer_Last;
                  Queue_HTTP_3_Packet
                    (Packet,
                     (if State.HTTP_3_Send_Final then
                        HTTP_3_Wait_Response_Head
                      else HTTP_3_Prepare_Retained));
               elsif Status = H3.Transport_Blocked then
                  Transport_Blocked;
               else
                  --  A peer can stop the request stream after publishing an
                  --  early final response.  Treat a rejected DATA write as an
                  --  incomplete upload and continue driving the response
                  --  direction before deciding that the exchange failed.
                  State.Metadata.Request_Incomplete := True;
                  State.HTTP_3_Stage := HTTP_3_Wait_Response_Head;
                  Reschedule;
               end if;

            when HTTP_3_Pull_Source =>
               Release_HTTP_3_Pump;
               declare
                  Last : Ada.Streams.Stream_Element_Offset;
                  Source_Result : Source_Step_Kind;
                  Count : Natural;
               begin
                  Read_Now
                    (State.Source_Item.all, State.Buffer, Last,
                     Source_Result);
                  Count :=
                    (if Last < State.Buffer'First then 0
                     else Natural (Last - State.Buffer'First + 1));
                  case Source_Result is
                     when Source_Progress =>
                        if Count = 0
                          or else (State.Source_Length.Is_Known
                            and then State.Source_Transferred +
                              Body_Size (Count) > State.Source_Length.Bytes)
                        then
                           Fail_Exchange (Item, Request_Source_Failed);
                           return;
                        end if;
                        State.Buffer_First := 1;
                        State.Buffer_Last := Count;
                        State.HTTP_3_Send_Final := False;
                        State.HTTP_3_Stage := HTTP_3_Send_Source;
                        H3_Connections.Signal_Outbound
                          (State.Connection.HTTP_3_Streams,
                           State.Metadata.HTTP_3_Handle);
                        Need_HTTP_3_Pump;
                     when Source_Finished =>
                        if Count /= 0 or else
                          (State.Source_Length.Is_Known and then
                             State.Source_Transferred /=
                               State.Source_Length.Bytes)
                        then
                           Fail_Exchange (Item, Request_Source_Failed);
                        else
                           State.Buffer_First := 1;
                           State.Buffer_Last := 0;
                           State.HTTP_3_Send_Final :=
                             Flyology.HTTP.Headers.Count
                               (State.Request_Item.Trailer_Fields) = 0;
                           State.HTTP_3_Stage := HTTP_3_Send_Source;
                           H3_Connections.Signal_Outbound
                             (State.Connection.HTTP_3_Streams,
                              State.Metadata.HTTP_3_Handle);
                           Need_HTTP_3_Pump;
                        end if;
                     when Source_Needs_Read | Source_Needs_Write =>
                        if Count /= 0 then
                           Fail_Exchange (Item, Request_Source_Failed);
                        else
                           declare
                              Descriptor : Flyology.IO.Descriptor;
                              Ready : Boolean;
                              Required : constant Source_Wait_Kind :=
                                Source_Wait_Kind (Source_Result);
                           begin
                              Source_Wait_Source
                                (State.Source_Item.all, Required,
                                 Descriptor, Ready);
                              if Ready then
                                 H3_Connections.Signal_Outbound
                                   (State.Connection.HTTP_3_Streams,
                                    State.Metadata.HTTP_3_Handle);
                                 Need_HTTP_3_Pump;
                              else
                                 State.HTTP_3_Source_Wait_FD := Descriptor;
                                 State.HTTP_3_Source_Wait_For_Write :=
                                   Required = Source_Needs_Write;
                                 State.HTTP_3_Source_Waiting := True;
                                 Start_HTTP_3_Receive;
                              end if;
                           end;
                        end if;
                  end case;
               exception
                  when Error : others =>
                     Remember_Failure (State, Error);
                     if State.Target = Response_Head_Target then
                        Ada.Exceptions.Save_Occurrence
                          (State.Saved_Error, Error);
                        State.Has_Saved_Error := True;
                     end if;
                     Fail_Exchange (Item, Request_Source_Failed);
               end;

            when HTTP_3_Send_Source =>
               declare
                  Empty : Ada.Streams.Stream_Element_Array (1 .. 0);
               begin
                  if State.Buffer_Last = 0 then
                     H3.Send_Data
                       (State.Connection.HTTP_3,
                        State.Connection.QUIC_Transport,
                        State.Metadata.HTTP_3_Stream, Empty,
                        State.HTTP_3_Send_Final, HTTP_3_Now,
                        Packet, Status);
                  else
                     H3.Send_Data
                       (State.Connection.HTTP_3,
                        State.Connection.QUIC_Transport,
                        State.Metadata.HTTP_3_Stream,
                        State.Buffer
                          (State.Buffer'First .. State.Buffer'First +
                             Ada.Streams.Stream_Element_Offset
                               (State.Buffer_Last - 1)),
                        False, HTTP_3_Now, Packet, Status);
                  end if;
               end;
               if Status = H3.Succeeded then
                  State.Source_Transferred := State.Source_Transferred +
                    Body_Size (State.Buffer_Last);
                  Queue_HTTP_3_Packet
                    (Packet,
                     (if State.Buffer_Last > 0 then HTTP_3_Pull_Source
                      elsif State.HTTP_3_Send_Final then
                        HTTP_3_Wait_Response_Head
                      else HTTP_3_Send_Trailers));
               elsif Status = H3.Transport_Blocked then
                  Transport_Blocked;
               else
                  --  A peer can stop the request stream after publishing an
                  --  early final response.  Treat a rejected DATA write as an
                  --  incomplete upload and continue driving the response
                  --  direction before deciding that the exchange failed.
                  State.Metadata.Request_Incomplete := True;
                  State.HTTP_3_Stage := HTTP_3_Wait_Response_Head;
                  Reschedule;
               end if;

            when HTTP_3_Send_Trailers =>
               H3.Clear (State.HTTP_3_Headers);
               for Index in 1 .. Flyology.HTTP.Headers.Count
                 (State.Request_Item.Trailer_Fields)
               loop
                  H3.Append
                    (State.HTTP_3_Headers,
                     H3.Make_Field
                       (Ada.Characters.Handling.To_Lower
                          (Flyology.HTTP.Headers.Name
                             (State.Request_Item.Trailer_Fields, Index)),
                        Flyology.HTTP.Headers.Value
                          (State.Request_Item.Trailer_Fields, Index)));
               end loop;
               H3.Send_Headers
                 (State.Connection.HTTP_3,
                  State.Connection.QUIC_Transport,
                  State.Metadata.HTTP_3_Stream, State.HTTP_3_Headers,
                  True, HTTP_3_Now, Packet, Status);
               if Status = H3.Succeeded then
                  Queue_HTTP_3_Packet
                    (Packet, HTTP_3_Wait_Response_Head);
               elsif Status = H3.Transport_Blocked then
                  Transport_Blocked;
               else
                  Fail_Exchange (Item, Transport_Failed);
               end if;

            when HTTP_3_Cancel_Request =>
               if not QUIC.Has_Stream
                 (State.Connection.QUIC_Transport,
                  State.Metadata.HTTP_3_Stream)
               then
                  --  A peer response/reset can retire the receive stream
                  --  before local cancellation reaches its drain step. With
                  --  no transport stream left, there is nothing more to put
                  --  on the wire and the pending typed outcome can complete
                  --  without poisoning sibling streams on the connection.
                  State.HTTP_3_Stage := HTTP_3_Cancel_Complete;
                  Reschedule;
                  return;
               end if;
               H3.Cancel_Request
                 (State.Connection.HTTP_3,
                  State.Connection.QUIC_Transport,
                  State.Metadata.HTTP_3_Stream,
                  (if State.Pending_Result = Response_Invalid
                   then H3.Malformed_Message
                   else H3.Cancel_Processing),
                  HTTP_3_Now, Packet, Status);
               if Status = H3.Succeeded then
                  Queue_HTTP_3_Packet
                    (Packet, HTTP_3_Cancel_Complete);
               elsif Status = H3.Transport_Blocked then
                  Transport_Blocked;
               else
                  Fail_Exchange (Item, Transport_Failed);
               end if;

            when HTTP_3_Cancel_Complete =>
               State.HTTP_3_Finished := True;
               State.HTTP_3_Cancelling := False;
               if State.Pending_Result = Response_Complete then
                  Finish_Success (Item);
               else
                  Release_Exchange_Transport (State, Reusable => True);
                  Complete_Exchange
                    (Item, State.Pending_Result,
                     (if State.Pending_Result = Cancelled
                      then Flyology.Operations.Cancelled
                      else Flyology.Operations.Failed));
               end if;

            when HTTP_3_Probe_Upload_Response =>
               Start_HTTP_3_Receive (Probe => True);

            when HTTP_3_Wait_Response_Head =>
               if H3_Connections.Owns_Pump
                 (State.Connection.HTTP_3_Streams,
                  State.Metadata.HTTP_3_Handle)
               then
                  Start_HTTP_3_Receive;
               else
                  State.Driver_State := HTTP_3_Waiting_For_Pump;
                  Reschedule;
               end if;

            when HTTP_3_Read_Response_Body =>
               declare
                  Result : H3_Connections.Body_Result;
                  Last : Ada.Streams.Stream_Element_Offset;
                  Finished : Boolean;
                  Trailers : Flyology.HTTP.Headers.List;
               begin
                  H3_Connections.Read
                    (State.Connection.HTTP_3_Streams,
                     State.Metadata.HTTP_3_Handle,
                     State.Buffer, Last, Finished, Result, Trailers);
                  case Result is
                     when H3_Connections.Body_Progress =>
                        if Last >= State.Buffer'First then
                           Deliver
                             (State.Buffer (State.Buffer'First .. Last));
                        end if;
                        if HTTP_3_Receive_Credit_Due
                          (State.Connection.all,
                           QUIC.Stream_Offset (State.HTTP_3_Decoded_Length),
                           State.HTTP_3_Last_Stream_Credit)
                        then
                           State.HTTP_3_After_Credit :=
                             HTTP_3_Read_Response_Body;
                           State.HTTP_3_Stage :=
                             HTTP_3_Return_Response_Credit;
                           Reschedule;
                        else
                           Yield_HTTP_3_Pump;
                        end if;
                     when H3_Connections.Body_Finished =>
                        if Last >= State.Buffer'First then
                           Deliver
                             (State.Buffer (State.Buffer'First .. Last));
                        end if;
                        State.Metadata.Trailers := Trailers;
                        State.HTTP_3_Finished := True;
                        State.Metadata.Reusable :=
                          H3_Connections.Is_Usable
                            (State.Connection.HTTP_3_Streams);
                        if HTTP_3_Receive_Credit_Due
                          (State.Connection.all,
                           QUIC.Stream_Offset (State.HTTP_3_Decoded_Length),
                           State.HTTP_3_Last_Stream_Credit)
                        then
                           State.HTTP_3_After_Credit :=
                             HTTP_3_Finish_Response_Body;
                           State.HTTP_3_Stage :=
                             HTTP_3_Return_Response_Credit;
                           Reschedule;
                        else
                           Finish_Decoded_Body;
                        end if;
                     when H3_Connections.Body_Would_Block =>
                        if H3_Connections.Owns_Pump
                          (State.Connection.HTTP_3_Streams,
                           State.Metadata.HTTP_3_Handle)
                        then
                           Start_HTTP_3_Receive;
                        else
                           State.Driver_State := HTTP_3_Waiting_For_Pump;
                           Reschedule;
                        end if;
                     when H3_Connections.Body_Connection_Failed =>
                        Fail_Exchange (Item, Transport_Failed);
                     when H3_Connections.Body_Stream_Failed =>
                        Fail_Exchange (Item, Response_Invalid);
                  end case;
               end;

            when HTTP_3_Return_Response_Credit =>
               declare
                  Credit_Status : QUIC.Send_Status;
               begin
                  Build_HTTP_3_Receive_Credit
                    (State.Connection.all,
                     QUIC.Stream_Offset (State.HTTP_3_Decoded_Length),
                     State.HTTP_3_Last_Stream_Credit,
                     HTTP_3_Now, Packet,
                     Credit_Status);
                  case Credit_Status is
                     when QUIC.Sent =>
                        Queue_HTTP_3_Packet
                          (Packet, State.HTTP_3_After_Credit);
                     when QUIC.Congestion_Blocked =>
                        Transport_Blocked;
                     when others =>
                        Fail_Exchange (Item, Transport_Failed);
                  end case;
               end;

            when HTTP_3_Finish_Response_Body =>
               Finish_Decoded_Body;
         end case;
      exception
         when Error : others =>
            Remember_Failure (State, Error);
            Fail_Exchange (Item, Transport_Failed);
      end Drive_HTTP_3_Protocol;

      Checkout    : Checkout_Result;
      Verify      : Boolean;
      Index       : Natural;
      Connection  : Pooled_Connection_Access;
      Acquisition : Connection_Drivers.Acquisition_Result;
      Preferred_HTTP_3 : Boolean := False;
      Preferred_HTTP_3_Port : Port_Number := Port_Number'First;
   begin
      case State.Driver_State is
         when Exchange_Idle | Waiting_For_Pool =>
            if State.Pool_Waiter then
               Owner.Pool.Unregister_Waiter;
               State.Pool_Waiter := False;
            end if;
            State.Result.Last_Phase := Admission_Wait;
            if State.Retry_Address_Pending then
               Preferred_HTTP_3 := State.Creating_HTTP_3;
               Preferred_HTTP_3_Port := State.Connection_Port;
            elsif Owner.Protocol_Policy = Require_HTTP_3 then
               Preferred_HTTP_3 := True;
               Preferred_HTTP_3_Port := Port (Owner.Origin_Value);
            elsif Owner.Protocol_Policy = Negotiate_HTTP_3 then
               Owner.HTTP_3_Alternative.Preferred
                 (Ada.Real_Time.Clock, Preferred_HTTP_3,
                  Preferred_HTTP_3_Port);
            end if;
            Owner.Pool.Try_Checkout
              (Now                => Ada.Real_Time.Clock,
               Prefer_HTTP_3      => Preferred_HTTP_3,
               Allow_TCP_Fallback =>
                 Owner.Protocol_Policy = Negotiate_HTTP_3,
               Result             => Checkout,
               Slot_Index         => Index,
               Connection         => Connection,
               Verify             => Verify);
            case Checkout is
               when Checkout_Idle =>
                  State.Connection := Connection;
                  State.Slot_Index := Index;
                  State.Was_Reused := True;
                  if Verify then
                     --  Retain enough lease metadata for transactional close
                     --  if the bounded quiescence probe sees delayed bytes.
                     State.Metadata := (others => <>);
                     State.Metadata.Owner := Owner;
                     State.Metadata.Connection := Connection;
                     State.Metadata.Slot_Index := Index;
                     State.Driver_State := Starting_Reused_Verification;
                     Reschedule;
                  else
                     Prepare_Request;
                  end if;
               when Checkout_Create =>
                  State.Slot_Index := Index;
                  State.Creating := True;
                  if not State.Retry_Address_Pending then
                     State.Creating_HTTP_3 := Preferred_HTTP_3;
                     State.Connection_Port :=
                       (if Preferred_HTTP_3 then Preferred_HTTP_3_Port
                        else Port (Owner.Origin_Value));
                  end if;
                  State.Driver_State :=
                    (if State.Retry_Address_Pending
                     then Preparing_Resolved_Address
                     else Preparing_Connect);
                  Reschedule;
               when Checkout_Discard =>
                  Close_And_Finish (Owner, Positive (Index), Connection);
                  Reschedule;
               when Checkout_Busy =>
                  Owner.Pool.Register_Waiter;
                  State.Pool_Waiter := True;
                  State.Driver_State := Waiting_For_Pool;
                  Arm_Pool;
               when Checkout_Closed =>
                  Fail_Exchange (Item, Client_Unavailable);
            end case;

         when Preparing_Connect =>
            Start_Connect;

         when Preparing_Resolved_Address =>
            Start_Resolved_Address;

         when Waiting_For_DNS =>
            if Event /= Flyology.Operations.Dependency_Changed
              or else not Flyology.Operations.Is_Terminal (State.DNS_Child)
            then
               raise Program_Error with
                 "HTTP DNS child resumed without a terminal dependency";
            end if;
            begin
               declare
                  Addresses : constant Flyology.IO.DNS.Address_Array :=
                    Flyology.IO.DNS.Finish (State.DNS_Child);
               begin
                  Flyology.Operations.Release (State.DNS_Child);
                  State.Active_Child := No_Exchange_Child;
                  if Addresses'Length = 0
                    or else Addresses'Length > Max_Resolved_Addresses
                  then
                     Fail_Exchange (Item, Connection_Failed);
                     return;
                  end if;
                  State.Resolved_Count := Addresses'Length;
                  State.Resolved_Next := 1;
                  for Offset in 0 .. Addresses'Length - 1 loop
                     State.Resolved_Addresses (Offset + 1) :=
                       Addresses (Addresses'First + Offset);
                  end loop;
                  Start_Resolved_Address;
               end;
            exception
               when Error : Flyology.IO.Timeout_Error =>
                  begin
                     Flyology.Operations.Release (State.DNS_Child);
                  exception
                     when others => null;
                  end;
                  State.Active_Child := No_Exchange_Child;
                  Remember_Failure (State, Error);
                  Fail_Exchange (Item, Timed_Out);
               when Error : Flyology.Cancellation.Operation_Cancelled =>
                  begin
                     Flyology.Operations.Release (State.DNS_Child);
                  exception
                     when others => null;
                  end;
                  State.Active_Child := No_Exchange_Child;
                  Remember_Failure (State, Error);
                  Fail_Exchange
                    (Item, Cancelled, Flyology.Operations.Cancelled);
               when Error : others =>
                  begin
                     Flyology.Operations.Release (State.DNS_Child);
                  exception
                     when others => null;
                  end;
                  State.Active_Child := No_Exchange_Child;
                  Remember_Failure (State, Error);
                  Fail_Exchange
                    (Item,
                     (if Owner.Pool.Is_Stopping
                      then Client_Unavailable else Connection_Failed));
            end;

         when Waiting_For_Connect =>
            if Event /= Flyology.Operations.Dependency_Changed
              or else not Flyology.Operations.Is_Terminal
                (State.Connect_Child)
            then
               raise Program_Error with
                 "HTTP connect child resumed without a terminal dependency";
            end if;
            begin
               Sockets.Finish (State.Connect_Child);
               Flyology.Operations.Release (State.Connect_Child);
               State.Active_Child := No_Exchange_Child;
               Install_Connected_Socket;
            exception
               when Error : others =>
                  if not Flyology.Operations.Is_Active (State.Connect_Child)
                    and then not Flyology.Operations.Is_Terminal
                      (State.Connect_Child)
                  then
                     begin
                        Flyology.Operations.Release (State.Connect_Child);
                     exception
                        when others => null;
                     end;
                  end if;
                  State.Active_Child := No_Exchange_Child;
                  Remember_Failure (State, Error);
                  Fail_Exchange
                    (Item,
                     (if Owner.Pool.Is_Stopping
                      then Client_Unavailable else Connection_Failed));
            end;

         when Waiting_For_TLS =>
            if Event /= Flyology.Operations.Dependency_Changed
              or else not Flyology.Operations.Is_Terminal (State.TLS_Child)
            then
               raise Program_Error with
                 "HTTP TLS child resumed without a terminal dependency";
            end if;
            begin
               Flyology.IO.Connections.TLS.Finish (State.TLS_Child);
               Flyology.Operations.Release (State.TLS_Child);
               State.Active_Child := No_Exchange_Child;
               if Owner.Protocol_Policy = HTTP_1_Only then
                  State.Connection.Protocol := HTTP_1_Transport;
               else
                  declare
                     Selected : constant String :=
                       Flyology.IO.Connections.TLS.Selected_Protocol
                         (State.Connection.Channel);
                  begin
                     if Selected = "h2" then
                        State.Connection.Protocol := HTTP_2_Transport;
                        H2_Connections.Create
                          (State.Connection.HTTP_2);
                     elsif Owner.Protocol_Policy in
                       Negotiate_HTTP_2 | Negotiate_HTTP_3
                       and then
                         (Selected = "" or else Selected = "http/1.1")
                     then
                        State.Connection.Protocol := HTTP_1_Transport;
                     else
                        raise Protocol_Error with
                          "TLS peer did not negotiate required HTTP/2";
                     end if;
                  end;
               end if;
               Owner.Pool.Install
                 (Positive (State.Slot_Index), State.Connection,
                  Ada.Real_Time.Clock);
               State.Creating := False;
               Prepare_Request;
            exception
               when Error : others =>
                  if not Flyology.Operations.Is_Active (State.TLS_Child)
                    and then not Flyology.Operations.Is_Terminal
                      (State.TLS_Child)
                  then
                     begin
                        Flyology.Operations.Release (State.TLS_Child);
                     exception
                        when others => null;
                     end;
                  end if;
                  State.Active_Child := No_Exchange_Child;
                  Remember_Failure (State, Error);
                  Fail_Exchange
                    (Item,
                     (if Owner.Pool.Is_Stopping
                      then Client_Unavailable else Connection_Failed));
            end;

         when Starting_Reused_Verification =>
            Start_Reused_Verification;

         when Waiting_For_Reused_Verification_Lease =>
            Connection_Drivers.Poll_Acquisition (State.IO, Acquisition);
            if Acquisition = Connection_Drivers.Acquired then
               State.Driver_State := Reading_Reused_Verification;
               Reschedule;
            else
               Connection_Drivers.Arm_Acquisition (State.IO, Item);
               Connection_Drivers.Arm_Deadline (State.IO, Item);
            end if;

         when Reading_Reused_Verification =>
            Verify_Reused_Transport;

         when Preparing_Verified_Request =>
            Prepare_Request;

         when Waiting_For_Connection_Lease =>
            Connection_Drivers.Poll_Acquisition (State.IO, Acquisition);
            if Acquisition = Connection_Drivers.Acquired then
               State.Driver_State := Sending_Head;
               State.Result.Last_Phase := Sending_Request_Head;
               Reschedule;
            else
               Connection_Drivers.Arm_Acquisition (State.IO, Item);
               Connection_Drivers.Arm_Deadline (State.IO, Item);
            end if;

         when Sending_Head =>
            Send_Head;
         when Sending_Retained_Content =>
            Send_Retained;
         when Pulling_Source =>
            Pull_Source;
         when Sending_Source_Prefix =>
            Send_Source_Control (Sending_Source_Content);
         when Sending_Source_Content =>
            Send_Source;
         when Sending_Source_Suffix =>
            Send_Source_Control (Pulling_Source);
         when Sending_Source_End =>
            Send_Source_Control (Receiving_Head);
         when Probing_Early_Response =>
            Probe_Early_Response;
         when Receiving_Head =>
            Receive_Head;
         when Receiving_Content =>
            Receive_Content_Step;
         when HTTP_2_Protocol_Step =>
            case State.HTTP_2_Stage is
               when HTTP_2_Upload =>
                  Upload_HTTP_2_Source;
               when HTTP_2_Response_Head =>
                  Poll_HTTP_2_Head (Early => False);
               when HTTP_2_Response_Body =>
                  Read_HTTP_2_Body;
            end case;
         when HTTP_2_Waiting_For_Pump =>
            --  A stream wake can mean either that the shared pump became
            --  claimable or that another owner published this stream's head,
            --  body, or failure while we waited. Re-poll the stream first;
            --  claiming and arming the transport immediately would ignore an
            --  already-published response and could sleep until deadline.
            if State.HTTP_2_Cancelling
              or else State.HTTP_2_Settling
              or else State.HTTP_2_Flush_Pending
            then
               Need_HTTP_2_Pump;
            else
               State.Driver_State := HTTP_2_Protocol_Step;
               Reschedule;
            end if;
         when HTTP_2_Waiting_For_Connection_Lease =>
            Connection_Drivers.Poll_Acquisition
              (State.IO, Acquisition);
            if Acquisition = Connection_Drivers.Acquired then
               State.Driver_State := HTTP_2_Driving_Pump;
               Reschedule;
            else
               Connection_Drivers.Arm_Acquisition (State.IO, Item);
               Connection_Drivers.Arm_Deadline (State.IO, Item);
            end if;
         when HTTP_2_Driving_Pump =>
            Drive_HTTP_2_Pump;
         when HTTP_3_Starting =>
            State.Driver_State := HTTP_3_Protocol_Step;
            Reschedule;
         when HTTP_3_Protocol_Step =>
            Drive_HTTP_3_Protocol;
         when HTTP_3_Waiting_For_Pump =>
            Need_HTTP_3_Pump;
         when HTTP_3_Sending_Datagram =>
            if Event /= Flyology.Operations.Dependency_Changed
              or else not Flyology.Operations.Is_Terminal
                (State.UDP_Send_Child)
            then
               raise Program_Error with
                 "HTTP/3 send resumed without a terminal dependency";
            end if;
            begin
               declare
                  Last : Ada.Streams.Stream_Element_Offset;
               begin
                  Sockets.Finish (State.UDP_Send_Child, Last);
                  if Last /= Ada.Streams.Stream_Element_Offset
                    (State.HTTP_3_Output_Last)
                  then
                     raise Flyology.IO.Device_Error with
                       "partial HTTP/3 datagram send";
                  end if;
               end;
               Flyology.Operations.Release (State.UDP_Send_Child);
               Free_Stream_Element_Array (State.HTTP_3_Output_Item);
               State.Active_Child := No_Exchange_Child;
               State.HTTP_3_Stage := State.HTTP_3_After_Send;
               if State.HTTP_3_After_Send in
                 HTTP_3_Prepare_Retained | HTTP_3_Pull_Source
               then
                  State.HTTP_3_After_Probe := State.HTTP_3_After_Send;
                  State.HTTP_3_Stage := HTTP_3_Probe_Upload_Response;
               end if;
               if State.Metadata.HTTP_3_Handle /= H3_Connections.No_Stream then
                  Yield_HTTP_3_Pump;
               else
                  State.Driver_State := HTTP_3_Protocol_Step;
                  Reschedule;
               end if;
            exception
               when Error : others =>
                  begin
                     Flyology.Operations.Release (State.UDP_Send_Child);
                  exception
                     when others => null;
                  end;
                  Free_Stream_Element_Array (State.HTTP_3_Output_Item);
                  State.Active_Child := No_Exchange_Child;
                  Remember_Failure (State, Error);
                  Fail_Exchange (Item, Transport_Failed);
            end;
         when HTTP_3_Receiving_Datagram =>
            if Event /= Flyology.Operations.Dependency_Changed
              or else not Flyology.Operations.Is_Terminal
                (State.UDP_Receive_Child)
            then
               raise Program_Error with
                 "HTTP/3 receive resumed without a terminal dependency";
            end if;
            declare
               Last : Ada.Streams.Stream_Element_Offset;
               Metadata : Sockets.Datagram_Metadata;
               Flight : QUIC.Datagram_Batch;
               Status : QUIC.Operation_Status;
               Timeout_Status : QUIC.Timeout_Status;
               Resume_Stage : constant HTTP_3_Exchange_Stage :=
                 State.HTTP_3_Stage;
            begin
               begin
                  Sockets.Finish
                    (State.UDP_Receive_Child, Last, Metadata);
               exception
                  when Sockets.Operation_Interrupted =>
                     declare
                        Source_Was_Armed : constant Boolean :=
                          State.HTTP_3_Source_Waiting;
                     begin
                        Flyology.Operations.Release
                          (State.UDP_Receive_Child);
                        State.Active_Child := No_Exchange_Child;
                        State.HTTP_3_Receive_Probe := False;
                        State.HTTP_3_Source_Waiting := False;
                        if Source_Was_Armed then
                           State.HTTP_3_After_Probe := State.HTTP_3_Stage;
                           Start_HTTP_3_Receive (Probe => True);
                        else
                           Yield_HTTP_3_Pump;
                        end if;
                        return;
                     end;
                  when Flyology.IO.Timeout_Error =>
                     Flyology.Operations.Release (State.UDP_Receive_Child);
                     State.Active_Child := No_Exchange_Child;
                     if State.HTTP_3_Receive_Probe then
                        State.HTTP_3_Receive_Probe := False;
                        State.HTTP_3_Source_Waiting := False;
                        State.Driver_State := HTTP_3_Protocol_Step;
                        Reschedule;
                        return;
                     end if;
                     State.HTTP_3_Source_Waiting := False;
                     if QUIC.Has_Recovery_Timeout
                       (State.Connection.QUIC_Transport)
                       and then QUIC.Recovery_Deadline
                         (State.Connection.QUIC_Transport) <= HTTP_3_Now
                     then
                        QUIC.Process_Timeout
                          (State.Connection.QUIC_Transport,
                           HTTP_3_Now, Flight, Timeout_Status);
                        if Timeout_Status = QUIC.Probes_Ready then
                           Queue_HTTP_3_Flight (Flight, Resume_Stage);
                        else
                           Fail_Exchange (Item, Transport_Failed);
                        end if;
                     else
                        Fail_Exchange (Item, Timed_Out);
                     end if;
                     return;
               end;
               Flyology.Operations.Release (State.UDP_Receive_Child);
               State.Active_Child := No_Exchange_Child;
               State.HTTP_3_Receive_Probe := False;
               State.HTTP_3_Source_Waiting := False;
               if Metadata.Truncated then
                  Fail_HTTP_3_Connection (Response_Invalid);
               elsif Last < State.HTTP_3_Input_Item.all'First then
                  State.Driver_State := HTTP_3_Protocol_Step;
                  Reschedule;
               else
                  QUIC.Process_Datagram
                    (State.Connection.QUIC_Transport,
                     State.HTTP_3_Input_Item.all
                       (State.HTTP_3_Input_Item.all'First .. Last),
                     Flight, Status, HTTP_3_Now);
                  case Status is
                     when QUIC.Succeeded | QUIC.Waiting_For_More =>
                        Queue_HTTP_3_Flight (Flight, Resume_Stage);
                     when QUIC.Connection_Closed =>
                        Fail_Exchange (Item, Transport_Failed);
                     when others =>
                        Fail_HTTP_3_Connection (Response_Invalid);
                  end case;
               end if;
            exception
               when Error : others =>
                  begin
                     Flyology.Operations.Release (State.UDP_Receive_Child);
                  exception
                     when others => null;
                  end;
                  State.Active_Child := No_Exchange_Child;
                  Remember_Failure (State, Error);
                  Fail_Exchange (Item, Transport_Failed);
            end;
         when Cancelling_Child =>
            if Event /= Flyology.Operations.Dependency_Changed then
               raise Program_Error with
                 "HTTP cancellation resumed without child completion";
            end if;
            if State.Active_Child = Connect_Exchange_Child then
               begin
                  Sockets.Finish (State.Connect_Child);
               exception
                  when others => null;
               end;
               begin
                  Flyology.Operations.Release (State.Connect_Child);
               exception
                  when others => null;
               end;
            elsif State.Active_Child = TLS_Exchange_Child then
               begin
                  Flyology.IO.Connections.TLS.Finish (State.TLS_Child);
               exception
                  when others => null;
               end;
               begin
                  Flyology.Operations.Release (State.TLS_Child);
               exception
                  when others => null;
               end;
            elsif State.Active_Child = UDP_Send_Exchange_Child then
               declare
                  Last : Ada.Streams.Stream_Element_Offset;
               begin
                  Sockets.Finish (State.UDP_Send_Child, Last);
               exception
                  when others => null;
               end;
               begin
                  Flyology.Operations.Release (State.UDP_Send_Child);
               exception
                  when others => null;
               end;
            elsif State.Active_Child = DNS_Exchange_Child then
               begin
                  declare
                     Addresses : constant Flyology.IO.DNS.Address_Array :=
                       Flyology.IO.DNS.Finish (State.DNS_Child);
                     pragma Unreferenced (Addresses);
                  begin
                     null;
                  end;
               exception
                  when others => null;
               end;
               begin
                  Flyology.Operations.Release (State.DNS_Child);
               exception
                  when others => null;
               end;
            elsif State.Active_Child = UDP_Receive_Exchange_Child then
               declare
                  Last : Ada.Streams.Stream_Element_Offset;
                  Metadata : Sockets.Datagram_Metadata;
               begin
                  Sockets.Finish
                    (State.UDP_Receive_Child, Last, Metadata);
               exception
                  when others => null;
               end;
               begin
                  Flyology.Operations.Release (State.UDP_Receive_Child);
               exception
                  when others => null;
               end;
            else
               raise Program_Error with
                 "HTTP cancellation lost its active child";
            end if;
            State.Active_Child := No_Exchange_Child;
            Fail_Exchange
              (Item, State.Pending_Result,
               (if State.Pending_Result = Cancelled
                then Flyology.Operations.Cancelled
                else Flyology.Operations.Failed));

         when Installing_Connection | Exchange_Done =>
            raise Program_Error with "invalid HTTP exchange driver state";
      end case;
   exception
      when Error : Flyology.Cancellation.Operation_Cancelled =>
         Remember_Failure (State, Error);
         Fail_Exchange (Item, Cancelled, Flyology.Operations.Cancelled);
      when Error : Flyology.IO.Timeout_Error =>
         Remember_Failure (State, Error);
         Fail_Exchange (Item, Timed_Out);
      when Error : Protocol_Error | Response_Too_Large =>
         Remember_Failure (State, Error);
         Fail_Exchange (Item, Response_Invalid);
      when Error : Sockets.Socket_Error | Flyology.IO.Device_Error |
           Flyology.IO.TLS.TLS_Error =>
         Remember_Failure (State, Error);
         Fail_Exchange
           (Item,
            (if State.Result.Admission = Not_Admitted
             then Connection_Failed else Transport_Failed));
      when Error : others =>
         Ada.Exceptions.Save_Occurrence (State.Saved_Error, Error);
         State.Has_Saved_Error := True;
         Release_Exchange_Transport (State, Reusable => False);
         Complete_Exchange
           (Item, Transport_Failed, Flyology.Operations.Failed);
   end Drive_Exchange_Engine;

   procedure Validate_Response_Bytes_For_Testing
     (Value : Ada.Streams.Stream_Element_Array) is
   begin
      HTTP_1_Internals.Validate_Response (Value);
   end Validate_Response_Bytes_For_Testing;

   procedure Observe_HTTP_3_Alternative
     (Item : in out Client; Fields : Flyology.HTTP.Headers.List)
   is
      Maximum_Age : constant Natural := 31 * 24 * 60 * 60;
      Changed : Boolean := False;

      procedure Parse (Text : String) is
         Lower : constant String := Ada.Characters.Handling.To_Lower (Text);
         Pattern : constant String := "h3="":";
         Marker : Natural := Ada.Strings.Fixed.Index (Lower, Pattern);
         First_Digit : Natural;
         Quote : Natural := 0;
         Port_Value : Natural := 0;
         Age_Value : Natural := 86_400;
      begin
         while Marker /= 0
           and then Marker > Lower'First
           and then Lower (Marker - 1) not in ',' | ' ' | Character'Val (9)
         loop
            Marker := Ada.Strings.Fixed.Index
              (Lower, Pattern, From => Marker + 1);
         end loop;
         if Lower = "clear" then
            Item.Control.State.HTTP_3_Alternative.Clear;
            Changed := True;
            return;
         elsif Marker = 0 then
            return;
         end if;
         First_Digit := Marker + 5;
         if First_Digit > Lower'Last then
            return;
         end if;
         for Index in First_Digit .. Lower'Last loop
            if Lower (Index) = '"' then
               Quote := Index;
               exit;
            elsif Lower (Index) not in '0' .. '9' then
               return;
            elsif Port_Value > 6_553 then
               return;
            else
               Port_Value := Port_Value * 10 +
                 Character'Pos (Lower (Index)) - Character'Pos ('0');
            end if;
         end loop;
         if Quote = 0 or else Quote = First_Digit
           or else Port_Value not in 1 .. 65_535
         then
            return;
         end if;
         if Quote < Lower'Last then
            declare
               Age_Marker : constant Natural := Ada.Strings.Fixed.Index
                 (Lower (Quote + 1 .. Lower'Last), "ma=");
            begin
               if Age_Marker /= 0 then
                  Age_Value := 0;
                  declare
                     Age_First : constant Natural := Age_Marker + 3;
                  begin
                     if Age_First > Lower'Last
                       or else Lower (Age_First) not in '0' .. '9'
                     then
                        return;
                     end if;
                     for Index in Age_First .. Lower'Last loop
                        exit when Lower (Index) not in '0' .. '9';
                        if Age_Value < Maximum_Age then
                           Age_Value := Natural'Min
                             (Maximum_Age,
                              Age_Value * 10 +
                                Character'Pos (Lower (Index)) -
                                Character'Pos ('0'));
                        end if;
                     end loop;
                  end;
               end if;
            end;
         end if;
         Item.Control.State.HTTP_3_Alternative.Remember
           (Port_Number (Port_Value), Duration (Age_Value));
         Changed := True;
      end Parse;
   begin
      if Item.Control.State.Protocol_Policy /= Negotiate_HTTP_3 then
         return;
      end if;
      for Index in 1 .. Flyology.HTTP.Headers.Count (Fields, "Alt-Svc") loop
         Parse (Flyology.HTTP.Headers.Value (Fields, "Alt-Svc", Index));
         exit when Changed;
      end loop;
   end Observe_HTTP_3_Alternative;

   function Same_Origin (Left, Right : Origin) return Boolean is
     (Scheme (Left) = Scheme (Right)
        and then Host (Left) = Host (Right)
        and then Port (Left) = Port (Right));

   function Without_Fragment (Value : String) return String is
      Marker : constant Natural := Ada.Strings.Fixed.Index (Value, "#");
   begin
      if Marker = 0 then
         return Value;
      elsif Marker = Value'First then
         return "";
      else
         return Value (Value'First .. Marker - 1);
      end if;
   end Without_Fragment;

   function Path_Part (Target : String) return String is
      Marker : constant Natural := Ada.Strings.Fixed.Index (Target, "?");
   begin
      return
        (if Marker = 0 then Target
         elsif Marker = Target'First then "/"
         else Target (Target'First .. Marker - 1));
   end Path_Part;

   function Remove_Dot_Segments (Value : String) return String is
      Input  : Unbounded_String := To_Unbounded_String (Value);
      Output : Unbounded_String;

      procedure Remove_Last_Output_Segment is
         Text : constant String := To_String (Output);
         Slash : Natural := 0;
      begin
         for Index in reverse Text'Range loop
            if Text (Index) = '/' then
               Slash := Index;
               exit;
            end if;
         end loop;
         if Slash = 0 then
            Output := Null_Unbounded_String;
         elsif Slash = Text'First then
            Output := Null_Unbounded_String;
         else
            Output := To_Unbounded_String (Text (Text'First .. Slash - 1));
         end if;
      end Remove_Last_Output_Segment;

      procedure Move_Segment is
         Text : constant String := To_String (Input);
         Stop : Natural := Text'Last;
         Start_Search : constant Natural :=
           (if Text (Text'First) = '/' then Text'First + 1 else Text'First);
      begin
         if Start_Search <= Text'Last then
            for Index in Start_Search .. Text'Last loop
               if Text (Index) = '/' then
                  Stop := Index - 1;
                  exit;
               end if;
            end loop;
         end if;
         if Text (Text'First) = '/' and then Stop < Text'First then
            Append (Output, "/");
            Delete (Input, 1, 1);
         else
            Append (Output, Text (Text'First .. Stop));
            Delete (Input, 1, Stop - Text'First + 1);
         end if;
      end Move_Segment;
   begin
      while Length (Input) > 0 loop
         declare
            Text : constant String := To_String (Input);
         begin
            if Ada.Strings.Fixed.Index (Text, "../") = Text'First then
               Delete (Input, 1, 3);
            elsif Ada.Strings.Fixed.Index (Text, "./") = Text'First then
               Delete (Input, 1, 2);
            elsif Ada.Strings.Fixed.Index (Text, "/./") = Text'First then
               Replace_Slice (Input, 1, 3, "/");
            elsif Text = "/." then
               Input := To_Unbounded_String ("/");
            elsif Ada.Strings.Fixed.Index (Text, "/../") = Text'First then
               Replace_Slice (Input, 1, 4, "/");
               Remove_Last_Output_Segment;
            elsif Text = "/.." then
               Input := To_Unbounded_String ("/");
               Remove_Last_Output_Segment;
            elsif Text = "." or else Text = ".." then
               Input := Null_Unbounded_String;
            else
               Move_Segment;
            end if;
         end;
      end loop;
      return (if Length (Output) = 0 then "/" else To_String (Output));
   end Remove_Dot_Segments;

   procedure Resolve_Redirect
     (Base_Origin : Origin;
      Base_Target : String;
      Location    : String;
      Target      : out Unbounded_String;
      Is_Same     : out Boolean)
   is
      Reference : constant String := Without_Fragment (Location);
      Resolved_Origin : Origin := Base_Origin;
      Raw_Target : Unbounded_String;

      function First_Path_Character
        (Value : String; From : Positive) return Natural
      is
      begin
         for Index in From .. Value'Last loop
            if Value (Index) = '/' or else Value (Index) = '?' then
               return Index;
            end if;
         end loop;
         return 0;
      end First_Path_Character;

      function Has_URI_Scheme (Value : String) return Boolean is
         Colon : constant Natural := Ada.Strings.Fixed.Index (Value, ":");
         Slash : constant Natural := Ada.Strings.Fixed.Index (Value, "/");
         Query : constant Natural := Ada.Strings.Fixed.Index (Value, "?");
      begin
         return Colon /= 0
           and then (Slash = 0 or else Colon < Slash)
           and then (Query = 0 or else Colon < Query);
      end Has_URI_Scheme;

      procedure Parse_Absolute (Value : String; Scheme_Relative : Boolean) is
         Start : constant Positive :=
           (if Scheme_Relative then Value'First + 2
            else Ada.Strings.Fixed.Index (Value, "://") + 3);
         Split : constant Natural := First_Path_Character (Value, Start);
         Origin_Last : constant Natural :=
           (if Split = 0 then Value'Last else Split - 1);
         Prefix : constant String :=
           (if Scheme_Relative
            then (if Scheme (Base_Origin) = Plain_HTTP
                  then "http:" else "https:")
            else "");
      begin
         Resolved_Origin := Parse_Origin
           (Prefix & Value (Value'First .. Origin_Last));
         if Split = 0 then
            Raw_Target := To_Unbounded_String ("/");
         elsif Value (Split) = '?' then
            Raw_Target := To_Unbounded_String
              ("/" & Value (Split .. Value'Last));
         else
            Raw_Target := To_Unbounded_String (Value (Split .. Value'Last));
         end if;
      exception
         when Constraint_Error =>
            raise Redirect_Error with "invalid redirect target origin";
      end Parse_Absolute;
   begin
      if Reference'Length = 0 then
         Raw_Target := To_Unbounded_String (Base_Target);
      elsif Reference'Length >= 2
        and then Reference (Reference'First .. Reference'First + 1) = "//"
      then
         Parse_Absolute (Reference, True);
      elsif Ada.Strings.Fixed.Index (Reference, "://") /= 0 then
         declare
            Separator : constant Natural :=
              Ada.Strings.Fixed.Index (Reference, "://");
            Name : constant String :=
              Ada.Characters.Handling.To_Lower
                (Reference (Reference'First .. Separator - 1));
         begin
            if Name /= "http" and then Name /= "https" then
               raise Redirect_Error with "unsupported redirect URI scheme";
            end if;
            Parse_Absolute (Reference, False);
         end;
      elsif Has_URI_Scheme (Reference) then
         raise Redirect_Error with "unsupported redirect URI scheme";
      elsif Reference (Reference'First) = '/' then
         Raw_Target := To_Unbounded_String (Reference);
      elsif Reference (Reference'First) = '?' then
         Raw_Target := To_Unbounded_String
           (Path_Part (Base_Target) & Reference);
      else
         declare
            Base_Path : constant String := Path_Part (Base_Target);
            Slash : Natural := Base_Path'First;
         begin
            for Index in reverse Base_Path'Range loop
               if Base_Path (Index) = '/' then
                  Slash := Index;
                  exit;
               end if;
            end loop;
            Raw_Target := To_Unbounded_String
              (Base_Path (Base_Path'First .. Slash) & Reference);
         end;
      end if;

      Is_Same := Same_Origin (Base_Origin, Resolved_Origin);
      declare
         Raw : constant String := To_String (Raw_Target);
         Query : constant Natural := Ada.Strings.Fixed.Index (Raw, "?");
         Path : constant String :=
           (if Query = 0 then Raw else Raw (Raw'First .. Query - 1));
         Suffix : constant String :=
           (if Query = 0 then "" else Raw (Query .. Raw'Last));
      begin
         Target := To_Unbounded_String (Remove_Dot_Segments (Path) & Suffix);
      end;
   exception
      when Redirect_Error => raise;
      when others =>
         raise Redirect_Error with "invalid redirect target";
   end Resolve_Redirect;

   procedure Rewrite_Without_Content
     (Value : in out Request; As_Head : Boolean) is
      Filtered : Flyology.HTTP.Headers.List;
   begin
      for Index in 1 .. Flyology.HTTP.Headers.Count (Value.Fields) loop
         declare
            Name : constant String :=
              Flyology.HTTP.Headers.Name (Value.Fields, Index);
            Lower : constant String := Ada.Characters.Handling.To_Lower (Name);
         begin
            if not (Ada.Strings.Fixed.Index (Lower, "content-") = Lower'First
                    or else Lower = "digest")
            then
               Flyology.HTTP.Headers.Add
                 (Filtered, Name,
                  Flyology.HTTP.Headers.Value (Value.Fields, Index));
            end if;
         end;
      end loop;
      Value.Fields := Filtered;
      Flyology.HTTP.Headers.Clear (Value.Trailer_Fields);
      Value.Body_Value := Flyology.Bytes.Empty;
      Value.Expect_Continue := False;
      Value.Method_Value := To_Method (if As_Head then "HEAD" else "GET");
   end Rewrite_Without_Content;

   --  Discard an intermediate redirect body so the transport stays reusable,
   --  giving up on the transport rather than the deadline once Maximum bytes
   --  have been discarded.
   procedure Drain
     (Item    : in out Response;
      Maximum : Natural;
      Token   : access Flyology.Cancellation.Token) is
      Buffer : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Receive_Buffer_Size));
      Last : Ada.Streams.Stream_Element_Offset;
      Finished : Boolean;
      Drained : Natural := 0;
   begin
      loop
         Read_Body (Item, Buffer, Last, Finished, Token);
         exit when Finished;
         if Last >= Buffer'First then
            Drained := Drained + Natural (Last - Buffer'First + 1);
         end if;
         if Drained > Maximum then
            if Item.Data /= null and then Item.Data.Connection /= null then
               Abandon_Response (Item.Data.all);
            end if;
            exit;
         end if;
      end loop;
   end Drain;

   procedure Move_Response
     (Source      : in out Response;
      Destination : in out Response)
   is
   begin
      if Destination.Data /= null then
         raise Program_Error with
           "response move destination is not vacant";
      elsif Source.Data = null then
         raise Program_Error with "response move source is vacant";
      end if;
      Destination.Data := Source.Data;
      Source.Data := null;
   end Move_Response;

   procedure Execute_Operation_Once
     (Item    : aliased in out Client;
      Value   : Request;
      Source  : access Request_Body_Source'Class;
      Length  : Body_Length;
      Started : Ada.Real_Time.Time;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token;
      Retried : not null access Boolean;
      Output  : in out Response;
      Retry   : out Boolean)
   is
      --  One root exchange, its DNS resolver child, and the resolver's one
      --  retained socket child. Other connection and protocol stages retain
      --  at most one child beneath the exchange.
      Set : aliased Flyology.Operations.Completion_Set (3);
      Operation : Exchange_Operation (Set'Access);
      Request_Copy : aliased Request := Value;
      Deadline : constant Monotonic_Deadline :=
        Deadline_After (Remaining (Started, Timeout));
      Adapter : aliased Synchronous_Source_Adapter :=
        (Source =>
           (if Source = null
            then null
            else Legacy_Source_Borrow'(Source.all'Unchecked_Access)),
         Length => Length,
         Deadline => Deadline,
         Token =>
           (if Token = null
            then null
            else Token_Borrow'(Token.all'Unchecked_Access)),
         Released => False,
         Finish_Pending => False);
      Result : Exchange_Result;
      Reply  : Response;
      Failure_Cause : Ada.Exceptions.Exception_Id :=
        Ada.Exceptions.Null_Id;

      function Has_Mutation_Condition return Boolean is
        (Flyology.HTTP.Headers.Count (Value.Fields, "if-match") > 0
           or else
         Flyology.HTTP.Headers.Count (Value.Fields, "if-none-match") > 0
           or else
         Flyology.HTTP.Headers.Count (Value.Fields, "if-unmodified-since") > 0
           or else
         Flyology.HTTP.Headers.Count (Value.Fields, "if-range") > 0);
   begin
      Retry := False;
      if Item.Control.State = null
        or else not Item.Control.State.Is_Configured
      then
         --  Preserve the ordinary Execute contract.  Scoped callers receive
         --  the typed Client_Unavailable result, while the synchronous API
         --  has always treated an unconfigured client as a programming error.
         raise Program_Error with "HTTP client is not configured";
      end if;

      --  Redirects remain an ordinary synchronous wrapper.  Every individual
      --  hop disables nested redirect policy and is driven by the same scoped
      --  H1/H2/H3 operation engine used by public composable exchanges.
      Request_Copy.Redirects := No_Redirects;
      if Source = null then
         Start_Exchange
           (Operation, Item'Unchecked_Access, Request_Copy'Access,
            Source => null, Sink => null, Target => Response_Head_Target,
            Deadline => Deadline, Token => Token);
      else
         Start_Exchange
           (Operation, Item'Unchecked_Access, Request_Copy'Access,
            Source => Adapter'Access, Sink => null,
            Target => Response_Head_Target, Deadline => Deadline,
            Token => Token, Defer_Drive => True);
         if Flyology.Operations.Is_Active (Operation) then
            Operation.State.Source_Attached := True;
            Flyology.Operations.Drive
              (Flyology.Operations.Operation'Class (Operation),
               Flyology.Operations.Start_Operation);
         end if;
      end if;
      Flyology.Operations.Wait_All (Set);
      Failure_Cause := Operation.State.Failure_Cause;
      Scoped.Finish (Operation, Result, Reply);
      if Result.Result_Kind = Response_Complete then
         Move_Response (Reply, Output);
         return;
      elsif not Retried.all
        and then Operation.State.HTTP_2_Retryable_Refusal
        and then Is_Idempotent (Value.Method_Value)
        and then not Has_Mutation_Condition
        and then
          (Source = null
             or else Source.all in Rewindable_Request_Body_Source'Class)
      then
         --  REFUSED_STREAM and a GOAWAY last-stream boundary prove that the
         --  peer did not process this stream. Preserve the ordinary one-shot
         --  replay for unconditional, replayable synchronous requests only.
         Item.Control.State.Pool.Record_Stale_Retry;
         if Source /= null then
            Rewind (Rewindable_Request_Body_Source'Class (Source.all));
         end if;
         Retried.all := True;
         Retry := True;
         return;
      elsif not Retried.all
        and then Operation.State.Was_Reused
        and then Result.Admission in Not_Admitted | Possibly_Admitted
        and then Result.Result_Kind in
          Connection_Failed | Transport_Failed | Response_Invalid
        and then Is_Idempotent (Value.Method_Value)
        and then not Has_Mutation_Condition
        and then
          (Source = null
             or else Source.all in Rewindable_Request_Body_Source'Class)
      then
         --  Preserve the ordinary synchronous one-shot stale retry for
         --  replayable, unconditional idempotent requests. Conditional
         --  mutations are deliberately excluded once admission is possible.
         Item.Control.State.Pool.Record_Stale_Retry;
         if Source /= null then
            Rewind (Rewindable_Request_Body_Source'Class (Source.all));
         end if;
         Retried.all := True;
         Retry := True;
         return;
      else
         if Failure_Cause /= Ada.Exceptions.Null_Id
           and then
             ((Result.Result_Kind in
                 Connection_Failed | Transport_Failed | Response_Invalid
                 and then
                   (Failure_Cause = Flyology.IO.TLS.TLS_Error'Identity
                      or else Failure_Cause = Protocol_Error'Identity
                      or else Failure_Cause = Response_Too_Large'Identity))
                or else
                  (Result.Result_Kind = Transport_Failed
                     and then
                       (Failure_Cause = Flyology.IO.Device_Error'Identity
                          or else Failure_Cause =
                            Flyology.IO.Sockets.Socket_Error'Identity))
                or else Result.Result_Kind = Request_Source_Failed)
         then
            Ada.Exceptions.Raise_Exception (Failure_Cause);
         end if;
         case Result.Result_Kind is
            when Response_Complete =>
               raise Program_Error with "unreachable complete response";
            when Pre_Admission_Rejected =>
               raise Constraint_Error with "HTTP request was rejected";
            when Cancelled =>
               raise Flyology.Cancellation.Operation_Cancelled;
            when Timed_Out =>
               raise Flyology.IO.Timeout_Error;
            when Client_Unavailable =>
               raise Client_Closed;
            when Connection_Failed =>
               raise Connection_Error;
            when Transport_Failed =>
               raise Flyology.IO.Device_Error;
            when Request_Source_Failed =>
               raise Request_Body_Error;
            when Response_Invalid =>
               raise Protocol_Error;
            when Response_Body_Too_Large =>
               raise Response_Too_Large;
            when Response_Sink_Failed =>
               raise Program_Error with
                 "internal response-head exchange used a response sink";
         end case;
      end if;
   end Execute_Operation_Once;

   procedure Execute_Redirects
     (Item    : aliased in out Client;
      Value   : Request;
      Source  : access Request_Body_Source'Class;
      Length  : Body_Length;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token;
      Output  : in out Response)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Current : Request := Value;
      Current_Source : access Request_Body_Source'Class := Source;
      Current_Length : Body_Length := Length;
      Hops : Redirect_Limit := 0;
      Seen : array (Redirect_Limit) of Unbounded_String;
      Seen_Last : Redirect_Limit := 0;
      Retried : aliased Boolean := False;
   begin
      Seen (0) := Current.Target_Value;
      loop
         declare
            Reply : Response;
            Retry : Boolean;
         begin
            loop
               Execute_Operation_Once
                 (Item, Current, Current_Source, Current_Length, Started,
                  Timeout, Token, Retried'Access, Reply, Retry);
               exit when not Retry;
            end loop;
            declare
               Locations : constant Natural :=
                 Header_Count (Reply, "Location");
               Action : constant Redirect_Action := Classify_Redirect
                 (Current.Redirects.Mode = Follow_Same_Origin,
                  Locations > 0, Status (Reply),
                  Image (Current.Method_Value) = "POST",
                  Image (Current.Method_Value) = "HEAD");
               Retry_Expectation : Boolean := False;
            begin
               if Status (Reply) = 417
                 and then Current.Expect_Continue
                 and then not Retried
               then
                  --  A complete 417 conclusively rejects the expectation
                  --  before this adapter has consumed Source. Retry once
                  --  without the Expect field, inside the original absolute
                  --  budget.
                  Drain (Reply, Max_Redirect_Drain_Bytes, Token);
                  Current.Expect_Continue := False;
                  Retried := True;
                  Retry_Expectation := True;
               elsif Action = Return_Redirect_Response then
                  Move_Response (Reply, Output);
                  return;
               elsif Locations /= 1 then
                  raise Redirect_Error with
                    "redirect response has multiple Location fields";
               elsif Hops = Current.Redirects.Maximum_Hops then
                  raise Redirect_Error with "redirect hop limit exceeded";
               end if;

               if not Retry_Expectation then
                  declare
                     Next_Target : Unbounded_String;
                     Within_Origin : Boolean;
                  begin
                     Resolve_Redirect
                       (Item.Control.State.Origin_Value,
                        To_String (Current.Target_Value),
                        Header (Reply, "Location"),
                        Next_Target, Within_Origin);
                     if not Within_Origin then
                        Move_Response (Reply, Output);
                        return;
                     end if;
                     for Index in Redirect_Limit range 0 .. Seen_Last loop
                        if Seen (Index) = Next_Target then
                           raise Redirect_Error with
                             "redirect cycle detected";
                        end if;
                     end loop;

                     if Action = Follow_Preserving_Method
                       and then Current_Source /= null
                       and then Current_Source.all not in
                         Rewindable_Request_Body_Source'Class
                     then
                        raise Redirect_Error with
                          "redirect requires a rewindable request body source";
                     end if;

                     Drain (Reply, Max_Redirect_Drain_Bytes, Token);
                     if Action = Follow_As_Get
                       or else Action = Follow_As_Head
                     then
                        Rewrite_Without_Content
                          (Current, As_Head => Action = Follow_As_Head);
                        Current_Source := null;
                        Current_Length := Unknown_Length;
                     elsif Current_Source /= null then
                        if Token /= null and then Token.Requested then
                           raise Flyology.Cancellation.Operation_Cancelled;
                        elsif Timeout >= 0.0
                          and then Remaining (Started, Timeout) <= 0.0
                        then
                           raise Flyology.IO.Timeout_Error;
                        end if;
                        Rewind
                          (Rewindable_Request_Body_Source'Class
                             (Current_Source.all));
                     end if;
                     begin
                        Set_Target (Current, To_String (Next_Target));
                     exception
                        when Constraint_Error =>
                           raise Redirect_Error with
                             "invalid redirect target";
                     end;
                     Hops := Hops + 1;
                     Seen_Last := Seen_Last + 1;
                     Seen (Seen_Last) := Next_Target;
                     Retried := False;
                  end;
               end if;
            end;
         end;
      end loop;
   end Execute_Redirects;

   function Execute
     (Item    : aliased in out Client;
      Value   : Request;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null) return Response is
   begin
      return Result : Response do
         Execute_Redirects
           (Item, Value, Source => null, Length => Unknown_Length,
            Timeout => Timeout, Token => Token, Output => Result);
      end return;
   end Execute;

   procedure Execute
     (Item    : aliased in out Client;
      Value   : Request;
      Result  : in out Response;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null) is
   begin
      Finalize (Result);
      Execute_Redirects
        (Item, Value, Source => null, Length => Unknown_Length,
         Timeout => Timeout, Token => Token, Output => Result);
   end Execute;

   function Execute
     (Item    : aliased in out Client;
      Value   : Request;
      Source  : in out Request_Body_Source'Class;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null) return Response is
   begin
      return Result : Response do
         Execute_Redirects
           (Item, Value, Source => Source'Access,
            Length => Declared_Length (Source),
            Timeout => Timeout, Token => Token, Output => Result);
      end return;
   end Execute;

   procedure Execute
     (Item    : aliased in out Client;
      Value   : Request;
      Source  : in out Request_Body_Source'Class;
      Result  : in out Response;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null) is
   begin
      Finalize (Result);
      Execute_Redirects
        (Item, Value, Source => Source'Access,
         Length => Declared_Length (Source),
         Timeout => Timeout, Token => Token, Output => Result);
   end Execute;

   procedure Require_Response (Item : Response) is
   begin
      if Item.Data = null then
         raise Program_Error with "HTTP response is not initialized";
      end if;
   end Require_Response;

   procedure Require_Trailers (Item : Response) is
   begin
      Require_Response (Item);
      if not Item.Data.Complete then
         raise Program_Error with
           "HTTP response trailers are unavailable before body completion";
      end if;
   end Require_Trailers;

   function Status (Item : Response) return Status_Code is
   begin
      Require_Response (Item);
      return Item.Data.Status_Value;
   end Status;

   function Reason_Phrase (Item : Response) return String is
   begin
      Require_Response (Item);
      return To_String (Item.Data.Reason_Value);
   end Reason_Phrase;

   function Negotiated_Protocol (Item : Response) return Protocol is
   begin
      Require_Response (Item);
      return Item.Data.Protocol_Value;
   end Negotiated_Protocol;

   function Header_Count (Item : Response; Name : String) return Natural is
   begin
      Require_Response (Item);
      return Flyology.HTTP.Headers.Count (Item.Data.Fields, Name);
   end Header_Count;

   function Header_Count (Item : Response) return Natural is
   begin
      Require_Response (Item);
      return Flyology.HTTP.Headers.Count (Item.Data.Fields);
   end Header_Count;

   function Header_Name (Item : Response; Index : Positive) return String is
   begin
      Require_Response (Item);
      return Flyology.HTTP.Headers.Name (Item.Data.Fields, Index);
   end Header_Name;

   function Header_Value (Item : Response; Index : Positive) return String is
   begin
      Require_Response (Item);
      return Flyology.HTTP.Headers.Value (Item.Data.Fields, Index);
   end Header_Value;

   function Header
     (Item : Response; Name : String; Occurrence : Positive := 1) return String
   is
   begin
      Require_Response (Item);
      return Flyology.HTTP.Headers.Value (Item.Data.Fields, Name, Occurrence);
   end Header;

   function Trailer_Count (Item : Response; Name : String) return Natural is
   begin
      Require_Trailers (Item);
      return Flyology.HTTP.Headers.Count (Item.Data.Trailers, Name);
   end Trailer_Count;

   function Trailer_Count (Item : Response) return Natural is
   begin
      Require_Trailers (Item);
      return Flyology.HTTP.Headers.Count (Item.Data.Trailers);
   end Trailer_Count;

   function Trailer_Name (Item : Response; Index : Positive) return String is
   begin
      Require_Trailers (Item);
      return Flyology.HTTP.Headers.Name (Item.Data.Trailers, Index);
   end Trailer_Name;

   function Trailer_Value (Item : Response; Index : Positive) return String is
   begin
      Require_Trailers (Item);
      return Flyology.HTTP.Headers.Value (Item.Data.Trailers, Index);
   end Trailer_Value;

   function Trailer
     (Item : Response; Name : String; Occurrence : Positive := 1) return String
   is
   begin
      Require_Trailers (Item);
      return Flyology.HTTP.Headers.Value
        (Item.Data.Trailers, Name, Occurrence);
   end Trailer;

   procedure Read_Body
     (Item     : in out Response;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Token    : access Flyology.Cancellation.Token := null)
   is
      use type H2_Connections.Body_Result;

      Result : H2_Connections.Body_Result;

      procedure Wait_For_Progress is
         Stream_FD   : Flyology.IO.Descriptor;
         Shutdown_FD : Flyology.IO.Descriptor;
         Token_FD    : Flyology.IO.Descriptor :=
           Flyology.IO.Invalid_Descriptor;
         Ready_Now   : Boolean;
         Stopping    : Boolean;
         Cancelled   : Boolean := False;
         Selected    : Natural;
      begin
         H2_Connections.Wait_Source
           (Item.Data.Connection.HTTP_2.all, Item.Data.HTTP_2_Stream,
            Stream_FD, Ready_Now);
         if Ready_Now then
            return;
         end if;
         Item.Data.Owner.Pool.Shutdown_Source (Shutdown_FD, Stopping);
         if Stopping then
            raise Client_Closed;
         end if;
         if Token /= null then
            Token.Wait_Source (Token_FD, Cancelled);
            if Cancelled then
               raise Flyology.Cancellation.Operation_Cancelled;
            end if;
         end if;
         if Token = null then
            declare
               Sources : Flyology.IO.Wait_Request_Array (1 .. 2);
            begin
               Sources (1) :=
                 (FD => Stream_FD, Condition => Flyology.IO.For_Read);
               Sources (2) :=
                 (FD => Shutdown_FD, Condition => Flyology.IO.For_Read);
               Selected := Flyology.IO.Wait_Any
                 (Sources, Remaining (Item.Data.Started, Item.Data.Timeout));
            end;
         else
            declare
               Sources : Flyology.IO.Wait_Request_Array (1 .. 3);
            begin
               Sources (1) :=
                 (FD => Stream_FD, Condition => Flyology.IO.For_Read);
               Sources (2) :=
                 (FD => Shutdown_FD, Condition => Flyology.IO.For_Read);
               Sources (3) :=
                 (FD => Token_FD, Condition => Flyology.IO.For_Read);
               Selected := Flyology.IO.Wait_Any
                 (Sources, Remaining (Item.Data.Started, Item.Data.Timeout));
            end;
         end if;
         if Selected = 0 then
            raise Flyology.IO.Timeout_Error;
         elsif Selected = 2 then
            raise Client_Closed;
         elsif Selected = 3 then
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
      end Wait_For_Progress;

      procedure Drive_HTTP_2_Until_Ready is
         Claimed : Boolean;

         procedure Pump (IO : in out Connection_Drivers.Capability) is
            Step : H2_Connections.Pump_Step;
            FD : Flyology.IO.Descriptor;
            Ready : Boolean;
            Waited : Connection_Drivers.Wait_Result;
            Interest : Connection_Drivers.Readiness_Interest;
         begin
            loop
               H2_Connections.Drive_Pump
                 (Item.Data.Connection.HTTP_2.all,
                  Item.Data.HTTP_2_Stream, IO, Step);
               H2_Connections.Wait_Source
                 (Item.Data.Connection.HTTP_2.all,
                  Item.Data.HTTP_2_Stream, FD, Ready);
               case Step.Result is
                  when H2_Connections.Pump_Progress =>
                     --  Keep draining the already-readable transport burst
                     --  after this stream becomes ready. Otherwise a native
                     --  synchronous body reader can consume the descriptor's
                     --  edge, hand the shared pump to a lightweight sibling,
                     --  and strand frames that are still buffered for it.
                     null;
                  when H2_Connections.Pump_Need_Read |
                       H2_Connections.Pump_Need_Write =>
                     exit when Ready;
                     Interest :=
                       (if Step.Outbound_Pending
                        then Connection_Drivers.Duplex_Interest
                        elsif Step.Result = H2_Connections.Pump_Need_Write
                        then Connection_Drivers.Write_Interest
                        else Connection_Drivers.Read_Interest);
                     Connection_Drivers.Wait
                       (IO,
                        H2_Connections.Outbound
                          (Item.Data.Connection.HTTP_2.all).all,
                        Interest, Result => Waited);
                  when H2_Connections.Pump_Peer_Closed |
                       H2_Connections.Pump_Protocol_Failed =>
                     exit;
               end case;
            end loop;
         end Pump;
      begin
         H2_Connections.Try_Claim_Pump
           (Item.Data.Connection.HTTP_2.all, Item.Data.HTTP_2_Stream,
            Claimed);
         if not Claimed then
            Wait_For_Progress;
            return;
         end if;
         begin
            Connection_Drivers.Run
              (Item.Data.Connection.Channel, Pump'Access,
               Remaining (Item.Data.Started, Item.Data.Timeout), Token);
         exception
            when others =>
               H2_Connections.Release_Pump
                 (Item.Data.Connection.HTTP_2.all,
                  Item.Data.HTTP_2_Stream);
               raise;
         end;
         H2_Connections.Release_Pump
           (Item.Data.Connection.HTTP_2.all, Item.Data.HTTP_2_Stream);
      end Drive_HTTP_2_Until_Ready;

      procedure Settle_HTTP_2_Control is
         Claimed : Boolean;

         procedure Pump (IO : in out Connection_Drivers.Capability) is
            Step : H2_Connections.Pump_Step;
            Waited : Connection_Drivers.Wait_Result;
            Interest : Connection_Drivers.Readiness_Interest;
         begin
            loop
               H2_Connections.Drive_Pump
                 (Item.Data.Connection.HTTP_2.all,
                  Item.Data.HTTP_2_Stream, IO, Step);
               case Step.Result is
                  when H2_Connections.Pump_Progress =>
                     null;
                  when H2_Connections.Pump_Need_Read =>
                     exit when not Step.Outbound_Pending;
                     Connection_Drivers.Wait
                       (IO,
                        H2_Connections.Outbound
                          (Item.Data.Connection.HTTP_2.all).all,
                        Connection_Drivers.Duplex_Interest,
                        Result => Waited);
                  when H2_Connections.Pump_Need_Write =>
                     Interest :=
                       (if Step.Outbound_Pending
                        then Connection_Drivers.Duplex_Interest
                        else Connection_Drivers.Write_Interest);
                     Connection_Drivers.Wait
                       (IO,
                        H2_Connections.Outbound
                          (Item.Data.Connection.HTTP_2.all).all,
                        Interest, Result => Waited);
                  when H2_Connections.Pump_Peer_Closed |
                       H2_Connections.Pump_Protocol_Failed =>
                     exit;
               end case;
            end loop;
         end Pump;
      begin
         --  The synchronous body adapter uses the same owner-driven session
         --  pump as a scoped exchange.  Before releasing its stream, give the
         --  pump the same bounded settlement pass used by the composable
         --  driver: parse already-buffered connection control frames and
         --  commit any queued ACK, credit, or stream reset output.  This is
         --  especially important when END_STREAM and a PING arrive together,
         --  or when a stream-local failure has queued RST_STREAM.
         H2_Connections.Try_Claim_Pump
           (Item.Data.Connection.HTTP_2.all, Item.Data.HTTP_2_Stream,
            Claimed);
         if not Claimed then
            return;
         end if;
         begin
            Connection_Drivers.Run
              (Item.Data.Connection.Channel, Pump'Access,
               Remaining (Item.Data.Started, Item.Data.Timeout), Token);
         exception
            when others =>
               H2_Connections.Release_Pump
                 (Item.Data.Connection.HTTP_2.all,
                  Item.Data.HTTP_2_Stream);
               raise;
         end;
         H2_Connections.Release_Pump
           (Item.Data.Connection.HTTP_2.all, Item.Data.HTTP_2_Stream);
      end Settle_HTTP_2_Control;
   begin
      Require_Response (Item);
      if Item.Data.Engine = HTTP_1_Response then
         HTTP_1_Internals.Read_Response_Body
           (Item, Data, Last, Finished, Token);
         return;
      elsif Item.Data.Engine = HTTP_3_Response then
         if Item.Data.Complete then
            Last := Data'First - 1;
            Finished := True;
         else
            HTTP_3_Internals.Read_Response_Body
              (Item, Data, Last, Finished, Token);
         end if;
         return;
      elsif Item.Data.Complete then
         Last := Data'First - 1;
         Finished := True;
         return;
      end if;
      loop
         H2_Connections.Read
           (Item.Data.Connection.HTTP_2.all, Item.Data.HTTP_2_Stream,
            Data, Last, Finished, Result, Item.Data.Trailers);
         case Result is
            when H2_Connections.Body_Progress |
                 H2_Connections.Body_Finished =>
               if Finished then
                  declare
                     Reusable : Boolean;
                  begin
                     --  A final response can arrive while the request body
                     --  is still open. Preserve the complete response body,
                     --  then cancel the abandoned request half and commit
                     --  its RST_STREAM before making the multiplexed session
                     --  reusable. Cancelling at response-head time would
                     --  discard a nonempty response body with the stream.
                     if Item.Data.Request_Incomplete then
                        H2_Connections.Cancel_Stream
                          (Item.Data.Connection.HTTP_2.all,
                           Item.Data.HTTP_2_Stream);
                        Item.Data.Request_Incomplete := False;
                     end if;
                     Settle_HTTP_2_Control;
                     Reusable := H2_Connections.Is_Usable
                       (Item.Data.Connection.HTTP_2.all);
                     H2_Connections.Release_Stream
                       (Item.Data.Connection.HTTP_2.all,
                        Item.Data.HTTP_2_Stream);
                     Item.Data.HTTP_2_Stream := H2_Connections.No_Stream;
                     Release_Lease (Item.Data.all, Reusable);
                  end;
               end if;
               return;
            when H2_Connections.Body_Would_Block =>
               Drive_HTTP_2_Until_Ready;
            when H2_Connections.Body_Connection_Failed |
                 H2_Connections.Body_Protocol_Failed |
                 H2_Connections.Body_Stream_Failed =>
               if Result = H2_Connections.Body_Stream_Failed then
                  Settle_HTTP_2_Control;
               end if;
               declare
                  Reusable : constant Boolean :=
                    Result = H2_Connections.Body_Stream_Failed
                      and then H2_Connections.Is_Usable
                        (Item.Data.Connection.HTTP_2.all);
               begin
                  H2_Connections.Release_Stream
                    (Item.Data.Connection.HTTP_2.all,
                     Item.Data.HTTP_2_Stream);
                  Item.Data.HTTP_2_Stream := H2_Connections.No_Stream;
                  Release_Lease (Item.Data.all, Reusable);
               end;
               raise Protocol_Error with
                 "HTTP/2 response stream failed before body completion";
         end case;
      end loop;
   end Read_Body;

   function Body_Complete (Item : Response) return Boolean is
   begin
      Require_Response (Item);
      return Item.Data.Complete;
   end Body_Complete;

   procedure Read_All
     (Item    : in out Response;
      Result  : in out Flyology.Bytes.Unbounded_Bytes;
      Maximum : Natural := 1_024 * 1_024;
      Token   : access Flyology.Cancellation.Token := null)
   is
      Buffer   : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Receive_Buffer_Size));
      Last     : Ada.Streams.Stream_Element_Offset;
      Finished : Boolean;
   begin
      Flyology.Bytes.Clear (Result);
      loop
         Read_Body (Item, Buffer, Last, Finished, Token);
         if Last >= Buffer'First then
            declare
               Count : constant Natural :=
                 Natural (Last - Buffer'First + 1);
            begin
               if Flyology.Bytes.Length (Result) > Maximum
                 or else Count > Maximum - Flyology.Bytes.Length (Result)
               then
                  if Item.Data /= null
                    and then Item.Data.Connection /= null
                  then
                     Abandon_Response (Item.Data.all);
                  end if;
                  raise Response_Too_Large;
               end if;
               Flyology.Bytes.Append (Result, Buffer (Buffer'First .. Last));
            end;
         end if;
         exit when Finished;
      end loop;
   exception
      when others =>
         Flyology.Bytes.Clear (Result);
         raise;
   end Read_All;

   function Read_All
     (Item    : in out Response;
      Maximum : Natural := 1_024 * 1_024;
      Token   : access Flyology.Cancellation.Token := null)
      return Flyology.Bytes.Unbounded_Bytes
   is
      Result : Flyology.Bytes.Unbounded_Bytes;
   begin
      Read_All (Item, Result, Maximum, Token);
      return Result;
   end Read_All;

   function Diagnostics (Item : Client) return Client_Diagnostics is
   begin
      if Item.Control.State = null then
         return
           (Transport_Capacity => Item.Capacity,
            Pending_Transports | Active_Exchanges | Reusable_Transports |
              Closing_Transports | Admission_Waiters | Transports_Created |
              Transport_Reuses | Transports_Closed | Stale_Retries |
              Admission_Timeouts => 0);
      end if;
      return Item.Control.State.Pool.Snapshot;
   end Diagnostics;

   procedure Prune_Idle (Item : in out Client) is
      Found      : Boolean;
      Slot_Index : Natural;
      Connection : Pooled_Connection_Access;
   begin
      if Item.Control.State = null then
         return;
      end if;
      loop
         Item.Control.State.Pool.Take_Idle
           (Found, Slot_Index, Connection);
         exit when not Found;
         Close_And_Finish
           (Item.Control.State, Positive (Slot_Index), Connection);
      end loop;
   end Prune_Idle;

   procedure Shutdown (Item : in out Client; Timeout : Duration := 5.0) is
   begin
      if Item.Control.State = null then
         return;
      end if;
      Item.Control.State.Pool.Request_Shutdown;
      Item.Control.State.Manager.Request_Shutdown;
      Interrupt_Active (Item.Control.State);
      Prune_Idle (Item);
      if Timeout < 0.0 then
         Item.Control.State.Pool.Await_Drained;
      else
         select
            Item.Control.State.Pool.Await_Drained;
         or
            delay Timeout;
            raise Flyology.IO.Timeout_Error;
         end select;
      end if;
   end Shutdown;

   overriding procedure Finalize (Item : in out Client_Control) is
      Found      : Boolean;
      Slot_Index : Natural;
      Connection : Pooled_Connection_Access;
      Final_Reference : Boolean := False;
   begin
      if Item.State = null then
         return;
      end if;
      begin
         Item.State.Pool.Request_Shutdown;
         Item.State.Manager.Request_Shutdown;
         Interrupt_Active (Item.State);
         loop
            Item.State.Pool.Take_Idle (Found, Slot_Index, Connection);
            exit when not Found;
            Close_And_Finish
              (Item.State, Positive (Slot_Index), Connection);
         end loop;
      exception
         when others => null;
      end;
      Item.State.Lifetime.Release_Client (Final_Reference);
      if Final_Reference then
         Release_State (Item.State);
      end if;
   end Finalize;

   overriding procedure Finalize (Item : in out Response) is
      Owner           : Client_State_Access;
      Final_Reference : Boolean := False;
   begin
      if Item.Data = null then
         return;
      end if;
      Owner := Item.Data.Owner;
      if Item.Data.Connection /= null then
         Abandon_Response (Item.Data.all);
      end if;
      if Item.Data.Retains_Owner then
         Item.Data.Retains_Owner := False;
         Owner.Lifetime.Release_Response (Final_Reference);
      end if;
      Free_Response_Data (Item.Data);
      if Final_Reference then
         Release_State (Owner);
      end if;
   exception
      when others =>
         if Item.Data /= null and then Item.Data.Retains_Owner
           and then Owner /= null
         then
            Item.Data.Retains_Owner := False;
            begin
               Owner.Lifetime.Release_Response (Final_Reference);
            exception
               when others => null;
            end;
         end if;
         Free_Response_Data (Item.Data);
         if Final_Reference and then Owner /= null then
            Release_State (Owner);
         end if;
   end Finalize;

end Flyology.HTTP.Client;
