with Ada.Streams;
with Flyology;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.HTTP_2;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with H2_Wire;
with Repro_Support;

--  H2-8.  WINDOW_UPDATE with a zero increment on an *idle* stream.
--  RFC 9113 5.1, idle: "Receiving any frame other than HEADERS or PRIORITY
--  on a stream in this state MUST be treated as a connection error
--  (Section 5.4.1) of type PROTOCOL_ERROR."  RFC 9113 6.4: "RST_STREAM
--  frames MUST NOT be sent for a stream in the 'idle' state."
--
--  Window_Update reports Stream_Failure for any non-zero stream with a zero
--  increment (server-http_2.adb:1217-1221); the frame handler then calls
--  Reject_Stream before the idle check (:2533-2541), and Reject_Stream with
--  no slot advances Last_Client_Stream, queues RST_STREAM on the idle
--  stream, and reports Accepted (:1277-1286), so no connection error
--  follows.  h2spec 2.6.0 covers neither combination: its 5.1/3 sends
--  WriteWindowUpdate(1, 100) and its 6.9/2 opens stream 1 with HEADERS
--  first, so the stream is not idle.
procedure Repro_H2_8 is
   use Ada.Streams;
   use Repro_Support;
   use H2_Wire;
   package App renames Flyology.HTTP.Server.Applications;
   package Connections renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;

   type Context is limited null record;

   procedure Handle (State : in out Context; X : in out App.Exchange);

   package Engine is new Flyology.HTTP.Server.HTTP_2 (Context, Handle);

   procedure Handle (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      X.Text (200, "ok");
   end Handle;

   Manager  : aliased Connections.Server (Capacity => 1);
   Listener : Sockets.Socket_Type;
   Address  : Sockets.Endpoint;
   State    : Context;
begin
   Note ("H2-8: WINDOW_UPDATE with increment 0 on an idle stream");
   Address := Listen_Loopback (Listener);

   declare
      task Server_Task is
         pragma Task_Info (Flyology.Native_Task);
      end Server_Task;

      task body Server_Task is
         Channel : Connections.Connection;
         Peer    : Sockets.Endpoint;
      begin
         Connections.Accept_Connection
           (Manager, Listener, Channel, Peer, Timeout => 15.0);
         Engine.Serve
           (State, Channel, Peer,
            Timeout => 10.0, Max_Connection_Age => 10.0);
         Connections.Close (Channel);
      exception
         when others => null;
      end Server_Task;

      Socket  : Sockets.Socket_Type;
      Info    : Frame_Info;
      Payload : Stream_Element_Array (1 .. 16_384) := (others => 0);
      Saw_Goaway : Boolean := False;
      Reset_Idle : Boolean := False;
      Served     : Boolean := False;
      Survived   : Boolean := False;
      Frames_Seen : Natural := 0;
   begin
      Connect_Peer (Socket, Address);
      --  Stream 5 has never carried a HEADERS frame, so it is idle.
      Send_Frame (Socket, Window_Update_Frame, 0, 5, U32 (0));
      --  A PING settles whether the connection was failed at all: a server
      --  that answered with GOAWAY never gets to the PING ACK.
      Send_Frame
        (Socket, Ping_Frame, 0, 0,
         Stream_Element_Array'(1 .. 8 => 16#5A#));
      begin
         loop
            Read_Frame_Header (Socket, Info, Wait => 5.0);
            Read_Payload (Socket, Info, Payload, Wait => 5.0);
            Frames_Seen := Frames_Seen + 1;
            Note
              ("  <- " & Frame_Name (Info.Kind) & " stream" &
               Natural'Image (Info.Stream_ID) & " length" &
               Natural'Image (Info.Length));
            if Info.Kind = Goaway_Frame then
               Saw_Goaway := True;
               exit;
            elsif Info.Kind = Reset_Stream_Frame
              and then Info.Stream_ID = 5
            then
               Reset_Idle := True;
            elsif Info.Kind = Ping_Frame
              and then (Info.Flags and Ack_Flag) /= 0
            then
               Survived := True;
               exit;
            end if;
            exit when Frames_Seen > 20;
         end loop;
      exception
         when others => Note ("  (no further frames)");
      end;
      if Reset_Idle then
         Note ("  the server sent RST_STREAM on the idle stream 5");
      end if;
      if Survived then
         Note ("  the server answered the PING, so the connection survived");
      end if;
      Check
        (Saw_Goaway,
         "a zero-increment WINDOW_UPDATE on an idle stream is a connection " &
         "error");
      Check
        (not Reset_Idle,
         "the server never sends RST_STREAM for a stream in the idle state");

      --  Consequence: Reject_Stream advanced Last_Client_Stream to 5, so a
      --  legitimate later request on stream 3 is now refused outright.
      if Survived then
         Send_Frame
           (Socket, Headers_Frame, End_Stream_Flag or End_Headers_Flag, 3,
            Request_Block ("GET", "/after"));
         begin
            loop
               Read_Frame_Header (Socket, Info, Wait => 5.0);
               Read_Payload (Socket, Info, Payload, Wait => 5.0);
               Note
                 ("  <- " & Frame_Name (Info.Kind) & " stream" &
                  Natural'Image (Info.Stream_ID) & " length" &
                  Natural'Image (Info.Length));
               if Info.Kind = Headers_Frame and then Info.Stream_ID = 3 then
                  Served := True;
                  exit;
               elsif Info.Kind = Goaway_Frame then
                  exit;
               end if;
            end loop;
         exception
            when others => null;
         end;
         Check
           (Served,
            "a legitimate request on stream 3 is still served afterwards");
      end if;
      Sockets.Close_Socket (Socket);
   end;

   Sockets.Close_Socket (Listener);
   Finish;
end Repro_H2_8;
