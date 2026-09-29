--  WEBSOCKET-4: the server refuses an upgrade whose Sec-WebSocket-Protocol
--  list contains an empty element.
--
--  server.adb:3961-3973 probes every upgrade that carries the field with
--  Header_Has_Exact_Token (Value, "Sec-WebSocket-Protocol",
--  "flyology-no-match"), and that helper (:3617-3642) runs Validate_Token on
--  each comma-separated element, which raises on the empty string
--  (:317-327).  The other list parsers in the same file skip empty elements:
--  Header_Has_Token (:527-550) for Connection and Upgrade, and
--  Negotiate_WebSocket_Deflate (:3798-3799).
--
--  RFC 9110 5.6.1.2: "a recipient MUST parse and ignore a reasonable number
--  of empty list elements".  RFC 6455 11.3.4 defines Sec-WebSocket-Protocol
--  as 1#token, which is that list rule.
--
--  This program asserts the correct behaviour: an upgrade offering
--  "chat, , superchat" or "chat," to a handler configured for chat is
--  accepted with 101 and Sec-WebSocket-Protocol: chat.  The third case is
--  the control: the same request without the empty element is accepted.
--
--  The Autobahn baselines (review/baselines/20- through 23-) never send a
--  subprotocol list, so no maintained suite covers this.

with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Server;
with Flyology.IO.Sockets;
with Repro_Support;

procedure Repro_Websocket_4 is
   package HTTP_Server renames Flyology.HTTP.Server;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Strings.Unbounded;
   use Repro_Support;
   use type Ada.Streams.Stream_Element_Offset;

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

   procedure Run_Case (Label : String; Offer : String) is
      Wire    : aliased Memory_Transport;
      Failed  : Boolean := False;
      Message : Unbounded_String;
   begin
      Wire.Input := To_Unbounded_String
        ("GET /chat HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Upgrade: websocket" & CRLF
         & "Connection: Upgrade" & CRLF
         & "Sec-WebSocket-Version: 13" & CRLF
         & "Sec-WebSocket-Protocol: " & Offer & CRLF
         & "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" & CRLF & CRLF);
      declare
         Client  : aliased HTTP_Server.Connection (Wire'Access);
         Request : HTTP_Server.Request;
         Closed  : Boolean;
      begin
         HTTP_Server.Read_Request (Client, Request, Closed);
         begin
            HTTP_Server.Accept_WebSocket
              (Client, Request, Protocol => "chat",
               Origin_Policy => HTTP_Server.Allow_Any_Origin);
         exception
            when Occurrence : Flyology.HTTP.Protocol_Error =>
               Failed := True;
               Message := To_Unbounded_String
                 (Ada.Exceptions.Exception_Message (Occurrence));
         end;
      end;
      if Failed then
         Note
           (Label & ": Accept_WebSocket raised Protocol_Error """
            & To_String (Message) & """");
      end if;
      Check
        (not Failed,
         Label & ": the upgrade offering """ & Offer & """ is accepted");
      declare
         Output : constant String := To_String (Wire.Output);
      begin
         Check
           (Ada.Strings.Fixed.Index (Output, "HTTP/1.1 101") = 1,
            Label & ": the response is 101 Switching Protocols");
         Check
           (Ada.Strings.Fixed.Index
              (Output, "Sec-WebSocket-Protocol: chat") /= 0,
            Label & ": the response selects chat");
      end;
   end Run_Case;

begin
   Note
     ("WEBSOCKET-4: empty elements in the Sec-WebSocket-Protocol list");
   --  Control first, so a failure here would point at the fixture rather
   --  than at the defect.
   Run_Case ("control", "chat, superchat");
   Run_Case ("interior empty element", "chat, , superchat");
   Run_Case ("leading empty element", ", chat");
   Run_Case ("adjacent commas", "chat,,superchat");
   Run_Case ("trailing comma", "chat,");
   Finish;
end Repro_Websocket_4;
