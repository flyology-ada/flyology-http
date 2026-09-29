--  H1-SERVER verification probe 2: the desync surfaces that do not live in
--  the head parser.  An unread request body, a rejected 100-continue upload,
--  a chunked trailer, Connection-token matching, and HEAD body suppression
--  are each driven with a pipelined follower so that a connection which
--  wrongly stays alive, or which reinterprets unread body bytes, shows up as
--  an extra response.  PASS refutes a desync defect here.
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Connection_Handlers;
with Repro_Support;

procedure Repro_H1_Server_7 is
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

   --  Echoes the request identity, so a served request is visible on the
   --  wire even when its body was never read.
   procedure Echo_Route
     (Item  : in out HTTP_Server.Connection;
      Value : HTTP_Server.Request) is
   begin
      HTTP_Server.Respond
        (Item, 200, "text/plain",
         "[" & HTTP_Server.Method (Value) & " "
         & HTTP_Server.Target (Value) & " "
         & HTTP_Server.Content (Value) & " trailer="
         & HTTP_Server.Header (Value, "X-Trailer") & "]");
   end Echo_Route;

   --  Refuses the upload without reading or accepting the body.
   procedure Reject_Route
     (Item  : in out HTTP_Server.Connection;
      Value : HTTP_Server.Request)
   is
      pragma Unreferenced (Value);
   begin
      HTTP_Server.Respond (Item, 403, "text/plain", "no");
   end Reject_Route;

   package Echo_Loop is new HTTP_Server.Connection_Handlers (Echo_Route);
   package Reject_Loop is new HTTP_Server.Connection_Handlers (Reject_Route);

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

   Smuggled : constant String :=
     "GET /smuggled HTTP/1.1" & CRLF & "Host: h" & CRLF & CRLF;
   --  35 octets, so a Content-Length of 35 covers it exactly.

   Wire_Text : Unbounded_String;
begin
   Note ("probe: unread bodies, rejected uploads, trailers, Connection");
   Note ("tokens and HEAD suppression, each with a pipelined follower");

   Expect_Equal (Smuggled'Length, 35, "pipelined follower is 35 octets");

   --  An unread body must force the connection closed; its octets must never
   --  be parsed as the next request-line.
   declare
      Channel : aliased Memory_Transport;
   begin
      Channel.Input := To_Unbounded_String
        ("POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
         & "Content-Length: 35" & CRLF & CRLF & Smuggled);
      declare
         Peer : HTTP_Server.Connection (Channel'Access);
      begin
         Echo_Loop.Serve
           (Peer, Timeout => 5.0, Buffer_Body => False,
            Max_Connection_Age => 30.0);
      end;
      Wire_Text := Channel.Output;
      Expect_Equal
        (Summarize (To_String (Wire_Text)), "200 [POST /a  trailer=]",
         "an unread body is not reparsed as the next request");
      Check
        (Ada.Strings.Fixed.Index
           (To_String (Wire_Text), "Connection: close") /= 0,
         "an unread body forces Connection: close");
   end;

   --  A 100-continue upload refused before Accept_Body must close too.
   declare
      Channel : aliased Memory_Transport;
   begin
      Channel.Input := To_Unbounded_String
        ("POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
         & "Expect: 100-continue" & CRLF
         & "Content-Length: 35" & CRLF & CRLF & Smuggled);
      declare
         Peer : HTTP_Server.Connection (Channel'Access);
      begin
         Reject_Loop.Serve
           (Peer, Timeout => 5.0, Buffer_Body => False,
            Max_Connection_Age => 30.0);
      end;
      Wire_Text := Channel.Output;
      Expect_Equal
        (Summarize (To_String (Wire_Text)), "403",
         "a refused 100-continue upload answers once and closes");
      Check
        (Ada.Strings.Fixed.Index (To_String (Wire_Text), " 100 ") = 0,
         "no 100 Continue is emitted for a refused upload");
   end;

   --  A chunked trailer must not become a request header field.
   declare
      Channel : aliased Memory_Transport;
   begin
      Channel.Input := To_Unbounded_String
        ("POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF
         & "Transfer-Encoding: chunked" & CRLF & CRLF
         & "1" & CRLF & "x" & CRLF & "0" & CRLF
         & "X-Trailer: injected" & CRLF & CRLF & Smuggled);
      declare
         Peer : HTTP_Server.Connection (Channel'Access);
      begin
         Echo_Loop.Serve (Peer, Timeout => 5.0, Max_Connection_Age => 30.0);
      end;
      Expect_Equal
        (Summarize (To_String (Channel.Output)),
         "200,200 [POST /a x trailer=] [GET /smuggled  trailer=]",
         "a trailer is not visible as a request header field");
   end;

   --  Connection token matching is whole-member, so notclose is not close.
   declare
      Channel : aliased Memory_Transport;
   begin
      Channel.Input := To_Unbounded_String
        ("GET /a HTTP/1.1" & CRLF & "Host: h" & CRLF
         & "Connection: notclose" & CRLF & CRLF & Smuggled);
      declare
         Peer : HTTP_Server.Connection (Channel'Access);
      begin
         Echo_Loop.Serve (Peer, Timeout => 5.0, Max_Connection_Age => 30.0);
      end;
      Expect_Equal
        (Summarize (To_String (Channel.Output)),
         "200,200 [GET /a  trailer=] [GET /smuggled  trailer=]",
         "Connection: notclose does not close the connection");
   end;

   declare
      Channel : aliased Memory_Transport;
   begin
      Channel.Input := To_Unbounded_String
        ("GET /a HTTP/1.1" & CRLF & "Host: h" & CRLF
         & "Connection: keep-alive, close" & CRLF & CRLF & Smuggled);
      declare
         Peer : HTTP_Server.Connection (Channel'Access);
      begin
         Echo_Loop.Serve (Peer, Timeout => 5.0, Max_Connection_Age => 30.0);
      end;
      Expect_Equal
        (Summarize (To_String (Channel.Output)),
         "200 [GET /a  trailer=]",
         "a close member closes even beside keep-alive");
   end;

   --  HEAD declares the length and sends no content.
   declare
      Channel : aliased Memory_Transport;
   begin
      Channel.Input := To_Unbounded_String
        ("HEAD /a HTTP/1.1" & CRLF & "Host: h" & CRLF & CRLF & Smuggled);
      declare
         Peer : HTTP_Server.Connection (Channel'Access);
      begin
         Echo_Loop.Serve (Peer, Timeout => 5.0, Max_Connection_Age => 30.0);
      end;
      Wire_Text := Channel.Output;
      Check
        (Ada.Strings.Fixed.Index
           (To_String (Wire_Text), "Content-Length: 19") /= 0,
         "HEAD declares the representation length");
      Check
        (Ada.Strings.Fixed.Index (To_String (Wire_Text), "[HEAD") = 0,
         "HEAD sends no response content");
      Expect_Equal
        (Summarize (To_String (Wire_Text)), "200,200 [GET /smuggled  trailer=]",
         "the request after a HEAD is framed correctly");
   end;

   Finish;
end Repro_H1_Server_7;
