--  H1-SERVER-1: a stray CRLF before a request-line is rejected as malformed,
--  and at EOF becomes a spurious 400.
--
--  RFC 9112 section 2.2: "In the interest of robustness, a server that is
--  expecting to receive and parse a request-line SHOULD ignore at least one
--  empty line (CRLF) received prior to the request-line."
--
--  The program asserts the CORRECT behaviour: the stray CRLF is skipped, the
--  pipelined request behind it is served, and a stray CRLF followed by FIN is
--  a clean close between requests rather than a protocol error.
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Server;
with Repro_Support;

procedure Repro_H1_Server_1 is
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

   First_Request : constant String :=
     "POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
     & "Content-Length: 1" & CRLF & CRLF & "x";

   Second_Request : constant String :=
     "GET /b HTTP/1.1" & CRLF & "Host: h" & CRLF
     & "Connection: close" & CRLF & CRLF;
begin
   Note ("RFC 9112 section 2.2 SHOULD-ignore of one empty line before a");
   Note ("request-line; the extra CRLF an HTTP/1.0 agent sends after a POST");

   --  Variant A: the stray CRLF precedes a pipelined request.
   declare
      Channel : aliased Memory_Transport;
   begin
      Channel.Input := To_Unbounded_String
        (First_Request & CRLF & Second_Request);
      declare
         Peer    : HTTP_Server.Connection (Channel'Access);
         Value   : HTTP_Server.Request;
         Closed  : Boolean;
      begin
         HTTP_Server.Read_Request (Peer, Value, Closed, Timeout => 5.0);
         Expect_Equal
           (HTTP_Server.Target (Value), "/a", "first request target");
         Expect_Equal
           (HTTP_Server.Content (Value), "x", "first request content");
         HTTP_Server.Respond (Peer, 200, "text/plain", "a", Timeout => 5.0);
         begin
            HTTP_Server.Read_Request (Peer, Value, Closed, Timeout => 5.0);
            Check (not Closed, "second request is not a peer close");
            Expect_Equal
              (HTTP_Server.Target (Value), "/b",
               "pipelined request behind a stray CRLF is served");
         exception
            when Error : Flyology.HTTP.Protocol_Error =>
               Check
                 (False,
                  "pipelined request behind a stray CRLF is served");
               Note
                 ("  raised Protocol_Error: "
                  & Ada.Exceptions.Exception_Message (Error));
         end;
      end;
   end;

   --  Variant B: the stray CRLF is the last thing the peer sends.
   declare
      Channel : aliased Memory_Transport;
   begin
      Channel.Input := To_Unbounded_String (First_Request & CRLF);
      declare
         Peer    : HTTP_Server.Connection (Channel'Access);
         Value   : HTTP_Server.Request;
         Closed  : Boolean;
      begin
         HTTP_Server.Read_Request (Peer, Value, Closed, Timeout => 5.0);
         Expect_Equal
           (HTTP_Server.Target (Value), "/a", "first request target (EOF)");
         HTTP_Server.Respond (Peer, 200, "text/plain", "a", Timeout => 5.0);
         begin
            HTTP_Server.Read_Request (Peer, Value, Closed, Timeout => 5.0);
            Check
              (Closed,
               "a stray CRLF then FIN is a clean close between requests");
         exception
            when Error : Flyology.HTTP.Protocol_Error =>
               Check
                 (False,
                  "a stray CRLF then FIN is a clean close between requests");
               Note
                 ("  raised Protocol_Error: "
                  & Ada.Exceptions.Exception_Message (Error));
         end;
      end;
   end;

   Finish;
end Repro_H1_Server_1;
