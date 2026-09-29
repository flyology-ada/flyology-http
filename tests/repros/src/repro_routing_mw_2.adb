--  ROUTING-MW-2. Applications.Respond validates before it writes a byte
--  (applications.adb:436-446 and, through it, server.adb:2732-2739), but its
--  blanket "when others => Item.Response_Value := Failed" at
--  applications.adb:465-468 relabels the exchange Failed for those pre-write
--  raises too.  applications.ads:51 documents Not_Started as "No response
--  bytes have been written", and middleware_errors.ads:8-9 promises
--  "Unexpected exceptions become a generic closing 500 before response
--  start".
--
--  This program asserts the promised behaviour.
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Middleware_Errors;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Sockets;
with Repro_Support;

procedure Repro_Routing_MW_2 is
   package HTTP_Server renames Flyology.HTTP.Server;
   package Applications renames Flyology.HTTP.Server.Applications;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Strings.Unbounded;
   use Repro_Support;
   use type Applications.Response_State;

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

   type Context is record
      After_Bad_Status : Applications.Response_State :=
        Applications.Upgraded;
      After_Second     : Applications.Response_State :=
        Applications.Upgraded;
   end record;

   package Routing is new Flyology.HTTP.Server.Routing (Context);

   package Errors is new Flyology.HTTP.Server.Middleware_Errors
     (Context, Routing.Components);

   --  Lets the pre-write Constraint_Error escape to the errors middleware.
   procedure Raise_Status
     (State : in out Context;
      X     : in out Applications.Exchange)
   is
      pragma Unreferenced (State);
   begin
      X.Respond (99, "text/plain; charset=utf-8", "x");
   end Raise_Status;

   --  Catches the pre-write raise itself and reports the exchange state.
   procedure Observe_Status
     (State : in out Context;
      X     : in out Applications.Exchange)
   is
   begin
      begin
         X.Respond (99, "text/plain; charset=utf-8", "x");
      exception
         when others => null;
      end;
      State.After_Bad_Status := X.Response;
   end Observe_Status;

   --  One complete response, then a rejected second call.
   procedure Double_Respond
     (State : in out Context;
      X     : in out Applications.Exchange)
   is
   begin
      X.Text (200, "first");
      begin
         X.Text (200, "second");
      exception
         when others => null;
      end;
      State.After_Second := X.Response;
   end Double_Respond;

   procedure Plain
     (State : in out Context;
      X     : in out Applications.Exchange)
   is
      pragma Unreferenced (State);
   begin
      X.Text (200, "plain");
   end Plain;

   Guarded : Routing.Router
     (Capacity => 4, Slashes => Routing.Strict_Slashes);
   Bare    : Routing.Router
     (Capacity => 4, Slashes => Routing.Strict_Slashes);
   State   : Context;

   function Answer
     (Routes : in out Routing.Router;
      Wire_In : String) return String
   is
      Wire : aliased Memory_Transport;
   begin
      Wire.Input := To_Unbounded_String (Wire_In);
      declare
         Client : aliased HTTP_Server.Connection (Wire'Access);
      begin
         Routes.Serve (State, Client, Test_Peer);
      end;
      return To_String (Wire.Output);
   end Answer;

   function One (Target : String) return String is
     ("GET " & Target & " HTTP/1.1" & CRLF & "Host: localhost" & CRLF
      & "Connection: close" & CRLF & CRLF);

   function Keep (Target : String) return String is
     ("GET " & Target & " HTTP/1.1" & CRLF & "Host: localhost" & CRLF & CRLF);

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
begin
   Guarded.Get ("/raise", Raise_Status'Access, Name => "raise");
   Guarded.Get ("/plain", Plain'Access, Name => "guarded.plain");
   Guarded.Add_Middleware (Errors.Call'Access);

   Bare.Get ("/observe", Observe_Status'Access, Name => "observe");
   Bare.Get ("/double", Double_Respond'Access, Name => "double");
   Bare.Get ("/plain", Plain'Access, Name => "bare.plain");

   --  1. middleware_errors.ads promises a generic closing 500 when the
   --     exception arrives before response start.  Respond (99, ...) raises
   --     at server.adb:2732 with nothing written.
   declare
      Output : constant String := Answer (Guarded, One ("/raise"));
   begin
      Note ("errors-middleware output ["
            & (if Output'Length > 40
               then Output (Output'First .. Output'First + 39) & "..."
               else Output) & "]");
      Note ("bytes written" & Natural'Image (Output'Length));
      Check (Ada.Strings.Fixed.Index (Output, "500") /= 0,
             "errors middleware writes the promised 500 for a pre-write "
             & "Respond failure");
   end;

   --  2. applications.ads:51 defines Not_Started as "No response bytes have
   --     been written", which is the state after a pre-write raise.
   declare
      Output : constant String := Answer (Bare, One ("/observe"));
      pragma Unreferenced (Output);
   begin
      Note ("state after pre-write raise: "
            & Applications.Response_State'Image (State.After_Bad_Status));
      Check (State.After_Bad_Status = Applications.Not_Started,
             "exchange stays Not_Started when Respond raised before "
             & "writing");
   end;

   --  3. A complete response followed by a rejected second call must stay
   --     Completed, and the keep-alive connection must serve the next
   --     pipelined request.
   declare
      Output : constant String :=
        Answer (Bare, Keep ("/double") & One ("/plain"));
   begin
      Note ("state after rejected second Respond: "
            & Applications.Response_State'Image (State.After_Second));
      Check (State.After_Second = Applications.Completed,
             "a fully written response stays Completed when a second "
             & "Respond is rejected");
      Note ("responses on the pipelined connection"
            & Natural'Image (Occurrences (Output, "HTTP/1.1 200")));
      Check (Occurrences (Output, "HTTP/1.1 200") = 2,
             "the pipelined request after a rejected second Respond is "
             & "still served");
   end;

   Finish;
end Repro_Routing_MW_2;
