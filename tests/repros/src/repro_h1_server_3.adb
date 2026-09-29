--  H1-SERVER-3: an oversized head, an unknown transfer coding, CONNECT, and
--  an unsupported version all collapse to one 400.
--
--  Only one of the five rows carries a normative requirement for a different
--  status.  RFC 9112 section 6.1: "A server that receives a request message
--  with a transfer coding it does not understand SHOULD respond with 501
--  (Not Implemented)."  That row is the assertion; the other four rows are
--  recorded as observed statuses, because 431 is only permissive in RFC 6585
--  section 5 ("It can be used both when ..."), RFC 9110 section 15.6.6
--  describes 505 without requiring it, RFC 9110 section 9.3.6 says only that
--  "An origin server MAY accept a CONNECT request, but most origin servers do
--  not implement CONNECT", and the RFC 7230 section 2.6 sentence about
--  processing a higher minor version as the highest conformant one does not
--  survive into RFC 9112 or RFC 9110.
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Connection_Handlers;
with Repro_Support;

procedure Repro_H1_Server_3 is
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

   procedure Handle
     (Item  : in out HTTP_Server.Connection;
      Value : HTTP_Server.Request) is
   begin
      HTTP_Server.Respond
        (Item, 200, "text/plain", HTTP_Server.Target (Value));
   end Handle;

   package Server_Loop is new HTTP_Server.Connection_Handlers (Handle);

   function Status_Of (Wire : String) return String is
      Found : constant Natural :=
        Ada.Strings.Fixed.Index (Wire, "HTTP/1.");
   begin
      if Found = 0 or else Found + 11 > Wire'Last then
         return "(no response)";
      end if;
      return Wire (Found + 9 .. Found + 11);
   end Status_Of;

   function Serve_Once (Wire : String) return String is
      Channel : aliased Memory_Transport;
   begin
      Channel.Input := To_Unbounded_String (Wire);
      declare
         Peer : HTTP_Server.Connection (Channel'Access);
      begin
         Server_Loop.Serve
           (Peer, Timeout => 5.0, Max_Connection_Age => 30.0);
      end;
      return Status_Of (To_String (Channel.Output));
   end Serve_Once;

   Oversized : constant String :=
     "GET / HTTP/1.1" & CRLF & "Host: h" & CRLF & "X-Fill: "
     & String'(1 .. HTTP_Server.Max_Header_Bytes => 'x') & CRLF & CRLF;
begin
   Note ("observed status for each row of the H1-SERVER-3 table");

   Note
     ("head over Max_Header_Bytes -> "
      & Serve_Once (Oversized) & " (431 would be RFC 6585 section 5)");

   Note
     ("CONNECT with a matching Host -> "
      & Serve_Once
          ("CONNECT example.test:443 HTTP/1.1" & CRLF
           & "Host: example.test:443" & CRLF & CRLF)
      & " (405 or 501 would be RFC 9110 section 15.5.6 or 15.6.2)");

   Note
     ("GET / HTTP/1.2 -> "
      & Serve_Once ("GET / HTTP/1.2" & CRLF & "Host: h" & CRLF & CRLF)
      & " (RFC 9112 no longer carries the RFC 7230 minor-version SHOULD)");

   Note
     ("GET / HTTP/2.0 on a cleartext HTTP/1 listener -> "
      & Serve_Once ("GET / HTTP/2.0" & CRLF & "Host: h" & CRLF & CRLF)
      & " (505 is RFC 9110 section 15.6.6, described not required)");

   Note
     ("Transfer-Encoding: chunked on HTTP/1.0 -> "
      & Serve_Once
          ("POST / HTTP/1.0" & CRLF & "Host: h" & CRLF
           & "Transfer-Encoding: chunked" & CRLF & CRLF
           & "0" & CRLF & CRLF)
      & " (RFC 9112 section 6.1 requires only faulty-framing plus close)");

   --  The one normative row: RFC 9112 section 6.1 SHOULD respond with 501.
   Expect_Equal
     (Serve_Once
        ("POST / HTTP/1.1" & CRLF & "Host: h" & CRLF
         & "Transfer-Encoding: gzip, chunked" & CRLF & CRLF
         & "0" & CRLF & CRLF),
      "501",
      "unknown transfer coding answers 501 (RFC 9112 section 6.1)");

   Finish;
end Repro_H1_Server_3;
