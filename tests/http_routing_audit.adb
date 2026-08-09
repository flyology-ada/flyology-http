--  Regression coverage for the 2026-08-07 audit findings in the server routing
--  and middleware. Every fix lands its failing reproduction here before the fix
--  itself.
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Interfaces;
with Flyology.Cancellation;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.CORS;
with Flyology.HTTP.Server.Middleware_Authentication;
with Flyology.HTTP.Server.Middleware_Bulkheads;
with Flyology.HTTP.Server.Middleware_CORS;
with Flyology.HTTP.Server.Middleware_Rate_Limits;
with Flyology.HTTP.Server.Middleware_Request_IDs;
with Flyology.HTTP.Server.Middleware_Security_Headers;
with Flyology.HTTP.Server.Routing;
with Flyology.IO;
with Flyology.IO.Sockets;

procedure HTTP_Routing_Audit is
   package HTTP_Server renames Flyology.HTTP.Server;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Strings.Unbounded;
   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type Flyology.HTTP.Origin_Scheme;

   CRLF : constant String := Character'Val (13) & Character'Val (10);
   Test_Peer : constant Sockets.Endpoint :=
     Sockets.Network_Endpoint (Sockets.Loopback_IPv4, 12_345);

   Failures : Natural := 0;

   procedure Expect
     (Label    : String;
      Actual   : String;
      Expected : String) is
   begin
      if Actual /= Expected then
         Failures := Failures + 1;
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "FAIL " & Label & ": expected [" & Expected
            & "] observed [" & Actual & "]");
      end if;
   end Expect;

   procedure Expect_In
     (Label    : String;
      Output   : String;
      Fragment : String) is
   begin
      if Ada.Strings.Fixed.Index (Output, Fragment) = 0 then
         Failures := Failures + 1;
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "FAIL " & Label & ": expected [" & Fragment
            & "] in [" & Output & "]");
      end if;
   end Expect_In;

   function Occurrences (Text, Fragment : String) return Natural is
      Total : Natural := 0;
      First : Positive := Text'First;
      Found : Natural;
   begin
      if Fragment'Length = 0 or else Text'Length < Fragment'Length then
         return 0;
      end if;
      while First <= Text'Last loop
         Found :=
           Ada.Strings.Fixed.Index (Text (First .. Text'Last), Fragment);
         exit when Found = 0;
         Total := Total + 1;
         First := Found + Fragment'Length;
      end loop;
      return Total;
   end Occurrences;

   --  Return the first value of a response field, or an empty string.
   function Field_Value (Output, Name : String) return String is
      Start : constant Natural :=
        Ada.Strings.Fixed.Index (Output, CRLF & Name & ": ");
      First : Positive;
      Stop  : Natural;
   begin
      if Start = 0 then
         return "";
      end if;
      First := Start + 2 + Name'Length + 2;
      Stop := Ada.Strings.Fixed.Index (Output (First .. Output'Last), CRLF);
      if Stop = 0 then
         return "";
      end if;
      return Output (First .. Stop - 1);
   end Field_Value;

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

   --  Finding 2. Raw_Path used an unanchored search for "://", so a query
   --  string carrying a URL re-parsed the origin-form target as absolute form
   --  and dispatched the path found after the query's own authority.
   procedure Check_Target_Form_Anchoring is
      package Applications renames Flyology.HTTP.Server.Applications;

      type Context is record
         Route : Unbounded_String;
         Path  : Unbounded_String;
      end record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      procedure Record_Hit
        (State : in out Context;
         X     : in out Applications.Exchange) is
      begin
         if X.Request_Scheme /= Flyology.HTTP.Plain_HTTP then
            Failures := Failures + 1;
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "FAIL default routed request scheme is not cleartext HTTP");
         end if;
         State.Route := To_Unbounded_String (X.Route_Name);
         State.Path := To_Unbounded_String (X.Path);
         X.Text (200, X.Route_Name);
      end Record_Hit;

      Routes : Routing.Router
        (Capacity => 8, Slashes => Routing.Strict_Slashes);
      State  : Context;

      procedure Route_Target
        (Target        : String;
         Expected_Name : String;
         Expected_Path : String)
      is
         Wire : aliased Memory_Transport;
      begin
         State := (others => Null_Unbounded_String);
         Wire.Input := To_Unbounded_String
           ("GET " & Target & " HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Routes.Serve (State, Client, Test_Peer);
         end;
         Expect
           ("finding 2 route for " & Target,
            To_String (State.Route), Expected_Name);
         Expect
           ("finding 2 path for " & Target,
            To_String (State.Path), Expected_Path);
      end Route_Target;
   begin
      Routes.Get ("/", Record_Hit'Access, Name => "root");
      Routes.Get ("/public", Record_Hit'Access, Name => "public");
      Routes.Get ("/admin/users", Record_Hit'Access, Name => "admin.users");
      Routes.Get ("/callback", Record_Hit'Access, Name => "callback");
      Routes.Get ("/done", Record_Hit'Access, Name => "done");
      Routes.Get ("/search", Record_Hit'Access, Name => "search");

      --  The four rows of the audit's table.
      Route_Target ("/public?x=a://b/admin/users", "public", "/public");
      Route_Target ("/admin/users?x=a://b/public", "admin.users",
                    "/admin/users");
      Route_Target
        ("/callback?redirect_uri=https://app.example.com/done",
         "callback", "/callback");
      Route_Target ("/search?q=https://example.com", "search", "/search");

      --  Genuine absolute form must keep working.
      Route_Target ("http://localhost/admin/users", "admin.users",
                    "/admin/users");
      Route_Target ("https://localhost/public?x=1", "public", "/public");
      Route_Target ("http://localhost", "root", "/");
      Route_Target ("http://localhost?x=1", "root", "/");
   end Check_Target_Form_Anchoring;

   --  Finding 17. Both limiters copy X.Route_Name into a fixed
   --  String (1 .. Max_Route_Length); an oversized name left the guard with
   --  the deny value still set, so every request to a route whose name
   --  exceeds that bound was refused permanently and without a diagnostic.
   --  Mounted REST route names exceed it easily.
   procedure Check_Long_Route_Name_Admission is
      package Applications renames Flyology.HTTP.Server.Applications;

      type Context is record
         Calls : Natural := 0;
      end record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      Clock_Value : Ada.Real_Time.Time := Ada.Real_Time.Clock;
      function Test_Clock return Ada.Real_Time.Time is (Clock_Value);
      function Client_Key (X : Applications.Exchange) return String is
        (X.Request_Header ("X-Client"));

      package Rates is new Flyology.HTTP.Server.Middleware_Rate_Limits
        (Context, Routing.Components, Client_Key,
         Capacity => 8, Clock => Test_Clock);
      package Bulkheads is new Flyology.HTTP.Server.Middleware_Bulkheads
        (Context, Routing.Components, Route_Capacity => 4);

      procedure Serve_It
        (State : in out Context;
         X     : in out Applications.Exchange) is
      begin
         State.Calls := State.Calls + 1;
         X.Text (200, "served");
      end Serve_It;

      Deep_Pattern : constant String :=
        "/api/v2/organizations/{org}/workspaces/{ws}/projects/{project}"
        & "/pipelines/{pipeline}/runs/{run}/artifacts/{artifact}";
      Deep_Target : constant String :=
        "/services/orchestration/api/v2/organizations/acme/workspaces/main"
        & "/projects/p1/pipelines/nightly/runs/r7/artifacts/a3";

      Nested     : Routing.Router
        (Capacity => 2, Slashes => Routing.Strict_Slashes);
      Rated      : Routing.Router
        (Capacity => 4, Slashes => Routing.Strict_Slashes);
      Bulkheaded : Routing.Router
        (Capacity => 4, Slashes => Routing.Strict_Slashes);
      State      : Context;

      function Status
        (Routes : in out Routing.Router;
         Target : String) return String
      is
         Wire : aliased Memory_Transport;
      begin
         Wire.Input := To_Unbounded_String
           ("POST " & Target & " HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "X-Client: 203.0.113.7" & CRLF
            & "Content-Length: 0" & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Routes.Serve (State, Client, Test_Peer);
         end;
         declare
            Output : constant String := To_String (Wire.Output);
         begin
            return
              (if Output'Length >= 12
               then Output (Output'First + 9 .. Output'First + 11)
               else "---");
         end;
      end Status;
   begin
      Nested.Post
        (Deep_Pattern, Serve_It'Access,
         Policy =>
           (Routing.Default_Route_Policy with delta
              Body_Handling   => Applications.Buffer_Body,
              Rate_Per_Second => 8,
              Concurrency     => 2));
      Rated.Post
        ("/short", Serve_It'Access, Name => "short",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Body_Handling   => Applications.Buffer_Body,
              Rate_Per_Second => 8,
              Concurrency     => 2));
      Rated.Mount
        ("/services/orchestration", Nested, Name_Prefix => "orchestration.");
      Bulkheaded.Mount
        ("/services/orchestration", Nested, Name_Prefix => "orchestration.");
      Rated.Add_Middleware (Rates.Call'Access);
      Bulkheaded.Add_Middleware (Bulkheads.Call'Access);

      declare
         Deep : constant Routing.Route_Description :=
           Rated.Describe_Route (2);
      begin
         --  The reproduction is only meaningful above the limiters' bound.
         if Length (Deep.Name) <= 128 then
            Failures := Failures + 1;
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "FAIL finding 17 setup: mounted route name is only"
               & Natural'Image (Length (Deep.Name)) & " characters");
         end if;
      end;

      --  Control: a short route name is admitted by the token bucket.
      Expect
        ("finding 17 short route", Status (Rated, "/short"), "200");

      --  The long-named route must be admitted on the same budget.
      Expect
        ("finding 17 rate-limited deep route",
         Status (Rated, Deep_Target), "200");
      Clock_Value := Clock_Value + Ada.Real_Time.Seconds (1);
      Expect
        ("finding 17 rate-limited deep route repeat",
         Status (Rated, Deep_Target), "200");

      --  The bulkhead denies the same name independently of the bucket.
      Expect
        ("finding 17 bulkheaded deep route",
         Status (Bulkheaded, Deep_Target), "200");
      Expect
        ("finding 17 bulkheaded deep route repeat",
         Status (Bulkheaded, Deep_Target), "200");

      Expect ("finding 17 handler calls", State.Calls'Image, " 5");
   end Check_Long_Route_Name_Admission;

   --  Finding 17 (same root cause). Bulkhead route counters were never
   --  released, so once Route_Capacity distinct names had been seen every
   --  further route was denied a bare 503 indistinguishable from a genuine
   --  concurrency denial. Counters at rest are now taken over, and a table
   --  whose entries are all in use reports a distinct problem type.
   procedure Check_Bulkhead_Counter_Reuse is
      package Applications renames Flyology.HTTP.Server.Applications;

      type Context is record
         Nested : Unbounded_String;
      end record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      package Reuse_Bulkheads is new Flyology.HTTP.Server.Middleware_Bulkheads
        (Context, Routing.Components, Route_Capacity => 2);
      package Held_Bulkheads is new Flyology.HTTP.Server.Middleware_Bulkheads
        (Context, Routing.Components, Route_Capacity => 1);

      Reused : Routing.Router
        (Capacity => 3, Slashes => Routing.Strict_Slashes);
      Held   : Routing.Router
        (Capacity => 2, Slashes => Routing.Strict_Slashes);
      State  : Context;

      procedure Plain
        (Value : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (Value);
      begin
         X.Text (200, "plain");
      end Plain;

      function Request_Once
        (Routes : in out Routing.Router;
         Target : String) return String
      is
         Wire : aliased Memory_Transport;
      begin
         Wire.Input := To_Unbounded_String
           ("GET " & Target & " HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Routes.Serve (State, Client, Test_Peer);
         end;
         return To_String (Wire.Output);
      end Request_Once;

      function Status_Of (Output : String) return String is
        (if Output'Length >= 12
         then Output (Output'First + 9 .. Output'First + 11) else "---");

      --  Runs while its own route counter is still held, so the second route
      --  cannot be metered at all when only one counter exists.
      procedure Nesting
        (Value : in out Context;
         X     : in out Applications.Exchange) is
      begin
         Value.Nested := To_Unbounded_String (Request_Once (Held, "/inner"));
         X.Text (200, "outer");
      end Nesting;
   begin
      Reused.Get
        ("/a", Plain'Access, Name => "a",
         Policy =>
           (Routing.Default_Route_Policy with delta Concurrency => 1));
      Reused.Get
        ("/b", Plain'Access, Name => "b",
         Policy =>
           (Routing.Default_Route_Policy with delta Concurrency => 1));
      Reused.Get
        ("/c", Plain'Access, Name => "c",
         Policy =>
           (Routing.Default_Route_Policy with delta Concurrency => 1));
      Reused.Add_Middleware (Reuse_Bulkheads.Call'Access);

      Held.Get
        ("/outer", Nesting'Access, Name => "outer",
         Policy =>
           (Routing.Default_Route_Policy with delta Concurrency => 1));
      Held.Get
        ("/inner", Plain'Access, Name => "inner",
         Policy =>
           (Routing.Default_Route_Policy with delta Concurrency => 1));
      Held.Add_Middleware (Held_Bulkheads.Call'Access);

      --  Two counters, three route names seen in turn. The third only fits
      --  once a counter at rest can be taken over.
      Expect
        ("finding 17 counter a",
         Status_Of (Request_Once (Reused, "/a")), "200");
      Expect
        ("finding 17 counter b",
         Status_Of (Request_Once (Reused, "/b")), "200");
      Expect
        ("finding 17 counter c",
         Status_Of (Request_Once (Reused, "/c")), "200");

      --  One counter, held by the outer route while the inner one runs. The
      --  inner denial must name the exhausted table, not read as a plain
      --  concurrency rejection.
      Expect
        ("finding 17 held outer",
         Status_Of (Request_Once (Held, "/outer")), "200");
      Expect
        ("finding 17 held inner", Status_Of (To_String (State.Nested)),
         "503");
      if Ada.Strings.Fixed.Index
        (To_String (State.Nested), "bulkhead-unmeterable") = 0
      then
         Failures := Failures + 1;
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "FAIL finding 17 held inner problem type: expected"
            & " bulkhead-unmeterable in [" & To_String (State.Nested) & "]");
      end if;
   end Check_Bulkhead_Counter_Reuse;

   --  Finding 27. Run_Automatic configured every automatic response with a
   --  zero concurrency and zero rate, which both limiters read as unlimited,
   --  so the 404, 405, OPTIONS, redirect, and malformed-path surface ran the
   --  whole global middleware chain and wrote a response with no per-client
   --  bound and no way to ask for one.
   procedure Check_Automatic_Response_Admission is
      package Applications renames Flyology.HTTP.Server.Applications;

      type Context is null record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      Clock_Value : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      function Test_Clock return Ada.Real_Time.Time is (Clock_Value);
      function Client_Key (X : Applications.Exchange) return String is
        (X.Request_Header ("X-Client"));

      package Rates is new Flyology.HTTP.Server.Middleware_Rate_Limits
        (Context, Routing.Components, Client_Key,
         Capacity => 32, Clock => Test_Clock);

      procedure Plain
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         X.Text (200, "plain");
      end Plain;

      Metered   : Routing.Router
        (Capacity => 2, Slashes => Routing.Strict_Slashes);
      Unmetered : Routing.Router
        (Capacity => 2, Slashes => Routing.Strict_Slashes);
      State     : Context;

      function Status
        (Routes : in out Routing.Router;
         Target : String) return String
      is
         Wire : aliased Memory_Transport;
      begin
         Wire.Input := To_Unbounded_String
           ("GET " & Target & " HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "X-Client: 198.51.100.9" & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Routes.Serve (State, Client, Test_Peer);
         end;
         declare
            Output : constant String := To_String (Wire.Output);
         begin
            return
              (if Output'Length >= 12
               then Output (Output'First + 9 .. Output'First + 11)
               else "---");
         end;
      end Status;
   begin
      Metered.Get
        ("/kept", Plain'Access, Name => "kept",
         Policy =>
           (Routing.Default_Route_Policy with delta Rate_Per_Second => 2));
      Metered.Add_Middleware (Rates.Call'Access);
      Metered.Set_Automatic_Admission (Rate_Per_Second => 2);

      Unmetered.Get ("/kept", Plain'Access, Name => "unmetered.kept");
      Unmetered.Add_Middleware (Rates.Call'Access);

      --  A configured router bounds its unmatched-path surface per client.
      Expect
        ("finding 27 first miss", Status (Metered, "/gone-1"), "404");
      Expect
        ("finding 27 second miss", Status (Metered, "/gone-2"), "404");
      Expect
        ("finding 27 third miss", Status (Metered, "/gone-3"), "429");
      Expect
        ("finding 27 fourth miss", Status (Metered, "/gone-4"), "429");

      --  The default stays unlimited, so an unconfigured router is unchanged.
      for Index in 1 .. 6 loop
         pragma Unreferenced (Index);
         Expect
           ("finding 27 default miss",
            Status (Unmetered, "/gone"), "404");
      end loop;
   end Check_Automatic_Response_Admission;

   --  Finding 30. Mount snapshots the source router's routes and middleware
   --  into the destination, so a registration on the source afterwards
   --  reached nothing. Setup code that mounted a subrouter and only then
   --  added its authorization middleware left every mounted route running
   --  unprotected with no diagnostic.
   procedure Check_Mount_Sealing is
      package Applications renames Flyology.HTTP.Server.Applications;

      type Context is null record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      procedure Secret
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         X.Text (200, "secret");
      end Secret;

      procedure Deny
        (State : in out Context;
         X     : in out Applications.Exchange;
         Next  : in out Routing.Components.Next_Handler)
      is
         pragma Unreferenced (State, Next);
      begin
         X.Problem (403, "forbidden", "Access is denied");
      end Deny;

      Ordered  : Routing.Router
        (Capacity => 2, Slashes => Routing.Strict_Slashes);
      Ordered_Sub : Routing.Router
        (Capacity => 1, Slashes => Routing.Strict_Slashes);
      Late     : Routing.Router
        (Capacity => 2, Slashes => Routing.Strict_Slashes);
      Late_Sub : Routing.Router
        (Capacity => 3, Slashes => Routing.Strict_Slashes);
      State    : Context;

      function Status
        (Routes : in out Routing.Router;
         Target : String) return String
      is
         Wire : aliased Memory_Transport;
      begin
         Wire.Input := To_Unbounded_String
           ("GET " & Target & " HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Routes.Serve (State, Client, Test_Peer);
         end;
         declare
            Output : constant String := To_String (Wire.Output);
         begin
            return
              (if Output'Length >= 12
               then Output (Output'First + 9 .. Output'First + 11)
               else "---");
         end;
      end Status;

      Raised : Boolean;
   begin
      --  Registering before mounting keeps working and does protect.
      Ordered_Sub.Get ("/secret", Secret'Access, Name => "secret");
      Ordered_Sub.Add_Middleware (Deny'Access, Name => "deny");
      Ordered.Mount ("/api", Ordered_Sub, Name_Prefix => "api.");
      Expect
        ("finding 30 protected mount",
         Status (Ordered, "/api/secret"), "403");

      --  Registering after mounting is a setup-time error, not a silently
      --  unprotected route.
      Late_Sub.Get ("/secret", Secret'Access, Name => "secret");
      Late.Mount ("/api", Late_Sub, Name_Prefix => "api.");
      Raised := False;
      begin
         Late_Sub.Add_Middleware (Deny'Access, Name => "deny");
      exception
         when Routing.Route_Error =>
            Raised := True;
      end;
      Expect ("finding 30 late middleware", Raised'Image, "TRUE");
      if not Raised then
         Expect
           ("finding 30 late middleware effect",
            Status (Late, "/api/secret"), "403");
      end if;

      Raised := False;
      begin
         Late_Sub.Add_Route_Middleware
           ("secret", Deny'Access, Middleware_Name => "deny");
      exception
         when Routing.Route_Error =>
            Raised := True;
      end;
      Expect ("finding 30 late route middleware", Raised'Image, "TRUE");

      Raised := False;
      begin
         Late_Sub.Get ("/other", Secret'Access, Name => "other");
      exception
         when Routing.Route_Error =>
            Raised := True;
      end;
      Expect ("finding 30 late route", Raised'Image, "TRUE");
   end Check_Mount_Sealing;

   --  Finding 32. Require_Authentication, the router's own fail-closed
   --  backstop, always advertised Bearer. An application whose authentication
   --  middleware runs at the Application stage places it after that backstop,
   --  so every request to a Required_Authentication route was answered with a
   --  challenge naming a scheme the application does not use, and the 401 was
   --  indistinguishable from the middleware's own rejection.
   procedure Check_Authentication_Challenge is
      package Applications renames Flyology.HTTP.Server.Applications;

      type Context is null record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      Basic_Challenge : constant String := "Basic realm=""app""";

      procedure Verify
        (Scheme        : String;
         Credential    : String;
         Authenticated : in out Boolean;
         Principal     : out Unbounded_String) is
      begin
         Authenticated := Scheme = "Basic" and then Credential = "ok";
         Principal :=
           (if Authenticated then To_Unbounded_String ("user")
            else Null_Unbounded_String);
      end Verify;

      package Basic_Auth is new
        Flyology.HTTP.Server.Middleware_Authentication
          (Context, Routing.Components, Verify,
           Challenge => Basic_Challenge);

      procedure Private_Page
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         X.Text (200, "private");
      end Private_Page;

      Late  : Routing.Router
        (Capacity => 1, Slashes => Routing.Strict_Slashes);
      Early : Routing.Router
        (Capacity => 1, Slashes => Routing.Strict_Slashes);
      State : Context;

      function Answer
        (Routes : in out Routing.Router;
         Target : String) return String
      is
         Wire : aliased Memory_Transport;
      begin
         Wire.Input := To_Unbounded_String
           ("GET " & Target & " HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Routes.Serve (State, Client, Test_Peer);
         end;
         return To_String (Wire.Output);
      end Answer;
   begin
      Late.Get
        ("/private", Private_Page'Access, Name => "private",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Authentication => Routing.Required_Authentication));
      Late.Add_Middleware
        (Basic_Auth.Call'Access, Stage => Routing.Application,
         Name => "authentication");
      Late.Set_Authentication_Challenge (Basic_Challenge);

      --  The backstop must advertise the application's configured scheme and
      --  must say that nothing installed a principal before it, so the
      --  misordering is visible instead of reading as a credential failure.
      declare
         Output : constant String := Answer (Late, "/private");
      begin
         Expect_In
           ("finding 32 backstop status", Output, "HTTP/1.1 401");
         Expect_In
           ("finding 32 backstop challenge", Output,
            "WWW-Authenticate: " & Basic_Challenge);
         Expect_In
           ("finding 32 backstop problem", Output,
            "authentication-not-installed");
      end;

      --  Authentication at the Request_Head stage runs before the backstop
      --  and keeps reporting an ordinary credential rejection.
      Early.Get
        ("/private", Private_Page'Access, Name => "private",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Authentication => Routing.Required_Authentication));
      Early.Add_Middleware
        (Basic_Auth.Call'Access, Name => "authentication");
      declare
         Output : constant String := Answer (Early, "/private");
      begin
         Expect_In
           ("finding 32 middleware challenge", Output,
            "WWW-Authenticate: " & Basic_Challenge);
         Expect_In
           ("finding 32 middleware problem", Output,
            "authentication-required");
      end;

      --  A challenge that cannot be sent must fail at setup, not per request.
      declare
         Raised : Boolean := False;
      begin
         begin
            Early.Set_Authentication_Challenge
              ("Basic" & Character'Val (13) & "X-Injected: 1");
         exception
            when Routing.Route_Error =>
               Raised := True;
         end;
         Expect ("finding 32 challenge validation", Raised'Image, "TRUE");
         Expect
           ("finding 32 challenge default",
            Late.Authentication_Challenge, Basic_Challenge);
      end;
   end Check_Authentication_Challenge;

   --  Finding 11. The Authenticate generic formal returns its security
   --  decision through an out-mode Boolean, which Ada passes with copy-out
   --  and no copy-in, so a hook with a path that returns without assigning it
   --  leaves the middleware reading whatever the callee's frame held. Whether
   --  that byte is nonzero is a property of the generated frame layout, so
   --  the bypass itself cannot be pinned deterministically; changing the mode
   --  to in out is the fix. What is pinned here is the only deterministic
   --  backstop the middleware has: an accepted decision that installs no
   --  principal must still be refused.
   procedure Check_Authentication_Backstop is
      package Applications renames Flyology.HTTP.Server.Applications;

      type Context is null record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      --  Accepts everything but names nobody.
      procedure Anonymous_Verify
        (Scheme        : String;
         Credential    : String;
         Authenticated : in out Boolean;
         Principal     : out Unbounded_String)
      is
         pragma Unreferenced (Scheme, Credential);
      begin
         Authenticated := True;
         Principal := Null_Unbounded_String;
      end Anonymous_Verify;

      package Anonymous_Auth is new
        Flyology.HTTP.Server.Middleware_Authentication
          (Context, Routing.Components, Anonymous_Verify);

      procedure Private_Page
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         X.Text (200, "private");
      end Private_Page;

      Guarded : Routing.Router
        (Capacity => 1, Slashes => Routing.Strict_Slashes);
      State   : Context;

      function Answer (Target, Credentials : String) return String is
         Wire : aliased Memory_Transport;
      begin
         Wire.Input := To_Unbounded_String
           ("GET " & Target & " HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Authorization: " & Credentials & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Guarded.Serve (State, Client, Test_Peer);
         end;
         return To_String (Wire.Output);
      end Answer;
   begin
      Guarded.Get
        ("/private", Private_Page'Access, Name => "private",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Authentication => Routing.Required_Authentication));
      Guarded.Add_Middleware
        (Anonymous_Auth.Call'Access, Name => "authentication");

      Expect_In
        ("finding 11 principal-less acceptance",
         Answer ("/private", "Basic AAAA"), "HTTP/1.1 401");
   end Check_Authentication_Backstop;

   --  Finding 11. A hook with a path that returns without assigning the
   --  decision used to hand the middleware whatever byte the hook's frame
   --  held, because an out scalar is copied out over the middleware's own
   --  Accepted : Boolean := False and never copied in. With the formal
   --  declared in out that False now reaches the hook and survives the
   --  unassigned path, so the refusal is deterministic and can be pinned.
   procedure Check_Partially_Written_Hook_Fails_Closed is
      package Applications renames Flyology.HTTP.Server.Applications;

      type Context is null record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      --  Decides Bearer and silently ignores every other scheme, which is the
      --  omission the audit describes.
      procedure Bearer_Only_Verify
        (Scheme        : String;
         Credential    : String;
         Authenticated : in out Boolean;
         Principal     : out Unbounded_String) is
      begin
         Principal := To_Unbounded_String ("attacker");
         if Scheme = "Bearer" then
            Authenticated := Credential = "secret";
         end if;
      end Bearer_Only_Verify;

      package Bearer_Auth is new
        Flyology.HTTP.Server.Middleware_Authentication
          (Context, Routing.Components, Bearer_Only_Verify);

      procedure Private_Page
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         X.Text (200, "private");
      end Private_Page;

      Guarded : Routing.Router
        (Capacity => 1, Slashes => Routing.Strict_Slashes);
      State   : Context;

      function Answer (Credentials : String) return String is
         Wire : aliased Memory_Transport;
      begin
         Wire.Input := To_Unbounded_String
           ("GET /private HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Authorization: " & Credentials & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Guarded.Serve (State, Client, Test_Peer);
         end;
         return To_String (Wire.Output);
      end Answer;
   begin
      Guarded.Get
        ("/private", Private_Page'Access, Name => "private",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Authentication => Routing.Required_Authentication));
      Guarded.Add_Middleware
        (Bearer_Auth.Call'Access, Name => "authentication");

      --  Prime the frame with a decision of True, so a hook that leaves the
      --  flag alone on the next call would read True if it were copied out.
      Expect_In
        ("finding 11 accepted Bearer",
         Answer ("Bearer secret"), "HTTP/1.1 200");
      Expect_In
        ("finding 11 unassigned decision",
         Answer ("Basic AAAA"), "HTTP/1.1 401");
      Expect_In
        ("finding 11 rejected Bearer",
         Answer ("Bearer wrong"), "HTTP/1.1 401");
   end Check_Partially_Written_Hook_Fails_Closed;

   --  Finding 26. Create rejected the wildcard/credentials combination only
   --  when Allowed_Origins was exactly "*", but Origin_Allowed matches whole
   --  space-separated tokens, so a "*" member reflected a literal Origin: *
   --  with Allow-Credentials: true while Wildcard stayed false.
   procedure Check_CORS_List_Member_Validation is
      package Applications renames Flyology.HTTP.Server.Applications;
      package CORS renames Flyology.HTTP.Server.CORS;

      type Context is null record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      Listed : aliased constant CORS.Policy := CORS.Create
        (Allowed_Origins   => "https://app.example https://ops.example",
         Allowed_Methods   => "GET",
         Allow_Credentials => True);

      function Resolve (Slot : Positive)
        return access constant CORS.Policy is
        (if Slot = 1 then Listed'Access else null);

      function Rejected
        (Origins     : String;
         Credentials : Boolean) return Boolean is
      begin
         declare
            Discard : constant CORS.Policy := CORS.Create
              (Allowed_Origins   => Origins,
               Allowed_Methods   => "GET",
               Allow_Credentials => Credentials);
            pragma Unreferenced (Discard);
         begin
            null;
         end;
         return False;
      exception
         when Program_Error =>
            return True;
      end Rejected;

      package CORS_Layer is new Flyology.HTTP.Server.Middleware_CORS
        (Context, Routing.Components, Resolve);

      procedure Plain
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         X.Text (200, "plain");
      end Plain;

      Shared : Routing.Router
        (Capacity => 1, Slashes => Routing.Strict_Slashes);
      State  : Context;

      function Answer (Origin : String) return String is
         Wire : aliased Memory_Transport;
      begin
         Wire.Input := To_Unbounded_String
           ("GET /data HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Origin: " & Origin & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Shared.Serve (State, Client, Test_Peer);
         end;
         return To_String (Wire.Output);
      end Answer;
   begin
      Shared.Get
        ("/data", Plain'Access, Name => "data",
         Policy =>
           (Routing.Default_Route_Policy with delta CORS_Policy => 1));
      Shared.Add_Middleware (CORS_Layer.Call'Access, Name => "cors");

      --  A listed wildcard never reaches Origin_Allowed.
      Expect
        ("finding 26 listed wildcard with credentials",
         Rejected ("https://app.example *", True)'Image, "TRUE");
      Expect
        ("finding 26 listed wildcard without credentials",
         Rejected ("https://app.example *", False)'Image, "TRUE");
      Expect
        ("finding 26 sole wildcard with credentials",
         Rejected ("*", True)'Image, "TRUE");
      Expect
        ("finding 26 listed null with credentials",
         Rejected ("https://app.example null", True)'Image, "TRUE");
      Expect
        ("finding 26 sole null with credentials",
         Rejected ("null", True)'Image, "TRUE");

      --  The shapes that were always meant to work still do.
      Expect
        ("finding 26 sole wildcard without credentials",
         Rejected ("*", False)'Image, "FALSE");
      Expect
        ("finding 26 listed null without credentials",
         Rejected ("https://app.example null", False)'Image, "FALSE");
      Expect
        ("finding 26 exact list with credentials",
         Rejected ("https://app.example https://ops.example", True)'Image,
         "FALSE");

      --  A credentialed exact list still reflects its own members and
      --  refuses every other origin.
      declare
         Allowed : constant String := Answer ("https://ops.example");
         Denied  : constant String := Answer ("https://evil.example");
      begin
         Expect
           ("finding 26 allowed member origin",
            Field_Value (Allowed, "Access-Control-Allow-Origin"),
            "https://ops.example");
         Expect
           ("finding 26 allowed member credentials",
            Field_Value (Allowed, "Access-Control-Allow-Credentials"),
            "true");
         Expect
           ("finding 26 allowed member vary",
            Field_Value (Allowed, "Vary"), "Origin");
         Expect
           ("finding 26 unlisted origin",
            Field_Value (Denied, "Access-Control-Allow-Origin"), "");
      end;
   end Check_CORS_List_Member_Validation;

   --  Finding 28. Add_Header is append-only and there is no set, replace, or
   --  remove operation, so a handler that needs a different value than the
   --  security-headers component configured emits two conflicting fields.
   procedure Check_Response_Header_Replacement is
      package Applications renames Flyology.HTTP.Server.Applications;

      type Context is null record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      package Headers is new
        Flyology.HTTP.Server.Middleware_Security_Headers
          (Context, Routing.Components,
           Referrer_Policy => "no-referrer",
           Frame_Options   => "SAMEORIGIN");

      procedure Widget
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         --  The replacement lands once even though the component already
         --  emitted the field, and removal matches the name
         --  case-insensitively.
         X.Set_Header ("X-Frame-Options", "ALLOWALL");
         X.Remove_Header ("referrer-policy");
         X.Text (200, "widget");
      end Widget;

      procedure Layered
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         --  Add_Header stays append-only: repeated names are legitimate for
         --  Set-Cookie and Vary.
         X.Add_Header ("Vary", "Accept-Encoding");
         X.Set_Header ("X-Content-Type-Options", "nosniff");
         X.Remove_Header ("X-Absent-Header");
         X.Text (200, "layered");
      end Layered;

      Embedded : Routing.Router
        (Capacity => 2, Slashes => Routing.Strict_Slashes);
      State    : Context;

      function Answer (Target : String) return String is
         Wire : aliased Memory_Transport;
      begin
         Wire.Input := To_Unbounded_String
           ("GET " & Target & " HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Embedded.Serve (State, Client, Test_Peer);
         end;
         return To_String (Wire.Output);
      end Answer;
   begin
      Embedded.Get ("/widget", Widget'Access, Name => "widget");
      Embedded.Get ("/layered", Layered'Access, Name => "layered");
      Embedded.Add_Middleware (Headers.Call'Access, Name => "headers");

      declare
         Output : constant String := Answer ("/widget");
      begin
         Expect
           ("finding 28 framing field count",
            Occurrences (Output, "X-Frame-Options:")'Image, " 1");
         Expect
           ("finding 28 framing value",
            Field_Value (Output, "X-Frame-Options"), "ALLOWALL");
         Expect
           ("finding 28 referrer field count",
            Occurrences (Output, "Referrer-Policy:")'Image, " 0");
         Expect
           ("finding 28 untouched field",
            Field_Value (Output, "X-Content-Type-Options"), "nosniff");
      end;

      declare
         Output : constant String := Answer ("/layered");
      begin
         Expect
           ("finding 28 appended duplicates",
            Occurrences (Output, "Vary:")'Image, " 1");
         Expect
           ("finding 28 replaced single field",
            Occurrences (Output, "X-Content-Type-Options:")'Image, " 1");
         Expect
           ("finding 28 retained referrer",
            Field_Value (Output, "Referrer-Policy"), "no-referrer");
      end;
   end Check_Response_Header_Replacement;

   --  Finding 29. Default request IDs were fly-<N> from one process-wide
   --  monotonic counter and were echoed to the client, so subtracting two
   --  observed values reported how many requests the server handled in
   --  between.
   procedure Check_Request_ID_Unpredictability is
      package Applications renames Flyology.HTTP.Server.Applications;

      use type Interfaces.Unsigned_64;

      type Context is null record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      package IDs is new Flyology.HTTP.Server.Middleware_Request_IDs
        (Context, Routing.Components);

      procedure Plain
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         X.Text (200, "plain");
      end Plain;

      Traced : Routing.Router
        (Capacity => 1, Slashes => Routing.Strict_Slashes);
      State  : Context;

      function Next_Identifier return String is
         Wire : aliased Memory_Transport;
      begin
         Wire.Input := To_Unbounded_String
           ("GET /traced HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Traced.Serve (State, Client, Test_Peer);
         end;
         return Field_Value (To_String (Wire.Output), "X-Request-ID");
      end Next_Identifier;

      Samples : array (1 .. 8) of Unbounded_String;
   begin
      Traced.Get ("/traced", Plain'Access, Name => "traced");
      Traced.Add_Middleware (IDs.Call'Access, Name => "request-ids");

      for Index in Samples'Range loop
         Samples (Index) := To_Unbounded_String (Next_Identifier);
      end loop;

      --  A fixed-width opaque suffix, so no request count is legible.
      for Index in Samples'Range loop
         declare
            Value : constant String := To_String (Samples (Index));
         begin
            if Value'Length /= 20
              or else Value (Value'First .. Value'First + 3) /= "fly-"
            then
               Failures := Failures + 1;
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "FAIL finding 29 identifier shape: observed ["
                  & Value & "]");
            end if;
         end;
      end loop;

      --  Distinct within the process, so the counter still guarantees
      --  uniqueness through the keyed permutation.
      for Left in Samples'Range loop
         for Right in Left + 1 .. Samples'Last loop
            if Samples (Left) = Samples (Right) then
               Failures := Failures + 1;
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "FAIL finding 29 duplicate identifier "
                  & To_String (Samples (Left)));
            end if;
         end loop;
      end loop;

      --  Successive identifiers must not sit at a constant numeric distance,
      --  which is what made the old counter a traffic-volume oracle.
      declare
         --  Read the suffix as a base-16 magnitude; the pre-fix decimal
         --  counter reads consistently under the same scale.
         function Numeric (Value : String) return Interfaces.Unsigned_64 is
            Result : Interfaces.Unsigned_64 := 0;
            Digit  : Natural;
         begin
            for Item of Value (Value'First + 4 .. Value'Last) loop
               Digit :=
                 (case Item is
                     when '0' .. '9' =>
                       Character'Pos (Item) - Character'Pos ('0'),
                     when 'a' .. 'f' =>
                       Character'Pos (Item) - Character'Pos ('a') + 10,
                     when others => 0);
               Result :=
                 Result * 16 + Interfaces.Unsigned_64 (Digit);
            end loop;
            return Result;
         end Numeric;

         Constant_Stride : Boolean := True;
         Stride : Interfaces.Unsigned_64;
         Previous : Interfaces.Unsigned_64;
         Current  : Interfaces.Unsigned_64;
      begin
         Previous := Numeric (To_String (Samples (1)));
         Current := Numeric (To_String (Samples (2)));
         Stride := Current - Previous;
         for Index in 3 .. Samples'Last loop
            Previous := Current;
            Current := Numeric (To_String (Samples (Index)));
            if Current - Previous /= Stride then
               Constant_Stride := False;
            end if;
         end loop;
         if Constant_Stride then
            Failures := Failures + 1;
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "FAIL finding 29 constant stride: "
               & To_String (Samples (1)) & " .. "
               & To_String (Samples (Samples'Last)));
         end if;
      end;
   end Check_Request_ID_Unpredictability;

begin
   Check_Target_Form_Anchoring;
   Check_Long_Route_Name_Admission;
   Check_Bulkhead_Counter_Reuse;
   Check_Automatic_Response_Admission;
   Check_Mount_Sealing;
   Check_Authentication_Challenge;
   Check_Authentication_Backstop;
   Check_Partially_Written_Hook_Fails_Closed;
   Check_CORS_List_Member_Validation;
   Check_Response_Header_Replacement;
   Check_Request_ID_Unpredictability;
   if Failures /= 0 then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "HTTP routing audit regressions:" & Failures'Image);
      raise Program_Error with "HTTP routing audit regressions";
   end if;
   Ada.Text_IO.Put_Line ("HTTP routing audit passed");
end HTTP_Routing_Audit;
