--  Regression coverage for the 2026-08-07 audit findings in the WebSocket server.
--  Every fix lands its failing reproduction here before the fix itself.
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology.Buffers;
with Flyology.Bytes;
with Flyology.Cancellation;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Routing;
with Flyology.HTTP.Server.WebSocket_Handlers;
with Flyology.IO.Sockets;

procedure WebSocket_Server_Audit is
   package Bytes renames Flyology.Bytes;
   package HTTP_Server renames Flyology.HTTP.Server;
   package Sockets renames Flyology.IO.Sockets;
   package WebSockets renames Flyology.HTTP.Server.WebSocket_Handlers;

   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element_Offset;

   CRLF : constant String := Character'Val (13) & Character'Val (10);

   --  Payload whose trailing octet can never begin a UTF-8 sequence.
   Invalid_Text : constant String := "ok" & Character'Val (16#FF#);

   Test_Peer : constant Sockets.Endpoint :=
     Sockets.Network_Endpoint (Sockets.Loopback_IPv4, 12_345);

   type Memory_Transport is limited new HTTP_Server.Transport with record
      Input  : Unbounded_String;
      Output : Unbounded_String;
   end record;

   overriding procedure Receive
     (Item    : in out Memory_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);

   overriding procedure Send_All
     (Item    : in out Memory_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);

   overriding procedure Receive
     (Item    : in out Memory_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
      Available : constant String := To_String (Item.Input);
      Count     : Natural;
   begin
      Data := (others => 0);
      Last := Data'First - 1;
      if Available'Length = 0 then
         return;
      end if;
      Count := Natural'Min (Natural (Data'Length), Available'Length);
      for Index in 1 .. Count loop
         Data (Data'First + Ada.Streams.Stream_Element_Offset (Index - 1)) :=
           Ada.Streams.Stream_Element (Character'Pos (Available (Index)));
      end loop;
      Last := Data'First + Ada.Streams.Stream_Element_Offset (Count - 1);
      Item.Input :=
        (if Count = Available'Length then Null_Unbounded_String
         else To_Unbounded_String (Available (Count + 1 .. Available'Last)));
   end Receive;

   overriding procedure Send_All
     (Item    : in out Memory_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
   begin
      for Value of Data loop
         Append (Item.Output, Character'Val (Value));
      end loop;
   end Send_All;

   --  Finding 19: the enqueue API must reject a Text_Frame payload that is
   --  not valid UTF-8 instead of admitting it and letting the owner task
   --  destroy the connection when the frame is written.
   procedure Check_Text_Frame_Admission is
      Item : WebSockets.Session
        (Capacity => 4, Byte_Limit => 4_096, Budget => null,
         Buffer_Pool => null);
      Accepted  : Boolean;
      Timed_Out : Boolean;
   begin
      WebSockets.Try_Publish
        (Item,
         (Kind => HTTP_Server.Text_Frame,
          Data => Bytes.From_Byte_String (Invalid_Text)),
         Accepted);
      pragma Assert
        (not Accepted,
         "Try_Publish admitted an invalid UTF-8 Text_Frame");
      WebSockets.Publish
        (Item,
         (Kind => HTTP_Server.Text_Frame,
          Data => Bytes.From_Byte_String (Invalid_Text)),
         Accepted);
      pragma Assert
        (not Accepted, "Publish admitted an invalid UTF-8 Text_Frame");
      WebSockets.Publish_For
        (Item,
         (Kind => HTTP_Server.Text_Frame,
          Data => Bytes.From_Byte_String (Invalid_Text)),
         Accepted, Timeout => 1.0, Timed_Out => Timed_Out);
      pragma Assert
        (not Accepted and then not Timed_Out,
         "Publish_For admitted an invalid UTF-8 Text_Frame");
      WebSockets.Try_Publish
        (Item,
         (Kind => HTTP_Server.Text_Frame,
          Data => Bytes.From_Byte_String
            ("caf" & Character'Val (16#C3#) & Character'Val (16#A9#))),
         Accepted);
      pragma Assert
        (Accepted, "Try_Publish rejected a valid multi-byte Text_Frame");
      WebSockets.Try_Publish
        (Item,
         (Kind => HTTP_Server.Binary_Frame,
          Data => Bytes.From_Byte_String (Invalid_Text)),
         Accepted);
      pragma Assert
        (Accepted, "Try_Publish rejected an arbitrary Binary_Frame");
      WebSockets.Close (Item);
   end Check_Text_Frame_Admission;

   --  Finding 19: the pooled ownership-transfer publishers enforce the same
   --  invariant, and an admission failure must preserve the caller's buffer.
   procedure Check_Moved_Text_Frame_Admission is
      package Buffers renames Flyology.Buffers;
      Storage : aliased Buffers.Pool (Block_Size => 16, Capacity => 2);
      Payload : Buffers.Unique_Buffer (Storage'Access);
      Item    : WebSockets.Session
        (Capacity => 2, Byte_Limit => 64, Budget => null,
         Buffer_Pool => Storage'Access);
      Accepted : Boolean;
   begin
      Buffers.Acquire (Payload);
      Buffers.Copy_From (Payload, [16#6F#, 16#6B#, 16#FF#]);
      WebSockets.Try_Publish_Move
        (Item, HTTP_Server.Text_Frame, Payload, Accepted);
      pragma Assert
        (not Accepted and then Buffers.Has_Buffer (Payload),
         "Try_Publish_Move admitted an invalid UTF-8 Text_Frame");
      WebSockets.Try_Publish_Move
        (Item, HTTP_Server.Binary_Frame, Payload, Accepted);
      pragma Assert
        (Accepted and then not Buffers.Has_Buffer (Payload),
         "Try_Publish_Move rejected an arbitrary Binary_Frame");
      WebSockets.Close (Item);
   end Check_Moved_Text_Frame_Admission;

   --  Finding 19: an invalid Text_Frame must not reach the owner task, where
   --  the send raises, the connection becomes terminal, and every other
   --  queued message is discarded.
   procedure Check_Text_Frame_Does_Not_Kill_Session is
      package Applications renames Flyology.HTTP.Server.Applications;
      package Routing is new Flyology.HTTP.Server.Routing (Boolean);

      Survivor : constant String := "survivor";
      Survivor_Frame : constant String :=
        Character'Val (16#81#)
        & Character'Val (Survivor'Length) & Survivor;
      Close_Frame : constant String :=
        Character'Val (16#88#) & Character'Val (16#80#) & "mask";

      Invalid_Accepted  : Boolean := False;
      Survivor_Accepted : Boolean := False;
      Run_Error         : Unbounded_String;

      procedure Chat
        (State : in out Boolean;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
         Item : WebSockets.Session
           (Capacity => 4, Byte_Limit => 4_096, Budget => null,
            Buffer_Pool => null);
         Accepted : Boolean;
      begin
         WebSockets.Try_Publish
           (Item,
            (Kind => HTTP_Server.Text_Frame,
             Data => Bytes.From_Byte_String (Invalid_Text)),
            Accepted);
         Invalid_Accepted := Accepted;
         WebSockets.Try_Publish
           (Item,
            (Kind => HTTP_Server.Text_Frame,
             Data => Bytes.From_Byte_String (Survivor)),
            Accepted);
         Survivor_Accepted := Accepted;
         WebSockets.Close (Item);
         begin
            WebSockets.Run (X, Item);
         exception
            when Error : others =>
               Run_Error := To_Unbounded_String
                 (Ada.Exceptions.Exception_Message (Error));
         end;
      end Chat;

      Routes : Routing.Router
        (Capacity => 1, Slashes => Routing.Strict_Slashes);
      State : Boolean := False;
      Wire  : aliased Memory_Transport;
   begin
      Routing.Get
        (Routes,
         "/chat", Chat'Access, Name => "chat",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Upgrade => Routing.Allow_WebSocket));
      Wire.Input := To_Unbounded_String
        ("GET /chat HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Upgrade: websocket" & CRLF
         & "Connection: Upgrade" & CRLF
         & "Sec-WebSocket-Version: 13" & CRLF
         & "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" & CRLF & CRLF
         & Close_Frame);
      declare
         Client : aliased HTTP_Server.Connection (Wire'Access);
      begin
         Routing.Serve (Routes, State, Client, Peer => Test_Peer);
      end;
      declare
         Output    : constant String := To_String (Wire.Output);
         Delivered : constant Boolean :=
           Ada.Strings.Fixed.Index (Output, Survivor_Frame) /= 0;
      begin
         pragma Assert
           (not Invalid_Accepted
            and then Survivor_Accepted
            and then Length (Run_Error) = 0
            and then Delivered,
            "invalid UTF-8 Text_Frame admitted="
            & Boolean'Image (Invalid_Accepted)
            & ", queued follow-up admitted="
            & Boolean'Image (Survivor_Accepted)
            & ", Run raised=""" & To_String (Run_Error)
            & """, follow-up delivered=" & Boolean'Image (Delivered));
      end;
   end Check_Text_Frame_Does_Not_Kill_Session;

begin
   Check_Text_Frame_Admission;
   Check_Moved_Text_Frame_Admission;
   Check_Text_Frame_Does_Not_Kill_Session;
end WebSocket_Server_Audit;
