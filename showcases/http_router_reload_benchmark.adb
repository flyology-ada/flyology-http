--  Measures routed dispatch throughput while the router republishes its
--  configuration underneath the traffic.
--
--  Every dispatch reads the router's published-generation word, and every
--  commit writes it. Those two words sit in the same router object, so a
--  reload can invalidate the line the dispatchers read. This benchmark
--  varies the reload rate against otherwise identical traffic, so the cost
--  of that interference can be measured instead of assumed.
--
--  The transport is in-memory and allocation-free, and each worker counts
--  into its own stack, so neither the harness nor the loader contributes
--  contention of its own.
with Ada.Command_Line;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Text_IO;
with Flyology.Cancellation;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Sockets;
with Showcase_Support;

procedure HTTP_Router_Reload_Benchmark is
   package HTTP_Server renames Flyology.HTTP.Server;
   package Applications renames Flyology.HTTP.Server.Applications;
   package Sockets renames Flyology.IO.Sockets;

   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;

   CRLF : constant String := Character'Val (13) & Character'Val (10);

   Request_Text : constant String :=
     "GET /users/42 HTTP/1.1" & CRLF
     & "Host: localhost" & CRLF
     & "Connection: close" & CRLF & CRLF;

   subtype Request_Bytes is
     Ada.Streams.Stream_Element_Array (1 .. Request_Text'Length);

   function Encoded_Request return Request_Bytes is
      Result : Request_Bytes;
   begin
      for Index in Request_Text'Range loop
         Result (Ada.Streams.Stream_Element_Offset (Index)) :=
           Ada.Streams.Stream_Element (Character'Pos (Request_Text (Index)));
      end loop;
      return Result;
   end Encoded_Request;

   Canned : constant Request_Bytes := Encoded_Request;

   Status_Marker : constant String := "HTTP/1.1 200";

   --  Replays one canned request and keeps only what the check needs, so a
   --  measured iteration allocates nothing.
   type Bench_Transport is limited new HTTP_Server.Transport with record
      Cursor : Ada.Streams.Stream_Element_Offset := Canned'First;
      Head   : String (Status_Marker'Range) := (others => ' ');
      Filled : Natural := 0;
   end record;

   overriding procedure Receive
     (Item    : in out Bench_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);

   overriding procedure Send_All
     (Item    : in out Bench_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);

   overriding procedure Receive
     (Item    : in out Bench_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
      Remaining : constant Ada.Streams.Stream_Element_Offset :=
        Canned'Last - Item.Cursor + 1;
      Count     : Ada.Streams.Stream_Element_Offset;
   begin
      Last := Data'First - 1;
      if Remaining <= 0 then
         return;
      end if;
      Count := Ada.Streams.Stream_Element_Offset'Min (Data'Length, Remaining);
      Data (Data'First .. Data'First + Count - 1) :=
        Canned (Item.Cursor .. Item.Cursor + Count - 1);
      Item.Cursor := Item.Cursor + Count;
      Last := Data'First + Count - 1;
   end Receive;

   overriding procedure Send_All
     (Item    : in out Bench_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
   begin
      for Value of Data loop
         exit when Item.Filled = Item.Head'Length;
         Item.Filled := Item.Filled + 1;
         Item.Head (Item.Head'First + Item.Filled - 1) :=
           Character'Val (Value);
      end loop;
   end Send_All;

   type Context is null record;

   package Routing is new Flyology.HTTP.Server.Routing (Context);

   procedure Handler_A
     (State : in out Context;
      X     : in out Applications.Exchange)
   is
      pragma Unreferenced (State);
   begin
      X.Text (200, "a");
   end Handler_A;

   procedure Handler_B
     (State : in out Context;
      X     : in out Applications.Exchange)
   is
      pragma Unreferenced (State);
   begin
      X.Text (200, "b");
   end Handler_B;

   Peer : constant Sockets.Endpoint :=
     Sockets.Network_Endpoint (Sockets.Loopback_IPv4, 12_345);

   --  Defaults chosen so one run finishes quickly enough to repeat as
   --  independent processes, which is the only way to rank two builds.
   Workers      : Positive := 4;
   Seconds      : Duration := 3.0;
   Reload_Rate  : Natural := 0;
   Route_Count  : Positive := 4;

   Routes  : Routing.Router
     (Capacity => 8, Slashes => Routing.Strict_Slashes);
   Hot     : Routing.Route_ID;

   Deadline : Ada.Real_Time.Time;

   protected Totals is
      procedure Add (Dispatches : Long_Long_Integer; Failures : Natural);
      procedure Note_Reloads (Count : Long_Long_Integer);
      function Dispatched return Long_Long_Integer;
      function Failed return Natural;
      function Reloaded return Long_Long_Integer;
   private
      Dispatch_Total : Long_Long_Integer := 0;
      Failure_Total  : Natural := 0;
      Reload_Total   : Long_Long_Integer := 0;
   end Totals;

   protected body Totals is
      procedure Add (Dispatches : Long_Long_Integer; Failures : Natural) is
      begin
         Dispatch_Total := Dispatch_Total + Dispatches;
         Failure_Total := Failure_Total + Failures;
      end Add;

      procedure Note_Reloads (Count : Long_Long_Integer) is
      begin
         Reload_Total := Count;
      end Note_Reloads;

      function Dispatched return Long_Long_Integer is (Dispatch_Total);
      function Failed return Natural is (Failure_Total);
      function Reloaded return Long_Long_Integer is (Reload_Total);
   end Totals;

   task type Worker;

   task body Worker is
      State      : Context;
      Dispatches : Long_Long_Integer := 0;
      Failures   : Natural := 0;
   begin
      loop
         declare
            Wire : aliased Bench_Transport;
         begin
            declare
               Client : aliased HTTP_Server.Connection (Wire'Access);
            begin
               Routes.Serve (State, Client, Peer);
            end;
            if Wire.Head /= Status_Marker then
               Failures := Failures + 1;
            end if;
         end;
         Dispatches := Dispatches + 1;
         --  Check the clock in batches: a per-iteration read would be a
         --  measurable share of a dispatch this cheap.
         exit when Dispatches mod 64 = 0
           and then Ada.Real_Time.Clock >= Deadline;
      end loop;
      --  One report per worker at the end, so the counters never share a
      --  line while the measurement is running.
      Totals.Add (Dispatches, Failures);
   exception
      when others =>
         Totals.Add (Dispatches, Failures + 1);
   end Worker;

   task type Loader;

   task body Loader is
      Period  : Ada.Real_Time.Time_Span;
      Next    : Ada.Real_Time.Time;
      Reloads : Long_Long_Integer := 0;
      Toggle  : Boolean := False;
   begin
      if Reload_Rate = 0 then
         Totals.Note_Reloads (0);
      else
         Period := Ada.Real_Time.Nanoseconds
           (Integer (1_000_000_000 / Long_Long_Integer (Reload_Rate)));
         Next := Ada.Real_Time.Clock;
         while Ada.Real_Time.Clock < Deadline loop
            declare
               Change : Routing.Update;
            begin
               Routes.Begin_Update (Change);
               Routing.Replace_Handler
                 (Change, Hot,
                  (if Toggle then Handler_A'Access else Handler_B'Access));
               Routes.Commit (Change);
            end;
            Toggle := not Toggle;
            Reloads := Reloads + 1;
            Next := Next + Period;
            delay until Next;
         end loop;
         Totals.Note_Reloads (Reloads);
      end if;
   exception
      when others =>
         Totals.Note_Reloads (Reloads);
   end Loader;

   function Argument_Value (Name : String; Default : String) return String is
   begin
      for Index in 1 .. Ada.Command_Line.Argument_Count - 1 loop
         if Ada.Command_Line.Argument (Index) = Name then
            return Ada.Command_Line.Argument (Index + 1);
         end if;
      end loop;
      return Default;
   end Argument_Value;

   function Count_Image (Value : Integer) return String is
      Text : constant String := Integer'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Count_Image;

   Elapsed : Duration;
   Started : Ada.Real_Time.Time;
begin
   Workers := Positive'Value (Argument_Value ("--workers", "4"));
   Seconds := Duration'Value (Argument_Value ("--seconds", "3.0"));
   Reload_Rate := Natural'Value (Argument_Value ("--reloads-per-second", "0"));
   Route_Count := Positive'Value (Argument_Value ("--routes", "4"));

   Routes.Get ("/users/{id}", Handler_A'Access, Hot, Name => "users.show");
   for Index in 2 .. Route_Count loop
      declare
         Extra : Routing.Route_ID;
         Label : constant String := Integer'Image (Index);
         Slug  : constant String := Label (Label'First + 1 .. Label'Last);
      begin
         Routes.Get
           ("/filler/" & Slug, Handler_A'Access, Extra,
            Name => "filler." & Slug);
      end;
   end loop;

   Started := Ada.Real_Time.Clock;
   Deadline := Started + Ada.Real_Time.To_Time_Span (Seconds);

   declare
      Crew   : array (1 .. Workers) of Worker;
      Reload : Loader;
      pragma Unreferenced (Crew, Reload);
   begin
      null;
   end;

   Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);

   Ada.Text_IO.Put_Line
     ("workers=" & Count_Image (Workers)
      & " routes=" & Count_Image (Route_Count)
      & " reloads_per_second=" & Count_Image (Reload_Rate)
      & " seconds=" & Showcase_Support.Fixed_Image (Long_Float (Elapsed), 3));
   Ada.Text_IO.Put_Line
     ("dispatches=" & Long_Long_Integer'Image (Totals.Dispatched)
      & " reloads=" & Long_Long_Integer'Image (Totals.Reloaded)
      & " failures=" & Natural'Image (Totals.Failed)
      & " retained_generations="
      & Natural'Image (Routes.Retained_Generations));
   Ada.Text_IO.Put_Line
     ("dispatches_per_second="
      & Showcase_Support.Fixed_Image
          (Long_Float (Totals.Dispatched) / Long_Float (Elapsed), 1));
end HTTP_Router_Reload_Benchmark;
