--  LIFETIME-3: src/flyology-http-server-request_tasks.ads:29-31 says
--
--    "Item must be declared with Parent => X.Cancellation so Ada enforces
--     the request-token borrow."
--
--  and src/flyology-http-server-applications.ads:63-65 says
--
--    "Access discriminants let Ada reject an exchange whose request,
--     connection, or token would not outlive it."
--
--  Neither claim has a tests/compile_fail case; scripts/test.sh:275-305 pins
--  three other lifetime claims and not these.  This program writes the escape
--  the first sentence says Ada rejects: it allocates an Operations.Scope whose
--  Parent discriminant is X.Cancellation from an access type declared OUTSIDE
--  the block that owns the token, exactly the shape
--  tests/compile_fail/websocket_pool_lifetime_fail.adb uses for the WebSocket
--  session pool.
--
--  This spike asserts the CORRECT behaviour, which here is that the escape is
--  rejected:
--
--    * exit 2 (BUILD FAILED, "statically too deep" / accessibility) means the
--      contract holds statically.  For this one program a build failure is the
--      expected result, not a broken spike.
--    * exit 0 with the Program_Error note means the contract holds only at run
--      time.
--    * exit 1 (BUG REPRODUCED) means the escape both compiles and runs, so the
--      sentence's "Ada enforces" is false and nothing in the repository
--      enforces it instead: Request_Tasks.Configure (request_tasks.adb:3-10)
--      forwards only X.Deadline and never compares Item.Parent with
--      X.Cancellation.
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Request_Tasks;
with Flyology.IO.Sockets;
with Repro_Support;

procedure Repro_Lifetime_3 is
   package HTTP_Server renames Flyology.HTTP.Server;
   package App renames Flyology.HTTP.Server.Applications;
   package Sockets renames Flyology.IO.Sockets;
   use Ada.Strings.Unbounded;
   use Repro_Support;
   use type Ada.Real_Time.Time;

   procedure Double
     (Input    : Integer;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Result   : out Integer)
   is
      pragma Unreferenced (Token, Deadline);
   begin
      Result := Input * 2;
   end Double;

   package Request_Work is new
     Flyology.HTTP.Server.Request_Tasks (Integer, Integer, Double);
   package Operations renames Request_Work.Operations;

   --  Declared here, so its collection outlives every nested block below.
   type Scope_Access is access all Operations.Scope;
   Escaped : Scope_Access;

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

   Wire : aliased Memory_Transport;
begin
   Note ("request_tasks.ads:29-31 claims Ada enforces the request-token");
   Note ("borrow; applications.ads:63-65 claims access discriminants let Ada");
   Note ("reject an exchange that outlives its token.  Neither has a");
   Note ("tests/compile_fail case (scripts/test.sh:275-305 pins three others).");

   Wire.Input := To_Unbounded_String
     ("GET /parallel HTTP/1.1" & CRLF & "Host: h" & CRLF
      & "Connection: close" & CRLF & CRLF);

   declare
      --  Everything the exchange borrows lives only for this block.
      Peer_Connection : aliased HTTP_Server.Connection (Wire'Access);
      Value           : aliased HTTP_Server.Request;
      Stop            : aliased Flyology.Cancellation.Token;
      Closed          : Boolean;
   begin
      HTTP_Server.Read_Request
        (Peer_Connection, Value, Closed, Timeout => 5.0);
      Check (not Closed, "fixture request parsed");

      declare
         X : App.Exchange := App.Create
           (Value    => Value,
            Item     => Peer_Connection,
            Peer     => Sockets.Network_Endpoint (Sockets.Loopback_IPv4, 1),
            Token    => Stop'Access,
            Deadline => Ada.Real_Time.Clock + Ada.Real_Time.Seconds (30));
      begin
         --  The escape.  Scope_Access is declared in the enclosing subprogram,
         --  so the allocated Scope outlives Stop.  If the .ads sentence held,
         --  this allocator would be rejected the way
         --  websocket_pool_lifetime_fail.adb's is.
         Escaped := new Operations.Scope
           (Capacity => 1, Parent => X.Cancellation);
         Check
           (False,
            "a Scope whose Parent is X.Cancellation cannot outlive the token");
         Note ("the allocator compiled and ran; no accessibility check fired");
         Note ("Escaped.Parent now designates a token that is about to die");
      end;
   exception
      when Error : Program_Error =>
         Note ("Program_Error from the allocator: "
               & Ada.Exceptions.Exception_Message (Error));
         Note ("the borrow is enforced, but dynamically rather than by the");
         Note ("static rule the .ads sentence implies");
   end;

   --  Stop is gone.  Escaped, if it exists, still names it.
   Check
     (Escaped = null,
      "no Scope survives the cancellation token it borrowed");

   Finish;
end Repro_Lifetime_3;
