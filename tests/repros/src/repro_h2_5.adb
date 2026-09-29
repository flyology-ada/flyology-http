with Ada.Streams;
with Ada.Strings.Fixed;
with Flyology;
with Flyology.HTTP;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with H2_Wire;
with Repro_Support;

--  H2-5.  A route body limit crossed mid-stream sets Body_Limit_Failure on
--  the HTTP/2 stream (src/flyology-http-server-http_2.adb:644-651).
--  Queue_Response_Head then refuses every response for that stream because
--  it tests Failure /= No_Failure (:839-846), so the routing layer's
--  X.Problem (413, ...) raises Flyology.IO.Device_Error, the handler task's
--  fallback 500 fails the same way, and the stream is reset with
--  INTERNAL_ERROR.  The same router over HTTP/1.1 delivers the 413, which
--  this spike checks as a control.
procedure Repro_H2_5 is
   use Ada.Streams;
   use Repro_Support;
   use H2_Wire;
   package App renames Flyology.HTTP.Server.Applications;
   package Connections renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;

   function Decimal (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   type Context is limited null record;

   procedure Upload (State : in out Context; X : in out App.Exchange);

   package Routing is new Flyology.HTTP.Server.Routing (Context);

   Routes : Routing.Router (Capacity => 1, Slashes => Routing.Strict_Slashes);

   procedure Upload (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      X.Text (200, "accepted");
   end Upload;

   State : Context;

   H2_Manager  : aliased Connections.Server (Capacity => 1);
   H2_Listener : Sockets.Socket_Type;
   H2_Address  : Sockets.Endpoint;

   H1_Manager  : aliased Connections.Server (Capacity => 1);
   H1_Listener : Sockets.Socket_Type;
   H1_Address  : Sockets.Endpoint;

   Block : constant Stream_Element_Array (1 .. 4_096) :=
     (others => Character'Pos ('b'));
begin
   Note ("H2-5: a body limit crossed mid-stream must still answer 413");
   Routes.Post
     ("/upload", Upload'Access, Name => "upload",
      Policy =>
        (Routing.Default_Route_Policy with delta
           Body_Handling => App.Buffer_Body,
           Max_Body      => 4_096));

   H2_Address := Listen_Loopback (H2_Listener);
   H1_Address := Listen_Loopback (H1_Listener);

   declare
      task H2_Task is
         pragma Task_Info (Flyology.Native_Task);
      end H2_Task;

      task body H2_Task is
         Channel : aliased Connections.Connection;
         Peer    : Sockets.Endpoint;
      begin
         Connections.Accept_Connection
           (H2_Manager, H2_Listener, Channel, Peer, Timeout => 20.0);
         Routes.Serve
           (State, Channel, Peer,
            Mode => Flyology.HTTP.Server.HTTP_2_Only,
            Timeout => 15.0, Max_Connection_Age => 15.0);
         Connections.Close (Channel);
      exception
         when others => null;
      end H2_Task;

      task H1_Task is
         pragma Task_Info (Flyology.Native_Task);
      end H1_Task;

      task body H1_Task is
         Channel : aliased Connections.Connection;
         Peer    : Sockets.Endpoint;
      begin
         Connections.Accept_Connection
           (H1_Manager, H1_Listener, Channel, Peer, Timeout => 20.0);
         Routes.Serve
           (State, Channel, Peer,
            Mode => Flyology.HTTP.Server.HTTP_1_Only,
            Timeout => 15.0, Max_Connection_Age => 15.0);
         Connections.Close (Channel);
      exception
         when others => null;
      end H1_Task;

      Socket  : Sockets.Socket_Type;
      Info    : Frame_Info;
      Payload : Stream_Element_Array (1 .. 16_384) := (others => 0);
      Status_Seen : Boolean := False;
      Reset_Code  : Integer := -1;
      Frames_Seen : Natural := 0;
   begin
      --  HTTP/2: no declared content-length, so the limit can only be seen
      --  once the second DATA frame arrives.
      Connect_Peer (Socket, H2_Address);
      Send_Frame
        (Socket, Headers_Frame, End_Headers_Flag, 1,
         Request_Block ("POST", "/upload"));
      delay 0.30;
      Send_Frame (Socket, Data_Frame, 0, 1, Block);
      delay 0.10;
      Send_Frame (Socket, Data_Frame, End_Stream_Flag, 1, Block);
      begin
         loop
            Read_Frame_Header (Socket, Info, Wait => 6.0);
            Read_Payload (Socket, Info, Payload, Wait => 6.0);
            Frames_Seen := Frames_Seen + 1;
            Note
              ("  <- " & Frame_Name (Info.Kind) & " stream" &
               Natural'Image (Info.Stream_ID) & " length" &
               Natural'Image (Info.Length));
            if Info.Kind = Headers_Frame and then Info.Stream_ID = 1 then
               Status_Seen := True;
               Note ("     first header octet " & Hex (Payload (1 .. 1)));
               exit;
            elsif Info.Kind = Reset_Stream_Frame and then Info.Stream_ID = 1
            then
               Reset_Code :=
                 Integer (Payload (1)) * 16#100_0000# +
                 Integer (Payload (2)) * 16#1_0000# +
                 Integer (Payload (3)) * 16#100# + Integer (Payload (4));
               exit;
            elsif Info.Kind = Goaway_Frame then
               exit;
            end if;
            exit when Frames_Seen > 20;
         end loop;
      exception
         when others => Note ("  (no further frames)");
      end;
      if Reset_Code >= 0 then
         Note
           ("  the server reset the stream with error code" &
            Integer'Image (Reset_Code) & " (2 is INTERNAL_ERROR)");
      end if;
      Check
        (Status_Seen,
         "HTTP/2 answers an over-limit body with a response head, not a reset");
      Sockets.Close_Socket (Socket);

      --  HTTP/1.1 control through the same router and the same route.
      declare
         H1 : Sockets.Socket_Type;
         Head : constant String :=
           "POST /upload HTTP/1.1" & CRLF &
           "Host: localhost" & CRLF &
           "Transfer-Encoding: chunked" & CRLF & CRLF;
         Chunk_Header : constant String := "1000" & CRLF;
         Reply : Stream_Element_Array (1 .. 512) := (others => 0);
         Last  : Stream_Element_Offset;
      begin
         Sockets.Create_Socket (H1);
         Sockets.Connect
           (H1,
            Sockets.Network_Endpoint
              (Sockets.Loopback_IPv4, H1_Address.Port),
            Timeout => 10.0);
         Sockets.Send_All (H1, Text_Bytes (Head), Timeout => 10.0);
         delay 0.20;
         Sockets.Send_All
           (H1, Text_Bytes (Chunk_Header) & Block & Text_Bytes (CRLF),
            Timeout => 10.0);
         delay 0.10;
         Sockets.Send_All
           (H1, Text_Bytes (Chunk_Header) & Block & Text_Bytes (CRLF) &
                Text_Bytes ("0" & CRLF & CRLF),
            Timeout => 10.0);
         Sockets.Receive (H1, Reply, Last, Timeout => 6.0);
         declare
            Text : constant String :=
              (if Last >= Reply'First then S (Reply (Reply'First .. Last))
               else "");
            Line_End : Natural := Text'First;
         begin
            while Line_End <= Text'Last
              and then Text (Line_End) /= Character'Val (13)
            loop
               Line_End := Line_End + 1;
            end loop;
            Note
              ("  HTTP/1.1 control status line: " &
               Text (Text'First .. Line_End - 1));
            Check
              (Ada.Strings.Fixed.Index (Text, "413") /= 0,
               "HTTP/1.1 delivers the 413 for the same route and body");
         end;
         Sockets.Close_Socket (H1);
      exception
         when others =>
            Note ("  HTTP/1.1 control did not complete");
      end;
   end;

   Sockets.Close_Socket (H1_Listener);
   Sockets.Close_Socket (H2_Listener);
   Finish;
end Repro_H2_5;
