with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Flyology;
with Flyology.Bytes;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Client.SSE;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Flyology.Operations;
with Flyology.QUIC.Test_Connections;
with Repro_Support;

--  SSE-1.  The same application call
--
--     X.Send_SSE (Data => "a" & LF);
--
--  must produce the same dispatched event data on every backend.  WHATWG
--  HTML, "Server-sent events", the dispatch-the-event algorithm, says:
--  "If the data buffer's last character is a U+000A LINE FEED (LF)
--  character, then remove the last character from the data buffer."  A
--  trailing LF in the application's value therefore survives the round trip
--  only when the serialiser emits one more empty `data:` line, because each
--  data field contributes its value plus one LF to the data buffer and the
--  last of those LFs is then stripped.
--
--  This spike drives one route that sends "a" & LF over HTTP/1.1, HTTP/2 and
--  HTTP/3 in process, and for each backend checks both the serialised wire
--  bytes and what the Flyology SSE client dispatches to the caller.
procedure Repro_SSE_1 is
   package App renames Flyology.HTTP.Server.Applications;
   package Client renames Flyology.HTTP.Client;
   package SSE renames Flyology.HTTP.Client.SSE;
   package Connections renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;
   package Fixtures renames Flyology.QUIC.Test_Connections;

   use Repro_Support;
   use type SSE.Read_Result;

   LF : constant Character := Character'Val (10);

   --  What the application asks for, and what a conformant client must
   --  therefore dispatch.
   Sent_Data      : constant String := "a" & LF;
   Expected_Event : constant String := "a" & LF;

   --  The only serialisation of Sent_Data that round-trips through the
   --  WHATWG dispatch algorithm.
   Expected_Wire  : constant String :=
     "data: a" & LF & "data:" & LF & LF;

   function Decimal (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   type Context is limited null record;
   package Routing is new Flyology.HTTP.Server.Routing (Context);

   procedure Events (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      X.Begin_SSE;
      X.Send_SSE (Data => Sent_Data);
      X.End_SSE;
   end Events;

   procedure Register (Routes : in out Routing.Router) is
   begin
      Routes.Get
        ("/sse", Events'Access, Name => "sse",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Upgrade => Routing.Allow_SSE));
   end Register;

   --  One backend's two observations: the serialised body of an ordinary GET
   --  and the event the SSE client dispatches for the same route.
   procedure Exercise (HTTP : aliased in out Client.Client; Label : String) is
      Raw_Request : Client.Request;
   begin
      Client.Set_Target (Raw_Request, "/sse");
      declare
         Reply : Client.Response :=
           Client.Execute (HTTP, Raw_Request, Timeout => 15.0);
         Payload : constant String :=
           Flyology.Bytes.To_Byte_String (Client.Read_All (Reply));
      begin
         Note (Label & " wire bytes: " & Printable (B (Payload)));
         Expect_Equal
           (Printable (B (Payload)), Printable (B (Expected_Wire)),
            Label & " serialised SSE body");
      end;

      declare
         SSE_Request : Client.Request;
         Source : aliased SSE.Event_Source
           (HTTP'Access, Maximum_Event_Bytes => 1_024);
         Event  : SSE.Event;
         Result : SSE.Read_Result;
      begin
         Client.Set_Target (SSE_Request, "/sse");
         SSE.Open
           (Source, SSE_Request,
            Initial_Reconnect_Delay => 0.0,
            Maximum_Reconnect_Delay => 1.0,
            Deadline => Client.Deadline_After (15.0));
         declare
            Set : aliased Flyology.Operations.Completion_Set (4);
            Operation : SSE.Read_Operation :=
              SSE.Read (Set'Access, Source'Access);
         begin
            Flyology.Operations.Wait_All (Set);
            SSE.Finish (Operation, Result, Event);
         end;
         Check (Result = SSE.Event_Available, Label & " dispatched an event");
         if Result = SSE.Event_Available then
            Note
              (Label & " dispatched data: " & Printable (B (SSE.Data (Event))));
            Expect_Equal
              (Printable (B (SSE.Data (Event))),
               Printable (B (Expected_Event)),
               Label & " dispatched event data");
         end if;
      end;
      Client.Shutdown (HTTP, Timeout => 5.0);
   end Exercise;

   ---------------------------------------------------------------- HTTP/1.1

   procedure Run_HTTP_1 is
      Manager  : aliased Connections.Server (Capacity => 1);
      Listener : Sockets.Socket_Type;
      Address  : Sockets.Endpoint;
      State    : Context;
      Routes   : Routing.Router
        (Capacity => 1, Slashes => Routing.Strict_Slashes);
   begin
      Register (Routes);
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Port (Ephemeral_Port)));
      Sockets.Listen_Socket (Listener, Length => 4);
      Address := Sockets.Get_Socket_Name (Listener);
      declare
         task Server_Task is
            pragma Task_Info (Flyology.Native_Task);
         end Server_Task;

         task body Server_Task is
            Channel : Connections.Connection;
            Peer    : Sockets.Endpoint;
         begin
            for Attempt in 1 .. 3 loop
               begin
                  Connections.Accept_Connection
                    (Manager, Listener, Channel, Peer, Timeout => 5.0);
                  Routes.Serve
                    (State, Channel, Peer,
                     Mode => Flyology.HTTP.Server.HTTP_1_Only,
                     Timeout => 15.0,
                     Max_Connection_Age => 30.0,
                     Max_Requests => 8);
                  Connections.Close (Channel);
               exception
                  when others =>
                     exit;
               end;
            end loop;
         end Server_Task;

         HTTP : aliased Client.Client (Capacity => 1);
      begin
         Client.Configure
           (HTTP,
            Flyology.HTTP.Parse_Origin
              ("http://127.0.0.1:" & Decimal (Natural (Address.Port))));
         Exercise (HTTP, "HTTP/1.1");
      end;
      Sockets.Close_Socket (Listener);
   end Run_HTTP_1;

   ------------------------------------------------------------------ HTTP/2

   procedure Run_HTTP_2 is
      Manager  : aliased Connections.Server (Capacity => 1);
      Listener : Sockets.Socket_Type;
      Address  : Sockets.Endpoint;
      State    : Context;
      Routes   : Routing.Router
        (Capacity => 1, Slashes => Routing.Strict_Slashes);
   begin
      Register (Routes);
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Port (Ephemeral_Port)));
      Sockets.Listen_Socket (Listener, Length => 4);
      Address := Sockets.Get_Socket_Name (Listener);
      declare
         task Server_Task is
            pragma Task_Info (Flyology.Native_Task);
         end Server_Task;

         task body Server_Task is
            Channel : Connections.Connection;
            Peer    : Sockets.Endpoint;
         begin
            for Attempt in 1 .. 3 loop
               begin
                  Connections.Accept_Connection
                    (Manager, Listener, Channel, Peer, Timeout => 5.0);
                  Routes.Serve
                    (State, Channel, Peer,
                     Mode => Flyology.HTTP.Server.HTTP_2_Only,
                     Timeout => 15.0,
                     Max_Connection_Age => 30.0);
                  Connections.Close (Channel);
               exception
                  when others =>
                     exit;
               end;
            end loop;
         end Server_Task;

         HTTP : aliased Client.Client (Capacity => 1);
      begin
         Client.Configure
           (HTTP,
            Flyology.HTTP.Parse_Origin
              ("http://127.0.0.1:" & Decimal (Natural (Address.Port))),
            Client.HTTP_2_Prior_Knowledge);
         Exercise (HTTP, "HTTP/2");
      end;
      Sockets.Close_Socket (Listener);
   end Run_HTTP_2;

   ------------------------------------------------------------------ HTTP/3

   procedure Run_HTTP_3 is
      Server_Socket : aliased Sockets.Socket_Type;
      Address : Sockets.Endpoint;
      State   : Context;
      Routes  : Routing.Router
        (Capacity => 1, Slashes => Routing.Strict_Slashes);
      Server_Error : Flyology.Bytes.Unbounded_Bytes;
   begin
      Register (Routes);
      Sockets.Create_Socket
        (Server_Socket, Sockets.IPv4, Sockets.Socket_Datagram);
      Sockets.Bind_Socket
        (Server_Socket,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Address := Sockets.Get_Socket_Name (Server_Socket);
      declare
         task Server_Task is
            pragma Task_Info (Flyology.Native_Task);
         end Server_Task;

         task body Server_Task is
         begin
            Routes.Serve_HTTP_3
              (State, Server_Socket,
               Fixtures.Server_Certificate,
               Fixtures.Server_Private_Key,
               Timeout => 15.0,
               Handshake_Timeout => 15.0,
               Max_Connection_Age => 30.0,
               Max_Requests => 2);
         exception
            when Error : others =>
               Server_Error := Flyology.Bytes.From_Byte_String
                 (Ada.Exceptions.Exception_Information (Error));
         end Server_Task;

         HTTP : aliased Client.Client (Capacity => 1);
      begin
         Client.Configure
           (HTTP,
            Flyology.HTTP.Parse_Origin
              ("https://127.0.0.1:" & Decimal (Natural (Address.Port))),
            Client.Require_HTTP_3,
            HTTP_3_Certificate_DER => Fixtures.Server_Certificate);
         Exercise (HTTP, "HTTP/3");
      end;
      if Flyology.Bytes.Length (Server_Error) > 0 then
         Note
           ("HTTP/3 server task reported: "
            & Flyology.Bytes.To_Byte_String (Server_Error));
      end if;
      Sockets.Close_Socket (Server_Socket);
   end Run_HTTP_3;

begin
   Note ("application sends Data => ""a"" & LF on one route, three backends");
   Note ("expected wire: " & Printable (B (Expected_Wire)));
   Note ("expected dispatched data: " & Printable (B (Expected_Event)));

   begin
      Run_HTTP_1;
   exception
      when Error : others =>
         Check (False, "HTTP/1.1 backend raised "
            & Ada.Exceptions.Exception_Name (Error));
   end;

   begin
      Run_HTTP_2;
   exception
      when Error : others =>
         Check (False, "HTTP/2 backend raised "
            & Ada.Exceptions.Exception_Name (Error));
   end;

   begin
      Run_HTTP_3;
   exception
      when Error : others =>
         Check (False, "HTTP/3 backend raised "
            & Ada.Exceptions.Exception_Name (Error));
   end;

   Finish;
end Repro_SSE_1;
