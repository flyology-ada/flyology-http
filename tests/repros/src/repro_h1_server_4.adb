--  H1-SERVER-4: an absolute-form request-target whose authority differs from
--  Host is refused, where RFC 9112 section 3.2.2 requires the Host field to
--  be ignored:
--
--    "When an origin server receives a request with an absolute-form of
--     request-target, the origin server MUST ignore the received Host header
--     field (if any) and instead use the host information of the
--     request-target."
--
--  RFC 9112 section 3.2 enumerates the Host cases that MUST answer 400: a
--  missing Host on HTTP/1.1, more than one Host field line, and a Host with
--  an invalid field value.  A valid Host that merely disagrees with the
--  target is not one of them.
--
--  The program asserts the CORRECT behaviour: the request is served and the
--  target's authority wins.
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Server;
with Repro_Support;

procedure Repro_H1_Server_4 is
   package HTTP_Server renames Flyology.HTTP.Server;
   use Ada.Strings.Unbounded;
   use Repro_Support;

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

   procedure Probe
     (Label, Wire, Expected_Target, Expected_Authority : String)
   is
      Channel : aliased Memory_Transport;
   begin
      Channel.Input := To_Unbounded_String (Wire);
      declare
         Peer   : HTTP_Server.Connection (Channel'Access);
         Value  : HTTP_Server.Request;
         Closed : Boolean;
      begin
         HTTP_Server.Read_Request (Peer, Value, Closed, Timeout => 5.0);
         Expect_Equal
           (HTTP_Server.Target (Value), Expected_Target, Label & " target");
         Expect_Equal
           (HTTP_Server.Authority (Value), Expected_Authority,
            Label & " authority");
      exception
         when Error : Flyology.HTTP.Protocol_Error =>
            Check (False, Label & " target");
            Note
              ("  raised Protocol_Error: "
               & Ada.Exceptions.Exception_Message (Error));
      end;
   end Probe;
begin
   Note ("RFC 9112 section 3.2.2 origin-server MUST-ignore of Host under an");
   Note ("absolute-form request-target");

   --  Baseline: an agreeing Host is accepted today, so the absolute form
   --  itself is supported and only the disagreement is refused.
   Probe
     ("absolute form with an agreeing Host (baseline)",
      "GET http://example.test/ HTTP/1.1" & CRLF
      & "Host: example.test" & CRLF & CRLF,
      "http://example.test/", "example.test");

   Probe
     ("absolute form with a differing Host",
      "GET http://example.test/ HTTP/1.1" & CRLF
      & "Host: other.test" & CRLF & CRLF,
      "http://example.test/", "example.test");

   Probe
     ("absolute form with a differing Host port",
      "GET http://example.test:8080/p?q HTTP/1.1" & CRLF
      & "Host: example.test" & CRLF & CRLF,
      "http://example.test:8080/p?q", "example.test:8080");

   Finish;
end Repro_H1_Server_4;
