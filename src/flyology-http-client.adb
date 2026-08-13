with Ada.Characters.Handling;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;
with Flyology.HTTP.Client_Policy;
with Flyology.HTTP.HTTP_2_Client_Connection;
with Flyology.HTTP.HTTP_2_Policy;
with Flyology.HTTP.HTTP_2_Requests;
with Flyology.HTTP.HTTP_3;
with Flyology.IO;
with Flyology.IO.Connections;
with Flyology.IO.Connections.TLS;
with Flyology.IO.DNS;
with Flyology.IO.Sockets;
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
   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type Flyology.IO.Descriptor;

   package Connections renames Flyology.IO.Connections;
   package H2_Connections renames
     Flyology.HTTP.HTTP_2_Client_Connection;
   package H2_Policy renames Flyology.HTTP.HTTP_2_Policy;
   package H2_Requests renames Flyology.HTTP.HTTP_2_Requests;
   package H3 renames Flyology.HTTP.HTTP_3;
   package QUIC renames Flyology.QUIC.Connections;
   package Sockets renames Flyology.IO.Sockets;
   use type Sockets.Address_Family;
   use type H2_Connections.Session_Access;
   use type H2_Connections.Stream_Handle;
   use type H2_Policy.Retry_Action;
   use type H2_Policy.Retry_Cause;
   use type H3.Event_Kind;
   use type H3.Operation_Status;
   use type QUIC.Connection_State;
   use type QUIC.Operation_Status;
   use type QUIC.Send_Status;
   use type QUIC.Stream_ID;
   use type QUIC.Timeout_Status;

   CRLF : constant String := Character'Val (13) & Character'Val (10);
   Receive_Buffer_Size : constant Positive := 8 * 1_024;
   Request_Buffer_Size : constant Positive := 8 * 1_024;
   Max_Request_Target_Bytes : constant Positive := 8 * 1_024;

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
      procedure Reject_Reuse
        (Slot_Index : Positive;
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
        (FD : out Flyology.IO.Descriptor; Can_Checkout : out Boolean);
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
      HTTP_3_Pending : Flyology.Bytes.Unbounded_Bytes;
      HTTP_3_Pending_Offset : Natural := 0;
      HTTP_3_Stream_Ended : Boolean := False;
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
      Request_Incomplete : Boolean := False;
      Saw_Response_Bytes : Boolean := False;
      Source_Failed      : Boolean := False;
      Informational_Count : Client_Policy.Informational_Count := 0;
      Retains_Owner  : Boolean := False;
      Started        : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Timeout        : Duration := 0.0;
   end record;

   procedure Free_State is new Ada.Unchecked_Deallocation
     (Client_State, Client_State_Access);
   procedure Free_Response_Data is new Ada.Unchecked_Deallocation
     (Response_Data, Response_Data_Access);

   procedure Release_State (Item : in out Client_State_Access) is
   begin
      if Item /= null then
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
            if Connection.Protocol = HTTP_3_Transport
              and then QUIC.Is_Connected (Connection.QUIC_Transport)
            then
               declare
                  Packet : QUIC.Datagram;
                  Status : QUIC.Send_Status;
                  Last   : Ada.Streams.Stream_Element_Offset;
               begin
                  QUIC.Build_Application_Close_Datagram
                    (Connection.QUIC_Transport, Packet, Status);
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

   package HTTP_3_Internals is
      Connection_Race_Lost : exception;

      procedure Start_Connection
        (State      : not null Client_State_Access;
         Connection : not null Pooled_Connection_Access;
         Started    : Ada.Real_Time.Time;
         Timeout    : Duration;
         Token      : access Flyology.Cancellation.Token;
         Race_Token : access Flyology.Cancellation.Token := null);

      procedure Execute_Request
        (Data            : in out Response_Data;
         Value           : Request;
         Authority       : String;
         Retained_Length : Natural;
         Token           : access Flyology.Cancellation.Token);

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
   use HTTP_3_Internals;

   package Exchange_Internals is
      procedure Translate_Interruption
        (State : not null Client_State_Access;
         Token : access Flyology.Cancellation.Token)
        with No_Return;

      procedure Checkout
        (Item       : in out Client;
         Connection : out Pooled_Connection_Access;
         Slot_Index : out Positive;
         Was_Reused : out Boolean;
         Force_TCP  : Boolean;
         Started    : Ada.Real_Time.Time;
         Timeout    : Duration;
         Token      : access Flyology.Cancellation.Token);
   end Exchange_Internals;

   package body Exchange_Internals is separate;
   use Exchange_Internals;

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

      procedure Send_Streaming_Body
        (Data   : in out Response_Data;
         Source : in out Request_Body_Source'Class;
         Length : Body_Length;
         Trailers : Flyology.HTTP.Headers.List;
         Token  : access Flyology.Cancellation.Token);

      procedure Await_Continue
        (Data         : in out Response_Data;
         Wait_Timeout : Duration;
         Token        : access Flyology.Cancellation.Token;
         Final_Ready  : out Boolean);

      procedure Reset_Attempt (Data : in out Response_Data);

      procedure Read_Final_Head
        (Data  : in out Response_Data;
         Token : access Flyology.Cancellation.Token);

      procedure Select_Body_Mode
        (Data : in out Response_Data; Request_Method : Method);

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
   use HTTP_1_Internals;

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

   function Execute_Internal
     (Item    : aliased in out Client;
      Value   : Request;
      Source  : access Request_Body_Source'Class;
      Length  : Body_Length;
      Started : Ada.Real_Time.Time;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token) return Response
   is
      Connection : Pooled_Connection_Access;
      Slot       : Positive;
      Was_Reused : Boolean;
      Retained_Length : constant Natural :=
        Flyology.Bytes.Length (Value.Body_Value);
      Has_Stream_Body : constant Boolean :=
        Source /= null
          and then (not Length.Is_Known or else Length.Bytes > 0);
      Has_Request_Body : constant Boolean :=
        Retained_Length > 0 or else Has_Stream_Body;
   begin
      if Item.Control.State = null
        or else not Item.Control.State.Is_Configured
      then
         raise Program_Error with "HTTP client is not configured";
      end if;
      case Validate_Upload
        (Has_Retained_Content => Retained_Length > 0,
         Has_Source           => Source /= null,
         Source_Length_Known  => Length.Is_Known,
         Source_Has_Content   => Has_Stream_Body,
         Has_Trailers         =>
           Flyology.HTTP.Headers.Count (Value.Trailer_Fields) > 0,
         Expect_Continue      => Value.Expect_Continue)
      is
         when Reject_Mixed_Body =>
            raise Constraint_Error with
              "streaming request cannot also contain a retained body";
         when Reject_Trailer_Framing =>
            raise Constraint_Error with
              "request trailers require an unknown-length streaming body";
         when Reject_Empty_Expectation =>
            raise Constraint_Error with
              "Expect: 100-continue requires a nonempty request body";
         when Accept_Upload =>
            null;
      end case;
      Validate_Request (Value);
      return Result : Response do
         Result.Data := new Response_Data;
         Result.Data.Owner := Item.Control.State;
         Item.Control.State.Lifetime.Retain_Response;
         Result.Data.Retains_Owner := True;
         Result.Data.Started := Started;
         Result.Data.Timeout := Timeout;
         declare
            Retried        : Boolean := False;
            Use_Expectation : Boolean := Value.Expect_Continue;
            Force_TCP       : Boolean := False;

            function Replay return Replay_Kind is
              (if Source = null then Direct_Replay
               elsif Source.all in Rewindable_Request_Body_Source'Class
               then Rewindable_Stream
               else One_Shot_Stream);

            function Retry_Decision return Stale_Retry_Action is
              (Classify_Stale_Retry
                 (Replay          => Replay,
                  Was_Reused      => Was_Reused,
                  Already_Retried => Retried,
                  Idempotent      => Is_Idempotent (Value.Method_Value),
                  Saw_Response    => Result.Data.Saw_Response_Bytes,
                  Source_Failed   => Result.Data.Source_Failed,
                  Time_Remains    =>
                    Timeout < 0.0
                      or else Remaining (Started, Timeout) > 0.0));

            procedure Retry_Stale (Action : Retry_Attempt_Action) is
               Was_HTTP_3 : constant Boolean :=
                 Result.Data.Engine = HTTP_3_Response;
            begin
               if Result.Data.Engine = HTTP_2_Response
                 and then Result.Data.Connection /= null
                 and then Result.Data.HTTP_2_Stream /=
                   H2_Connections.No_Stream
               then
                  H2_Connections.Release_Stream
                    (Result.Data.Connection.HTTP_2.all,
                     Result.Data.HTTP_2_Stream);
                  Result.Data.HTTP_2_Stream := H2_Connections.No_Stream;
               end if;
               Release_Lease (Result.Data.all, False);
               Reset_Attempt (Result.Data.all);
               if Was_HTTP_3
                 and then Item.Control.State.Protocol_Policy =
                   Negotiate_HTTP_3
               then
                  Item.Control.State.HTTP_3_Alternative.Clear;
                  Force_TCP := True;
               end if;
               if Action = Rewind_And_Retry then
                  if Token /= null and then Token.Requested then
                     raise Flyology.Cancellation.Operation_Cancelled;
                  elsif Timeout >= 0.0
                    and then Remaining (Started, Timeout) <= 0.0
                  then
                     raise Flyology.IO.Timeout_Error;
                  end if;
                  Rewind
                    (Rewindable_Request_Body_Source'Class (Source.all));
               end if;
               Item.Control.State.Pool.Record_Stale_Retry;
               Retried := True;
            end Retry_Stale;

            procedure Wait_For_HTTP_2 is
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
                 (Result.Data.Connection.HTTP_2.all,
                  Result.Data.HTTP_2_Stream, Stream_FD, Ready_Now);
               if Ready_Now then
                  return;
               end if;
               Item.Control.State.Pool.Shutdown_Source
                 (Shutdown_FD, Stopping);
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
                       (Sources, Remaining (Started, Timeout));
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
                       (Sources, Remaining (Started, Timeout));
                  end;
               end if;
               if Selected = 0 then
                  raise Flyology.IO.Timeout_Error;
               elsif Selected = 2 then
                  raise Client_Closed;
               elsif Selected = 3 then
                  raise Flyology.Cancellation.Operation_Cancelled;
               end if;
            end Wait_For_HTTP_2;

            procedure Execute_HTTP_2 (Retry : out Boolean) is
               Handle    : H2_Connections.Stream_Handle;
               Accepted  : Boolean;
               Head      : H2_Connections.Head_Result;
               Finished  : Boolean;
               Fields    : Flyology.HTTP.Headers.List;
               Status    : Status_Code;

               procedure Retry_Stream (Cause : H2_Policy.Retry_Cause) is
                  H2_Replay : constant H2_Policy.Replay_Kind :=
                    (if Source = null then H2_Policy.Direct_Replay
                     elsif Source.all in
                       Rewindable_Request_Body_Source'Class
                     then H2_Policy.Rewindable_Stream
                     else H2_Policy.One_Shot_Stream);
                  Action : constant H2_Policy.Retry_Action :=
                    H2_Policy.Classify_Retry
                      (Cause           => Cause,
                       Replay          => H2_Replay,
                       Stream_Id       => H2_Connections.Identifier (Handle),
                       Last_Stream_Id  => 0,
                       Already_Retried => Retried,
                       Idempotent      => Is_Idempotent (Value.Method_Value),
                       Saw_Response    => False,
                       Source_Failed   => False,
                       Time_Remains    =>
                         Timeout < 0.0
                           or else Remaining (Started, Timeout) > 0.0);
                  Reusable : constant Boolean :=
                    Cause = H2_Policy.Refused_Stream
                      and then H2_Connections.Is_Usable
                        (Result.Data.Connection.HTTP_2.all);
               begin
                  H2_Connections.Release_Stream
                    (Result.Data.Connection.HTTP_2.all, Handle);
                  Result.Data.HTTP_2_Stream := H2_Connections.No_Stream;
                  Release_Lease (Result.Data.all, Reusable);
                  Reset_Attempt (Result.Data.all);
                  if Action = H2_Policy.Propagate_Failure then
                     raise Protocol_Error with
                       "HTTP/2 peer rejected the request stream";
                  elsif Action = H2_Policy.Rewind_And_Retry then
                     Rewind
                       (Rewindable_Request_Body_Source'Class (Source.all));
                  end if;
                  Item.Control.State.Pool.Record_Stale_Retry;
                  Retried := True;
                  Retry := True;
               end Retry_Stream;
            begin
               Retry := False;
               if Source /= null then
                  raise Constraint_Error with
                    "HTTP/2 streaming request bodies are not yet supported";
               elsif Value.Expect_Continue then
                  raise Constraint_Error with
                    "HTTP/2 Expect: 100-continue is not yet supported";
               end if;
               declare
                  Header_Block : constant Flyology.Bytes.Unbounded_Bytes :=
                    H2_Requests.Encode_Head
                      (Method_Text => Image (Value.Method_Value),
                       Scheme_Text =>
                         (if Scheme (Item.Control.State.Origin_Value) =
                            Secure_HTTPS
                          then "https" else "http"),
                       Authority => Host_Field
                         (Item.Control.State.Origin_Value),
                       Target => To_String (Value.Target_Value),
                       Fields => Value.Fields,
                       Has_Content_Length => Retained_Length > 0,
                       Content_Length => Long_Long_Integer (Retained_Length),
                       Expect_Continue => False);
               begin
                  H2_Connections.Open
                    (Result.Data.Connection.HTTP_2.all,
                     Flyology.Bytes.To_Array (Header_Block),
                     Value.Body_Value,
                     Image (Value.Method_Value) = "HEAD",
                     Handle, Accepted);
               end;
               if not Accepted then
                  Release_Lease
                    (Result.Data.all,
                     H2_Connections.Is_Usable
                       (Result.Data.Connection.HTTP_2.all));
                  Reset_Attempt (Result.Data.all);
                  Retry := True;
                  return;
               end if;
               Result.Data.Engine := HTTP_2_Response;
               Result.Data.HTTP_2_Stream := Handle;
               loop
                  H2_Connections.Poll_Head
                    (Result.Data.Connection.HTTP_2.all, Handle,
                     Head, Status, Fields, Finished);
                  case Head is
                     when H2_Connections.Head_Ready =>
                        Result.Data.Status_Value := Status;
                        Result.Data.Fields := Fields;
                        Result.Data.Protocol_Value := HTTP_2_Protocol;
                        Result.Data.Saw_Response_Bytes := True;
                        Observe_HTTP_3_Alternative
                          (Item, Result.Data.Fields);
                        if Finished then
                           H2_Connections.Release_Stream
                             (Result.Data.Connection.HTTP_2.all, Handle);
                           Result.Data.HTTP_2_Stream :=
                             H2_Connections.No_Stream;
                           Release_Lease
                             (Result.Data.all,
                              H2_Connections.Is_Usable
                                (Result.Data.Connection.HTTP_2.all));
                        end if;
                        return;
                     when H2_Connections.Head_Would_Block =>
                        Wait_For_HTTP_2;
                     when H2_Connections.Head_Refused =>
                        Retry_Stream (H2_Policy.Refused_Stream);
                        return;
                     when H2_Connections.Head_Goaway_Unprocessed =>
                        Retry_Stream (H2_Policy.Go_Away_Unprocessed);
                        return;
                     when H2_Connections.Head_Connection_Failed =>
                        raise Protocol_Error with
                          "HTTP/2 connection failed before response headers";
                  end case;
               end loop;
            end Execute_HTTP_2;
         begin
            loop
               Connection := null;
               declare
                  Preferred : Boolean := False;
                  Alternative_Port : Port_Number;
               begin
                  if not Force_TCP
                    and then Item.Control.State.Protocol_Policy =
                      Negotiate_HTTP_3
                  then
                     Item.Control.State.HTTP_3_Alternative.Preferred
                       (Ada.Real_Time.Clock, Preferred, Alternative_Port);
                  end if;
                  begin
                     Checkout
                       (Item, Connection, Slot, Was_Reused, Force_TCP,
                        Started, Timeout, Token);
                  exception
                     when Connection_Error | Protocol_Error |
                          Flyology.IO.Device_Error |
                          Flyology.IO.Timeout_Error |
                          Flyology.IO.Sockets.Socket_Error =>
                        if Preferred and then not Retried then
                           Item.Control.State.HTTP_3_Alternative.Clear;
                           Item.Control.State.Pool.Record_Stale_Retry;
                           Force_TCP := True;
                           Retried := True;
                        else
                           raise;
                        end if;
                  end;
               end;
               if Connection = null then
                  goto Retry_Admission;
               end if;
               Result.Data.Connection := Connection;
               Result.Data.Slot_Index := Slot;
               begin
                  if Connection.Protocol = HTTP_3_Transport then
                     if Source /= null then
                        raise Constraint_Error with
                          "HTTP/3 streaming request bodies are not yet " &
                          "supported";
                     end if;
                     Execute_Request
                       (Result.Data.all, Value,
                        Host_Field (Item.Control.State.Origin_Value),
                        Retained_Length, Token);
                     Observe_HTTP_3_Alternative (Item, Result.Data.Fields);
                     exit;
                  elsif Connection.Protocol = HTTP_2_Transport then
                     declare
                        Retry : Boolean;
                     begin
                        Execute_HTTP_2 (Retry);
                        if not Retry then
                           exit;
                        end if;
                     end;
                  else
                     declare
                        Head : constant String := Request_Head
                          (Item.Control.State.all, Value,
                           Streaming => Source /= null,
                           Stream_Length => Length,
                           Use_Expectation => Use_Expectation);
                     begin
                        Connections.Send_All
                          (Result.Data.Connection.Channel, Byte_Array (Head),
                           Remaining (Started, Timeout), Token => Token);
                     end;
                     declare
                        Final_Ready : Boolean := False;
                        Body_Sent   : Boolean := False;
                     begin
                        if Use_Expectation and then Has_Request_Body then
                           Await_Continue
                             (Result.Data.all, Value.Continue_Wait, Token,
                              Final_Ready);
                        end if;
                        if not Final_Ready then
                           if Retained_Length > 0 then
                              Connections.Send_All
                                (Result.Data.Connection.Channel,
                                 Flyology.Bytes.To_Array (Value.Body_Value),
                                 Remaining (Started, Timeout), Token => Token);
                           elsif Source /= null then
                              Send_Streaming_Body
                                (Result.Data.all, Source.all, Length,
                                 Value.Trailer_Fields, Token);
                           end if;
                           Body_Sent := Has_Request_Body;
                           Read_Final_Head (Result.Data.all, Token);
                        end if;
                        --  A final response before the expected body leaves
                        --  the declared Content-Length or chunked body
                        --  untransmitted, so the peer is still mid-message.
                        Result.Data.Request_Incomplete :=
                          Use_Expectation
                            and then Has_Request_Body
                            and then not Body_Sent;
                        if Classify_Expectation_Response
                          (Expectation_Sent => Use_Expectation,
                           Body_Sent        => Body_Sent,
                           Already_Retried  => Retried,
                           Status           => Result.Data.Status_Value,
                           Attempt_Allowed  =>
                             (Token = null or else not Token.Requested)
                               and then
                                 (Timeout < 0.0
                                    or else
                                      Remaining (Started, Timeout) > 0.0)) =
                          Retry_Without_Expectation
                        then
                           Release_Lease (Result.Data.all, False);
                           Reset_Attempt (Result.Data.all);
                           Use_Expectation := False;
                           Retried := True;
                        else
                           Select_Body_Mode
                             (Result.Data.all, Value.Method_Value);
                           Observe_HTTP_3_Alternative
                             (Item, Result.Data.Fields);
                           exit;
                        end if;
                     end;
                  end if;
               exception
                  when Protocol_Error =>
                     declare
                        Action : constant Stale_Retry_Action :=
                          Retry_Decision;
                     begin
                        if Action /= Propagate_Failure then
                           Retry_Stale (Retry_Attempt_Action (Action));
                        else
                           raise;
                        end if;
                     end;
                  when Flyology.IO.Device_Error |
                       Flyology.IO.Sockets.Socket_Error |
                       Flyology.IO.TLS.TLS_Error =>
                     declare
                        Action : constant Stale_Retry_Action :=
                          Retry_Decision;
                     begin
                        if Action /= Propagate_Failure then
                           Retry_Stale (Retry_Attempt_Action (Action));
                        else
                           raise;
                        end if;
                     end;
               end;
               <<Retry_Admission>>
               null;
            end loop;
         end;
      end return;
   exception
      when Flyology.Cancellation.Operation_Cancelled =>
         Translate_Interruption (Item.Control.State, Token);
      when others =>
         if Item.Control.State /= null
           and then Item.Control.State.Pool.Is_Stopping
         then
            raise Client_Closed;
         end if;
         raise;
   end Execute_Internal;

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

   function Take (Item : in out Response) return Response is
   begin
      return Result : Response do
         Result.Data := Item.Data;
         Item.Data := null;
      end return;
   end Take;

   function Execute_Redirects
     (Item    : aliased in out Client;
      Value   : Request;
      Source  : access Request_Body_Source'Class;
      Length  : Body_Length;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token) return Response
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Current : Request := Value;
      Current_Source : access Request_Body_Source'Class := Source;
      Current_Length : Body_Length := Length;
      Hops : Redirect_Limit := 0;
      Seen : array (Redirect_Limit) of Unbounded_String;
      Seen_Last : Redirect_Limit := 0;
   begin
      Seen (0) := Current.Target_Value;
      loop
         declare
            Reply : Response := Execute_Internal
              (Item, Current, Current_Source, Current_Length, Started,
               Timeout, Token);
            Locations : constant Natural := Header_Count (Reply, "Location");
            Action : constant Redirect_Action := Classify_Redirect
              (Current.Redirects.Mode = Follow_Same_Origin,
               Locations > 0, Status (Reply),
               Image (Current.Method_Value) = "POST",
               Image (Current.Method_Value) = "HEAD");
         begin
            if Action = Return_Redirect_Response then
               return Take (Reply);
            elsif Locations /= 1 then
               raise Redirect_Error with
                 "redirect response has multiple Location fields";
            elsif Hops = Current.Redirects.Maximum_Hops then
               raise Redirect_Error with "redirect hop limit exceeded";
            end if;

            declare
               Next_Target : Unbounded_String;
               Within_Origin : Boolean;
            begin
               Resolve_Redirect
                 (Item.Control.State.Origin_Value,
                  To_String (Current.Target_Value), Header (Reply, "Location"),
                  Next_Target, Within_Origin);
               if not Within_Origin then
                  return Take (Reply);
               end if;
               for Index in Redirect_Limit range 0 .. Seen_Last loop
                  if Seen (Index) = Next_Target then
                     raise Redirect_Error with "redirect cycle detected";
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
               if Action = Follow_As_Get or else Action = Follow_As_Head then
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
                     raise Redirect_Error with "invalid redirect target";
               end;
               Hops := Hops + 1;
               Seen_Last := Seen_Last + 1;
               Seen (Seen_Last) := Next_Target;
            end;
         end;
      end loop;
   end Execute_Redirects;

   function Execute
     (Item    : aliased in out Client;
      Value   : Request;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null) return Response is
     (Execute_Redirects
        (Item, Value, Source => null, Length => Unknown_Length,
         Timeout => Timeout, Token => Token));

   function Execute
     (Item    : aliased in out Client;
      Value   : Request;
      Source  : in out Request_Body_Source'Class;
      Timeout : Duration := 30.0;
      Token   : access Flyology.Cancellation.Token := null) return Response is
     (Execute_Redirects
        (Item, Value, Source => Source'Access,
         Length => Declared_Length (Source),
         Timeout => Timeout, Token => Token));

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
                     Reusable : constant Boolean :=
                       H2_Connections.Is_Usable
                         (Item.Data.Connection.HTTP_2.all);
                  begin
                     H2_Connections.Release_Stream
                       (Item.Data.Connection.HTTP_2.all,
                        Item.Data.HTTP_2_Stream);
                     Item.Data.HTTP_2_Stream := H2_Connections.No_Stream;
                     Release_Lease (Item.Data.all, Reusable);
                  end;
               end if;
               return;
            when H2_Connections.Body_Would_Block =>
               Wait_For_Progress;
            when H2_Connections.Body_Connection_Failed |
                 H2_Connections.Body_Stream_Failed =>
               H2_Connections.Release_Stream
                 (Item.Data.Connection.HTTP_2.all,
                  Item.Data.HTTP_2_Stream);
               Item.Data.HTTP_2_Stream := H2_Connections.No_Stream;
               Release_Lease (Item.Data.all, False);
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

   function Read_All
     (Item : in out Response;
      Maximum : Natural := 1_024 * 1_024;
      Token : access Flyology.Cancellation.Token := null)
      return Flyology.Bytes.Unbounded_Bytes
   is
      Result   : Flyology.Bytes.Unbounded_Bytes;
      Buffer   : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Receive_Buffer_Size));
      Last     : Ada.Streams.Stream_Element_Offset;
      Finished : Boolean;
   begin
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
