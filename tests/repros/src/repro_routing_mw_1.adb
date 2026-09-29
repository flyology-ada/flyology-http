--  ROUTING-MW-1. routing.ads:806-811 promises that the router's automatic
--  responses, "404, 405, CORS preflight, OPTIONS, the trailing slash
--  redirect, and the malformed-path 400 ... run the whole global middleware
--  chain" and are metered by Set_Automatic_Admission.  A decoded path with
--  more than Max_Segments (64) segments raises Route_Error from Split_Path
--  at routing.adb:1895, which is outside Decode_For_Dispatch, so the outer
--  handler at routing.adb:2086-2090 writes the 400 directly.
--
--  This program asserts the promised behaviour for both malformed-path
--  shapes: the security-headers middleware runs and the automatic rate
--  limit meters the surface.
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Real_Time;
with Flyology.Cancellation;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Middleware_Rate_Limits;
with Flyology.HTTP.Server.Middleware_Security_Headers;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Sockets;
with Repro_Support;

procedure Repro_Routing_MW_1 is
   package HTTP_Server renames Flyology.HTTP.Server;
   package Applications renames Flyology.HTTP.Server.Applications;
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

   Clock_Value : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   function Test_Clock return Ada.Real_Time.Time is (Clock_Value);
   function Client_Key (X : Applications.Exchange) return String is
     (X.Request_Header ("X-Client"));

   package Rates is new Flyology.HTTP.Server.Middleware_Rate_Limits
     (Context, Routing.Components, Client_Key,
      Capacity => 32, Clock => Test_Clock);

   package Guards is new Flyology.HTTP.Server.Middleware_Security_Headers
     (Context, Routing.Components);

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

   --  Send one request on a fresh connection; return the whole response.
   function Answer (Target : String) return String is
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
      return To_String (Wire.Output);
   end Answer;

   function Status (Output : String) return String is
     (if Output'Length >= 12
      then Output (Output'First + 9 .. Output'First + 11) else "---");

   function Has (Output, Fragment : String) return Boolean is
     (Ada.Strings.Fixed.Index (Output, Fragment) /= 0);

   --  65 single-character segments: one past Max_Segments = 64.
   function Long_Target return String is
      Result : Unbounded_String;
   begin
      for Index in 1 .. 65 loop
         Append (Result, "/a");
      end loop;
      return To_String (Result);
   end Long_Target;

   Over : constant String := Long_Target;
begin
   Routes.Get ("/kept", Plain'Access, Name => "kept");
   Routes.Add_Middleware (Guards.Call'Access);
   Routes.Add_Middleware (Rates.Call'Access);
   Routes.Set_Automatic_Admission (Rate_Per_Second => 1);

   Note ("target length" & Natural'Image (Over'Length)
         & " bytes, 65 segments");

   --  Control: the Decode_Path failure 400, which routing.adb routes through
   --  Run_Automatic.  This is the behaviour the spec promises for BOTH.
   declare
      First  : constant String := Answer ("/%2e%2e/x");
      Second : constant String := Answer ("/%2e%2e/x");
   begin
      Note ("control first status " & Status (First));
      Check (Status (First) = "400", "control: decode-failure answers 400");
      Check (Has (First, "X-Content-Type-Options: nosniff"),
             "control: decode-failure 400 runs security-headers middleware");
      Note ("control second status " & Status (Second));
      Check (Status (Second) = "429",
             "control: second decode-failure 400 is rate limited");
   end;

   --  The finding: the same promise for a path with more than 64 segments.
   declare
      First  : constant String := Answer (Over);
      Second : constant String := Answer (Over);
   begin
      Note ("over-segment first status " & Status (First));
      Check (Status (First) = "400",
             "65-segment target answers 400");
      Check (Has (First, "X-Content-Type-Options: nosniff"),
             "65-segment 400 runs the global security-headers middleware");
      Note ("over-segment second status " & Status (Second));
      Check (Status (Second) = "429",
             "second 65-segment 400 is metered by automatic admission");
   end;

   Finish;
end Repro_Routing_MW_1;
