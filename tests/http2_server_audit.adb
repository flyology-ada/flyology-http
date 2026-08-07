--  Regression coverage for the 2026-08-07 audit findings in the HTTP/2 server
--  engine. Every fix lands its failing reproduction here before the fix
--  itself. The peer speaks raw HTTP/2 frames over a loopback socket so that
--  connection-level flow control and output scheduling stay observable.
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.HTTP_2;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Interfaces;

procedure HTTP2_Server_Audit is
   use Ada.Streams;
   use type Interfaces.Unsigned_32;
   package App renames Flyology.HTTP.Server.Applications;
   package Connections renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;

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

   procedure Handle (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      if X.Request_Target = "/slow" then
         delay 0.30;
         X.Text (200, "slow");
      else
         X.Text (200, "ok");
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
   Settings_Frame      : constant Stream_Element := 16#04#;
   Ping_Frame          : constant Stream_Element := 16#06#;
   Goaway_Frame        : constant Stream_Element := 16#07#;
   Window_Update_Frame : constant Stream_Element := 16#08#;
   End_Stream_Flag     : constant Stream_Element := 16#01#;
   Ack_Flag            : constant Stream_Element := 16#01#;
   End_Headers_Flag    : constant Stream_Element := 16#04#;

   Manager  : aliased Connections.Server (Capacity => 1);
   Listener : Sockets.Socket_Type;
   Address  : Sockets.Endpoint;
   State    : Context;
   Sessions : constant := 1;

   procedure Connect_Peer (Socket : in out Sockets.Socket_Type) is
   begin
      Sockets.Create_Socket (Socket);
      Sockets.Connect
        (Socket,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Address.Port),
         Timeout => 10.0);
      Sockets.Send_All (Socket, Preface, Timeout => 10.0);
      Send_Frame (Socket, Settings_Frame, 0, 0, Empty);
   end Connect_Peer;

begin
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

   end;

   Sockets.Close_Socket (Listener);
   if Failures /= 0 then
      raise Program_Error with
        "HTTP/2 server audit regressions: " & Decimal (Failures);
   end if;
   Ada.Text_IO.Put_Line ("HTTP/2 server audit passed");
end HTTP2_Server_Audit;
