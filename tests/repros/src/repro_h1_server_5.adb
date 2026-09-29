--  H1-SERVER-5: peer-chosen request shapes surface as Program_Error, which
--  escapes the documented Protocol_Error rejection channel.
--
--  src/flyology-http-server.ads:857 documents
--    "@exception Protocol_Error Request is not a valid version 13 upgrade"
--  for Accept_WebSocket, and Connection_Handlers.Serve maps Protocol_Error to
--  a best-effort 400 with Connection: close.  Program_Error is not mapped, so
--  it leaves Serve and the peer receives nothing at all.
--
--  Whether a GET carries content, whether the method is HEAD, and whether the
--  version is HTTP/1.0 are all chosen by the peer, not by the application, so
--  they belong on the rejection channel rather than the application-fault
--  channel that tests/http_smoke.adb Check_Application_Failure_Propagates
--  pins.
--
--  The program asserts the CORRECT behaviour: Serve returns, and the peer
--  receives a client-error response.
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Connection_Handlers;
with Repro_Support;

procedure Repro_H1_Server_5 is
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

   procedure Upgrade_Route
     (Item  : in out HTTP_Server.Connection;
      Value : HTTP_Server.Request) is
   begin
      HTTP_Server.Accept_WebSocket (Item, Value, Timeout => 5.0);
   end Upgrade_Route;

   procedure SSE_Route
     (Item  : in out HTTP_Server.Connection;
      Value : HTTP_Server.Request)
   is
      pragma Unreferenced (Value);
   begin
      HTTP_Server.Begin_SSE (Item, Timeout => 5.0);
      HTTP_Server.End_Response_Stream (Item, Timeout => 5.0);
   end SSE_Route;

   package Upgrade_Loop is
     new HTTP_Server.Connection_Handlers (Upgrade_Route);
   package SSE_Loop is new HTTP_Server.Connection_Handlers (SSE_Route);

   function Status_Of (Wire : String) return String is
      Found : constant Natural := Ada.Strings.Fixed.Index (Wire, "HTTP/1.");
   begin
      if Found = 0 or else Found + 11 > Wire'Last then
         return "(no response)";
      end if;
      return Wire (Found + 9 .. Found + 11);
   end Status_Of;

   procedure Judge (Label, Escaped, Status : String) is
   begin
      Check (Escaped = "", Label & ": no exception escapes Serve");
      if Escaped /= "" then
         Note ("  escaped: " & Escaped);
      end if;
      Check
        (Status'Length = 3 and then Status (Status'First) = '4',
         Label & ": peer receives a client-error response");
      if not (Status'Length = 3 and then Status (Status'First) = '4') then
         Note ("  wire status: " & Status);
      end if;
   end Judge;

   procedure Probe_Upgrade (Label, Wire : String; Buffer_Body : Boolean) is
      Channel : aliased Memory_Transport;
      Escaped : Unbounded_String;
   begin
      Channel.Input := To_Unbounded_String (Wire);
      declare
         Peer : HTTP_Server.Connection (Channel'Access);
      begin
         Upgrade_Loop.Serve
           (Peer, Timeout => 5.0, Buffer_Body => Buffer_Body,
            Max_Connection_Age => 30.0);
      exception
         when Error : others =>
            Escaped := To_Unbounded_String
              (Ada.Exceptions.Exception_Name (Error) & " """
               & Ada.Exceptions.Exception_Message (Error) & """");
      end;
      Judge
        (Label, To_String (Escaped), Status_Of (To_String (Channel.Output)));
   end Probe_Upgrade;

   procedure Probe_SSE (Label, Wire : String) is
      Channel : aliased Memory_Transport;
      Escaped : Unbounded_String;
   begin
      Channel.Input := To_Unbounded_String (Wire);
      declare
         Peer : HTTP_Server.Connection (Channel'Access);
      begin
         SSE_Loop.Serve
           (Peer, Timeout => 5.0, Max_Connection_Age => 30.0);
      exception
         when Error : others =>
            Escaped := To_Unbounded_String
              (Ada.Exceptions.Exception_Name (Error) & " """
               & Ada.Exceptions.Exception_Message (Error) & """");
      end;
      Judge
        (Label, To_String (Escaped), Status_Of (To_String (Channel.Output)));
   end Probe_SSE;

   Handshake : constant String :=
     "Host: h" & CRLF
     & "Upgrade: websocket" & CRLF
     & "Connection: Upgrade" & CRLF
     & "Sec-WebSocket-Version: 13" & CRLF
     & "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" & CRLF;
begin
   Note ("peer-chosen shapes reaching Accept_WebSocket and Begin_SSE through");
   Note ("the raw Connection_Handlers engine");

   --  Baseline: the same handshake without a body upgrades cleanly, so only
   --  the peer-chosen body is at issue.
   declare
      Channel : aliased Memory_Transport;
      Escaped : Unbounded_String;
   begin
      Channel.Input := To_Unbounded_String
        ("GET /websocket HTTP/1.1" & CRLF & Handshake & CRLF);
      declare
         Peer : HTTP_Server.Connection (Channel'Access);
      begin
         Upgrade_Loop.Serve
           (Peer, Timeout => 5.0, Max_Connection_Age => 30.0);
      exception
         when Error : others =>
            Escaped := To_Unbounded_String
              (Ada.Exceptions.Exception_Name (Error));
      end;
      Check
        (Escaped = Null_Unbounded_String
           and then Status_Of (To_String (Channel.Output)) = "101",
         "baseline: a bodiless handshake upgrades (101)");
      if Escaped /= Null_Unbounded_String then
         Note ("  escaped: " & To_String (Escaped));
      end if;
   end;

   Probe_Upgrade
     ("upgrade with Content-Length body, buffered",
      "GET /websocket HTTP/1.1" & CRLF & Handshake
      & "Content-Length: 1" & CRLF & CRLF & "x",
      Buffer_Body => True);

   Probe_Upgrade
     ("upgrade with Content-Length body, unbuffered",
      "GET /websocket HTTP/1.1" & CRLF & Handshake
      & "Content-Length: 1" & CRLF & CRLF & "x",
      Buffer_Body => False);

   Probe_Upgrade
     ("upgrade with a chunked body, unbuffered",
      "GET /websocket HTTP/1.1" & CRLF & Handshake
      & "Transfer-Encoding: chunked" & CRLF & CRLF
      & "1" & CRLF & "x" & CRLF & "0" & CRLF & CRLF,
      Buffer_Body => False);

   Probe_SSE
     ("HEAD on an SSE route",
      "HEAD /events HTTP/1.1" & CRLF & "Host: h" & CRLF & CRLF);

   Probe_SSE
     ("HTTP/1.0 on an SSE route",
      "GET /events HTTP/1.0" & CRLF & "Host: h" & CRLF & CRLF);

   Finish;
end Repro_H1_Server_5;
