with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Client.SSE;
with Flyology.IO.Sockets;
with Repro_Support;

--  SSE-2.  Flyology.HTTP.Client.SSE documents two caller-limit exceptions on
--  Read (src/flyology-http-client-sse.ads:85-86):
--
--     @exception Event_Too_Large Retained parser state would exceed the bound
--     @exception Reconnect_Delay_Too_Large A retry field exceeds caller policy
--
--  Both are raised by the parser.  While the parser is being fed by the
--  response body sink, Flyology.HTTP.Client's Deliver
--  (src/flyology-http-client.adb:3884-3891) catches every sink exception and
--  converts it to the typed result Response_Sink_Failed, keeping only the
--  exception NAME in Result.Detail.  The SSE layer's Handle_Exchange_Failure
--  then falls into its `when others` arm and raises Invalid_Event_Stream.
--
--  This spike checks the documented identity for each exception, and also
--  checks the narrower path the discovery reviewer identified: when the
--  offending bytes are left in Pending after an earlier event completed in
--  the same delivered slice, the next Read parses them outside the sink and
--  the documented exception does reach the caller.
procedure Repro_SSE_2 is
   package Client renames Flyology.HTTP.Client;
   package SSE renames Flyology.HTTP.Client.SSE;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use Repro_Support;
   use type Ada.Exceptions.Exception_Id;
   use type SSE.Read_Result;
   use type Sockets.Selector_Status;

   LF : constant Character := Character'Val (10);

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

   --  One scenario: a raw HTTP/1.1 peer that answers every request with one
   --  fixed event-stream body, and a client that reads until something is
   --  raised.
   procedure Run_Case
     (Label           : String;
      Stream_Body     : String;
      Max_Event_Bytes : Positive;
      Max_Delay       : Duration;
      Warmup_Reads    : Natural;
      Expected_Id     : Ada.Exceptions.Exception_Id;
      Expected_Name   : String)
   is
      Listener : Sockets.Socket_Type;
      Address  : Sockets.Endpoint;
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Port (Ephemeral_Port)));
      Sockets.Listen_Socket (Listener, Length => 4);
      Address := Sockets.Get_Socket_Name (Listener);

      declare
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
            for Session in 1 .. 3 loop
               Sockets.Accept_Socket
                 (Listener, Peer, From, Timeout => 5.0, Status => Status);
               exit when Status /= Sockets.Completed;
               Head := Null_Unbounded_String;
               loop
                  Sockets.Receive (Peer, Buffer, Last, Timeout => 5.0);
                  exit when Last < Buffer'First;
                  for Index in Buffer'First .. Last loop
                     Append (Head, Character'Val (Buffer (Index)));
                  end loop;
                  exit when Ada.Strings.Fixed.Index
                    (To_String (Head), CRLF & CRLF) /= 0;
               end loop;
               --  Head and body leave in one write, so the client engine
               --  hands the parser the whole body as a single slice.
               Sockets.Send_All
                 (Peer,
                  To_Bytes
                    ("HTTP/1.1 200 OK" & CRLF
                     & "Content-Type: text/event-stream" & CRLF
                     & "Content-Length: " & Decimal (Stream_Body'Length)
                     & CRLF & "Connection: close" & CRLF & CRLF
                     & Stream_Body),
                  Timeout => 5.0);
               Sockets.Close_Socket (Peer);
            end loop;
         exception
            when others =>
               if Sockets.Is_Open (Peer) then
                  Sockets.Close_Socket (Peer);
               end if;
         end Raw_Server;

         HTTP    : aliased Client.Client (Capacity => 1);
         Request : Client.Request;
         Source  : aliased SSE.Event_Source
           (HTTP'Access, Maximum_Event_Bytes => Max_Event_Bytes);
         Event   : SSE.Event;
         Result  : SSE.Read_Result;
         Raised  : Boolean := False;
      begin
         Client.Configure
           (HTTP,
            Flyology.HTTP.Parse_Origin
              ("http://127.0.0.1:" & Decimal (Natural (Address.Port))));
         Client.Set_Target (Request, "/events");
         SSE.Open
           (Source, Request,
            Initial_Reconnect_Delay => 0.0,
            Maximum_Reconnect_Delay => Max_Delay,
            Deadline => Client.Deadline_After (15.0));

         for Warmup in 1 .. Warmup_Reads loop
            begin
               SSE.Read (Source, Result, Event, Token => null);
               Note
                 (Label & " warm-up read" & Warmup'Image & " returned "
                  & SSE.Read_Result'Image (Result) & " data ["
                  & Printable (B (SSE.Data (Event))) & "]");
            exception
               when Error : others =>
                  Check
                    (False,
                     Label & " warm-up read raised "
                     & Ada.Exceptions.Exception_Name (Error));
                  Raised := True;
            end;
            exit when Raised;
         end loop;

         if not Raised then
            begin
               SSE.Read (Source, Result, Event, Token => null);
               Check
                 (False,
                  Label & " raised nothing; Read returned "
                  & SSE.Read_Result'Image (Result));
            exception
               when Error : others =>
                  Note
                    (Label & " observed "
                     & Ada.Exceptions.Exception_Name (Error) & ": "
                     & Ada.Exceptions.Exception_Message (Error));
                  Check
                    (Ada.Exceptions.Exception_Identity (Error) = Expected_Id,
                     Label & " raises " & Expected_Name);
            end;
         end if;

         begin
            Client.Shutdown (HTTP, Timeout => 5.0);
         exception
            when others => null;
         end;
      end;
      Sockets.Close_Socket (Listener);
   end Run_Case;

begin
   Note ("contract: client-sse.ads:85-86 documents Event_Too_Large and");
   Note ("Reconnect_Delay_Too_Large as Read exceptions");

   --  A retry value the caller's policy forbids, seen as the first thing in
   --  the stream.  Reached through the sink.
   Run_Case
     (Label           => "retry over caller maximum (first event)",
      Stream_Body     => "retry: 5000" & LF & LF,
      Max_Event_Bytes => 1_024,
      Max_Delay       => 1.0,
      Warmup_Reads    => 0,
      Expected_Id     => SSE.Reconnect_Delay_Too_Large'Identity,
      Expected_Name   => "Reconnect_Delay_Too_Large");

   --  A line longer than the caller's byte bound.  Also reached through the
   --  sink.
   Run_Case
     (Label           => "event over caller byte bound (first event)",
      Stream_Body     => "data: " & String'(1 .. 64 => 'a') & LF & LF,
      Max_Event_Bytes => 16,
      Max_Delay       => 1.0,
      Warmup_Reads    => 0,
      Expected_Id     => SSE.Event_Too_Large'Identity,
      Expected_Name   => "Event_Too_Large");

   --  The narrower path: the offending retry field follows a complete event
   --  in the same delivered slice, so the second Read parses it from Pending
   --  in Process_Buffered rather than in the sink.
   Run_Case
     (Label           => "retry over caller maximum (bytes left in Pending)",
      Stream_Body     =>
        "data: x" & LF & LF & "retry: 5000" & LF & LF,
      Max_Event_Bytes => 1_024,
      Max_Delay       => 1.0,
      Warmup_Reads    => 1,
      Expected_Id     => SSE.Reconnect_Delay_Too_Large'Identity,
      Expected_Name   => "Reconnect_Delay_Too_Large");

   --  Same shape for the byte bound.
   Run_Case
     (Label           => "event over caller byte bound (bytes left in Pending)",
      Stream_Body     =>
        "data: x" & LF & LF & "data: " & String'(1 .. 64 => 'a') & LF & LF,
      Max_Event_Bytes => 48,
      Max_Delay       => 1.0,
      Warmup_Reads    => 1,
      Expected_Id     => SSE.Event_Too_Large'Identity,
      Expected_Name   => "Event_Too_Large");

   Finish;
end Repro_SSE_2;
