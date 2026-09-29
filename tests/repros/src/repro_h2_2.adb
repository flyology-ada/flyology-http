with Ada.Command_Line;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.HTTP_2;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with H2_Wire;
with Repro_Support;

--  H2-2.  The server advertises SETTINGS_INITIAL_WINDOW_SIZE = 16384 and
--  enforces it from the first DATA frame.  RFC 9113 6.9.3: "A receiver that
--  wishes to use a smaller flow-control window than the current size can
--  send a new SETTINGS frame.  However, the receiver MUST be prepared to
--  receive data that exceeds this window size, since the sender might send
--  data that exceeds the lower limit prior to processing the SETTINGS
--  frame."  The same section permits at most a stream error
--  (RST_STREAM(FLOW_CONTROL_ERROR)) for the affected stream, never a
--  connection error.
--
--  The peer here behaves exactly as a conforming sender that has not yet
--  processed the server's SETTINGS: it uses the protocol default 65535
--  stream window and writes 20480 octets of DATA in one burst.  Stock
--  curl 8.7.1/nghttp2 1.68.1 emits the same burst; run this program with
--  the single argument "serve" to hold a loopback HTTP/2 server open for
--  30 seconds and point curl at the port it prints.
procedure Repro_H2_2 is
   use Ada.Streams;
   use Repro_Support;
   use H2_Wire;
   package App renames Flyology.HTTP.Server.Applications;
   package Connections renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;

   function Decimal (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   type Context is limited null record;

   procedure Handle (State : in out Context; X : in out App.Exchange);

   package Engine is new Flyology.HTTP.Server.HTTP_2 (Context, Handle);

   procedure Handle (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      --  Hold the response so the burst is parsed while the stream is open
      --  and the handler has returned no credit of its own.
      delay 1.0;
      X.Text (200, "ok");
   end Handle;

   Manager  : aliased Connections.Server (Capacity => 1);
   Listener : Sockets.Socket_Type;
   Address  : Sockets.Endpoint;
   State    : Context;

   Serve_Mode : constant Boolean :=
     Ada.Command_Line.Argument_Count >= 1
       and then Ada.Command_Line.Argument (1) = "serve";

   Head : constant Stream_Element_Array :=
     Request_Block ("POST", "/upload") &
     Literal ("content-length", "20480");

   First_Burst  : constant Stream_Element_Array (1 .. 16_384) :=
     (others => Character'Pos ('u'));
   Second_Burst : constant Stream_Element_Array (1 .. 4_096) :=
     (others => Character'Pos ('u'));
begin
   Address := Listen_Loopback (Listener);

   if Serve_Mode then
      --  Out-of-band mode for a stock peer: hold one HTTP/2 connection.
      Ada.Text_IO.Put_Line ("PORT=" & Decimal (Natural (Address.Port)));
      Ada.Text_IO.Flush;
      declare
         Channel : Connections.Connection;
         Peer    : Sockets.Endpoint;
      begin
         Connections.Accept_Connection
           (Manager, Listener, Channel, Peer, Timeout => 30.0);
         Engine.Serve
           (State, Channel, Peer,
            Timeout => 25.0, Max_Connection_Age => 25.0);
         Connections.Close (Channel);
      exception
         when others => null;
      end;
      Sockets.Close_Socket (Listener);
      return;
   end if;

   Note ("H2-2: over-window DATA before the peer processed our SETTINGS");

   declare
      task Server_Task is
         pragma Task_Info (Flyology.Native_Task);
      end Server_Task;

      task body Server_Task is
         Channel : Connections.Connection;
         Peer    : Sockets.Endpoint;
      begin
         Connections.Accept_Connection
           (Manager, Listener, Channel, Peer, Timeout => 20.0);
         Engine.Serve
           (State, Channel, Peer,
            Timeout => 15.0, Max_Connection_Age => 15.0);
         Connections.Close (Channel);
      exception
         when others => null;
      end Server_Task;

      Socket  : Sockets.Socket_Type;
      Info    : Frame_Info;
      Payload : Stream_Element_Array (1 .. 16_384) := (others => 0);
      Saw_Goaway  : Boolean := False;
      Goaway_Code : Natural := 0;
      Saw_Reset   : Boolean := False;
      Saw_Status  : Boolean := False;
      Frames_Seen : Natural := 0;
   begin
      --  Connect and announce our own (empty) SETTINGS without ever reading
      --  the server's, exactly as a peer that has not processed it yet.
      Connect_Peer (Socket, Address);
      Send_Frame (Socket, Headers_Frame, End_Headers_Flag, 1, Head);
      Send_Frame (Socket, Data_Frame, 0, 1, First_Burst);
      Send_Frame (Socket, Data_Frame, End_Stream_Flag, 1, Second_Burst);

      begin
         loop
            Read_Frame_Header (Socket, Info, Wait => 4.0);
            Read_Payload (Socket, Info, Payload, Wait => 4.0);
            Frames_Seen := Frames_Seen + 1;
            Note
              ("  <- " & Frame_Name (Info.Kind) & " stream" &
               Natural'Image (Info.Stream_ID) & " length" &
               Natural'Image (Info.Length));
            if Info.Kind = Goaway_Frame then
               Saw_Goaway := True;
               if Info.Length >= 8 then
                  Goaway_Code :=
                    Natural (Payload (5)) * 16#100_0000# +
                    Natural (Payload (6)) * 16#1_0000# +
                    Natural (Payload (7)) * 16#100# +
                    Natural (Payload (8));
               end if;
               exit;
            elsif Info.Kind = Reset_Stream_Frame then
               Saw_Reset := True;
            elsif Info.Kind = Headers_Frame and then Info.Stream_ID = 1 then
               Saw_Status := True;
            elsif Info.Kind = Data_Frame
              and then Info.Stream_ID = 1
              and then (Info.Flags and End_Stream_Flag) /= 0
            then
               exit;
            end if;
            exit when Frames_Seen > 40;
         end loop;
      exception
         when others =>
            Note ("  (no further frames)");
      end;

      if Saw_Goaway then
         Note ("  GOAWAY error code" & Natural'Image (Goaway_Code) &
               " (0x3 is FLOW_CONTROL_ERROR, 0x1 is PROTOCOL_ERROR)");
      end if;
      if Saw_Reset then
         Note ("  the server reset the stream, which RFC 9113 6.9.3 permits");
      end if;
      if Saw_Status then
         Note ("  the server answered the raw peer's request");
      end if;
      Check
        (not Saw_Goaway,
         "20480 octets of DATA sent before the peer could process the " &
         "server's reduced SETTINGS is not a connection error");
      Sockets.Close_Socket (Socket);
   end;

   Sockets.Close_Socket (Listener);
   Finish;
end Repro_H2_2;
