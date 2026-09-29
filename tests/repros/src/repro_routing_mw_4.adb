--  ROUTING-MW-4. Metrics.In_Memory keys each series on
--  (Route, Method, Status_Class) and never evicts: metrics.adb:54-83 fills
--  Values (1 .. Capacity) and, once Value.Series = Capacity, every
--  first-seen series is counted in Dropped_Series and discarded for the
--  life of the sink.  Route is bounded to the registered table plus the
--  "flyology.*" literals, but Method is the request method as parsed, and
--  an unknown method to any existing path is answered 405 through the
--  router's automatic chain, which runs the metrics middleware with
--  Route_Name = "flyology.method_not_allowed".
--
--  This program asserts that a legitimate route/method/class combination
--  first seen after a flood of attacker-chosen method tokens is still
--  counted.
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Metrics;
with Flyology.HTTP.Server.Middleware_Metrics;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Sockets;
with Repro_Support;

procedure Repro_Routing_MW_4 is
   package HTTP_Server renames Flyology.HTTP.Server;
   package Applications renames Flyology.HTTP.Server.Applications;
   package Metrics renames Flyology.HTTP.Server.Metrics;
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

   Sink : aliased Metrics.In_Memory (Capacity => 4);

   package Meters is new Flyology.HTTP.Server.Middleware_Metrics
     (Context, Routing.Components, Output => Sink'Access);

   procedure Plain
     (State : in out Context;
      X     : in out Applications.Exchange)
   is
      pragma Unreferenced (State);
   begin
      X.Text (200, "plain");
   end Plain;

   Routes : Routing.Router
     (Capacity => 2, Slashes => Routing.Strict_Slashes);
   State  : Context;

   function Answer (Method, Target : String) return String is
      Wire : aliased Memory_Transport;
   begin
      Wire.Input := To_Unbounded_String
        (Method & " " & Target & " HTTP/1.1" & CRLF
         & "Host: localhost" & CRLF
         & "Connection: close" & CRLF & CRLF);
      declare
         Client : aliased HTTP_Server.Connection (Wire'Access);
      begin
         Routes.Serve (State, Client, Test_Peer);
      end;
      return To_String (Wire.Output);
   end Answer;

   function Status (Output : String) return String is
     (if Output'Length >= 12
      then Output (Output'First + 9 .. Output'First + 11) else "---");

   --  Distinct 5-byte method tokens, all valid HTTP tokens.
   function Flood_Method (Index : Natural) return String is
      Digits_Text : constant String := "0123456789";
   begin
      return "M" & Digits_Text (Digits_Text'First + (Index / 1_000) mod 10)
        & Digits_Text (Digits_Text'First + (Index / 100) mod 10)
        & Digits_Text (Digits_Text'First + (Index / 10) mod 10)
        & Digits_Text (Digits_Text'First + Index mod 10);
   end Flood_Method;
begin
   Routes.Get ("/x", Plain'Access, Name => "x");
   Routes.Add_Middleware (Meters.Call'Access);

   --  Confirm the capacity the sink was created with, and that no series
   --  exists yet.
   declare
      Before : constant Metrics.Snapshot := Metrics.Read (Sink);
   begin
      Note ("series before flood" & Natural'Image (Before.Series)
            & ", dropped" & Natural'Image (Before.Dropped_Series));
   end;

   --  Four attacker-chosen method tokens against an existing path.  Each is
   --  a 405 whose route name is the "flyology.method_not_allowed" literal,
   --  so only the method varies.
   for Index in 0 .. 3 loop
      declare
         Output : constant String := Answer (Flood_Method (Index), "/x");
      begin
         Note ("flood " & Flood_Method (Index) & " /x -> " & Status (Output));
         Check (Status (Output) = "405",
                "an unknown method to an existing path answers 405");
      end;
   end loop;

   declare
      After : constant Metrics.Snapshot := Metrics.Read (Sink);
   begin
      Note ("series after flood" & Natural'Image (After.Series)
            & ", dropped" & Natural'Image (After.Dropped_Series));
      Check (After.Series = 4,
             "the flood filled the series table (evidence the method is "
             & "the varying key)");
   end;

   --  The legitimate series arrives afterwards.
   declare
      Output : constant String := Answer ("GET", "/x");
      After  : constant Metrics.Snapshot := Metrics.Read (Sink);
   begin
      Note ("legitimate GET /x -> " & Status (Output));
      Check (Status (Output) = "200", "the real route still answers 200");
      Note ("series after the real request" & Natural'Image (After.Series)
            & ", dropped" & Natural'Image (After.Dropped_Series));
      Check (After.Dropped_Series = 0,
             "a legitimate route/method/class series first seen after a "
             & "method flood is not dropped");
   end;

   --  Ten more legitimate requests: every one is dropped, permanently.
   for Index in 1 .. 10 loop
      pragma Unreferenced (Index);
      declare
         Output : constant String := Answer ("GET", "/x");
         pragma Unreferenced (Output);
      begin
         null;
      end;
   end loop;

   declare
      Final : constant Metrics.Snapshot := Metrics.Read (Sink);
   begin
      Note ("final requests" & Natural'Image (Final.Requests)
            & ", series" & Natural'Image (Final.Series)
            & ", dropped" & Natural'Image (Final.Dropped_Series));
      Check (Final.Dropped_Series = 0,
             "the sink recovers: repeated legitimate traffic is counted "
             & "per series again");
   end;

   Finish;
end Repro_Routing_MW_4;
