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

   --  Runtime router updates publish a complete immutable generation. Route
   --  and middleware identities survive replacement, stale candidates fail,
   --  and concurrent dispatch observes either complete generation.
   procedure Check_Runtime_Reconfiguration is
      package Applications renames Flyology.HTTP.Server.Applications;

      type Context is null record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      use type Routing.Middleware_ID;
      use type Routing.Route_ID;

      procedure Handler_One
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         X.Text (200, "one");
      end Handler_One;

      procedure Handler_Two
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         X.Text (200, "two");
      end Handler_Two;

      procedure Global_One
        (State : in out Context;
         X     : in out Applications.Exchange;
         Next  : in out Routing.Components.Next_Handler) is
      begin
         X.Add_Header ("X-Global", "one");
         Next.Call (State, X);
      end Global_One;

      procedure Global_Two
        (State : in out Context;
         X     : in out Applications.Exchange;
         Next  : in out Routing.Components.Next_Handler) is
      begin
         X.Add_Header ("X-Global", "two");
         Next.Call (State, X);
      end Global_Two;

      procedure Local_One
        (State : in out Context;
         X     : in out Applications.Exchange;
         Next  : in out Routing.Components.Next_Handler) is
      begin
         X.Add_Header ("X-Local", "one");
         Next.Call (State, X);
      end Local_One;

      procedure Local_Two
        (State : in out Context;
         X     : in out Applications.Exchange;
         Next  : in out Routing.Components.Next_Handler) is
      begin
         X.Add_Header ("X-Local", "two");
         Next.Call (State, X);
      end Local_Two;

      Routes : Routing.Router
        (Capacity => 2, Slashes => Routing.Strict_Slashes);
      State  : Context;

      function Response return String is
         Wire : aliased Memory_Transport;
      begin
         Wire.Input := To_Unbounded_String
           ("GET /users/42 HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Routes.Serve (State, Client, Test_Peer);
         end;
         return To_String (Wire.Output);
      end Response;

      User_Route    : Routing.Route_ID;
      Resolved      : Routing.Route_ID;
      Global_Layer  : Routing.Middleware_ID;
      Local_Layer   : Routing.Middleware_ID;
      Found         : Boolean;
   begin
      Routes.Get
        ("/users/{id}", Handler_One'Access, User_Route,
         Name => "users.show");
      Routes.Add_Middleware
        (Global_One'Access, Global_Layer, Name => "global-version");
      Routes.Add_Route_Middleware
        ("users.show", Local_One'Access, Local_Layer,
         Middleware_Name => "local-version");

      Routes.Find_Route ("users.show", Resolved, Found);
      Expect ("runtime route found", Found'Image, "TRUE");
      Expect
        ("runtime route helper id",
         Boolean'Image (Resolved = User_Route), "TRUE");
      Expect
        ("runtime route description id",
         Boolean'Image (Routes.Describe_Route (1).ID = User_Route), "TRUE");
      Expect
        ("runtime global middleware id",
         Boolean'Image
           (Routes.Describe_Global_Middleware (1).ID = Global_Layer),
         "TRUE");
      Expect
        ("runtime local middleware id",
         Boolean'Image
           (Routes.Describe_Route_Middleware (1, 1).ID = Local_Layer),
         "TRUE");
      declare
         Output : constant String := Response;
      begin
         Expect_In ("runtime initial handler", Output, CRLF & CRLF & "one");
         Expect_In ("runtime initial global", Output, "X-Global: one");
         Expect_In ("runtime initial local", Output, "X-Local: one");
      end;

      declare
         Change : Routing.Update;
         Policy : Routing.Route_Policy := Routing.Default_Route_Policy;
      begin
         Policy.Timeout := 1.25;
         Routes.Begin_Update (Change);
         Routing.Replace_Handler (Change, User_Route, Handler_Two'Access);
         Routing.Set_Policy (Change, User_Route, Policy);
         Routing.Replace_Middleware
           (Change, Global_Layer, Global_Two'Access);
         Routing.Replace_Middleware
           (Change, Local_Layer, Local_Two'Access);
         Routes.Commit (Change);
      end;
      declare
         Output : constant String := Response;
      begin
         Expect_In ("runtime replaced handler", Output, CRLF & CRLF & "two");
         Expect_In ("runtime replaced global", Output, "X-Global: two");
         Expect_In ("runtime replaced local", Output, "X-Local: two");
      end;
      Expect
        ("runtime route id stable",
         Boolean'Image
           (Routes.Describe_Route (1).ID = User_Route), "TRUE");
      Expect
        ("runtime middleware id stable",
         Boolean'Image
           (Routes.Describe_Route_Middleware (1, 1).ID = Local_Layer),
         "TRUE");
      Expect
        ("runtime policy replaced",
         Boolean'Image
           (Routes.Describe_Route (1).Policy.Timeout = 1.25), "TRUE");

      declare
         First  : Routing.Update;
         Stale  : Routing.Update;
         Raised : Boolean := False;
      begin
         Routes.Begin_Update (First);
         Routes.Begin_Update (Stale);
         Routing.Set_Authentication_Challenge (First, "Basic realm=test");
         Routes.Commit (First);
         begin
            Routing.Set_Authentication_Challenge (Stale, "Bearer");
            Routes.Commit (Stale);
         exception
            when Routing.Stale_Update =>
               Raised := True;
         end;
         Expect ("runtime stale update", Raised'Image, "TRUE");
         Expect
           ("runtime candidate parameter",
            Routes.Authentication_Challenge, "Basic realm=test");
      end;

      declare
         Change       : Routing.Update;
         New_Route    : Routing.Route_ID;
         New_Global   : Routing.Middleware_ID;
         Raised_Route : Boolean := False;
         Raised_Layer : Boolean := False;
      begin
         Routes.Begin_Update (Change);
         Routing.Remove (Change, User_Route);
         Routing.Add
           (Change, "GET", "/users/{id}", Handler_One'Access, New_Route,
            Name => "users.show");
         Routing.Remove_Middleware (Change, Global_Layer);
         Routing.Add_Middleware
           (Change, Global_One'Access, New_Global, Name => "global-version");
         Routes.Commit (Change);
         Expect
           ("runtime route ids not reused",
            Boolean'Image (New_Route /= User_Route), "TRUE");
         Expect
           ("runtime middleware ids not reused",
            Boolean'Image (New_Global /= Global_Layer), "TRUE");

         declare
            Invalid : Routing.Update;
         begin
            Routes.Begin_Update (Invalid);
            begin
               Routing.Replace_Handler
                 (Invalid, User_Route, Handler_Two'Access);
            exception
               when Routing.Route_Error =>
                  Raised_Route := True;
            end;
            begin
               Routing.Replace_Middleware
                 (Invalid, Global_Layer, Global_Two'Access);
            exception
               when Routing.Route_Error =>
                  Raised_Layer := True;
            end;
         end;
         Expect ("runtime removed route id", Raised_Route'Image, "TRUE");
         Expect
           ("runtime removed middleware id", Raised_Layer'Image, "TRUE");
      end;

      declare
         Hot_Routes : Routing.Router
           (Capacity => 1, Slashes => Routing.Strict_Slashes);
         Hot_Route  : Routing.Route_ID;

         Publications : constant := 101;

         --  Cancel opens the gate without arming the workers, so a failure
         --  before Start can never strand them and deadlock the block exit.
         protected Start_Barrier is
            procedure Start;
            procedure Cancel;
            entry Wait (Proceed : out Boolean);
         private
            Open    : Boolean := False;
            Armed   : Boolean := False;
         end Start_Barrier;

         protected body Start_Barrier is
            procedure Start is
            begin
               Armed := True;
               Open := True;
            end Start;

            procedure Cancel is
            begin
               Open := True;
            end Cancel;

            entry Wait (Proceed : out Boolean) when Open is
            begin
               Proceed := Armed;
            end Wait;
         end Start_Barrier;

         protected Results is
            procedure Fail;
            procedure Note_Initial;
            procedure Note_Final;
            procedure Enter_Round_One;
            entry Wait_Round_One;
            procedure Publishing_Done;
            function Publishing_Complete return Boolean;
            procedure Finish;
            entry Wait_Until_Done;
            function Failure_Count return Natural;
            function Initial_Count return Natural;
            function Final_Count return Natural;
         private
            Failures_Seen : Natural := 0;
            Initial_Seen  : Natural := 0;
            Final_Seen    : Natural := 0;
            Round_One     : Natural := 0;
            Published     : Boolean := False;
            Finished      : Natural := 0;
         end Results;

         protected body Results is
            procedure Fail is
            begin
               Failures_Seen := Failures_Seen + 1;
            end Fail;

            procedure Note_Initial is
            begin
               Initial_Seen := Initial_Seen + 1;
            end Note_Initial;

            procedure Note_Final is
            begin
               Final_Seen := Final_Seen + 1;
            end Note_Final;

            procedure Enter_Round_One is
            begin
               Round_One := Round_One + 1;
            end Enter_Round_One;

            entry Wait_Round_One when Round_One = 4 is
            begin
               null;
            end Wait_Round_One;

            procedure Publishing_Done is
            begin
               Published := True;
            end Publishing_Done;

            function Publishing_Complete return Boolean is (Published);

            procedure Finish is
            begin
               Finished := Finished + 1;
            end Finish;

            entry Wait_Until_Done when Finished = 4 is
            begin
               null;
            end Wait_Until_Done;

            function Failure_Count return Natural is (Failures_Seen);
            function Initial_Count return Natural is (Initial_Seen);
            function Final_Count return Natural is (Final_Seen);
         end Results;

         task type Worker;

         task body Worker is
            Local_State : Context;
            Proceed     : Boolean;
            Counted     : Boolean := False;
            Rounds      : Natural := 0;

            --  Returns the response body marker, or NUL when the exchange was
            --  not a well-formed 200 carrying one of the two known bodies.
            function One_Request return Character is
               Wire : aliased Memory_Transport;
            begin
               Wire.Input := To_Unbounded_String
                 ("GET /hot HTTP/1.1" & CRLF
                  & "Host: localhost" & CRLF
                  & "Connection: close" & CRLF & CRLF);
               declare
                  Client : aliased HTTP_Server.Connection (Wire'Access);
               begin
                  Hot_Routes.Serve (Local_State, Client, Test_Peer);
               end;
               declare
                  Output : constant String := To_String (Wire.Output);
               begin
                  if Ada.Strings.Fixed.Index (Output, " 200 ") = 0 then
                     return Character'Val (0);
                  elsif Ada.Strings.Fixed.Index
                          (Output, CRLF & CRLF & "one") /= 0
                  then
                     return '1';
                  elsif Ada.Strings.Fixed.Index
                          (Output, CRLF & CRLF & "two") /= 0
                  then
                     return '2';
                  else
                     return Character'Val (0);
                  end if;
               end;
            end One_Request;

            Seen : Character;
         begin
            Start_Barrier.Wait (Proceed);
            if not Proceed then
               Results.Fail;
               Results.Enter_Round_One;
            else
               --  Round one runs before any publication, so it must observe
               --  the handler the direct registration installed.
               Seen := One_Request;
               if Seen /= '1' then
                  Results.Fail;
               else
                  Results.Note_Initial;
               end if;
               Counted := True;
               Results.Enter_Round_One;

               --  Serve across the whole publication sequence. Every
               --  response must be one complete generation, never a mixture.
               while not Results.Publishing_Complete
                 and then Rounds < 100_000
               loop
                  Seen := One_Request;
                  if Seen = Character'Val (0) then
                     Results.Fail;
                  end if;
                  Rounds := Rounds + 1;
               end loop;

               --  Publication has stopped, so the generation is fixed and
               --  this request must observe the last handler published.
               Seen := One_Request;
               if Seen /= '2' then
                  Results.Fail;
               else
                  Results.Note_Final;
               end if;
            end if;
            Results.Finish;
         exception
            when others =>
               Results.Fail;
               if not Counted then
                  Results.Enter_Round_One;
               end if;
               Results.Finish;
         end Worker;

         Workers : array (1 .. 4) of Worker;
         pragma Unreferenced (Workers);
      begin
         begin
            Hot_Routes.Get
              ("/hot", Handler_One'Access, Hot_Route, Name => "hot");
         exception
            when others =>
               Start_Barrier.Cancel;
               raise;
         end;
         Start_Barrier.Start;

         select
            Results.Wait_Round_One;
         or
            delay 30.0;
            Expect ("runtime concurrent round one reached", "FALSE", "TRUE");
         end select;

         --  An odd count leaves Handler_Two published, so the closing request
         --  of every worker has a single correct answer.
         for Generation in 1 .. Publications loop
            declare
               Change : Routing.Update;
            begin
               Hot_Routes.Begin_Update (Change);
               Routing.Replace_Handler
                 (Change, Hot_Route,
                  (if Generation mod 2 = 0
                   then Handler_One'Access
                   else Handler_Two'Access));
               Hot_Routes.Commit (Change);
            end;
         end loop;
         Results.Publishing_Done;

         select
            Results.Wait_Until_Done;
         or
            delay 30.0;
            Expect ("runtime concurrent workers completed", "FALSE", "TRUE");
         end select;

         Expect
           ("runtime concurrent generation consistency",
            Results.Failure_Count'Image, " 0");
         Expect
           ("runtime concurrent pre-publication generation",
            Results.Initial_Count'Image, " 4");
         Expect
           ("runtime concurrent post-publication generation",
            Results.Final_Count'Image, " 4");
      end;
   end Check_Runtime_Reconfiguration;

   --  Direct registration writes the published generation in place, so the
   --  first dispatch seals the router. Every direct registration and setter
   --  must then refuse rather than tear the generation a request is reading,
   --  while updates keep working.
   procedure Check_Sealed_Registration is
      package Applications renames Flyology.HTTP.Server.Applications;

      type Context is null record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      procedure Handler_One
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         X.Text (200, "one");
      end Handler_One;

      procedure Handler_Two
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         X.Text (200, "two");
      end Handler_Two;

      procedure Layer
        (State : in out Context;
         X     : in out Applications.Exchange;
         Next  : in out Routing.Components.Next_Handler) is
      begin
         X.Add_Header ("X-Layer", "on");
         Next.Call (State, X);
      end Layer;

      Routes : Routing.Router
        (Capacity => 4, Slashes => Routing.Strict_Slashes);
      Fresh  : Routing.Router
        (Capacity => 4, Slashes => Routing.Strict_Slashes);
      State  : Context;

      function Response return String is
         Wire : aliased Memory_Transport;
      begin
         Wire.Input := To_Unbounded_String
           ("GET /users/42 HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Routes.Serve (State, Client, Test_Peer);
         end;
         return To_String (Wire.Output);
      end Response;

      Served        : Routing.Route_ID;
      Ignored_Route : Routing.Route_ID;
      Ignored_Layer : Routing.Middleware_ID;
      Raised        : Boolean;
   begin
      Routes.Get
        ("/users/{id}", Handler_One'Access, Served, Name => "users.show");
      Expect_In ("sealed initial handler", Response, CRLF & CRLF & "one");

      Raised := False;
      begin
         Routes.Get
           ("/late", Handler_One'Access, Ignored_Route, Name => "late");
      exception
         when Routing.Route_Error =>
            Raised := True;
      end;
      Expect ("sealed route registration refused", Raised'Image, "TRUE");

      Raised := False;
      begin
         Routes.Add_Middleware (Layer'Access, Ignored_Layer, Name => "late");
      exception
         when Routing.Route_Error =>
            Raised := True;
      end;
      Expect ("sealed global middleware refused", Raised'Image, "TRUE");

      Raised := False;
      begin
         Routes.Add_Route_Middleware (Served, Layer'Access, Ignored_Layer);
      exception
         when Routing.Route_Error =>
            Raised := True;
      end;
      Expect ("sealed route middleware refused", Raised'Image, "TRUE");

      Raised := False;
      begin
         Routes.Add_Route_Middleware
           ("users.show", Layer'Access, Ignored_Layer);
      exception
         when Routing.Route_Error =>
            Raised := True;
      end;
      Expect ("sealed named route middleware refused", Raised'Image, "TRUE");

      Raised := False;
      begin
         Routes.Set_Authentication_Challenge ("Basic realm=late");
      exception
         when Routing.Route_Error =>
            Raised := True;
      end;
      Expect ("sealed challenge refused", Raised'Image, "TRUE");

      Raised := False;
      begin
         Routes.Set_Automatic_Admission (Concurrency => 4);
      exception
         when Routing.Route_Error =>
            Raised := True;
      end;
      Expect ("sealed admission refused", Raised'Image, "TRUE");

      Raised := False;
      begin
         Fresh.Mount ("/api", Routes);
      exception
         when Routing.Route_Error =>
            Raised := True;
      end;
      Expect ("sealed mount source refused", Raised'Image, "TRUE");

      --  Nothing was admitted, and the served generation is intact.
      Expect ("sealed route set unchanged", Routes.Route_Count'Image, " 1");
      Expect
        ("sealed global middleware unchanged",
         Routes.Global_Middleware_Count'Image, " 0");
      Expect_In ("sealed handler unchanged", Response, CRLF & CRLF & "one");

      --  An unsealed router still accepts direct registration.
      Fresh.Get
        ("/fresh", Handler_One'Access, Ignored_Route, Name => "fresh");
      Expect ("unsealed router still registers", Fresh.Route_Count'Image, " 1");

      --  Updates remain the supported path on a serving router.
      declare
         Change : Routing.Update;
      begin
         Routes.Begin_Update (Change);
         Routing.Replace_Handler (Change, Served, Handler_Two'Access);
         Routing.Add_Middleware (Change, Layer'Access, Ignored_Layer);
         Routes.Commit (Change);
      end;
      declare
         Output : constant String := Response;
      begin
         Expect_In ("sealed update handler", Output, CRLF & CRLF & "two");
         Expect_In ("sealed update middleware", Output, "X-Layer: on");
      end;
   end Check_Sealed_Registration;

   --  Mounting copies a middleware registration into the mounted routes. The
   --  copy keeps the source registration identity, so one candidate operation
   --  on that identity reaches every chain carrying it. A mounted router is
   --  also closed to updates, not only to direct registration.
   procedure Check_Mounted_Middleware_Identity is
      package Applications renames Flyology.HTTP.Server.Applications;

      type Context is null record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      use type Routing.Middleware_ID;

      procedure Endpoint
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         X.Text (200, "thing");
      end Endpoint;

      procedure Layer_One
        (State : in out Context;
         X     : in out Applications.Exchange;
         Next  : in out Routing.Components.Next_Handler) is
      begin
         X.Add_Header ("X-Mounted", "one");
         Next.Call (State, X);
      end Layer_One;

      procedure Layer_Two
        (State : in out Context;
         X     : in out Applications.Exchange;
         Next  : in out Routing.Components.Next_Handler) is
      begin
         X.Add_Header ("X-Mounted", "two");
         Next.Call (State, X);
      end Layer_Two;

      Parent : Routing.Router
        (Capacity => 4, Slashes => Routing.Strict_Slashes);
      Sub    : Routing.Router
        (Capacity => 4, Slashes => Routing.Strict_Slashes);
      State  : Context;

      function Response return String is
         Wire : aliased Memory_Transport;
      begin
         Wire.Input := To_Unbounded_String
           ("GET /api/thing HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Parent.Serve (State, Client, Test_Peer);
         end;
         return To_String (Wire.Output);
      end Response;

      Sub_Route : Routing.Route_ID;
      Sub_Layer : Routing.Middleware_ID;
      Raised    : Boolean := False;
   begin
      Sub.Get ("/thing", Endpoint'Access, Sub_Route, Name => "thing");
      Sub.Add_Middleware (Layer_One'Access, Sub_Layer, Name => "mounted");
      Parent.Mount ("/api", Sub, Name_Prefix => "api.");

      Expect
        ("mounted middleware keeps its identity",
         Boolean'Image
           (Parent.Describe_Route_Middleware (1, 1).ID = Sub_Layer), "TRUE");
      Expect_In ("mounted middleware runs", Response, "X-Mounted: one");

      declare
         Change : Routing.Update;
      begin
         Parent.Begin_Update (Change);
         Routing.Replace_Middleware (Change, Sub_Layer, Layer_Two'Access);
         Parent.Commit (Change);
      end;
      Expect_In ("mounted middleware replaced", Response, "X-Mounted: two");

      declare
         Change : Routing.Update;
      begin
         Parent.Begin_Update (Change);
         Routing.Remove_Middleware (Change, Sub_Layer);
         Parent.Commit (Change);
      end;
      declare
         Output : constant String := Response;
      begin
         Expect
           ("mounted middleware removed",
            Boolean'Image
              (Ada.Strings.Fixed.Index (Output, "X-Mounted") = 0), "TRUE");
         Expect_In ("mounted route still served", Output, " 200 ");
      end;

      begin
         declare
            Change : Routing.Update;
         begin
            Sub.Begin_Update (Change);
         end;
      exception
         when Routing.Route_Error =>
            Raised := True;
      end;
      Expect ("mounted source update refused", Raised'Image, "TRUE");
   end Check_Mounted_Middleware_Identity;

   --  A candidate whose base was replaced can never be published, so Commit
   --  releases it and the update object stays usable. A candidate rejected by
   --  validation stays active so it can be corrected, and Abandon drops it.
   procedure Check_Update_Lifecycle is
      package Applications renames Flyology.HTTP.Server.Applications;

      type Context is null record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      procedure Endpoint
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         X.Text (200, "thing");
      end Endpoint;

      Routes : Routing.Router
        (Capacity => 4, Slashes => Routing.Strict_Slashes);
      Served : Routing.Route_ID;
      Raised : Boolean;
   begin
      Routes.Get ("/thing", Endpoint'Access, Served, Name => "thing");

      declare
         Retry : Routing.Update;
         First : Routing.Update;
      begin
         Routes.Begin_Update (Retry);
         Routes.Begin_Update (First);
         Routing.Set_Authentication_Challenge (First, "Basic realm=first");
         Routes.Commit (First);

         Raised := False;
         begin
            Routing.Set_Authentication_Challenge (Retry, "Bearer");
            Routes.Commit (Retry);
         exception
            when Routing.Stale_Update =>
               Raised := True;
         end;
         Expect ("stale commit rejected", Raised'Image, "TRUE");

         --  A stale commit released the candidate, so this reuse of the same
         --  hoisted object must not raise Program_Error.
         Routes.Begin_Update (Retry);
         Routing.Set_Authentication_Challenge (Retry, "Bearer realm=second");
         Routes.Commit (Retry);
      end;
      Expect
        ("stale retry republished",
         Routes.Authentication_Challenge, "Bearer realm=second");

      declare
         Change : Routing.Update;
      begin
         Routes.Begin_Update (Change);
         Routing.Set_Authentication_Challenge (Change, "Basic realm=dropped");
         Routing.Abandon (Change);
         Routes.Begin_Update (Change);
         Routing.Set_Authentication_Challenge (Change, "Basic realm=kept");
         Routes.Commit (Change);
      end;
      Expect
        ("abandoned candidate discarded",
         Routes.Authentication_Challenge, "Basic realm=kept");

      declare
         Change : Routing.Update;
         Extra  : Routing.Route_ID;
      begin
         Routes.Begin_Update (Change);
         Routing.Add
           (Change, "GET", "/other", Endpoint'Access, Extra, Name => "thing");
         Raised := False;
         begin
            Routes.Commit (Change);
         exception
            when Routing.Route_Error =>
               Raised := True;
         end;
         Expect ("rejected candidate reported", Raised'Image, "TRUE");
         Expect
           ("rejected candidate left generation",
            Routes.Route_Count'Image, " 1");

         --  Validation failure keeps the candidate, so correcting it and
         --  committing again must succeed without rebuilding.
         Routing.Rename (Change, Extra, "other");
         Routes.Commit (Change);
      end;
      Expect ("corrected candidate published", Routes.Route_Count'Image, " 2");
   end Check_Update_Lifecycle;

   --  Candidate Add skips the duplicate-name and ambiguity scans that direct
   --  registration performs and defers them to Commit, so those rejections
   --  are the only thing between a candidate and an unroutable generation.
   procedure Check_Update_Validation is
      package Applications renames Flyology.HTTP.Server.Applications;

      type Context is null record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      use type Routing.Middleware_Stage;

      procedure Endpoint
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         X.Text (200, "thing");
      end Endpoint;

      procedure Layer
        (State : in out Context;
         X     : in out Applications.Exchange;
         Next  : in out Routing.Components.Next_Handler) is
      begin
         X.Add_Header ("X-Layer", "on");
         Next.Call (State, X);
      end Layer;

      Routes : Routing.Router
        (Capacity => 4, Slashes => Routing.Strict_Slashes);
      Served   : Routing.Route_ID;
      Health   : Routing.Route_ID;
      Layer_ID : Routing.Middleware_ID;
      Found    : Boolean;
      Raised   : Boolean;
   begin
      Routes.Get
        ("/users/{id}", Endpoint'Access, Served, Name => "users.show");

      --  Same method, overlapping pattern, equal specificity.
      declare
         Change : Routing.Update;
         Extra  : Routing.Route_ID;
      begin
         Routes.Begin_Update (Change);
         Routing.Add
           (Change, "GET", "/users/{other}", Endpoint'Access, Extra,
            Name => "users.other");
         Raised := False;
         begin
            Routes.Commit (Change);
         exception
            when Routing.Route_Error =>
               Raised := True;
         end;
         Expect ("ambiguous candidate rejected", Raised'Image, "TRUE");
      end;
      Expect
        ("ambiguous rejection left generation",
         Routes.Route_Count'Image, " 1");

      declare
         Change : Routing.Update;
      begin
         Routes.Begin_Update (Change);
         Routing.Add
           (Change, "GET", "/health", Endpoint'Access, Health,
            Name => "health");
         Routes.Commit (Change);
      end;
      Expect ("second route published", Routes.Route_Count'Image, " 2");

      --  Set_Match is the one operation that can newly create an ambiguity
      --  against a route the candidate never touched.
      declare
         Change : Routing.Update;
      begin
         Routes.Begin_Update (Change);
         Routing.Set_Match (Change, Health, "GET", "/users/{other}");
         Raised := False;
         begin
            Routes.Commit (Change);
         exception
            when Routing.Route_Error =>
               Raised := True;
         end;
         Expect ("Set_Match ambiguity rejected", Raised'Image, "TRUE");
      end;

      declare
         Change : Routing.Update;
      begin
         Routes.Begin_Update (Change);
         Routing.Rename (Change, Health, "users.show");
         Raised := False;
         begin
            Routes.Commit (Change);
         exception
            when Routing.Route_Error =>
               Raised := True;
         end;
         Expect ("rename collision rejected", Raised'Image, "TRUE");
      end;
      Expect
        ("rejected renames left generation",
         To_String (Routes.Describe_Route (2).Name), "health");

      --  The same operations succeed when the result is a valid whole.
      declare
         Change : Routing.Update;
      begin
         Routes.Begin_Update (Change);
         Routing.Set_Match (Change, Health, "POST", "/healthz");
         Routing.Rename (Change, Health, "health.check");
         Routing.Add_Middleware
           (Change, Layer'Access, Layer_ID, Name => "layer");
         Routing.Set_Automatic_Admission
           (Change, Concurrency => 3, Rate_Per_Second => 7);
         Routes.Commit (Change);
      end;
      Expect
        ("Set_Match method applied",
         To_String (Routes.Describe_Route (2).Method), "POST");
      Expect
        ("Set_Match pattern applied",
         To_String (Routes.Describe_Route (2).Pattern), "/healthz");
      Expect
        ("Rename applied",
         To_String (Routes.Describe_Route (2).Name), "health.check");
      Expect
        ("candidate admission applied",
         Routes.Automatic_Concurrency'Image, " 3");
      Expect
        ("candidate rate applied",
         Routes.Automatic_Rate_Per_Second'Image, " 7");

      declare
         Change : Routing.Update;
      begin
         Routes.Begin_Update (Change);
         Routing.Set_Middleware_Stage
           (Change, Layer_ID, Routing.Application);
         Routes.Commit (Change);
      end;
      Expect
        ("Set_Middleware_Stage applied",
         Routing.Middleware_Stage'Image
           (Routes.Describe_Global_Middleware (1).Stage), "APPLICATION");

      Routes.Find_Route ("health.check", Health, Found);
      Expect ("renamed route resolves", Found'Image, "TRUE");
   end Check_Update_Validation;

   --  Each Router introspection call reads the generation published when it
   --  runs, so a count from one call and an index used in the next can
   --  straddle a commit. A snapshot pins one generation for the traversal.
   procedure Check_Introspection_Snapshot is
      package Applications renames Flyology.HTTP.Server.Applications;

      type Context is null record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      procedure Endpoint
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         X.Text (200, "thing");
      end Endpoint;

      procedure Layer
        (State : in out Context;
         X     : in out Applications.Exchange;
         Next  : in out Routing.Components.Next_Handler) is
      begin
         X.Add_Header ("X-Layer", "on");
         Next.Call (State, X);
      end Layer;

      Routes : Routing.Router
        (Capacity => 4, Slashes => Routing.Strict_Slashes);
      First  : Routing.Route_ID;
      Second : Routing.Route_ID;
      Third  : Routing.Route_ID;
      Layer_ID : Routing.Middleware_ID;
      View   : Routing.Snapshot;
      Total  : Natural;
      Raised : Boolean;
   begin
      Routes.Get ("/a", Endpoint'Access, First, Name => "a");
      Routes.Get ("/b", Endpoint'Access, Second, Name => "b");
      Routes.Get ("/c", Endpoint'Access, Third, Name => "c");
      Routes.Add_Middleware (Layer'Access, Layer_ID, Name => "layer");
      Routes.Add_Route_Middleware (Second, Layer'Access, Layer_ID);

      Routes.Take_Snapshot (View);
      Total := Routing.Route_Count (View);
      Expect ("snapshot captured count", Total'Image, " 3");

      --  Shrink the published generation underneath the traversal.
      declare
         Change : Routing.Update;
      begin
         Routes.Begin_Update (Change);
         Routing.Remove (Change, Third);
         Routing.Remove (Change, Second);
         Routes.Commit (Change);
      end;
      Expect ("published generation shrank", Routes.Route_Count'Image, " 1");

      declare
         Names : Unbounded_String;
      begin
         for Index in 1 .. Total loop
            Append (Names, Routing.Describe_Route (View, Index).Name);
            Append (Names, ",");
         end loop;
         Expect ("snapshot traversal complete", To_String (Names), "a,b,c,");
      end;

      Expect
        ("snapshot keeps global middleware",
         Routing.Global_Middleware_Count (View)'Image, " 1");
      Expect
        ("snapshot keeps route middleware",
         Routing.Route_Middleware_Count (View, 2)'Image, " 1");
      Expect
        ("snapshot describes route middleware",
         To_String (Routing.Describe_Route_Middleware (View, 2, 1).Name), "");

      declare
         Resolved : Routing.Route_ID;
         Found    : Boolean;
      begin
         Routing.Find_Route (View, "b", Resolved, Found);
         Expect ("snapshot resolves captured name", Found'Image, "TRUE");
         Routes.Find_Route ("b", Resolved, Found);
         Expect ("published no longer resolves name", Found'Image, "FALSE");
      end;

      --  The per-call form is exactly what a snapshot exists to avoid.
      Raised := False;
      begin
         declare
            Ignored : constant Routing.Route_Description :=
              Routes.Describe_Route (Total);
         begin
            Expect ("unreachable", To_String (Ignored.Name), "");
         end;
      exception
         when Constraint_Error =>
            Raised := True;
      end;
      Expect ("per-call traversal straddles a commit", Raised'Image, "TRUE");

      Raised := False;
      begin
         declare
            Empty   : Routing.Snapshot;
            Ignored : constant Natural := Routing.Route_Count (Empty);
         begin
            Expect ("unreachable", Ignored'Image, "");
         end;
      exception
         when Program_Error =>
            Raised := True;
      end;
      Expect ("empty snapshot refused", Raised'Image, "TRUE");
   end Check_Introspection_Snapshot;

   --  Commit retains the superseded generation so an in-flight dispatch never
   --  reads freed storage. That retention is unbounded over a process
   --  lifetime, so it must be observable and releasable.
   procedure Check_Generation_Retention is
      package Applications renames Flyology.HTTP.Server.Applications;

      type Context is null record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      procedure Endpoint_One
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         X.Text (200, "one");
      end Endpoint_One;

      procedure Endpoint_Two
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         X.Text (200, "two");
      end Endpoint_Two;

      Routes : Routing.Router
        (Capacity => 2, Slashes => Routing.Strict_Slashes);
      State  : Context;
      Served : Routing.Route_ID;

      function Response return String is
         Wire : aliased Memory_Transport;
      begin
         Wire.Input := To_Unbounded_String
           ("GET /thing HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Connection: close" & CRLF & CRLF);
         declare
            Client : aliased HTTP_Server.Connection (Wire'Access);
         begin
            Routes.Serve (State, Client, Test_Peer);
         end;
         return To_String (Wire.Output);
      end Response;
   begin
      Routes.Get ("/thing", Endpoint_One'Access, Served, Name => "thing");
      Expect
        ("fresh router retains one generation",
         Routes.Retained_Generations'Image, " 1");

      for Generation in 1 .. 5 loop
         pragma Unreferenced (Generation);
         declare
            Change : Routing.Update;
         begin
            Routes.Begin_Update (Change);
            Routing.Replace_Handler (Change, Served, Endpoint_One'Access);
            Routes.Commit (Change);
         end;
      end loop;
      Expect
        ("each commit retains a generation",
         Routes.Retained_Generations'Image, " 6");

      --  A rejected commit must not retain anything.
      declare
         Change : Routing.Update;
         Extra  : Routing.Route_ID;
         Raised : Boolean := False;
      begin
         Routes.Begin_Update (Change);
         Routing.Add
           (Change, "GET", "/other", Endpoint_One'Access, Extra,
            Name => "thing");
         begin
            Routes.Commit (Change);
         exception
            when Routing.Route_Error =>
               Raised := True;
         end;
         Expect ("rejected commit reported", Raised'Image, "TRUE");
      end;
      Expect
        ("rejected commit retains nothing",
         Routes.Retained_Generations'Image, " 6");

      Routes.Reclaim;
      Expect
        ("reclaim releases superseded generations",
         Routes.Retained_Generations'Image, " 1");

      Expect_In ("reclaimed router serves", Response, CRLF & CRLF & "one");

      declare
         Change : Routing.Update;
      begin
         Routes.Begin_Update (Change);
         Routing.Replace_Handler (Change, Served, Endpoint_Two'Access);
         Routes.Commit (Change);
      end;
      Expect_In
        ("reclaimed router commits", Response, CRLF & CRLF & "two");
      Expect
        ("commit after reclaim retains one more",
         Routes.Retained_Generations'Image, " 2");

      Routes.Reclaim;
      Routes.Reclaim;
      Expect
        ("repeated reclaim is idempotent",
         Routes.Retained_Generations'Image, " 1");
      Expect_In
        ("router serves after repeated reclaim",
         Response, CRLF & CRLF & "two");
   end Check_Generation_Retention;

   --  Direct registration decides ambiguity as each route is added, while a
   --  candidate defers the same decision to Commit. Both now read the
   --  segments and score compiled at registration instead of splitting the
   --  patterns again, so they must still agree on every pair.
   procedure Check_Ambiguity_Agreement is
      package Applications renames Flyology.HTTP.Server.Applications;

      type Context is null record;

      package Routing is new Flyology.HTTP.Server.Routing (Context);

      procedure Endpoint
        (State : in out Context;
         X     : in out Applications.Exchange)
      is
         pragma Unreferenced (State);
      begin
         X.Text (200, "thing");
      end Endpoint;

      function Direct_Rejects
        (Left_Method, Left, Right_Method, Right : String) return Boolean
      is
         Probe : Routing.Router
           (Capacity => 4, Slashes => Routing.Strict_Slashes);
         First, Second : Routing.Route_ID;
      begin
         Probe.Add
           (Left_Method, Left, Endpoint'Access, First, Name => "left");
         Probe.Add
           (Right_Method, Right, Endpoint'Access, Second, Name => "right");
         return False;
      exception
         when Routing.Route_Error =>
            return True;
      end Direct_Rejects;

      function Candidate_Rejects
        (Left_Method, Left, Right_Method, Right : String) return Boolean
      is
         Probe : Routing.Router
           (Capacity => 4, Slashes => Routing.Strict_Slashes);
         Change        : Routing.Update;
         First, Second : Routing.Route_ID;
      begin
         Probe.Begin_Update (Change);
         Routing.Add
           (Change, Left_Method, Left, Endpoint'Access, First,
            Name => "left");
         Routing.Add
           (Change, Right_Method, Right, Endpoint'Access, Second,
            Name => "right");
         Probe.Commit (Change);
         return False;
      exception
         when Routing.Route_Error =>
            return True;
      end Candidate_Rejects;

      procedure Agree
        (Left         : String;
         Right        : String;
         Ambiguous    : Boolean;
         Left_Method  : String := "GET";
         Right_Method : String := "GET")
      is
         Label : constant String :=
           Left_Method & " " & Left & " vs " & Right_Method & " " & Right;
      begin
         Expect
           ("direct ambiguity " & Label,
            Boolean'Image
              (Direct_Rejects (Left_Method, Left, Right_Method, Right)),
            Boolean'Image (Ambiguous));
         Expect
           ("candidate ambiguity " & Label,
            Boolean'Image
              (Candidate_Rejects (Left_Method, Left, Right_Method, Right)),
            Boolean'Image (Ambiguous));
      end Agree;
   begin
      Agree ("/users/{id}", "/users/{other}", True);
      Agree ("/a/b", "/a/b", True);
      Agree ("/x/{*rest}", "/x/{*other}", True);
      Agree ("/users/{id}", "/users/me", False);
      Agree ("/a/b", "/a/c", False);
      Agree ("/files/{*rest}", "/files/{name}", False);
      Agree ("/a", "/a/b", False);
      Agree
        ("/users/{id}", "/users/{other}", False, Right_Method => "POST");
   end Check_Ambiguity_Agreement;

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
   Check_Runtime_Reconfiguration;
   Check_Sealed_Registration;
   Check_Mounted_Middleware_Identity;
   Check_Update_Lifecycle;
   Check_Update_Validation;
   Check_Introspection_Snapshot;
   Check_Generation_Retention;
   Check_Ambiguity_Agreement;
   if Failures /= 0 then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "HTTP routing audit regressions:" & Failures'Image);
      raise Program_Error with "HTTP routing audit regressions";
   end if;
   Ada.Text_IO.Put_Line ("HTTP routing audit passed");
end HTTP_Routing_Audit;
