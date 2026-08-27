with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Client.SSE;
with Flyology.IO.Sockets;
with Flyology.Operations;

procedure HTTP1_SSE_Client_Integration is
   package Client renames Flyology.HTTP.Client;
   package SSE renames Flyology.HTTP.Client.SSE;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use type SSE.Read_Result;
   use type Sockets.Selector_Status;

   CRLF : constant String := Character'Val (13) & Character'Val (10);

   function Bytes (Value : String) return Stream_Element_Array is
      Result : Stream_Element_Array
        (1 .. Stream_Element_Offset (Value'Length));
   begin
      for Offset in 0 .. Value'Length - 1 loop
         Result (Result'First + Stream_Element_Offset (Offset)) :=
           Stream_Element (Character'Pos (Value (Value'First + Offset)));
      end loop;
      return Result;
   end Bytes;

   function Decimal (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal;

   protected Coordination is
      procedure Publish (Value : Sockets.Port);
      procedure Finish (Passed : Boolean);
      entry Wait_Ready (Value : out Sockets.Port; Passed : out Boolean);
      entry Wait_Done (Passed : out Boolean);
   private
      Port_Value : Sockets.Port := Sockets.Any_Port;
      Ready      : Boolean := False;
      Done       : Boolean := False;
      OK         : Boolean := True;
   end Coordination;

   protected body Coordination is
      procedure Publish (Value : Sockets.Port) is
      begin
         Port_Value := Value;
         Ready := True;
      end Publish;

      procedure Finish (Passed : Boolean) is
      begin
         OK := OK and Passed;
         Done := True;
      end Finish;

      entry Wait_Ready
        (Value : out Sockets.Port; Passed : out Boolean)
        when Ready or Done
      is
      begin
         Value := Port_Value;
         Passed := OK;
      end Wait_Ready;

      entry Wait_Done (Passed : out Boolean) when Done is
      begin
         Passed := OK;
      end Wait_Done;
   end Coordination;

   task Raw_Server is
      pragma Task_Info (Flyology.Native_Task);
   end Raw_Server;

   task body Raw_Server is
      Listener : Sockets.Socket_Type;
      Peer     : Sockets.Socket_Type;
      Address  : Sockets.Endpoint;
      Status   : Sockets.Selector_Status;

      function Receive_Head return String is
         Buffer : Stream_Element_Array (1 .. 2_048);
         Last   : Stream_Element_Offset;
         Result : Unbounded_String;
      begin
         loop
            Sockets.Receive (Peer, Buffer, Last, Timeout => 5.0);
            pragma Assert (Last >= Buffer'First);
            for Index in Buffer'First .. Last loop
               Append (Result, Character'Val (Buffer (Index)));
            end loop;
            exit when Ada.Strings.Fixed.Index
              (To_String (Result), CRLF & CRLF) /= 0;
         end loop;
         return To_String (Result);
      end Receive_Head;

      procedure Accept_Peer is
      begin
         Sockets.Accept_Socket
           (Listener, Peer, Address, Timeout => 5.0, Status => Status);
         pragma Assert (Status = Sockets.Completed);
      end Accept_Peer;

      procedure Send_Response
        (Status_Line : String;
         Payload     : String := "") is
      begin
         Sockets.Send_All
           (Peer,
            Bytes
               (Status_Line & CRLF &
               (if Payload = "" then ""
                else
                  "Content-Type: text/event-stream" & CRLF &
                  "Content-Length: " & Decimal (Payload'Length) & CRLF) &
               "Connection: close" & CRLF & CRLF & Payload),
            Timeout => 5.0);
         Sockets.Close_Socket (Peer);
      end Send_Response;

      procedure Check_Request
        (Expected_Last_ID : String;
         Expect_ID        : Boolean) is
         Head : constant String := Receive_Head;
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index (Head, "GET /events HTTP/1.1") /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Head, "Accept: text/event-stream" & CRLF) /= 0);
         if Expect_ID then
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Head, "Last-Event-ID: " & Expected_Last_ID & CRLF) /= 0);
         else
            pragma Assert
              (Ada.Strings.Fixed.Index (Head, "Last-Event-ID:") = 0);
         end if;
      end Check_Request;

      First_Body : constant String :=
        "retry: 0001" & Character'Val (10) &
        "id: one" & Character'Val (10) &
        "event: tick" & Character'Val (10) &
        "data: alpha" & Character'Val (10) &
        "data: beta" & Character'Val (10) & Character'Val (10);
      Second_Body : constant String :=
        "id: two" & Character'Val (10) &
        "data: gamma" & Character'Val (10) & Character'Val (10);
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener);
      Coordination.Publish (Sockets.Get_Socket_Name (Listener).Port);

      Accept_Peer;
      Check_Request (Expected_Last_ID => "", Expect_ID => False);
      Send_Response ("HTTP/1.1 200 OK", First_Body);

      Accept_Peer;
      Check_Request (Expected_Last_ID => "one", Expect_ID => True);
      Send_Response ("HTTP/1.1 200 OK", Second_Body);

      Accept_Peer;
      Check_Request (Expected_Last_ID => "two", Expect_ID => True);
      Send_Response ("HTTP/1.1 204 No Content");

      Sockets.Close_Socket (Listener);
      Coordination.Finish (True);
   exception
      when Occurrence : others =>
         Ada.Text_IO.Put_Line
           ("raw HTTP/1.1 SSE server failed: " &
            Ada.Exceptions.Exception_Information (Occurrence));
         if Sockets.Is_Open (Peer) then
            Sockets.Close_Socket (Peer);
         end if;
         if Sockets.Is_Open (Listener) then
            Sockets.Close_Socket (Listener);
         end if;
         Coordination.Finish (False);
   end Raw_Server;

   Port      : Sockets.Port;
   Server_OK : Boolean;
begin
   Coordination.Wait_Ready (Port, Server_OK);
   pragma Assert (Server_OK);
   declare
      HTTP    : aliased Client.Client (Capacity => 1);
      Request : Client.Request;
      Source  : aliased SSE.Event_Source
        (HTTP'Access, Maximum_Event_Bytes => 1_024);
      Event   : SSE.Event;
      Result  : SSE.Read_Result;
   begin
      Client.Configure
        (HTTP,
         Flyology.HTTP.Parse_Origin
           ("http://127.0.0.1:" & Decimal (Natural (Port))));
      Client.Set_Target (Request, "/events");
      Client.Add_Header (Request, "Accept", "application/json");
      Client.Add_Header (Request, "Last-Event-ID", "template-id");
      SSE.Open
        (Source, Request,
         Initial_Reconnect_Delay => 0.0,
         Maximum_Reconnect_Delay => 1.0,
         Deadline => Client.Deadline_After (10.0));
      declare
         Set       : aliased Flyology.Operations.Completion_Set (4);
         Operation : SSE.Read_Operation :=
           SSE.Read (Set'Access, Source'Access);
      begin
         Flyology.Operations.Wait_All (Set);
         SSE.Finish (Operation, Result, Event);
      end;
      pragma Assert (Result = SSE.Event_Available);
      pragma Assert
        (SSE.Data (Event) = "alpha" & Character'Val (10) & "beta");
      pragma Assert (SSE.Event_Type (Event) = "tick");
      pragma Assert (SSE.Last_Event_ID (Event) = "one");
      pragma Assert (SSE.Reconnect_Delay (Source) = 0.001);

      SSE.Read (Source, Result, Event, Token => null);
      pragma Assert (Result = SSE.Event_Available);
      pragma Assert (SSE.Data (Event) = "gamma");
      pragma Assert (SSE.Event_Type (Event) = "message");
      pragma Assert (SSE.Last_Event_ID (Event) = "two");

      SSE.Read (Source, Result, Event, Token => null);
      pragma Assert (Result = SSE.Stream_Stopped);
      SSE.Read (Source, Result, Event, Token => null);
      pragma Assert (Result = SSE.Stream_Stopped);
      Client.Shutdown (HTTP, Timeout => 5.0);
   end;
   Coordination.Wait_Done (Server_OK);
   pragma Assert (Server_OK);
end HTTP1_SSE_Client_Integration;
