--  H1-SERVER verification probe: request-smuggling surface of the HTTP/1.x
--  server head parser.  Unlike a finding spike this one asserts that the
--  CURRENT behaviour is sound, so PASS (exit 0) refutes a smuggling defect
--  and BUG REPRODUCED (exit 1) names a concrete desync primitive.
--
--  Each case drives Connection_Handlers.Serve over an in-memory transport
--  with one hostile head followed by a pipelined "GET /smuggled".  The
--  summary line records every response status the server wrote and every
--  request the application actually saw, so a case that turns one message
--  into two, or that reads a different number of body bytes than the
--  declared framing allows, shows up as a summary mismatch.
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Connection_Handlers;
with Repro_Support;

procedure Repro_H1_Server_6 is
   package HTTP_Server renames Flyology.HTTP.Server;
   use Ada.Strings.Unbounded;
   use Repro_Support;

   NUL : constant Character := Character'Val (0);
   LF  : constant Character := Character'Val (10);
   HT  : constant Character := Character'Val (9);

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

   procedure Handle
     (Item  : in out HTTP_Server.Connection;
      Value : HTTP_Server.Request) is
   begin
      HTTP_Server.Respond
        (Item, 200, "text/plain",
         "[" & HTTP_Server.Method (Value)
         & " " & HTTP_Server.Target (Value)
         & " " & HTTP_Server.Content (Value) & "]");
   end Handle;

   package Server_Loop is new HTTP_Server.Connection_Handlers (Handle);

   --  Statuses in wire order, then every request the application saw.
   function Summarize (Text : String) return String is
      Result : Unbounded_String;
      First  : Positive := Text'First;
   begin
      loop
         declare
            Found : constant Natural :=
              Ada.Strings.Fixed.Index (Text (First .. Text'Last), "HTTP/1.");
         begin
            exit when Found = 0 or else Found + 11 > Text'Last;
            if Length (Result) > 0 then
               Append (Result, ",");
            end if;
            Append (Result, Text (Found + 9 .. Found + 11));
            First := Found + 7;
            exit when First > Text'Last;
         end;
      end loop;
      First := Text'First;
      loop
         declare
            Open  : constant Natural :=
              Ada.Strings.Fixed.Index (Text (First .. Text'Last), "[");
            Close : Natural;
         begin
            exit when Open = 0;
            Close := Ada.Strings.Fixed.Index (Text (Open .. Text'Last), "]");
            exit when Close = 0;
            Append (Result, " " & Text (Open .. Close));
            First := Close + 1;
            exit when First > Text'Last;
         end;
      end loop;
      return To_String (Result);
   end Summarize;

   procedure Probe (Label, Wire, Expected : String) is
      Channel : aliased Memory_Transport;
   begin
      Channel.Input := To_Unbounded_String (Wire);
      declare
         Peer : HTTP_Server.Connection (Channel'Access);
      begin
         Server_Loop.Serve
           (Peer, Timeout => 5.0, Max_Connection_Age => 30.0);
      exception
         when Error : others =>
            Append
              (Channel.Output,
               "<<escaped " & Ada.Exceptions.Exception_Name (Error) & ">>");
      end;
      Expect_Equal (Summarize (To_String (Channel.Output)), Expected, Label);
   end Probe;

   Smuggled : constant String :=
     "GET /smuggled HTTP/1.1" & CRLF & "Host: h" & CRLF & CRLF;

   Rejected : constant String := "400";
   Served   : constant String :=
     "200,200 [POST /a hello] [GET /smuggled ]";
begin
   Note ("probe: HTTP/1.x request-smuggling surface (Content-Length,");
   Note ("Transfer-Encoding, field-name and field-value grammar)");

   --  RFC 9110 section 8.6: Content-Length = 1*DIGIT.  A sign is not a DIGIT.
   Probe
     ("Content-Length with a leading plus is refused",
      "POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
      & "Content-Length: +5" & CRLF & CRLF & "hello" & Smuggled,
      Rejected);

   --  Leading zeros are 1*DIGIT and must decode to 5, not 0 and not octal.
   Probe
     ("Content-Length with leading zeros decodes to five",
      "POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
      & "Content-Length: 005" & CRLF & CRLF & "hello" & Smuggled,
      Served);

   --  RFC 9112 section 5: field-line = field-name ":" OWS field-value OWS.
   Probe
     ("Content-Length surrounded by OWS decodes to five",
      "POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
      & "Content-Length:   5   " & CRLF & CRLF & "hello" & Smuggled,
      Served);

   Probe
     ("Content-Length surrounded by HTAB decodes to five",
      "POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
      & "Content-Length:" & HT & "5" & HT & CRLF & CRLF & "hello" & Smuggled,
      Served);

   --  A NUL is a control byte and is not OWS.
   Probe
     ("Content-Length with a trailing NUL is refused",
      "POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
      & "Content-Length: 5" & NUL & CRLF & CRLF & "hello" & Smuggled,
      Rejected);

   --  Ada 'Value accepts underscores and based literals; the parser must not.
   Probe
     ("Content-Length with an Ada underscore is refused",
      "POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
      & "Content-Length: 1_0" & CRLF & CRLF & "hello" & Smuggled,
      Rejected);

   Probe
     ("Content-Length as an Ada based literal is refused",
      "POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
      & "Content-Length: 16#5#" & CRLF & CRLF & "hello" & Smuggled,
      Rejected);

   Probe
     ("Content-Length list value is refused",
      "POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
      & "Content-Length: 5, 5" & CRLF & CRLF & "hello" & Smuggled,
      Rejected);

   --  Two field lines whose names differ only by case are one field.
   Probe
     ("case-differing repeated Content-Length is refused",
      "POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
      & "Content-Length: 5" & CRLF & "content-length: 6" & CRLF & CRLF
      & "hello" & Smuggled,
      Rejected);

   --  RFC 9112 section 5.1: a server MUST reject whitespace between the
   --  field name and the colon.
   Probe
     ("Content-Length name with a trailing space is refused",
      "POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
      & "Content-Length : 5" & CRLF & CRLF & "hello" & Smuggled,
      Rejected);

   --  RFC 9112 section 5.2: obs-fold must be rejected or replaced by SP.
   Probe
     ("obs-folded Content-Length is refused",
      "POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
      & "Content-Length: 5" & CRLF & " 0" & CRLF & CRLF & "hello" & Smuggled,
      Rejected);

   --  A bare LF must not terminate a field line.
   Probe
     ("bare LF between two Content-Length lines is refused",
      "POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
      & "Content-Length: 6" & LF & "Content-Length: 0" & CRLF & CRLF
      & "hello" & Smuggled,
      Rejected);

   --  RFC 9112 section 6.1: chunked must be the final coding and this server
   --  supports no other; two field lines are two codings.
   Probe
     ("two Transfer-Encoding lines are refused",
      "POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
      & "Transfer-Encoding: identity" & CRLF
      & "Transfer-Encoding: chunked" & CRLF & CRLF
      & "5" & CRLF & "hello" & CRLF & "0" & CRLF & CRLF & Smuggled,
      Rejected);

   Probe
     ("case-differing repeated Transfer-Encoding is refused",
      "POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
      & "Transfer-Encoding: chunked" & CRLF
      & "transfer-encoding: chunked" & CRLF & CRLF
      & "5" & CRLF & "hello" & CRLF & "0" & CRLF & CRLF & Smuggled,
      Rejected);

   Probe
     ("Transfer-Encoding chunked-comma-chunked is refused",
      "POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
      & "Transfer-Encoding: chunked, chunked" & CRLF & CRLF
      & "5" & CRLF & "hello" & CRLF & "0" & CRLF & CRLF & Smuggled,
      Rejected);

   --  RFC 9112 section 6.1: Transfer-Encoding must not be sent to an
   --  HTTP/1.0 recipient.
   Probe
     ("Transfer-Encoding on HTTP/1.0 is refused",
      "POST /a HTTP/1.0" & CRLF & "Host: h" & CRLF
      & "Transfer-Encoding: chunked" & CRLF & CRLF
      & "5" & CRLF & "hello" & CRLF & "0" & CRLF & CRLF & Smuggled,
      Rejected);

   --  RFC 9112 section 6.3 item 3: Content-Length with Transfer-Encoding.
   Probe
     ("Content-Length together with Transfer-Encoding is refused",
      "POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
      & "Content-Length: 5" & CRLF & "Transfer-Encoding: chunked" & CRLF
      & CRLF & "5" & CRLF & "hello" & CRLF & "0" & CRLF & CRLF & Smuggled,
      Rejected);

   Probe
     ("Transfer-Encoding before Content-Length is refused",
      "POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
      & "Transfer-Encoding: chunked" & CRLF & "Content-Length: 5" & CRLF
      & CRLF & "5" & CRLF & "hello" & CRLF & "0" & CRLF & CRLF & Smuggled,
      Rejected);

   --  A trailer must not be able to introduce framing after the fact.
   Probe
     ("Content-Length in a chunked trailer is refused",
      "POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
      & "Transfer-Encoding: chunked" & CRLF & CRLF
      & "5" & CRLF & "hello" & CRLF & "0" & CRLF
      & "Content-Length: 5" & CRLF & CRLF & Smuggled,
      Rejected);

   --  The well-formed chunked baseline: one request, one pipelined follower.
   Probe
     ("well-formed chunked body frames exactly one request",
      "POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
      & "Transfer-Encoding: chunked" & CRLF & CRLF
      & "5" & CRLF & "hello" & CRLF & "0" & CRLF & CRLF & Smuggled,
      Served);

   Finish;
end Repro_H1_Server_6;
