--  H1-CLIENT-3.  http_1_internals.adb:410-418 decides reuse with
--
--     Data.Reusable :=
--       (if Data.Version_Value = HTTP_1_1
--        then not Close_Token else Keep_Token);
--
--  so on an HTTP/1.0 response the "close" connection option is never
--  consulted.  RFC 9112 section 9.3 evaluates it first and unconditionally:
--  "If the 'close' connection option is present (Section 9.6), the connection
--  will not persist after the current response; else, ... If the received
--  protocol is HTTP/1.0, the 'keep-alive' connection option is present ...
--  the connection will persist after the current response".
--
--  This program asserts that a response carrying both options leaves no
--  reusable transport in the pool, on HTTP/1.0 as well as HTTP/1.1.  The
--  lone-keep-alive case is the control that proves the measurement works.
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.Bytes;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.IO.Sockets;
with Repro_Support;

procedure Repro_H1_Client_3 is
   package HC renames Flyology.HTTP.Client;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use Repro_Support;
   use type Sockets.Selector_Status;

   type Case_Index is (Ten_Keep_Alive, Eleven_Both, Ten_Both);
   type Head_Table is array (Case_Index) of Unbounded_String;

   Heads : constant Head_Table :=
     (Ten_Keep_Alive => To_Unbounded_String
        ("HTTP/1.0 200 OK" & CRLF
         & "Connection: keep-alive" & CRLF
         & "Content-Length: 2" & CRLF & CRLF & "ok"),
      Eleven_Both => To_Unbounded_String
        ("HTTP/1.1 200 OK" & CRLF
         & "Connection: keep-alive, close" & CRLF
         & "Content-Length: 2" & CRLF & CRLF & "ok"),
      Ten_Both => To_Unbounded_String
        ("HTTP/1.0 200 OK" & CRLF
         & "Connection: keep-alive, close" & CRLF
         & "Content-Length: 2" & CRLF & CRLF & "ok"));

   function Decimal (Value : Long_Long_Integer) return String is
      Text : constant String := Long_Long_Integer'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Decimal;

   protected Coordination is
      procedure Publish (Value : Sockets.Port);
      entry Wait_Ready (Value : out Sockets.Port);
      procedure Server_Failed (Text : String);
      function Server_Note return String;
   private
      Port_Value : Sockets.Port := Sockets.Any_Port;
      Ready      : Boolean := False;
      Message    : Unbounded_String;
   end Coordination;

   protected body Coordination is
      procedure Publish (Value : Sockets.Port) is
      begin
         Port_Value := Value;
         Ready := True;
      end Publish;

      entry Wait_Ready (Value : out Sockets.Port) when Ready is
      begin
         Value := Port_Value;
      end Wait_Ready;

      procedure Server_Failed (Text : String) is
      begin
         Message := To_Unbounded_String (Text);
      end Server_Failed;

      function Server_Note return String is (To_String (Message));
   end Coordination;

   task Raw_Server is
      pragma Task_Info (Flyology.Native_Task);
   end Raw_Server;

   task body Raw_Server is
      Listener : Sockets.Socket_Type;

      procedure Serve (Which : Case_Index) is
         Peer    : Sockets.Socket_Type;
         Address : Sockets.Endpoint;
         Status  : Sockets.Selector_Status;
         Buffer  : Stream_Element_Array (1 .. 4_096);
         Last    : Stream_Element_Offset;
         Seen    : Unbounded_String;
      begin
         Sockets.Accept_Socket
           (Listener, Peer, Address, Timeout => 10.0, Status => Status);
         if Status /= Sockets.Completed then
            raise Program_Error with "raw peer accept did not complete";
         end if;
         loop
            Sockets.Receive (Peer, Buffer, Last, Timeout => 10.0);
            exit when Last < Buffer'First;
            for Index in Buffer'First .. Last loop
               Append (Seen, Character'Val (Buffer (Index)));
            end loop;
            exit when Ada.Strings.Fixed.Index (To_String (Seen), CRLF & CRLF)
              /= 0;
         end loop;
         Sockets.Send_All (Peer, B (To_String (Heads (Which))), Timeout => 5.0);
         --  The "close" option announces this: the peer really does close.
         Sockets.Close_Socket (Peer);
      exception
         when Occurrence : others =>
            Coordination.Server_Failed
              (Case_Index'Image (Which) & ": "
               & Ada.Exceptions.Exception_Information (Occurrence));
            if Sockets.Is_Open (Peer) then
               Sockets.Close_Socket (Peer);
            end if;
      end Serve;
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener);
      Coordination.Publish (Sockets.Get_Socket_Name (Listener).Port);
      for Which in Case_Index loop
         Serve (Which);
      end loop;
      Sockets.Close_Socket (Listener);
   exception
      when Occurrence : others =>
         Coordination.Server_Failed
           (Ada.Exceptions.Exception_Information (Occurrence));
         if Sockets.Is_Open (Listener) then
            Sockets.Close_Socket (Listener);
         end if;
   end Raw_Server;

   function Reusable_After (Which : Case_Index; Port : Sockets.Port)
     return Integer
   is
      Item    : aliased HC.Client (Capacity => 1);
      Request : HC.Request;
      Answer  : Integer;
   begin
      HC.Configure
        (Item,
         Flyology.HTTP.Parse_Origin
           ("http://127.0.0.1:" & Decimal (Long_Long_Integer (Port))));
      HC.Set_Target (Request, "/" & Case_Index'Image (Which));
      declare
         Reply   : HC.Response := HC.Execute (Item, Request, Timeout => 10.0);
         Content : Flyology.Bytes.Unbounded_Bytes;
      begin
         HC.Read_All (Reply, Content);
         if HC.Status (Reply) /= 200 then
            Coordination.Server_Failed
              (Case_Index'Image (Which) & ": unexpected status");
         end if;
      end;
      Answer := HC.Diagnostics (Item).Reusable_Transports;
      HC.Shutdown (Item);
      return Answer;
   exception
      when Occurrence : others =>
         Ada.Text_IO.Put_Line
           (Case_Index'Image (Which) & " client failed: "
            & Ada.Exceptions.Exception_Information (Occurrence));
         HC.Shutdown (Item);
         return -1;
   end Reusable_After;

   Port : Sockets.Port;
begin
   Coordination.Wait_Ready (Port);
   declare
      Lone_Keep : constant Integer := Reusable_After (Ten_Keep_Alive, Port);
      Both_11   : constant Integer := Reusable_After (Eleven_Both, Port);
      Both_10   : constant Integer := Reusable_After (Ten_Both, Port);
   begin
      Note ("HTTP/1.0 'keep-alive'        -> Reusable_Transports ="
            & Integer'Image (Lone_Keep));
      Note ("HTTP/1.1 'keep-alive, close' -> Reusable_Transports ="
            & Integer'Image (Both_11));
      Note ("HTTP/1.0 'keep-alive, close' -> Reusable_Transports ="
            & Integer'Image (Both_10));
      Check (Lone_Keep = 1,
             "control: HTTP/1.0 with a lone keep-alive is pooled");
      Check (Both_11 = 0,
             "control: HTTP/1.1 with close present is not pooled");
      Check (Both_10 = 0,
             "HTTP/1.0 with close present is not pooled (RFC 9112 9.3"
             & " evaluates close first)");
   end;
   if Coordination.Server_Note /= "" then
      Ada.Text_IO.Put_Line ("raw peer note: " & Coordination.Server_Note);
   end if;
   Finish;
end Repro_H1_Client_3;
