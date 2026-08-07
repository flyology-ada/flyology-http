--  Regression coverage for the 2026-08-07 audit findings in the HTTP/1.x server.
--  Every fix lands its failing reproduction here before the fix itself.
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Requests;
with Flyology.HTTP.Server.Responses;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Sockets;

procedure HTTP_Server_Audit is
   package HTTP_Server renames Flyology.HTTP.Server;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Strings.Unbounded;
   use type Flyology.HTTP.HTTP_Version;

   CRLF : constant String := Character'Val (13) & Character'Val (10);
   LF   : constant Character := Character'Val (10);
   NUL  : constant Character := Character'Val (0);

   Test_Peer : constant Sockets.Endpoint :=
     Sockets.Network_Endpoint (Sockets.Loopback_IPv4, 12_345);

   --  Render control bytes as escapes so a failing assertion reports the
   --  observed wire bytes rather than swallowing them.
   function Visible (Value : String) return String is
      Digits_Set : constant String := "0123456789ABCDEF";
      Result     : Unbounded_String;
   begin
      for Item of Value loop
         if Character'Pos (Item) < 32 or else Character'Pos (Item) = 127 then
            Append
              (Result,
               "\x"
               & Digits_Set (Character'Pos (Item) / 16 + 1)
               & Digits_Set (Character'Pos (Item) mod 16 + 1));
         else
            Append (Result, Item);
         end if;
      end loop;
      return To_String (Result);
   end Visible;

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
      use type Ada.Streams.Stream_Element_Offset;
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

   --  Return the connection output written after the last response status
   --  line, which is the error response the audit inspects.
   function Final_Response (Wire : Memory_Transport) return String is
      Output : constant String := To_String (Wire.Output);
      Mark   : constant Natural :=
        Ada.Strings.Fixed.Index (Output, "HTTP/1.", Ada.Strings.Backward);
   begin
      return (if Mark = 0 then Output else Output (Mark .. Output'Last));
   end Final_Response;

   --  Finding 23. Current_Is_Head and Current_Version were assigned as the
   --  last statements of Read_Request_Head, so a request rejected on a reused
   --  connection was answered against the previous request's method and
   --  version.
   procedure Check_Per_Request_Response_Shape is
   begin
      declare
         Wire     : aliased Memory_Transport;
         Rejected : Boolean := False;
      begin
         Wire.Input := To_Unbounded_String
           ("HEAD /one HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF & CRLF
            & "GET /two HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Content-Length: nope" & CRLF & CRLF);
         declare
            Client  : HTTP_Server.Connection (Wire'Access);
            Request : HTTP_Server.Request;
            Closed  : Boolean;
         begin
            HTTP_Server.Read_Request_Head (Client, Request, Closed);
            pragma Assert (HTTP_Server.Method (Request) = "HEAD");
            HTTP_Server.Respond (Client, 200, "text/plain", "hidden");
            begin
               HTTP_Server.Read_Request_Head (Client, Request, Closed);
            exception
               when Flyology.HTTP.Protocol_Error =>
                  Rejected := True;
            end;
            pragma Assert (Rejected);
            HTTP_Server.Respond
              (Client, 400, "text/plain; charset=utf-8",
               "bad request" & LF, Close => True);
         end;
         declare
            Reply : constant String := Final_Response (Wire);
         begin
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Reply, "HTTP/1.1 400 Bad Request") = Reply'First,
               "status line: " & Visible (Reply));
            pragma Assert
              (Ada.Strings.Fixed.Index (Reply, "Content-Length: 12") /= 0,
               "content length: " & Visible (Reply));
            pragma Assert
              (Ada.Strings.Fixed.Index (Reply, "bad request" & LF) /= 0,
               "missing error payload: " & Visible (Reply));
         end;
      end;

      declare
         Wire     : aliased Memory_Transport;
         Rejected : Boolean := False;
      begin
         Wire.Input := To_Unbounded_String
           ("GET /one HTTP/1.0" & CRLF
            & "Host: localhost" & CRLF
            & "Connection: keep-alive" & CRLF & CRLF
            & "GET /two" & CRLF
            & "Host: localhost" & CRLF & CRLF);
         declare
            Client  : HTTP_Server.Connection (Wire'Access);
            Request : HTTP_Server.Request;
            Closed  : Boolean;
         begin
            HTTP_Server.Read_Request_Head (Client, Request, Closed);
            pragma Assert
              (HTTP_Server.Version (Request) = Flyology.HTTP.HTTP_1_0);
            HTTP_Server.Respond (Client, 200, "text/plain", "one");
            begin
               HTTP_Server.Read_Request_Head (Client, Request, Closed);
            exception
               when Flyology.HTTP.Protocol_Error =>
                  Rejected := True;
            end;
            pragma Assert (Rejected);
            HTTP_Server.Respond
              (Client, 400, "text/plain; charset=utf-8",
               "bad request" & LF, Close => True);
         end;
         declare
            Reply : constant String := Final_Response (Wire);
         begin
            pragma Assert
              (Ada.Strings.Fixed.Index (Reply, "HTTP/1.1 400") = Reply'First,
               "stale version: " & Visible (Reply));
         end;
      end;

      --  A rejected HEAD still suppresses the error payload, because the
      --  flag now follows the request line that was actually received.
      declare
         Wire     : aliased Memory_Transport;
         Rejected : Boolean := False;
      begin
         Wire.Input := To_Unbounded_String
           ("GET /one HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF & CRLF
            & "HEAD /two HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Content-Length: nope" & CRLF & CRLF);
         declare
            Client  : HTTP_Server.Connection (Wire'Access);
            Request : HTTP_Server.Request;
            Closed  : Boolean;
         begin
            HTTP_Server.Read_Request_Head (Client, Request, Closed);
            HTTP_Server.Respond (Client, 200, "text/plain", "one");
            begin
               HTTP_Server.Read_Request_Head (Client, Request, Closed);
            exception
               when Flyology.HTTP.Protocol_Error =>
                  Rejected := True;
            end;
            pragma Assert (Rejected);
            HTTP_Server.Respond
              (Client, 400, "text/plain; charset=utf-8",
               "bad request" & LF, Close => True);
         end;
         declare
            Reply : constant String := Final_Response (Wire);
         begin
            pragma Assert
              (Ada.Strings.Fixed.Index (Reply, "bad request" & LF) = 0,
               "payload answered HEAD: " & Visible (Reply));
         end;
      end;
   end Check_Per_Request_Response_Shape;

   --  Finding 24. Repeated Cookie field lines were joined with ", " like a
   --  comma-list field, so every cookie value on the first line absorbed
   --  the next line.
   procedure Check_Repeated_Cookie_Fields is
      package Applications renames Flyology.HTTP.Server.Applications;
      package Requests renames Flyology.HTTP.Server.Requests;
      package Responses renames Flyology.HTTP.Server.Responses;
      type Context is null record;
      package Routing is new Flyology.HTTP.Server.Routing (Context);

      Session : Unbounded_String;
      Extra   : Unbounded_String;
      Joined  : Unbounded_String;

      procedure Show
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
         Builder : Responses.Builder;
      begin
         Session := To_Unbounded_String (Requests.Cookie (X, "sid"));
         Extra := To_Unbounded_String (Requests.Cookie (X, "x"));
         Joined := To_Unbounded_String (X.Request_Header ("Cookie"));
         Builder.Initialize (200, "text/plain");
         Builder.Set_Payload ("ok");
         Builder.Send (X);
      end Show;

      Routes : Routing.Router
        (Capacity => 1, Slashes => Routing.Strict_Slashes);
      State  : Context;
      Wire   : aliased Memory_Transport;
   begin
      Routes.Get ("/cookies", Show'Access, Name => "cookies");
      Wire.Input := To_Unbounded_String
        ("GET /cookies HTTP/1.1" & CRLF
         & "Host: example.test" & CRLF
         & "Cookie: sid=good" & CRLF
         & "Cookie: x=y" & CRLF
         & "Connection: close" & CRLF & CRLF);
      declare
         Client : aliased HTTP_Server.Connection (Wire'Access);
      begin
         Routes.Serve (State, Client, Test_Peer);
      end;
      pragma Assert (To_String (Session) = "good", To_String (Session));
      pragma Assert (To_String (Extra) = "y", To_String (Extra));
      pragma Assert
        (To_String (Joined) = "sid=good; x=y", To_String (Joined));
   end Check_Repeated_Cookie_Fields;

   --  Finding 25. Decode_Query emitted any percent-escaped byte, so a query
   --  value was the one request surface able to carry an embedded NUL or C0
   --  control byte into an application.
   procedure Check_Query_Control_Bytes is
      package Applications renames Flyology.HTTP.Server.Applications;
      package Requests renames Flyology.HTTP.Server.Requests;
      package Responses renames Flyology.HTTP.Server.Responses;
      type Context is null record;
      package Routing is new Flyology.HTTP.Server.Routing (Context);

      Rejected : Boolean := False;
      Observed : Unbounded_String;
      Benign   : Unbounded_String;
      Spaced   : Unbounded_String;

      procedure Show
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
         Builder : Responses.Builder;
      begin
         Benign := To_Unbounded_String (Requests.Query (X, "ok"));
         Spaced := To_Unbounded_String (Requests.Query (X, "sp"));
         begin
            Observed := To_Unbounded_String (Requests.Query (X, "name"));
         exception
            when Flyology.HTTP.Protocol_Error =>
               Rejected := True;
         end;
         Builder.Initialize (200, "text/plain");
         Builder.Set_Payload ("ok");
         Builder.Send (X);
      end Show;

      Routes : Routing.Router
        (Capacity => 1, Slashes => Routing.Strict_Slashes);
      State  : Context;
      Wire   : aliased Memory_Transport;
   begin
      Routes.Get ("/files", Show'Access, Name => "files");
      Wire.Input := To_Unbounded_String
        ("GET /files?name=report%2Etxt%00.png&ok=report%2Etxt&sp=a+b"
         & " HTTP/1.1" & CRLF
         & "Host: example.test" & CRLF
         & "Connection: close" & CRLF & CRLF);
      declare
         Client : aliased HTTP_Server.Connection (Wire'Access);
      begin
         Routes.Serve (State, Client, Test_Peer);
      end;
      pragma Assert (To_String (Benign) = "report.txt", To_String (Benign));
      pragma Assert (To_String (Spaced) = "a b", To_String (Spaced));
      pragma Assert (Rejected, Visible (To_String (Observed)));
      pragma Assert
        (Ada.Strings.Fixed.Index (To_String (Observed), "" & NUL) = 0,
         Visible (To_String (Observed)));
   end Check_Query_Control_Bytes;

begin
   Check_Per_Request_Response_Shape;
   Check_Repeated_Cookie_Fields;
   Check_Query_Control_Bytes;
end HTTP_Server_Audit;
