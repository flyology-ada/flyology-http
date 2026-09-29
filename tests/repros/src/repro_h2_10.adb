with Ada.Streams;
with Flyology;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.HTTP_2;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with H2_Wire;
with Repro_Support;

--  H2-10.  A stream whose response completed while its request half is
--  still open is never completed and never reset (Maybe_Complete requires
--  Remote_End, server-http_2.adb:419-428; the handler task performs no drain
--  or reset after Handle returns, :2112-2139).  The body octets already
--  buffered for it are charged to the 65535-octet connection receive window
--  and never credited back, because credit is returned only when bytes leave
--  the stream buffer.  Four such streams consume the whole connection
--  window.
--
--  RFC 9113 8.1 makes the server's RST_STREAM(NO_ERROR) after a complete
--  response a MAY, so this is a resource-lifetime defect rather than a
--  conformance violation; the assertion is that the connection window is
--  recoverable at all.
procedure Repro_H2_10 is
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
      --  Reject before reading any body, as an authentication middleware or
      --  a Reject_Body route does.
      X.Text (401, "no");
   end Handle;

   Manager  : aliased Connections.Server (Capacity => 1);
   Listener : Sockets.Socket_Type;
   Address  : Sockets.Endpoint;
   State    : Context;

   Upload_Size : constant := 16_000;
   Streams     : constant := 4;
   Block : constant Stream_Element_Array (1 .. Upload_Size) :=
     (others => Character'Pos ('u'));
begin
   Note ("H2-10: un-credited input on early-answered streams");
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
            Timeout => 12.0, Max_Connection_Age => 12.0);
         Connections.Close (Channel);
      exception
         when others => null;
      end Server_Task;

      Socket  : Sockets.Socket_Type;
      Info    : Frame_Info;
      Payload : Stream_Element_Array (1 .. 16_384) := (others => 0);
      Answered : Natural := 0;
      Resets   : Natural := 0;
      Connection_Credit : Natural := 0;
      Frames_Seen : Natural := 0;
   begin
      Connect_Peer (Socket, Address);
      for Index in 1 .. Streams loop
         declare
            Stream_ID : constant Natural := 2 * Index - 1;
         begin
            --  No END_STREAM: the request half stays open, which RFC 9113
            --  8.1 explicitly allows while the server answers early.
            Send_Frame
              (Socket, Headers_Frame, End_Headers_Flag, Stream_ID,
               Request_Block ("POST", "/reject"));
            Send_Frame (Socket, Data_Frame, 0, Stream_ID, Block);
         end;
      end loop;
      Note
        ("  sent" & Natural'Image (Streams * Upload_Size) &
         " octets across" & Natural'Image (Streams) & " streams," &
         " against a 65535-octet connection window");
      begin
         loop
            Read_Frame_Header (Socket, Info, Wait => 4.0);
            Read_Payload (Socket, Info, Payload, Wait => 4.0);
            Frames_Seen := Frames_Seen + 1;
            if Info.Kind = Headers_Frame and then Info.Stream_ID /= 0 then
               Answered := Answered + 1;
            elsif Info.Kind = Reset_Stream_Frame then
               Resets := Resets + 1;
            elsif Info.Kind = Window_Update_Frame
              and then Info.Stream_ID = 0
            then
               Connection_Credit := Connection_Credit +
                 Natural (Payload (1) and 16#7F#) * 16#100_0000# +
                 Natural (Payload (2)) * 16#1_0000# +
                 Natural (Payload (3)) * 16#100# + Natural (Payload (4));
            elsif Info.Kind = Goaway_Frame then
               Note ("  <- GOAWAY");
               exit;
            end if;
            exit when Frames_Seen > 60;
         end loop;
      exception
         when others => Note ("  (no further frames)");
      end;
      Note
        ("  responses:" & Natural'Image (Answered) &
         "  resets:" & Natural'Image (Resets) &
         "  connection credit returned:" &
         Natural'Image (Connection_Credit) & " octets");
      Check
        (Answered = Streams,
         "every stream receives its early response (precondition)");
      Check
        (Connection_Credit + Resets * Upload_Size >= Streams * Upload_Size,
         "the connection receive window is recovered for body octets no " &
         "handler will ever read");
      Sockets.Close_Socket (Socket);
   end;

   Sockets.Close_Socket (Listener);
   Finish;
end Repro_H2_10;
