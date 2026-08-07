--  Regression coverage for the 2026-08-07 audit findings in the HTTP/2 server
--  engine. Every fix lands its failing reproduction here before the fix
--  itself. The peer speaks raw HTTP/2 frames over a loopback socket so that
--  connection-level flow control and output scheduling stay observable.
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.IO;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.HTTP_2;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Interfaces;

procedure HTTP2_Server_Audit is
   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use type Interfaces.Unsigned_32;
   package App renames Flyology.HTTP.Server.Applications;
   package Connections renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;

   CR : constant Character := Character'Val (13);
   LF : constant Character := Character'Val (10);

   Failures : Natural := 0;

   procedure Check (Condition : Boolean; Label : String) is
   begin
      if Condition then
         Ada.Text_IO.Put_Line ("  ok   " & Label);
      else
         Failures := Failures + 1;
         Ada.Text_IO.Put_Line ("  FAIL " & Label);
      end if;
   end Check;

   function Decimal (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   type Context is limited null record;

   procedure Handle (State : in out Context; X : in out App.Exchange);

   package Engine is new Flyology.HTTP.Server.HTTP_2 (Context, Handle);
   package Routing is new Flyology.HTTP.Server.Routing (Context);

   --  Routed counterparts of the raw engine handlers. SSE is only reachable
   --  through a route that permits it, and an asterisk-form target only
   --  reaches a handler once it has matched a one-segment parameter.
   procedure Events (State : in out Context; X : in out App.Exchange);
   procedure By_Id (State : in out Context; X : in out App.Exchange);

   Routes : Routing.Router
     (Capacity => 2, Slashes => Routing.Strict_Slashes);

   procedure Events (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      X.Begin_SSE;
      if X.Request_Target = "/sse/event" then
         X.Send_SSE (Data => "safe", Event => "tick" & LF & "data: forged");
      elsif X.Request_Target = "/sse/id" then
         X.Send_SSE (Data => "safe", Id => "1" & LF & "data: forged");
      elsif X.Request_Target = "/sse/comment" then
         X.Send_SSE_Comment ("ping" & LF & "data: forged");
      elsif X.Request_Target = "/sse/utf8" then
         X.Send_SSE (Data => "bad" & Character'Val (16#FF#) & "byte");
      else
         X.Send_SSE (Data => "hello", Event => "ok");
      end if;
      X.End_SSE;
   end Events;

   procedure By_Id (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      X.Text (200, "id=" & X.Parameter ("id"));
   end By_Id;

   --  A response field section far larger than one frame, so the encoded head
   --  spans many CONTINUATION fragments and the connection output stays
   --  pinned to its slot for longer than the socket can buffer.
   Fragmented_Head_Size : constant := 2 * 1_024 * 1_024;
   type Text_Access is access String;
   Fragmented_Type : constant Text_Access :=
     new String'(1 .. Fragmented_Head_Size => 'p');

   procedure Handle (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      if X.Request_Target = "/slow" then
         delay 0.30;
         X.Text (200, "slow");
      elsif X.Request_Target = "/hold" then
         --  Deliberately never reads the request body, so the stream receive
         --  window stays depleted when the peer resets the stream.
         delay 0.30;
         X.No_Content;
      elsif X.Request_Target = "/bigheaders" then
         X.Respond (200, Fragmented_Type.all, "h");
      elsif X.Request_Target = "/flood" then
         X.Begin_Stream (200, "application/octet-stream");
         for Index in 1 .. 64 loop
            X.Write_Chunk (String'(1 .. 16_384 => 'f'));
         end loop;
         X.End_Stream;
      else
         --  Report what the pseudo-headers turned into: the raw target the
         --  log sink would see, and the fields the reconstructed header
         --  block re-parses out of the spliced authority.
         X.Text
           (200,
            "target=" & X.Request_Target &
              " te=" & X.Request_Header ("transfer-encoding") &
              " hosts=" & Decimal (X.Request_Header_Count ("host")));
      end if;
   end Handle;

   ---------------------------------------------------------------------------
   --  Raw HTTP/2 peer helpers
   ---------------------------------------------------------------------------

   Preface : constant Stream_Element_Array :=
     (Character'Pos ('P'), Character'Pos ('R'), Character'Pos ('I'),
      Character'Pos (' '), Character'Pos ('*'), Character'Pos (' '),
      Character'Pos ('H'), Character'Pos ('T'), Character'Pos ('T'),
      Character'Pos ('P'), Character'Pos ('/'), Character'Pos ('2'),
      Character'Pos ('.'), Character'Pos ('0'), 13, 10, 13, 10,
      Character'Pos ('S'), Character'Pos ('M'), 13, 10, 13, 10);

   Empty : constant Stream_Element_Array (1 .. 0) := (others => 0);

   function Frame_Header
     (Length    : Natural;
      Kind      : Stream_Element;
      Flags     : Stream_Element;
      Stream_ID : Natural) return Stream_Element_Array
   is
      Value : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Stream_ID);
   begin
      return
        (1 => Stream_Element (Length / 65_536),
         2 => Stream_Element ((Length / 256) mod 256),
         3 => Stream_Element (Length mod 256),
         4 => Kind,
         5 => Flags,
         6 => Stream_Element (Interfaces.Shift_Right (Value, 24) and 16#7F#),
         7 => Stream_Element (Interfaces.Shift_Right (Value, 16) and 16#FF#),
         8 => Stream_Element (Interfaces.Shift_Right (Value, 8) and 16#FF#),
         9 => Stream_Element (Value and 16#FF#));
   end Frame_Header;

   function U32 (Value : Natural) return Stream_Element_Array is
      Number : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Value);
   begin
      return
        (1 => Stream_Element (Interfaces.Shift_Right (Number, 24) and 16#7F#),
         2 => Stream_Element (Interfaces.Shift_Right (Number, 16) and 16#FF#),
         3 => Stream_Element (Interfaces.Shift_Right (Number, 8) and 16#FF#),
         4 => Stream_Element (Number and 16#FF#));
   end U32;

   function Text_Bytes (Value : String) return Stream_Element_Array is
      Result : Stream_Element_Array (1 .. Value'Length);
   begin
      for Offset in 0 .. Value'Length - 1 loop
         Result (Result'First + Stream_Element_Offset (Offset)) :=
           Stream_Element (Character'Pos (Value (Value'First + Offset)));
      end loop;
      return Result;
   end Text_Bytes;

   --  One HPACK literal field without indexing and with a new name. Names and
   --  values stay under 127 bytes so the length prefixes are single octets.
   function Literal (Name, Value : String) return Stream_Element_Array is
     ((1 => 16#00#, 2 => Stream_Element (Name'Length)) & Text_Bytes (Name) &
      (1 => Stream_Element (Value'Length)) & Text_Bytes (Value));

   function Request_Block
     (Method, Path : String) return Stream_Element_Array
   is
     (Literal (":method", Method) & Literal (":scheme", "http") &
      Literal (":authority", "localhost") & Literal (":path", Path));

   --  The same field section with every pseudo-header under test control,
   --  so an authority or a target may carry octets the encoder would never
   --  produce on its own.
   function Pseudo_Block
     (Method, Path, Authority : String) return Stream_Element_Array
   is
     (Literal (":method", Method) & Literal (":scheme", "http") &
      Literal (":authority", Authority) & Literal (":path", Path));

   procedure Send_Frame
     (Socket    : Sockets.Socket_Type;
      Kind      : Stream_Element;
      Flags     : Stream_Element;
      Stream_ID : Natural;
      Payload   : Stream_Element_Array) is
   begin
      Sockets.Send_All
        (Socket,
         Frame_Header (Payload'Length, Kind, Flags, Stream_ID) & Payload,
         Timeout => 10.0);
   end Send_Frame;

   type Frame_Info is record
      Kind      : Stream_Element := 0;
      Flags     : Stream_Element := 0;
      Stream_ID : Natural := 0;
      Length    : Natural := 0;
   end record;

   procedure Read_Frame_Header
     (Socket : Sockets.Socket_Type;
      Info   : out Frame_Info;
      Wait   : Duration)
   is
      Wire : Stream_Element_Array (1 .. 9);
   begin
      Sockets.Receive_Exactly (Socket, Wire, Timeout => Wait);
      Info :=
        (Kind => Wire (4),
         Flags => Wire (5),
         Stream_ID =>
           Natural (Wire (6) and 16#7F#) * 16#100_0000# +
           Natural (Wire (7)) * 16#1_0000# +
           Natural (Wire (8)) * 16#100# + Natural (Wire (9)),
         Length =>
           Natural (Wire (1)) * 65_536 + Natural (Wire (2)) * 256 +
             Natural (Wire (3)));
   end Read_Frame_Header;

   procedure Read_Payload
     (Socket  : Sockets.Socket_Type;
      Info    : Frame_Info;
      Payload : out Stream_Element_Array;
      Wait    : Duration) is
   begin
      if Info.Length > 0 then
         Sockets.Receive_Exactly
           (Socket,
            Payload (Payload'First ..
              Payload'First + Stream_Element_Offset (Info.Length) - 1),
            Timeout => Wait);
      end if;
   end Read_Payload;

   Data_Frame          : constant Stream_Element := 16#00#;
   Headers_Frame       : constant Stream_Element := 16#01#;
   Reset_Stream_Frame  : constant Stream_Element := 16#03#;
   Settings_Frame      : constant Stream_Element := 16#04#;
   Ping_Frame          : constant Stream_Element := 16#06#;
   Goaway_Frame        : constant Stream_Element := 16#07#;
   Window_Update_Frame : constant Stream_Element := 16#08#;
   Continuation_Frame  : constant Stream_Element := 16#09#;
   End_Stream_Flag     : constant Stream_Element := 16#01#;
   Ack_Flag            : constant Stream_Element := 16#01#;
   End_Headers_Flag    : constant Stream_Element := 16#04#;

   Manager  : aliased Connections.Server (Capacity => 1);
   Listener : Sockets.Socket_Type;
   Address  : Sockets.Endpoint;
   State    : Context;
   Sessions : constant := 9;

   Router_Manager  : aliased Connections.Server (Capacity => 1);
   Router_Listener : Sockets.Socket_Type;
   Router_Address  : Sockets.Endpoint;

   procedure Connect_Peer
     (Socket : in out Sockets.Socket_Type;
      Where  : Sockets.Endpoint) is
   begin
      Sockets.Create_Socket (Socket);
      Sockets.Connect
        (Socket,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Where.Port),
         Timeout => 10.0);
      Sockets.Send_All (Socket, Preface, Timeout => 10.0);
      Send_Frame (Socket, Settings_Frame, 0, 0, Empty);
   end Connect_Peer;

   procedure Connect_Peer (Socket : in out Sockets.Socket_Type) is
   begin
      Connect_Peer (Socket, Address);
   end Connect_Peer;

   --  Drive one request field section on an established connection and
   --  report what the server made of it: the response body it produced, or
   --  the fact that it refused the stream outright.
   procedure Probe_Stream
     (Socket    : Sockets.Socket_Type;
      Stream_ID : Positive;
      Block     : Stream_Element_Array;
      Response  : out Unbounded_String;
      Refused   : out Boolean)
   is
      Info    : Frame_Info;
      Payload : Stream_Element_Array (1 .. 16_384) := (others => 0);
      Settled : Boolean := False;
   begin
      Response := Null_Unbounded_String;
      Refused := False;
      Send_Frame
        (Socket, Headers_Frame, End_Stream_Flag or End_Headers_Flag,
         Stream_ID, Block);
      while not Settled loop
         Read_Frame_Header (Socket, Info, Wait => 5.0);
         Read_Payload (Socket, Info, Payload, Wait => 5.0);
         if Info.Stream_ID = Stream_ID
           and then Info.Kind = Data_Frame
         then
            for Offset in 1 .. Stream_Element_Offset (Info.Length) loop
               Append
                 (Response, Character'Val (Natural (Payload (Offset))));
            end loop;
            Settled := (Info.Flags and End_Stream_Flag) /= 0;
         elsif Info.Stream_ID = Stream_ID
           and then Info.Kind in Headers_Frame | Continuation_Frame
         then
            Settled := (Info.Flags and End_Stream_Flag) /= 0;
         elsif Info.Stream_ID = Stream_ID
           and then Info.Kind = Reset_Stream_Frame
         then
            Refused := True;
            Settled := True;
         elsif Info.Kind = Goaway_Frame then
            Refused := True;
            Settled := True;
         end if;
      end loop;
   end Probe_Stream;

   --  The same probe on a connection of its own, so a refusal that escalates
   --  to the connection cannot disturb the following probe.
   procedure Probe
     (Block    : Stream_Element_Array;
      Response : out Unbounded_String;
      Refused  : out Boolean)
   is
      Socket : Sockets.Socket_Type;
   begin
      Connect_Peer (Socket);
      Probe_Stream (Socket, 1, Block, Response, Refused);
      Sockets.Close_Socket (Socket);
   end Probe;

begin
   Routes.Get
     ("/sse/{kind}", Events'Access, Name => "sse",
      Policy =>
        (Routing.Default_Route_Policy with delta
           Upgrade => Routing.Allow_SSE));
   Routes.Get ("/{id}", By_Id'Access, Name => "byid");

   Sockets.Create_Socket (Listener);
   Sockets.Set_Socket_Option
     (Listener, Sockets.Socket_Level, (Sockets.Reuse_Address, True));
   Sockets.Bind_Socket
     (Listener,
      Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
   Sockets.Listen_Socket (Listener, Length => 4);
   Address := Sockets.Get_Socket_Name (Listener);

   Sockets.Create_Socket (Router_Listener);
   Sockets.Set_Socket_Option
     (Router_Listener, Sockets.Socket_Level,
      (Sockets.Reuse_Address, True));
   Sockets.Bind_Socket
     (Router_Listener,
      Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
   Sockets.Listen_Socket (Router_Listener, Length => 4);
   Router_Address := Sockets.Get_Socket_Name (Router_Listener);

   declare
      task Server_Task is
         pragma Task_Info (Flyology.Native_Task);
      end Server_Task;

      task body Server_Task is
      begin
         for Session in 1 .. Sessions loop
            declare
               Channel : Connections.Connection;
               Peer    : Sockets.Endpoint;
            begin
               Connections.Accept_Connection
                 (Manager, Listener, Channel, Peer, Timeout => 20.0);
               Engine.Serve
                 (State, Channel, Peer,
                  Timeout => 20.0, Max_Connection_Age => 20.0);
               Connections.Close (Channel);
            exception
               when others => null;
            end;
         end loop;
      end Server_Task;
   begin
      ------------------------------------------------------------------------
      --  Finding 7: DATA on a closed or half-closed-remote stream must be
      --  charged to, and credited back on, the connection receive window.
      ------------------------------------------------------------------------
      Ada.Text_IO.Put_Line
        ("finding 7: closed-stream DATA connection window accounting");
      declare
         Socket  : Sockets.Socket_Type;
         Info    : Frame_Info;
         Payload : Stream_Element_Array (1 .. 16_384) := (others => 0);
         Credit  : Natural := 0;
         Closed_Stream_Bytes : constant Natural := 2 * 16_384;
         Acknowledged : Boolean := False;
      begin
         Connect_Peer (Socket);
         Send_Frame
           (Socket, Headers_Frame, End_Stream_Flag or End_Headers_Flag, 3,
            Request_Block ("GET", "/slow"));
         --  Half-closed (remote): the handler is still running, so the slot
         --  is open with Remote_End set.
         Send_Frame (Socket, Data_Frame, 0, 3, Payload);
         --  Implicitly closed: stream 1 was skipped and is below the highest
         --  client stream, so no slot is ever found for it.
         Send_Frame (Socket, Data_Frame, 0, 1, Payload);
         Send_Frame
           (Socket, Ping_Frame, 0, 0,
            Stream_Element_Array'(1 .. 8 => 16#5A#));
         while not Acknowledged loop
            Read_Frame_Header (Socket, Info, Wait => 5.0);
            Read_Payload (Socket, Info, Payload, Wait => 5.0);
            if Info.Kind = Window_Update_Frame and then Info.Stream_ID = 0 then
               Credit := Credit +
                 Natural (Payload (1) and 16#7F#) * 16#100_0000# +
                 Natural (Payload (2)) * 16#1_0000# +
                 Natural (Payload (3)) * 16#100# + Natural (Payload (4));
            elsif Info.Kind = Ping_Frame
              and then (Info.Flags and Ack_Flag) /= 0
            then
               Acknowledged := True;
            elsif Info.Kind = Goaway_Frame then
               Acknowledged := True;
            end if;
         end loop;
         Ada.Text_IO.Put_Line
           ("  connection credit returned: " & Decimal (Credit) &
              " of " & Decimal (Closed_Stream_Bytes) & " closed-stream bytes");
         Check
           (Credit >= Closed_Stream_Bytes,
            "closed-stream DATA is credited back on the connection window");
         Sockets.Close_Socket (Socket);
      end;

      ------------------------------------------------------------------------
      --  Finding 8: a reused stream slot must start from the advertised
      --  initial receive window, not the previous stream's residue.
      ------------------------------------------------------------------------
      Ada.Text_IO.Put_Line
        ("finding 8: reused stream slot receive window");
      declare
         Socket  : Sockets.Socket_Type;
         Info    : Frame_Info;
         Payload : Stream_Element_Array (1 .. 16_384) := (others => 0);
         Goaway_Error : Integer := -1;
         Responded : Boolean := False;
         Settled : Boolean := False;

         procedure Ping_Round_Trip is
            Seen : Boolean := False;
         begin
            Send_Frame
              (Socket, Ping_Frame, 0, 0,
               Stream_Element_Array'(1 .. 8 => 16#17#));
            while not Seen loop
               Read_Frame_Header (Socket, Info, Wait => 5.0);
               Read_Payload (Socket, Info, Payload, Wait => 5.0);
               Seen := Info.Kind = Ping_Frame
                 and then (Info.Flags and Ack_Flag) /= 0;
            end loop;
         end Ping_Round_Trip;
      begin
         Connect_Peer (Socket);
         Send_Frame
           (Socket, Headers_Frame, End_Headers_Flag, 1,
            Request_Block ("POST", "/hold"));
         Send_Frame
           (Socket, Data_Frame, 0, 1, Payload (1 .. 16_000));
         Send_Frame (Socket, Reset_Stream_Frame, 0, 1, U32 (8));
         --  Let the cancelled handler finish so the slot is reaped and reused.
         delay 0.80;
         Ping_Round_Trip;
         Ping_Round_Trip;
         Send_Frame
           (Socket, Headers_Frame, End_Headers_Flag, 3,
            Request_Block ("POST", "/hold"));
         --  Legal for a fresh stream: 1 000 bytes against the advertised
         --  16 384-byte initial stream receive window.
         Send_Frame
           (Socket, Data_Frame, End_Stream_Flag, 3, Payload (1 .. 1_000));
         while not Settled loop
            Read_Frame_Header (Socket, Info, Wait => 5.0);
            Read_Payload (Socket, Info, Payload, Wait => 5.0);
            if Info.Kind = Goaway_Frame then
               Goaway_Error :=
                 Integer (Natural (Payload (5)) * 16#100_0000# +
                   Natural (Payload (6)) * 16#1_0000# +
                   Natural (Payload (7)) * 16#100# + Natural (Payload (8)));
               Settled := True;
            elsif Info.Kind = Headers_Frame and then Info.Stream_ID = 3 then
               Responded := True;
               Settled := True;
            end if;
         end loop;
         if Goaway_Error >= 0 then
            Ada.Text_IO.Put_Line
              ("  reused slot rejected a legal DATA frame; GOAWAY code " &
                 Decimal (Natural (Goaway_Error)));
         end if;
         Check
           (Responded,
            "a slot reused after a mid-upload reset accepts legal DATA");
         Sockets.Close_Socket (Socket);
      end;

      ------------------------------------------------------------------------
      --  Finding 14: a stream torn down while the connection output is
      --  pinned to its fragmented field section must not freeze the
      --  connection. Nothing else can be written until that block ends, so
      --  the block has to finish and the pin has to clear.
      ------------------------------------------------------------------------
      Ada.Text_IO.Put_Line
        ("finding 14: continuation pin released on a torn-down stream");
      declare
         Socket  : Sockets.Socket_Type;
         Info    : Frame_Info;
         Payload : Stream_Element_Array (1 .. 16_384) := (others => 0);
         Flood_Bytes : Natural := 0;
         Flood_Total : constant Natural := 64 * 16_384;
         Fragments : Natural := 0;
         Completed_Block : Boolean := False;
         Early_Ack : Boolean := False;
         Finished : Boolean := False;
      begin
         Connect_Peer (Socket);
         Send_Frame
           (Socket, Headers_Frame, End_Stream_Flag or End_Headers_Flag, 1,
            Request_Block ("GET", "/flood"));
         Send_Frame (Socket, Window_Update_Frame, 0, 0, U32 (4_000_000));
         Send_Frame (Socket, Window_Update_Frame, 0, 1, U32 (4_000_000));
         Send_Frame
           (Socket, Headers_Frame, End_Stream_Flag or End_Headers_Flag, 3,
            Request_Block ("GET", "/bigheaders"));
         --  Read nothing while the server fills the socket send buffer. The
         --  field section is far larger than that buffer, so the connection
         --  output is still pinned to stream 3 when the reset below is
         --  parsed. The PING that follows proves it: a queued control frame
         --  can only be written once the pin clears, so its acknowledgement
         --  must arrive after the last field-section fragment.
         delay 1.00;
         Send_Frame (Socket, Reset_Stream_Frame, 0, 3, U32 (8));
         Send_Frame
           (Socket, Ping_Frame, 0, 0,
            Stream_Element_Array'(1 .. 8 => 16#33#));
         while not Finished loop
            Read_Frame_Header (Socket, Info, Wait => 5.0);
            Read_Payload (Socket, Info, Payload, Wait => 5.0);
            if Info.Stream_ID = 3
              and then Info.Kind in Headers_Frame | Continuation_Frame
            then
               Fragments := Fragments + 1;
               Completed_Block := Completed_Block
                 or else (Info.Flags and End_Headers_Flag) /= 0;
            elsif Info.Kind = Ping_Frame
              and then (Info.Flags and Ack_Flag) /= 0
            then
               Early_Ack := not Completed_Block;
            elsif Info.Kind = Data_Frame and then Info.Stream_ID = 1 then
               Flood_Bytes := Flood_Bytes + Info.Length;
               Finished := (Info.Flags and End_Stream_Flag) /= 0;
            end if;
         end loop;
         Ada.Text_IO.Put_Line
           ("  flood delivered " & Decimal (Flood_Bytes) & " of " &
              Decimal (Flood_Total) & " bytes across " & Decimal (Fragments) &
              " field-section fragments");
         Check
           (Fragments > 1 and then Completed_Block,
            "the pinned field section is completed, never truncated");
         Check
           (not Early_Ack,
            "the reset was parsed while the connection output was pinned");
         Check
           (Flood_Bytes = Flood_Total,
            "connection output resumes after the pinned stream is released");
         Sockets.Close_Socket (Socket);
      exception
         when Flyology.IO.Timeout_Error =>
            Ada.Text_IO.Put_Line
              ("  connection output froze after " & Decimal (Fragments) &
                 " field-section fragments and " & Decimal (Flood_Bytes) &
                 " of " & Decimal (Flood_Total) & " flood bytes");
            Check (False,
              "connection output resumes after the pinned stream is released");
            Sockets.Close_Socket (Socket);
      end;

      ------------------------------------------------------------------------
      --  Finding 33: RFC 9113 5.1 requires a connection PROTOCOL_ERROR for
      --  any frame other than HEADERS or PRIORITY on an idle stream.
      ------------------------------------------------------------------------
      Ada.Text_IO.Put_Line ("finding 33: idle-stream connection error code");
      declare
         function Idle_Goaway_Code
           (Kind : Stream_Element; Payload : Stream_Element_Array)
            return Natural
         is
            Socket  : Sockets.Socket_Type;
            Info    : Frame_Info;
            Scratch : Stream_Element_Array (1 .. 16_384);
            Code    : Natural := 0;
            Seen    : Boolean := False;
         begin
            Connect_Peer (Socket);
            Send_Frame (Socket, Kind, 0, 7, Payload);
            while not Seen loop
               Read_Frame_Header (Socket, Info, Wait => 5.0);
               Read_Payload (Socket, Info, Scratch, Wait => 5.0);
               if Info.Kind = Goaway_Frame then
                  Code := Natural (Scratch (5)) * 16#100_0000# +
                    Natural (Scratch (6)) * 16#1_0000# +
                    Natural (Scratch (7)) * 16#100# + Natural (Scratch (8));
                  Seen := True;
               end if;
            end loop;
            Sockets.Close_Socket (Socket);
            return Code;
         end Idle_Goaway_Code;

         Data_Code : constant Natural := Idle_Goaway_Code
           (Data_Frame, Stream_Element_Array'(1 .. 64 => 16#61#));
         Update_Code : constant Natural :=
           Idle_Goaway_Code (Window_Update_Frame, U32 (100));
      begin
         Ada.Text_IO.Put_Line
           ("  idle DATA GOAWAY code " & Decimal (Data_Code) &
              ", idle WINDOW_UPDATE GOAWAY code " & Decimal (Update_Code));
         Check (Data_Code = 1, "idle DATA is a connection PROTOCOL_ERROR");
         Check
           (Update_Code = 1,
            "idle WINDOW_UPDATE is a connection PROTOCOL_ERROR");
      end;

      ------------------------------------------------------------------------
      --  Findings 3, 16 and 31: HPACK returns the four request pseudo-header
      --  values as raw octets. :authority is spliced into the header block
      --  the application layer re-parses as CRLF-delimited "Name: Value"
      --  lines, :path becomes the target handed to the log sink, and an
      --  asterisk-form :path reaches a handler for methods HTTP/1 refuses
      --  it for.
      ------------------------------------------------------------------------
      Ada.Text_IO.Put_Line
        ("findings 3, 16, 31: unvalidated HTTP/2 pseudo-header octets");
      declare
         Response : Unbounded_String;
         Refused  : Boolean;
      begin
         Probe
           (Pseudo_Block
              ("GET", "/probe",
               "localhost" & CR & LF & "Transfer-Encoding: chunked"),
            Response, Refused);
         Ada.Text_IO.Put_Line
           ("  spliced :authority yielded " &
              (if Refused then "a refused stream"
               else '"' & To_String (Response) & '"'));
         Check
           (Refused,
            "an :authority carrying CR LF is refused");
         Check
           (Index (Response, "te=chunked") = 0,
            "no Transfer-Encoding is injected through :authority");

         Probe
           (Pseudo_Block
              ("GET", "/x" & CR & LF & "forged-log-line", "localhost"),
            Response, Refused);
         Ada.Text_IO.Put_Line
           ("  control-byte :path yielded " &
              (if Refused then "a refused stream"
               else '"' & To_String (Response) & '"'));
         Check (Refused, "a :path carrying CR LF is refused");
         Check
           (Index (Response, "forged-log-line") = 0,
            "no forged line reaches the request target");

         Probe (Pseudo_Block ("GET", "*", "localhost"), Response, Refused);
         Ada.Text_IO.Put_Line
           ("  asterisk-form GET yielded " &
              (if Refused then "a refused stream"
               else '"' & To_String (Response) & '"'));
         Check (Refused, "asterisk-form :path is refused for GET");

         Probe
           (Pseudo_Block ("OPTIONS", "*", "localhost"), Response, Refused);
         Check
           (not Refused and then Index (Response, "target=*") /= 0,
            "asterisk-form :path is still admitted for OPTIONS");
      end;
   end;

   ---------------------------------------------------------------------------
   --  Finding 4: the HTTP/2 stream backend re-implements SSE serialization
   --  and drops the newline and UTF-8 validation the HTTP/1.1 writer
   --  applies, so an event name, an id, or a comment splits the stream into
   --  attacker-chosen events. Finding 31 reaches its parameterized route
   --  only through the router, so both share this session.
   ---------------------------------------------------------------------------
   declare
      task Router_Task is
         pragma Task_Info (Flyology.Native_Task);
      end Router_Task;

      task body Router_Task is
         Channel : aliased Connections.Connection;
         Peer    : Sockets.Endpoint;
      begin
         Connections.Accept_Connection
           (Router_Manager, Router_Listener, Channel, Peer, Timeout => 20.0);
         Routes.Serve
           (State, Channel, Peer,
            Mode => Flyology.HTTP.Server.HTTP_2_Only,
            Timeout => 20.0, Max_Connection_Age => 20.0);
         Connections.Close (Channel);
      exception
         when others => null;
      end Router_Task;

      Socket   : Sockets.Socket_Type;
      Response : Unbounded_String;
      Refused  : Boolean;

      Forged : constant String := LF & "data: forged";
   begin
      Ada.Text_IO.Put_Line
        ("finding 4: SSE field validation on the HTTP/2 backend");
      Connect_Peer (Socket, Router_Address);

      Probe_Stream
        (Socket, 1, Request_Block ("GET", "/sse/event"), Response, Refused);
      Ada.Text_IO.Put_Line
        ("  newline event name produced " &
           (if Refused then "a refused stream"
            else Decimal (Length (Response)) & " body bytes"));
      Check
        (Index (Response, Forged) = 0,
         "a newline in an SSE event name cannot forge a data line");

      Probe_Stream
        (Socket, 3, Request_Block ("GET", "/sse/id"), Response, Refused);
      Check
        (Index (Response, Forged) = 0,
         "a newline in an SSE id cannot forge a data line");

      Probe_Stream
        (Socket, 5, Request_Block ("GET", "/sse/comment"), Response, Refused);
      Ada.Text_IO.Put_Line
        ("  newline comment produced """ & To_String (Response) & '"');
      Check
        (Index (Response, Forged) = 0,
         "a newline in an SSE comment cannot forge a data line");

      Probe_Stream
        (Socket, 7, Request_Block ("GET", "/sse/utf8"), Response, Refused);
      Check
        (Index (Response, String'(1 => Character'Val (16#FF#))) = 0,
         "invalid UTF-8 never reaches the SSE body");

      Probe_Stream
        (Socket, 9, Request_Block ("GET", "/sse/ok"), Response, Refused);
      Check
        (not Refused and then Index (Response, "event: ok") /= 0
           and then Index (Response, "data: hello") /= 0,
         "a well-formed SSE event is still served over HTTP/2");

      Probe_Stream
        (Socket, 11, Pseudo_Block ("GET", "*", "localhost"),
         Response, Refused);
      Ada.Text_IO.Put_Line
        ("  routed asterisk-form GET yielded " &
           (if Refused then "a refused stream"
            else '"' & To_String (Response) & '"'));
      Check
        (Refused and then Index (Response, "id=*") = 0,
         "asterisk-form :path never binds a route parameter");
      Sockets.Close_Socket (Socket);
   end;

   Sockets.Close_Socket (Router_Listener);
   Sockets.Close_Socket (Listener);
   if Failures /= 0 then
      raise Program_Error with
        "HTTP/2 server audit regressions: " & Decimal (Failures);
   end if;
   Ada.Text_IO.Put_Line ("HTTP/2 server audit passed");
end HTTP2_Server_Audit;
