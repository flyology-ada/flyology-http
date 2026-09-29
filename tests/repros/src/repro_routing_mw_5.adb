--  ROUTING-MW-5. Middleware_CORS emits "Vary: Origin" only from Add_Origin
--  (middleware_cors.adb:24-26), which runs only when an Origin is present
--  AND allowed AND the method is allowed.  The early returns at :40-43,
--  :53-61 and :92-95 hand the request to the next component with no Vary,
--  so for a route whose CORS policy is a non-wildcard origin list the
--  representation's header set depends on Origin while the cacheable
--  response carries no Vary key.
--
--  WHATWG Fetch Standard, "CORS protocol and HTTP caches":
--    "If CORS protocol requirements are more complicated than setting
--     `Access-Control-Allow-Origin` to * or a static origin, `Vary` is to
--     be used."
--    "In particular, consider what happens if `Vary` is not used and a
--     server is configured to send `Access-Control-Allow-Origin` for a
--     certain resource only in response to a CORS request. When a user
--     agent receives a response to a non-CORS request for that resource
--     ... the response will lack `Access-Control-Allow-Origin` and the
--     user agent will cache that response. Then, if the user agent
--     subsequently encounters a CORS request for the resource, it will
--     use that cached response from the previous non-CORS request,
--     without `Access-Control-Allow-Origin`."
--
--  RFC 9110 Section 12.5.5 states the cache-key purpose of Vary: "To
--  inform cache recipients that they MUST NOT use this response to satisfy
--  a later request unless the later request has the same values for the
--  listed header fields as the original request (Section 4.1 of
--  [CACHING]).  In other words, Vary expands the cache key required to
--  match a new request to the stored cache entry."
--
--  This program asserts that every response whose CORS header set depends
--  on Origin carries Vary: Origin.  Cache behaviour itself is not
--  observable from a spike; only the emitted field is.
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.CORS;
with Flyology.HTTP.Server.Middleware_CORS;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Sockets;
with Repro_Support;

procedure Repro_Routing_MW_5 is
   package HTTP_Server renames Flyology.HTTP.Server;
   package Applications renames Flyology.HTTP.Server.Applications;
   package CORS renames Flyology.HTTP.Server.CORS;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Strings.Unbounded;
   use Repro_Support;

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

   type Context is null record;

   package Routing is new Flyology.HTTP.Server.Routing (Context);

   Listed : aliased constant CORS.Policy := CORS.Create
     (Allowed_Origins => "https://app.example https://ops.example",
      Allowed_Methods => "GET");

   function Resolve (Slot : Positive)
     return access constant CORS.Policy is
     (if Slot = 1 then Listed'Access else null);

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

   --  Origin_Field is the complete "Origin: ..." line, or empty for a
   --  non-CORS request such as a direct navigation.
   function Answer (Origin_Field : String) return String is
      Wire : aliased Memory_Transport;
   begin
      Wire.Input := To_Unbounded_String
        ("GET /data HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & Origin_Field
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

   declare
      Allowed : constant String :=
        Answer ("Origin: https://app.example" & CRLF);
      Denied  : constant String :=
        Answer ("Origin: https://evil.example" & CRLF);
      No_CORS : constant String := Answer ("");
   begin
      --  Control: the allowed path is already correct.
      Note ("allowed  ACAO=[" & Field_Value (Allowed,
              "Access-Control-Allow-Origin")
            & "] Vary=[" & Field_Value (Allowed, "Vary") & "]");
      Check (Field_Value (Allowed, "Access-Control-Allow-Origin")
               = "https://app.example",
             "control: an allowed origin is reflected");
      Check (Field_Value (Allowed, "Vary") = "Origin",
             "control: the allowed-origin response carries Vary: Origin");

      --  The finding: the two responses whose header set differs from the
      --  allowed one carry no Vary, so a cache stores them under a key that
      --  ignores Origin.
      Note ("denied   ACAO=[" & Field_Value (Denied,
              "Access-Control-Allow-Origin")
            & "] Vary=[" & Field_Value (Denied, "Vary") & "]");
      Check (Field_Value (Denied, "Access-Control-Allow-Origin") = "",
             "a disallowed origin is not reflected");
      Check (Field_Value (Denied, "Vary") = "Origin",
             "the disallowed-origin response carries Vary: Origin");

      Note ("no-Origin ACAO=[" & Field_Value (No_CORS,
              "Access-Control-Allow-Origin")
            & "] Vary=[" & Field_Value (No_CORS, "Vary") & "]");
      Check (Field_Value (No_CORS, "Access-Control-Allow-Origin") = "",
             "a non-CORS request gets no Access-Control-Allow-Origin");
      Check (Field_Value (No_CORS, "Vary") = "Origin",
             "the non-CORS response carries Vary: Origin, so a cache "
             & "cannot reuse it for a later CORS request");
   end;

   Finish;
end Repro_Routing_MW_5;
