--  Regression coverage for the 2026-08-07 audit findings in the HTTP/1.x server.
--  Every fix lands its failing reproduction here before the fix itself.
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology.Bytes;
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
   use type HTTP_Server.WebSocket_Data_Kind;

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

   --  Admit one further buffered request against Budget and report whether
   --  the shared ingress budget refused it. This is the reservation a real
   --  peer's next buffered request performs, and its refusal is the
   --  503 ingress-budget-exhausted the audit describes.
   function Buffered_Request_Denied
     (Budget : not null access HTTP_Server.Ingress_Budget) return Boolean
   is
      Wire   : aliased Memory_Transport;
      Denied : Boolean := False;
   begin
      Wire.Input := To_Unbounded_String
        ("POST /rival HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Content-Length: 5" & CRLF & CRLF & "hello");
      declare
         Client  : HTTP_Server.Connection (Wire'Access);
         Request : HTTP_Server.Request;
         Closed  : Boolean;
      begin
         HTTP_Server.Configure_Ingress_Budget (Client, Budget);
         begin
            HTTP_Server.Read_Request (Client, Request, Closed);
         exception
            when HTTP_Server.Resource_Exhausted =>
               Denied := True;
         end;
      end;
      return Denied;
   end Buffered_Request_Denied;

   --  Transport that replays a canned prefix and then stalls like a peer that
   --  stops sending mid-body. The stall is the only point at which the
   --  reservation a half-read body holds is observable from outside
   --  Buffer_Request_Body, so the budget probe runs from there.
   type Probing_Transport
     (Budget : not null access HTTP_Server.Ingress_Budget) is
     limited new HTTP_Server.Transport with record
      Input        : Unbounded_String;
      Probed       : Boolean := False;
      Reserved     : Natural := 0;
      Rival_Denied : Boolean := False;
   end record;

   overriding procedure Receive
     (Item    : in out Probing_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);

   overriding procedure Send_All
     (Item    : in out Probing_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);

   overriding procedure Receive
     (Item    : in out Probing_Transport;
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
         if not Item.Probed then
            Item.Probed := True;
            Item.Reserved := HTTP_Server.Current (Item.Budget.all).Current;
            Item.Rival_Denied := Buffered_Request_Denied (Item.Budget);
         end if;
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
     (Item    : in out Probing_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Item, Data, Timeout, Token);
   begin
      null;
   end Send_All;

   --  Return one complete client-masked WebSocket frame header for Opcode and
   --  Size. The mask is all zero bytes, so the payload travels unchanged.
   function Client_Frame_Header
     (Opcode : Natural;
      Size   : Natural) return String
   is
      Result : Unbounded_String;
   begin
      Append (Result, Character'Val (128 + Opcode));
      if Size < 126 then
         Append (Result, Character'Val (128 + Size));
      elsif Size <= 65_535 then
         Append (Result, Character'Val (128 + 126));
         Append (Result, Character'Val (Size / 256));
         Append (Result, Character'Val (Size mod 256));
      else
         Append (Result, Character'Val (128 + 127));
         declare
            Octets : String (1 .. 8) := (others => Character'Val (0));
            Value  : Natural := Size;
         begin
            for Index in reverse Octets'Range loop
               Octets (Index) := Character'Val (Value mod 256);
               Value := Value / 256;
            end loop;
            Append (Result, Octets);
         end;
      end if;
      Append (Result, String'(1 .. 4 => Character'Val (0)));
      return To_String (Result);
   end Client_Frame_Header;

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

   --  Finding 12. Buffer_Request_Body reserved the whole declared length, or
   --  the whole body ceiling for a chunked request, before any body
   --  byte arrived. A peer that dribbled one chunk and stalled pinned the
   --  entire ceiling, and every later buffered request was refused.
   procedure Check_Buffered_Ingress_Reservation is
      Read_Ahead : constant := 8 * 1_024;
   begin
      --  A chunked peer that has delivered one byte.
      declare
         Budget : aliased HTTP_Server.Ingress_Budget
           (Limit => HTTP_Server.Default_Ingress_Budget_Bytes);
         Wire   : aliased Probing_Transport (Budget'Access);
         Stalled : Boolean := False;
      begin
         Wire.Input := To_Unbounded_String
           ("POST /upload HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Transfer-Encoding: chunked" & CRLF & CRLF
            & "1" & CRLF & "A" & CRLF);
         declare
            Client  : HTTP_Server.Connection (Wire'Access);
            Request : HTTP_Server.Request;
            Closed  : Boolean;
         begin
            HTTP_Server.Configure_Ingress_Budget (Client, Budget'Access);
            begin
               HTTP_Server.Read_Request (Client, Request, Closed);
            exception
               when Flyology.HTTP.Protocol_Error =>
                  Stalled := True;
            end;
         end;
         pragma Assert (Stalled);
         pragma Assert (Wire.Probed);
         pragma Assert
           (Wire.Reserved <= Read_Ahead,
            "chunked reservation pinned"
            & Natural'Image (Wire.Reserved) & " bytes for 1 body byte");
         pragma Assert
           (not Wire.Rival_Denied,
            "a dribbling chunked peer starved the next buffered request");
         pragma Assert (HTTP_Server.Current (Budget).Current = 0);
      end;

      --  A fixed-length peer that declared a full body and delivered one byte.
      declare
         Budget : aliased HTTP_Server.Ingress_Budget
           (Limit => HTTP_Server.Default_Ingress_Budget_Bytes);
         Wire   : aliased Probing_Transport (Budget'Access);
         Stalled : Boolean := False;
      begin
         Wire.Input := To_Unbounded_String
           ("POST /upload HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Content-Length:"
            & Flyology.HTTP.Body_Size'Image
                (HTTP_Server.Max_Request_Body) & CRLF & CRLF
            & "A");
         declare
            Client  : HTTP_Server.Connection (Wire'Access);
            Request : HTTP_Server.Request;
            Closed  : Boolean;
         begin
            HTTP_Server.Configure_Ingress_Budget (Client, Budget'Access);
            begin
               HTTP_Server.Read_Request (Client, Request, Closed);
            exception
               when Flyology.HTTP.Protocol_Error =>
                  Stalled := True;
            end;
         end;
         pragma Assert (Stalled);
         pragma Assert (Wire.Probed);
         pragma Assert
           (Wire.Reserved <= Read_Ahead,
            "declared reservation pinned"
            & Natural'Image (Wire.Reserved) & " bytes for 1 body byte");
         pragma Assert
           (not Wire.Rival_Denied,
            "a dribbling fixed-length peer starved the next request");
         pragma Assert (HTTP_Server.Current (Budget).Current = 0);
      end;

      --  A complete body still reserves exactly its decoded length, and the
      --  budget still refuses a body it cannot hold.
      declare
         Budget : aliased HTTP_Server.Ingress_Budget (Limit => 8);
         Wire   : aliased Memory_Transport;
         Denied : Boolean := False;
      begin
         Wire.Input := To_Unbounded_String
           ("POST /one HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Content-Length: 5" & CRLF & CRLF & "hello");
         declare
            Client  : HTTP_Server.Connection (Wire'Access);
            Request : HTTP_Server.Request;
            Closed  : Boolean;
         begin
            HTTP_Server.Configure_Ingress_Budget (Client, Budget'Access);
            HTTP_Server.Read_Request (Client, Request, Closed);
            pragma Assert (HTTP_Server.Content (Request) = "hello");
            pragma Assert (HTTP_Server.Current (Budget).Current = 5);
            Denied := Buffered_Request_Denied (Budget'Access);
         end;
         pragma Assert (Denied);
         pragma Assert (HTTP_Server.Current (Budget).Current = 0);
         pragma Assert (HTTP_Server.Current (Budget).Peak = 5);
      end;

      --  A body larger than the whole budget is still refused at admission.
      declare
         Budget : aliased HTTP_Server.Ingress_Budget (Limit => 4);
         Wire   : aliased Memory_Transport;
         Denied : Boolean := False;
      begin
         Wire.Input := To_Unbounded_String
           ("POST /one HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Content-Length: 5" & CRLF & CRLF & "hello");
         declare
            Client  : HTTP_Server.Connection (Wire'Access);
            Request : HTTP_Server.Request;
            Closed  : Boolean;
         begin
            HTTP_Server.Configure_Ingress_Budget (Client, Budget'Access);
            begin
               HTTP_Server.Read_Request (Client, Request, Closed);
            exception
               when HTTP_Server.Resource_Exhausted =>
                  Denied := True;
            end;
         end;
         pragma Assert (Denied);
         pragma Assert (HTTP_Server.Current (Budget).Denials = 1);
         pragma Assert (HTTP_Server.Current (Budget).Current = 0);
      end;
   end Check_Buffered_Ingress_Reservation;

   procedure Check_64_Bit_Body_Bounds is
      Large : constant Flyology.HTTP.Body_Size := 5 * 1_024 * 1_024 * 1_024;
   begin
      pragma Assert (Large > Flyology.HTTP.Body_Size (Natural'Last));

      --  A fixed-length S3 multipart-sized request is admitted without
      --  narrowing through Natural, while a route may still reject it by
      --  applying an explicit smaller limit before any body byte is read.
      declare
         Wire     : aliased Memory_Transport;
         Rejected : Boolean := False;
      begin
         Wire.Input := To_Unbounded_String
           ("PUT /part HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Content-Length:" & Flyology.HTTP.Body_Size'Image (Large)
            & CRLF & CRLF);
         declare
            Client  : HTTP_Server.Connection (Wire'Access);
            Request : HTTP_Server.Request;
            Closed  : Boolean;
         begin
            HTTP_Server.Read_Request_Head
              (Client, Request, Closed, Max_Body => Large);
            pragma Assert (not Closed);
            pragma Assert (not HTTP_Server.Body_Complete (Client));
            begin
               HTTP_Server.Narrow_Body_Limit (Client, Large - 1);
            exception
               when HTTP_Server.Payload_Too_Large =>
                  Rejected := True;
            end;
         end;
         pragma Assert (Rejected);
      end;

      --  The same 5 GiB value in chunk framing reaches the body receive path.
      --  A missing chunk payload is a protocol EOF, not an integer failure.
      declare
         Wire        : aliased Memory_Transport;
         Saw_EOF     : Boolean := False;
         Data        : Ada.Streams.Stream_Element_Array (1 .. 1);
         Last        : Ada.Streams.Stream_Element_Offset;
         Finished    : Boolean;
      begin
         Wire.Input := To_Unbounded_String
           ("PUT /part HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Transfer-Encoding: chunked" & CRLF & CRLF
            & "140000000" & CRLF);
         declare
            Client  : HTTP_Server.Connection (Wire'Access);
            Request : HTTP_Server.Request;
            Closed  : Boolean;
         begin
            HTTP_Server.Read_Request_Head
              (Client, Request, Closed, Max_Body => Large);
            begin
               HTTP_Server.Read_Body (Client, Data, Last, Finished);
            exception
               when Flyology.HTTP.Protocol_Error =>
                  Saw_EOF := True;
            end;
         end;
         pragma Assert (Saw_EOF);
      end;

      --  Decimal framing outside Body_Size is rejected as malformed instead
      --  of wrapping or leaking Constraint_Error through the public parser.
      declare
         Wire     : aliased Memory_Transport;
         Rejected : Boolean := False;
      begin
         Wire.Input := To_Unbounded_String
           ("PUT /overflow HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Content-Length: 9223372036854775808" & CRLF & CRLF);
         declare
            Client  : HTTP_Server.Connection (Wire'Access);
            Request : HTTP_Server.Request;
            Closed  : Boolean;
         begin
            begin
               HTTP_Server.Read_Request_Head (Client, Request, Closed);
            exception
               when Flyology.HTTP.Protocol_Error =>
                  Rejected := True;
            end;
         end;
         pragma Assert (Rejected);
      end;
   end Check_64_Bit_Body_Bounds;

   --  Finding 34. Close_WebSocket dropped back to the 1 MiB default message
   --  limit once the receive it was draining had finished, so a frame the
   --  application's own limit permits aborted the close handshake it had
   --  already committed to instead of completing the clean 1000 close.
   procedure Check_Close_Handshake_Message_Limit is
      Application_Limit : constant := 2 * 1_024 * 1_024;
      Frame_Size        : constant := 1_024 * 1_024 + 1;
      Budget  : aliased HTTP_Server.Ingress_Budget
        (Limit => 4 * 1_024 * 1_024);
      Wire    : aliased Memory_Transport;
      Failure : Unbounded_String;
   begin
      Wire.Input := To_Unbounded_String
        ("GET /chat HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Upgrade: websocket" & CRLF
         & "Connection: Upgrade" & CRLF
         & "Sec-WebSocket-Version: 13" & CRLF
         & "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" & CRLF & CRLF
         & Client_Frame_Header (1, 2) & "hi"
         & Client_Frame_Header (2, Frame_Size));
      for Index in 1 .. Frame_Size / 65_536 loop
         Append (Wire.Input, String'(1 .. 65_536 => 'A'));
      end loop;
      Append
        (Wire.Input, String'(1 .. Frame_Size mod 65_536 => 'A'));
      Append
        (Wire.Input,
         Client_Frame_Header (8, 2)
         & Character'Val (1_000 / 256) & Character'Val (1_000 mod 256));
      declare
         Client  : HTTP_Server.Connection (Wire'Access);
         Request : HTTP_Server.Request;
         Message : Flyology.Bytes.Unbounded_Bytes;
         Kind    : HTTP_Server.WebSocket_Data_Kind;
         Closed  : Boolean;
      begin
         HTTP_Server.Configure_Ingress_Budget (Client, Budget'Access);
         HTTP_Server.Read_Request (Client, Request, Closed);
         HTTP_Server.Accept_WebSocket (Client, Request);
         HTTP_Server.Receive_WebSocket
           (Client, Kind, Message, Closed,
            Max_Message => Application_Limit);
         pragma Assert (not Closed);
         pragma Assert (Kind = HTTP_Server.Text_Frame);
         pragma Assert (Flyology.Bytes.To_Byte_String (Message) = "hi");
         begin
            HTTP_Server.Close_WebSocket (Client);
         exception
            when Error : Flyology.HTTP.Protocol_Error =>
               Failure := To_Unbounded_String
                 (Ada.Exceptions.Exception_Message (Error));
         end;
      end;
      pragma Assert
        (Length (Failure) = 0,
         "close handshake aborted: " & To_String (Failure));
      pragma Assert
        (Length (Wire.Input) = 0,
         "close handshake stopped before the peer close frame");
      pragma Assert (HTTP_Server.Current (Budget).Current = 0);
   end Check_Close_Handshake_Message_Limit;

begin
   Check_Per_Request_Response_Shape;
   Check_Repeated_Cookie_Fields;
   Check_Query_Control_Bytes;
   Check_Buffered_Ingress_Reservation;
   Check_64_Bit_Body_Bounds;
   Check_Close_Handshake_Message_Limit;
end HTTP_Server_Audit;
