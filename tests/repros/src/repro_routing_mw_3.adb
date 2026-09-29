--  ROUTING-MW-3. RFC 9113 Section 8.3.1 defines ":path" as "the path and
--  query parts of the target URI (the absolute-path production and,
--  optionally, a '?' character followed by the query production)", and
--  Section 8.3 requires: "Endpoints MUST treat a request or response that
--  contains undefined or invalid pseudo-header fields as malformed
--  (Section 8.1.1)", which Section 8.1.1 makes "a stream error
--  (Section 5.4.2) of type PROTOCOL_ERROR".  An absolute-form URI is not an
--  absolute-path, so an HTTP/2 :path of "http://host/admin/users" is
--  malformed.
--
--  The only :path checks on the HTTP/2 admission path
--  (http_2.adb:2341-2349) never require a leading '/', so routing.adb's
--  Raw_Path, written for the HTTP/1 absolute form (RFC 9112 Section 3.2.2),
--  strips the embedded authority and routes what follows.  HTTP/3 rejects
--  the same value (http_3_header_policy.adb:299-304) and HTTP/1 validates
--  the embedded authority against Host (server.adb:826-848).
--
--  This program asserts the RFC-required rejection on HTTP/2 and records
--  the HTTP/1 contrast.
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology;
with Flyology.Cancellation;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Requests;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Interfaces;
with Repro_Support;

procedure Repro_Routing_MW_3 is
   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use Repro_Support;
   use type Interfaces.Unsigned_32;

   package HTTP_Server renames Flyology.HTTP.Server;
   package App renames Flyology.HTTP.Server.Applications;
   package Connections renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;

   Test_Peer : constant Sockets.Endpoint :=
     Sockets.Network_Endpoint (Sockets.Loopback_IPv4, 12_345);

   --  In-memory transport for the HTTP/1 contrast.
   type Memory_Transport is limited new HTTP_Server.Transport with record
      Input  : Unbounded_String;
      Output : Unbounded_String;
   end record;

   overriding procedure Receive
     (Item    : in out Memory_Transport;
      Data    : out Stream_Element_Array;
      Last    : out Stream_Element_Offset;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);

   overriding procedure Send_All
     (Item    : in out Memory_Transport;
      Data    : Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);

   overriding procedure Receive
     (Item    : in out Memory_Transport;
      Data    : out Stream_Element_Array;
      Last    : out Stream_Element_Offset;
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
         Data (Data'First + Stream_Element_Offset (Index - 1)) :=
           Stream_Element (Character'Pos (Available (Index)));
      end loop;
      Last := Data'First + Stream_Element_Offset (Count - 1);
      Item.Input :=
        (if Count = Available'Length then Null_Unbounded_String
         else To_Unbounded_String (Available (Count + 1 .. Available'Last)));
   end Receive;

   overriding procedure Send_All
     (Item    : in out Memory_Transport;
      Data    : Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
   begin
      for Value of Data loop
         Append (Item.Output, Character'Val (Value));
      end loop;
   end Send_All;

   type Context is limited null record;

   package Routing is new Flyology.HTTP.Server.Routing (Context);

   procedure Report
     (State : in out Context;
      X     : in out App.Exchange)
   is
      pragma Unreferenced (State);
   begin
      X.Text
        (200,
         "route=" & X.Route_Name & " path=" & X.Path
         & " x=" & Flyology.HTTP.Server.Requests.Query (X, "x"));
   end Report;

   Routes : Routing.Router
     (Capacity => 4, Slashes => Routing.Strict_Slashes);
   State  : Context;

   --  Raw HTTP/2 peer ------------------------------------------------------

   Preface : constant Stream_Element_Array :=
     (Character'Pos ('P'), Character'Pos ('R'), Character'Pos ('I'),
      Character'Pos (' '), Character'Pos ('*'), Character'Pos (' '),
      Character'Pos ('H'), Character'Pos ('T'), Character'Pos ('T'),
      Character'Pos ('P'), Character'Pos ('/'), Character'Pos ('2'),
      Character'Pos ('.'), Character'Pos ('0'), 13, 10, 13, 10,
      Character'Pos ('S'), Character'Pos ('M'), 13, 10, 13, 10);

   Empty : constant Stream_Element_Array (1 .. 0) := (others => 0);

   Data_Frame         : constant Stream_Element := 16#00#;
   Headers_Frame      : constant Stream_Element := 16#01#;
   Reset_Stream_Frame : constant Stream_Element := 16#03#;
   Settings_Frame     : constant Stream_Element := 16#04#;
   Goaway_Frame       : constant Stream_Element := 16#07#;
   Continuation_Frame : constant Stream_Element := 16#09#;
   End_Stream_Flag    : constant Stream_Element := 16#01#;
   End_Headers_Flag   : constant Stream_Element := 16#04#;

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

   function Text_Bytes (Value : String) return Stream_Element_Array is
      Result : Stream_Element_Array (1 .. Value'Length);
   begin
      for Offset in 0 .. Value'Length - 1 loop
         Result (Result'First + Stream_Element_Offset (Offset)) :=
           Stream_Element (Character'Pos (Value (Value'First + Offset)));
      end loop;
      return Result;
   end Text_Bytes;

   --  One HPACK literal field without indexing and with a new name.
   function Literal (Name, Value : String) return Stream_Element_Array is
     ((1 => 16#00#, 2 => Stream_Element (Name'Length)) & Text_Bytes (Name) &
      (1 => Stream_Element (Value'Length)) & Text_Bytes (Value));

   function Request_Block (Path : String) return Stream_Element_Array is
     (Literal (":method", "GET") & Literal (":scheme", "http") &
      Literal (":authority", "localhost") & Literal (":path", Path));

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

   Manager  : aliased Connections.Server (Capacity => 1);
   Listener : Sockets.Socket_Type;
   Address  : Sockets.Endpoint;
   Sessions : constant := 3;

   procedure Probe
     (Path     : String;
      Response : out Unbounded_String;
      Refused  : out Boolean)
   is
      Socket  : Sockets.Socket_Type;
      Info    : Frame_Info;
      Payload : Stream_Element_Array (1 .. 16_384) := (others => 0);
      Settled : Boolean := False;
   begin
      Response := Null_Unbounded_String;
      Refused := False;
      Sockets.Create_Socket (Socket);
      Sockets.Connect
        (Socket,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Address.Port),
         Timeout => 10.0);
      Sockets.Send_All (Socket, Preface, Timeout => 10.0);
      Send_Frame (Socket, Settings_Frame, 0, 0, Empty);
      Send_Frame
        (Socket, Headers_Frame, End_Stream_Flag or End_Headers_Flag, 1,
         Request_Block (Path));
      while not Settled loop
         Read_Frame_Header (Socket, Info, Wait => 5.0);
         Read_Payload (Socket, Info, Payload, Wait => 5.0);
         if Info.Stream_ID = 1 and then Info.Kind = Data_Frame then
            for Offset in 1 .. Stream_Element_Offset (Info.Length) loop
               Append (Response, Character'Val (Natural (Payload (Offset))));
            end loop;
            Settled := (Info.Flags and End_Stream_Flag) /= 0;
         elsif Info.Stream_ID = 1
           and then Info.Kind in Headers_Frame | Continuation_Frame
         then
            Settled := (Info.Flags and End_Stream_Flag) /= 0;
         elsif Info.Stream_ID = 1
           and then Info.Kind = Reset_Stream_Frame
         then
            Refused := True;
            Settled := True;
         elsif Info.Kind = Goaway_Frame then
            Refused := True;
            Settled := True;
         end if;
      end loop;
      Sockets.Close_Socket (Socket);
   end Probe;

   --  HTTP/1 contrast on the in-memory transport.
   function HTTP_1_Answer (Target, Host : String) return String is
      Wire : aliased Memory_Transport;
   begin
      Wire.Input := To_Unbounded_String
        ("GET " & Target & " HTTP/1.1" & CRLF
         & "Host: " & Host & CRLF
         & "Connection: close" & CRLF & CRLF);
      declare
         Client : aliased HTTP_Server.Connection (Wire'Access);
      begin
         Routes.Serve (State, Client, Test_Peer);
      end;
      return To_String (Wire.Output);
   end HTTP_1_Answer;

   function Status (Output : String) return String is
     (if Output'Length >= 12
      then Output (Output'First + 9 .. Output'First + 11) else "---");
begin
   Routes.Get ("/admin/users", Report'Access, Name => "admin.users");
   Routes.Get ("/", Report'Access, Name => "root");

   Sockets.Create_Socket (Listener);
   Sockets.Set_Socket_Option
     (Listener, Sockets.Socket_Level, (Sockets.Reuse_Address, True));
   Sockets.Bind_Socket
     (Listener,
      Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
   Sockets.Listen_Socket (Listener, Length => 4);
   Address := Sockets.Get_Socket_Name (Listener);

   declare
      task Server_Task is
         pragma Task_Info (Flyology.Native_Task);
      end Server_Task;

      task body Server_Task is
      begin
         for Session in 1 .. Sessions loop
            pragma Unreferenced (Session);
            declare
               Channel : aliased Connections.Connection;
               Peer    : Sockets.Endpoint;
            begin
               Connections.Accept_Connection
                 (Manager, Listener, Channel, Peer, Timeout => 20.0);
               Routes.Serve
                 (State, Channel, Peer,
                  Mode               => HTTP_Server.HTTP_2_Only,
                  Timeout            => 20.0,
                  Max_Connection_Age => 20.0);
               Connections.Close (Channel);
            exception
               when others => null;
            end;
         end loop;
      exception
         when others => null;
      end Server_Task;

      Response : Unbounded_String;
      Refused  : Boolean;
   begin
      --  Control: the legal origin-form target is served.
      Probe ("/admin/users", Response, Refused);
      Note ("control :path=/admin/users -> "
            & (if Refused then "refused" else To_String (Response)));
      Check (not Refused and then
             Ada.Strings.Fixed.Index
               (To_String (Response), "route=admin.users") /= 0,
             "control: origin-form :path reaches its route");

      --  The finding: the absolute form is malformed per RFC 9113 8.3.1.
      Probe ("http://localhost/admin/users", Response, Refused);
      Note (":path=http://localhost/admin/users -> "
            & (if Refused then "refused" else To_String (Response)));
      Check (Refused,
             "absolute-form :path is treated as malformed (RFC 9113 "
             & "Sections 8.3, 8.3.1, 8.1.1)");

      --  The same shape with the query delimiter first: the embedded
      --  authority is discarded and the query is taken from the whole value.
      Probe ("http://localhost?x=1/admin", Response, Refused);
      Note (":path=http://localhost?x=1/admin -> "
            & (if Refused then "refused" else To_String (Response)));
      Check (Refused,
             "absolute-form :path with a query is treated as malformed");
   end;

   --  HTTP/1 contrast: the same authority confusion is rejected there.
   declare
      Legit : constant String :=
        HTTP_1_Answer ("http://localhost/admin/users", "localhost");
      Split : constant String :=
        HTTP_1_Answer ("http://evil.example/admin/users", "localhost");
   begin
      Note ("HTTP/1 absolute form agreeing with Host -> " & Status (Legit));
      Note ("HTTP/1 absolute form disagreeing with Host -> "
            & Status (Split));
      Check (Status (Legit) = "200",
             "HTTP/1 absolute form with a matching Host is served");
      Check (Status (Split) = "400",
             "HTTP/1 rejects an absolute form whose authority conflicts "
             & "with Host");
   end;

   Sockets.Close_Socket (Listener);
   Finish;
end Repro_Routing_MW_3;
