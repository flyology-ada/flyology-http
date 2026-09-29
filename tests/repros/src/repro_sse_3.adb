with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Client.SSE;
with Flyology.IO.Sockets;
with Repro_Support;

--  SSE-3.  Flyology.HTTP.Client.SSE.Read promises
--  (src/flyology-http-client-sse.ads:74-77):
--
--     Cancellation and the absolute deadline interrupt requests, reads, and
--     reconnect waits using their ordinary exceptions.
--
--  Begin_Reconnect (src/flyology-http-client-sse.adb:648-661) clamps the
--  interval to the deadline but arms Flyology.IO.Timers.Sleep_For with no
--  token, and the Waiting_Reconnect arm (:890-896) calls Check_Control only
--  after the timer has already fired.  Nothing in the blocking Read overload
--  reaches Request_Cancellation, which is the only path that cancels the
--  timer early.
--
--  The spike times a blocking Read that is cancelled 0.2 s into a
--  server-chosen 3 s reconnect wait.  Honouring the contract means the call
--  returns promptly with Operation_Cancelled.
procedure Repro_SSE_3 is
   package Client renames Flyology.HTTP.Client;
   package SSE renames Flyology.HTTP.Client.SSE;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use Repro_Support;
   use type Ada.Real_Time.Time;
   use type SSE.Read_Result;
   use type Sockets.Selector_Status;

   LF : constant Character := Character'Val (10);

   --  The server's retry value, and the caller's ceiling for it.
   Server_Retry_Seconds  : constant Duration := 3.0;
   Caller_Maximum_Delay  : constant Duration := 10.0;
   --  When cancellation arrives, and the budget a prompt return must meet.
   Cancel_After_Seconds  : constant Duration := 0.2;
   Prompt_Return_Seconds : constant Duration := 1.0;

   Stream_Body : constant String :=
     "retry: 3000" & LF & "data: a" & LF & LF;

   function Decimal (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function To_Bytes (Value : String) return Stream_Element_Array is
      Result : Stream_Element_Array
        (1 .. Stream_Element_Offset (Value'Length));
   begin
      for Offset in 0 .. Value'Length - 1 loop
         Result (Result'First + Stream_Element_Offset (Offset)) :=
           Stream_Element (Character'Pos (Value (Value'First + Offset)));
      end loop;
      return Result;
   end To_Bytes;

   Listener : Sockets.Socket_Type;
   Address  : Sockets.Endpoint;
begin
   Note ("contract: client-sse.ads:74-77 says cancellation interrupts");
   Note ("reconnect waits using its ordinary exception");

   Sockets.Create_Socket (Listener);
   Sockets.Bind_Socket
     (Listener,
      Sockets.Network_Endpoint
        (Sockets.Loopback_IPv4, Sockets.Port (Ephemeral_Port)));
   Sockets.Listen_Socket (Listener, Length => 4);
   Address := Sockets.Get_Socket_Name (Listener);

   declare
      --  One response, then close.  The client must wait 3 s before it would
      --  reconnect, and that wait is what cancellation has to interrupt.
      task Raw_Server is
         pragma Task_Info (Flyology.Native_Task);
      end Raw_Server;

      task body Raw_Server is
         Peer   : Sockets.Socket_Type;
         From   : Sockets.Endpoint;
         Status : Sockets.Selector_Status;
         Buffer : Stream_Element_Array (1 .. 4_096);
         Last   : Stream_Element_Offset;
         Head   : Unbounded_String;
      begin
         Sockets.Accept_Socket
           (Listener, Peer, From, Timeout => 10.0, Status => Status);
         if Status = Sockets.Completed then
            loop
               Sockets.Receive (Peer, Buffer, Last, Timeout => 10.0);
               exit when Last < Buffer'First;
               for Index in Buffer'First .. Last loop
                  Append (Head, Character'Val (Buffer (Index)));
               end loop;
               exit when Ada.Strings.Fixed.Index
                 (To_String (Head), CRLF & CRLF) /= 0;
            end loop;
            Sockets.Send_All
              (Peer,
               To_Bytes
                 ("HTTP/1.1 200 OK" & CRLF
                  & "Content-Type: text/event-stream" & CRLF
                  & "Content-Length: " & Decimal (Stream_Body'Length) & CRLF
                  & "Connection: close" & CRLF & CRLF & Stream_Body),
               Timeout => 10.0);
            Sockets.Close_Socket (Peer);
         end if;
      exception
         when others =>
            if Sockets.Is_Open (Peer) then
               Sockets.Close_Socket (Peer);
            end if;
      end Raw_Server;

      HTTP    : aliased Client.Client (Capacity => 1);
      Request : Client.Request;
      Source  : aliased SSE.Event_Source
        (HTTP'Access, Maximum_Event_Bytes => 1_024);
      Event   : SSE.Event;
      Result  : SSE.Read_Result;
      Stop    : aliased Flyology.Cancellation.Token;
      Armed   : Boolean := False;
      pragma Volatile (Armed);

      task Canceller is
         pragma Task_Info (Flyology.Native_Task);
      end Canceller;

      task body Canceller is
      begin
         while not Armed loop
            delay 0.005;
         end loop;
         delay Cancel_After_Seconds;
         Stop.Request;
      end Canceller;

      Started, Ended : Ada.Real_Time.Time;
      Elapsed : Duration := 0.0;
      Observed : Unbounded_String;
   begin
      Client.Configure
        (HTTP,
         Flyology.HTTP.Parse_Origin
           ("http://127.0.0.1:" & Decimal (Natural (Address.Port))));
      Client.Set_Target (Request, "/events");
      SSE.Open
        (Source, Request,
         Initial_Reconnect_Delay => 0.0,
         Maximum_Reconnect_Delay => Caller_Maximum_Delay,
         Deadline => Client.Deadline_After (60.0));

      --  First read returns the event and adopts the server's retry value.
      SSE.Read (Source, Result, Event, Token => Stop'Access);
      Check (Result = SSE.Event_Available, "first read returned an event");
      Expect_Equal (SSE.Data (Event), "a", "first event data");
      Expect_Equal
        (Duration'Image (SSE.Reconnect_Delay (Source)),
         Duration'Image (Server_Retry_Seconds),
         "server retry adopted as the reconnect delay");

      --  The peer has closed, so the second read enters the reconnect wait.
      Armed := True;
      Started := Ada.Real_Time.Clock;
      begin
         SSE.Read (Source, Result, Event, Token => Stop'Access);
         Ended := Ada.Real_Time.Clock;
         Observed := To_Unbounded_String
           ("no exception; Read returned "
            & SSE.Read_Result'Image (Result));
      exception
         when Error : others =>
            Ended := Ada.Real_Time.Clock;
            Observed := To_Unbounded_String
              (Ada.Exceptions.Exception_Name (Error));
      end;
      Elapsed := Ada.Real_Time.To_Duration (Ended - Started);

      Note
        ("cancellation requested" & Cancel_After_Seconds'Image
         & " s into a" & Server_Retry_Seconds'Image & " s reconnect wait");
      Note ("second Read outcome: " & To_String (Observed));
      Note ("second Read took" & Elapsed'Image & " s");

      Expect_Equal
        (To_String (Observed),
         Ada.Exceptions.Exception_Name
           (Flyology.Cancellation.Operation_Cancelled'Identity),
         "cancelled reconnect wait raises Operation_Cancelled");
      Check
        (Elapsed <= Prompt_Return_Seconds,
         "cancelled Read returns within"
         & Prompt_Return_Seconds'Image & " s (took" & Elapsed'Image & " s)");

      begin
         Client.Shutdown (HTTP, Timeout => 5.0);
      exception
         when others => null;
      end;
   end;
   Sockets.Close_Socket (Listener);
   Finish;
end Repro_SSE_3;
