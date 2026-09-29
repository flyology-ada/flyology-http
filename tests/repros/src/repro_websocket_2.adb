--  WEBSOCKET-2: the client's Close drains the peer close under the 1 MiB
--  Default_Max_Message rather than the bound the application has been using,
--  so a larger message already in flight makes Close raise Message_Too_Large
--  and abort the close handshake it started.
--
--  websocket_client.adb:1372-1374 calls Receive with no Max_Message, so the
--  drain runs under Default_Max_Message (.ads:17, 1 MiB).  Receive classifies
--  the frame with that Maximum, raises Message_Too_Large (:1210, :1222-1233),
--  and the handler at :1315-1317 drops the transport, so the exception leaves
--  Close and the peer never receives the close echo it is waiting for.
--
--  Close's documented exceptions (.ads:305-314) are Program_Error,
--  Constraint_Error, Connection_Error, Flyology.IO.Timeout_Error and
--  Flyology.Cancellation.Operation_Cancelled.  Message_Too_Large is not among
--  them.
--
--  This is the client-side analogue of prior finding 34, which was fixed on
--  the server by retaining the last bound (server.adb:4813-4816).
--
--  Scenario: the application receives under Max_Message => 2 MiB, the peer
--  sends a 1 MiB + 1 binary message that crosses the client's Close on the
--  wire, and the application then calls Close.  RFC 6455 5.5.1 and 7.1.1:
--  the endpoint that sent a Close waits for the peer's Close before closing
--  the connection, and data already in flight is expected.
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

procedure Repro_Websocket_2 is
   package WS renames Flyology.HTTP.WebSocket_Client;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use Repro_Support;
   use type Sockets.Selector_Status;
   use type WS.Data_Kind;

   GUID : constant String := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
   Big_Length : constant := 1_024 * 1_024 + 1;

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
      procedure Record_Close (Seen : Boolean);
      function Close_Seen return Boolean;
      procedure Server_Failed (Text : String);
      function Server_Note return String;
   private
      Port_Value : Sockets.Port := Sockets.Any_Port;
      Ready      : Boolean := False;
      Saw_Close  : Boolean := False;
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

      procedure Record_Close (Seen : Boolean) is
      begin
         Saw_Close := Seen;
      end Record_Close;

      function Close_Seen return Boolean is (Saw_Close);

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
      --  One small text message the application consumes, then a binary
      --  message one byte above the 1 MiB default bound which crosses the
      --  client's Close on the wire.
      Sockets.Send_All
        (Peer, (16#81#, 16#02#, 16#68#, 16#69#), Timeout => 5.0);
      Sockets.Send_All
        (Peer,
         (16#82#, 16#7F#, 0, 0, 0, 0, 0, 16#10#, 0, 1),
         Timeout => 10.0);
      declare
         Chunk : constant Stream_Element_Array (1 .. 4_096) :=
           (others => 16#41#);
         Sent  : Natural := 0;
      begin
         while Sent < Big_Length loop
            if Big_Length - Sent >= Chunk'Length then
               Sockets.Send_All (Peer, Chunk, Timeout => 20.0);
               Sent := Sent + Natural (Chunk'Length);
            else
               Sockets.Send_All
                 (Peer,
                  Chunk
                    (1 .. Stream_Element_Offset (Big_Length - Sent)),
                  Timeout => 20.0);
               Sent := Big_Length;
            end if;
         end loop;
      end;
      --  Answer the client's Close with the echo the handshake expects.
      begin
         loop
            Sockets.Receive (Peer, Buffer, Last, Timeout => 10.0);
            exit when Last < Buffer'First;
            for Index in Buffer'First .. Last loop
               if Buffer (Index) = 16#88# then
                  Saw_Close := True;
               end if;
            end loop;
            if Saw_Close then
               Sockets.Send_All
                 (Peer, (16#88#, 16#02#, 16#03#, 16#E8#), Timeout => 5.0);
               exit;
            end if;
         end loop;
      exception
         when Flyology.IO.Timeout_Error => null;
      end;
      begin
         loop
            Sockets.Receive (Peer, Buffer, Last, Timeout => 3.0);
            exit when Last < Buffer'First;
         end loop;
      exception
         when Flyology.IO.Timeout_Error => null;
      end;
      Coordination.Record_Close (Saw_Close);
      Sockets.Close_Socket (Peer);
      Sockets.Close_Socket (Listener);
   exception
      when Occurrence : others =>
         Coordination.Record_Close (Saw_Close);
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
     ("WEBSOCKET-2: Close drains under the 1 MiB default, not the "
      & "application's bound");
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
   begin
      --  The application's own bound, well above the 1 MiB default.
      WS.Receive
        (Client, Kind, Data, Closed,
         Max_Message => 2 * 1_024 * 1_024, Timeout => 10.0);
      Check
        (Flyology.Bytes.To_Byte_String (Data) = "hi",
         "the first message is delivered under the application's bound");
   end;

   declare
      Raised : Unbounded_String;
   begin
      begin
         WS.Close (Client, Timeout => 20.0);
      exception
         when Occurrence : others =>
            Raised := To_Unbounded_String
              (Ada.Exceptions.Exception_Name (Occurrence)
               & ": " & Ada.Exceptions.Exception_Message (Occurrence));
            Note ("Close raised " & To_String (Raised));
      end;
      Check
        (Raised = Null_Unbounded_String,
         "Close completes the handshake it started instead of raising an "
         & "exception its contract does not list");
   end;

   declare
      Code : Integer := -1;
   begin
      begin
         Code := WS.Close_Code (Client);
      exception
         when Occurrence : others =>
            Note
              ("Close_Code raised "
               & Ada.Exceptions.Exception_Name (Occurrence));
      end;
      Note ("Close_Code =" & Integer'Image (Code));
      Check (Code = 1_000, "the peer close status is available after Close");
   end;

   delay 0.5;
   Note
     ("peer saw the client Close frame = "
      & Boolean'Image (Coordination.Close_Seen));
   if Coordination.Server_Note /= "" then
      Note ("raw peer note: " & Coordination.Server_Note);
   end if;
   Finish;
end Repro_Websocket_2;
