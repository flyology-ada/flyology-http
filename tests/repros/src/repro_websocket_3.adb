--  WEBSOCKET-3: the client fails the connection by closing the TCP
--  connection, with no Close frame, on every protocol failure it detects.
--
--  RFC 6455 7.1.7: "If _The WebSocket Connection is Established_ prior to
--  the point where the endpoint is required to _Fail the WebSocket
--  Connection_, the endpoint SHOULD send a Close frame with an appropriate
--  status code (Section 7.4) before proceeding to _Close the WebSocket
--  Connection_."  The same paragraph permits omitting the frame only when
--  the endpoint "believes the other side is unlikely to be able to receive
--  and process the Close frame, due to the nature of the error"; a text
--  frame whose payload is not valid UTF-8 is not such an error, and
--  section 7.4.1 assigns 1007 to exactly this case.
--
--  websocket_client.adb:1243-1248 raises Protocol_Error for invalid UTF-8
--  text and the handler at :1310-1321 calls Drop_Transport (:546-557), which
--  closes the socket.  Nothing on that path writes a Close frame.  The
--  server engine does the opposite in Fail (server.adb:4243-4260).
--
--  This program asserts the correct behaviour: the raw peer observes a
--  masked Close frame carrying 1007 before the client's TCP close.
--
--  The Autobahn baselines in review/baselines/20- through 23- cover the
--  SERVER only.  The client has never been run in Autobahn's
--  client-under-test role, which is where this would show up as a close
--  verdict, so no maintained suite covers it.
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology;
with Flyology.Bytes;
with Flyology.HTTP;
with Flyology.HTTP.WebSocket_Client;
with Flyology.IO;
with Flyology.IO.Sockets;
with GNAT.SHA1;
with Repro_Support;

procedure Repro_Websocket_3 is
   package WS renames Flyology.HTTP.WebSocket_Client;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use Repro_Support;
   use type Sockets.Selector_Status;
   use type WS.Data_Kind;

   GUID : constant String := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

   Alphabet : constant String :=
     "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

   function Base64 (Data : Stream_Element_Array) return String is
      Output : Unbounded_String;
      Index  : Stream_Element_Offset := Data'First;
      Triple : Natural;
      Left   : Stream_Element_Offset;
   begin
      while Index <= Data'Last loop
         Left := Data'Last - Index + 1;
         Triple := Natural (Data (Index)) * 65_536;
         if Left >= 2 then
            Triple := Triple + Natural (Data (Index + 1)) * 256;
         end if;
         if Left >= 3 then
            Triple := Triple + Natural (Data (Index + 2));
         end if;
         Append (Output, Alphabet (Alphabet'First + Triple / 262_144));
         Append
           (Output, Alphabet (Alphabet'First + (Triple / 4_096) mod 64));
         if Left >= 2 then
            Append
              (Output, Alphabet (Alphabet'First + (Triple / 64) mod 64));
         else
            Append (Output, '=');
         end if;
         if Left >= 3 then
            Append (Output, Alphabet (Alphabet'First + Triple mod 64));
         else
            Append (Output, '=');
         end if;
         Index := Index + 3;
      end loop;
      return To_String (Output);
   end Base64;

   function From_Hex (Value : String) return Stream_Element_Array is
      Result : Stream_Element_Array
        (1 .. Stream_Element_Offset (Value'Length / 2));
      Source : Natural := Value'First;

      function Nibble (C : Character) return Natural is
        (case C is
            when '0' .. '9' => Character'Pos (C) - Character'Pos ('0'),
            when 'a' .. 'f' => Character'Pos (C) - Character'Pos ('a') + 10,
            when 'A' .. 'F' => Character'Pos (C) - Character'Pos ('A') + 10,
            when others => raise Constraint_Error);
   begin
      for Element of Result loop
         Element := Stream_Element
           (16 * Nibble (Value (Source)) + Nibble (Value (Source + 1)));
         Source := Source + 2;
      end loop;
      return Result;
   end From_Hex;

   protected Coordination is
      procedure Publish (Value : Sockets.Port);
      entry Wait_Ready (Value : out Sockets.Port);
      procedure Record_Close (Seen : Boolean; Code : Integer);
      function Close_Seen return Boolean;
      function Close_Code return Integer;
      procedure Server_Failed (Text : String);
      function Server_Note return String;
   private
      Port_Value : Sockets.Port := Sockets.Any_Port;
      Ready      : Boolean := False;
      Saw_Close  : Boolean := False;
      Code_Value : Integer := -1;
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

      procedure Record_Close (Seen : Boolean; Code : Integer) is
      begin
         Saw_Close := Seen;
         Code_Value := Code;
      end Record_Close;

      function Close_Seen return Boolean is (Saw_Close);
      function Close_Code return Integer is (Code_Value);

      procedure Server_Failed (Text : String) is
      begin
         Message := To_Unbounded_String (Text);
      end Server_Failed;

      function Server_Note return String is (To_String (Message));
   end Coordination;

   task Raw_Peer is
      pragma Task_Info (Flyology.Native_Task);
   end Raw_Peer;

   task body Raw_Peer is
      Listener : Sockets.Socket_Type;
      Peer     : Sockets.Socket_Type;
      Address  : Sockets.Endpoint;
      Status   : Sockets.Selector_Status;
      Buffer   : Stream_Element_Array (1 .. 8_192);
      Last     : Stream_Element_Offset;
      Seen     : Unbounded_String;
      Mark     : Natural := 0;
      Key      : Unbounded_String;
      Saw_Close : Boolean := False;
      Code      : Integer := -1;
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener);
      Coordination.Publish (Sockets.Get_Socket_Name (Listener).Port);
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
         Mark := Ada.Strings.Fixed.Index (To_String (Seen), CRLF & CRLF);
         exit when Mark /= 0;
      end loop;
      declare
         Head   : constant String := To_String (Seen);
         Prefix : constant String := "Sec-WebSocket-Key: ";
         Start  : constant Natural :=
           Ada.Strings.Fixed.Index (Head, Prefix);
         Stop   : Natural;
      begin
         if Start = 0 then
            raise Program_Error with "no Sec-WebSocket-Key in the upgrade";
         end if;
         Stop := Ada.Strings.Fixed.Index
           (Head (Start + Prefix'Length .. Head'Last), CRLF);
         Key := To_Unbounded_String
           (Head (Start + Prefix'Length .. Stop - 1));
      end;
      declare
         Accept_Value : constant String :=
           Base64 (From_Hex (GNAT.SHA1.Digest (To_String (Key) & GUID)));
      begin
         Sockets.Send_All
           (Peer,
            B ("HTTP/1.1 101 Switching Protocols" & CRLF
               & "Upgrade: websocket" & CRLF
               & "Connection: Upgrade" & CRLF
               & "Sec-WebSocket-Accept: " & Accept_Value & CRLF & CRLF),
            Timeout => 5.0);
      end;
      --  One text frame whose single payload byte is not valid UTF-8.
      Sockets.Send_All (Peer, (16#81#, 16#01#, 16#FF#), Timeout => 5.0);
      --  Read everything the client sends until it closes the connection,
      --  looking for a masked Close frame (0x88) and its status code.
      declare
         Tail  : Stream_Element_Array (1 .. 256);
         Fill  : Stream_Element_Offset := 0;
      begin
         loop
            Sockets.Receive (Peer, Buffer, Last, Timeout => 5.0);
            exit when Last < Buffer'First;
            for Index in Buffer'First .. Last loop
               if Fill < Tail'Last then
                  Fill := Fill + 1;
                  Tail (Fill) := Buffer (Index);
               end if;
            end loop;
         end loop;
         if Fill >= 2 and then Tail (1) = 16#88# then
            Saw_Close := True;
            if Fill >= 8
              and then Natural (Tail (2) and 16#7F#) >= 2
            then
               Code :=
                 Natural (Tail (7) xor Tail (3)) * 256
                 + Natural (Tail (8) xor Tail (4));
            end if;
         end if;
      exception
         when Flyology.IO.Timeout_Error => null;
      end;
      Coordination.Record_Close (Saw_Close, Code);
      Sockets.Close_Socket (Peer);
      Sockets.Close_Socket (Listener);
   exception
      when Occurrence : others =>
         Coordination.Record_Close (Saw_Close, Code);
         Coordination.Server_Failed
           (Ada.Exceptions.Exception_Information (Occurrence));
         if Sockets.Is_Open (Peer) then
            Sockets.Close_Socket (Peer);
         end if;
         if Sockets.Is_Open (Listener) then
            Sockets.Close_Socket (Listener);
         end if;
   end Raw_Peer;

   Port   : Sockets.Port;
   Client : WS.Client;
   Value  : WS.Request;
begin
   Note
     ("WEBSOCKET-3: no Close frame is sent when the client fails the "
      & "connection");
   Coordination.Wait_Ready (Port);
   WS.Configure
     (Client,
      WS.Parse_Origin
        ("ws://127.0.0.1:"
         & Ada.Strings.Fixed.Trim
             (Natural'Image (Natural (Port)), Ada.Strings.Left)));
   WS.Set_Target (Value, "/socket");
   WS.Connect (Client, Value, Timeout => 5.0);
   Check (WS.Is_Open (Client), "the upgrade completes");

   declare
      Kind   : WS.Data_Kind;
      Data   : Flyology.Bytes.Unbounded_Bytes;
      Closed : Boolean;
      Raised : Boolean := False;
   begin
      begin
         WS.Receive (Client, Kind, Data, Closed, Timeout => 5.0);
      exception
         when Occurrence : Flyology.HTTP.Protocol_Error =>
            Raised := True;
            Note
              ("Receive raised Protocol_Error: "
               & Ada.Exceptions.Exception_Message (Occurrence));
      end;
      Check (Raised, "the invalid UTF-8 text frame is detected");
      Check (not WS.Is_Open (Client), "the session is no longer open");
   end;

   --  Give the peer a moment to observe the close or the EOF.
   delay 0.5;
   Note
     ("peer saw a Close frame = " & Boolean'Image (Coordination.Close_Seen)
      & ", status code =" & Integer'Image (Coordination.Close_Code));
   Check
     (Coordination.Close_Seen,
      "the client sends a Close frame before closing the connection");
   Check
     (Coordination.Close_Code = 1_007,
      "the Close frame carries 1007 (invalid frame payload data)");
   if Coordination.Server_Note /= "" then
      Note ("raw peer note: " & Coordination.Server_Note);
   end if;
   Finish;
end Repro_Websocket_3;
