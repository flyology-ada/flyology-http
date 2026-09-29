with Ada.Streams;
with Flyology;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.HTTP_2;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with H2_Wire;
with Repro_Support;

--  H2-9.  After the server itself resets a stream, the stream is closed.
--  RFC 9113 5.1, closed: "An endpoint MUST NOT send frames other than
--  PRIORITY on a closed stream."  For a stream the endpoint reset while it
--  was open or half-closed (local), the same section says: "An endpoint that
--  sends a RST_STREAM frame on a stream that is in the 'open' or
--  'half-closed (local)' state could receive any type of frame. ... An
--  endpoint MUST minimally process and then discard any frames it receives
--  in this state."  Publish_Data's closed-stream branches
--  (server-http_2.adb:618-631) do not separate that case from half-closed
--  (remote), so every in-flight DATA frame draws another RST_STREAM.
procedure Repro_H2_9 is
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
      --  A fixed-length response the handler then overruns.  The engine
      --  resets the stream, exactly as tests/http2_server_audit.adb's
      --  "/fixed-overrun" case asserts.
      X.Begin_Stream (200, "text/plain", Content_Length => 1);
      X.Write_Chunk ("xx");
   end Handle;

   Manager  : aliased Connections.Server (Capacity => 1);
   Listener : Sockets.Socket_Type;
   Address  : Sockets.Endpoint;
   State    : Context;

   Chunk : constant Stream_Element_Array (1 .. 100) :=
     (others => Character'Pos ('d'));
begin
   Note ("H2-9: DATA on a stream the server itself reset");
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
      Resets_Before : Natural := 0;
      Resets_After  : Natural := 0;
      Credits_After : Natural := 0;
      Frames_Seen   : Natural := 0;
   begin
      Connect_Peer (Socket, Address);
      --  No END_STREAM: the request half stays open so DATA is legal to
      --  send until the server closes the stream.
      Send_Frame
        (Socket, Headers_Frame, End_Headers_Flag, 1,
         Request_Block ("POST", "/fixed-overrun"));
      --  Wait for the server's own RST_STREAM.
      begin
         loop
            Read_Frame_Header (Socket, Info, Wait => 6.0);
            Read_Payload (Socket, Info, Payload, Wait => 6.0);
            Note
              ("  <- " & Frame_Name (Info.Kind) & " stream" &
               Natural'Image (Info.Stream_ID) & " length" &
               Natural'Image (Info.Length));
            exit when Info.Kind = Reset_Stream_Frame
              and then Info.Stream_ID = 1;
            exit when Info.Kind = Goaway_Frame;
         end loop;
         Resets_Before := 1;
      exception
         when others => null;
      end;
      Check
        (Resets_Before = 1,
         "the server resets the overrun stream (precondition)");

      --  Three DATA frames a peer may legitimately already have in flight.
      for Index in 1 .. 3 loop
         Send_Frame (Socket, Data_Frame, 0, 1, Chunk);
      end loop;
      Note ("  sent three DATA frames on the closed stream 1");
      begin
         loop
            Read_Frame_Header (Socket, Info, Wait => 2.0);
            Read_Payload (Socket, Info, Payload, Wait => 2.0);
            Frames_Seen := Frames_Seen + 1;
            Note
              ("  <- " & Frame_Name (Info.Kind) & " stream" &
               Natural'Image (Info.Stream_ID) & " length" &
               Natural'Image (Info.Length));
            if Info.Kind = Reset_Stream_Frame and then Info.Stream_ID = 1
            then
               Resets_After := Resets_After + 1;
            elsif Info.Kind = Window_Update_Frame then
               Credits_After := Credits_After + 1;
            end if;
            exit when Frames_Seen > 12;
         end loop;
      exception
         when others => Note ("  (no further frames)");
      end;
      Note
        ("  extra RST_STREAM frames:" & Natural'Image (Resets_After) &
         ", WINDOW_UPDATE frames:" & Natural'Image (Credits_After));
      Check
        (Resets_After = 0,
         "no further RST_STREAM is sent on the closed stream");
      Sockets.Close_Socket (Socket);
   end;

   Sockets.Close_Socket (Listener);
   Finish;
end Repro_H2_9;
