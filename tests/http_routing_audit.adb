--  Regression coverage for the 2026-08-07 audit findings in the server routing
--  and middleware. Every fix lands its failing reproduction here before the fix
--  itself.
with Ada.Streams;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology.Cancellation;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Routing;
with Flyology.IO;
with Flyology.IO.Sockets;

procedure HTTP_Routing_Audit is
   package HTTP_Server renames Flyology.HTTP.Server;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element_Offset;

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

begin
   Check_Target_Form_Anchoring;
   if Failures /= 0 then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "HTTP routing audit regressions:" & Failures'Image);
      raise Program_Error with "HTTP routing audit regressions";
   end if;
   Ada.Text_IO.Put_Line ("HTTP routing audit passed");
end HTTP_Routing_Audit;
