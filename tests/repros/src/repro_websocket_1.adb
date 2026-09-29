--  WEBSOCKET-1: the client's 32-control-frame bound is scoped to one Receive
--  call rather than to one message or one idle interval, so a server that
--  sends keepalive Pings kills a healthy session on the 33rd.
--
--  websocket_client.adb:32 declares Max_Control_Frames = 32; :1200 makes
--  Control_Count a local of Receive; :1252-1257 raises Protocol_Error when
--  the count passes the bound; the handler at :1315-1317 drops the transport.
--  Nothing resets the counter inside one call, and a negative Timeout, the
--  only way the API offers to wait indefinitely for the next message, keeps
--  the application inside a single call for the whole wait.
--
--  RFC 6455 5.5.2: "A Ping frame MAY serve as a keepalive"; and "Upon
--  receipt of a Ping frame, an endpoint MUST send a Pong frame in response".
--  Neither that section nor 5.4 bounds how many control frames a peer may
--  send.  This program asserts the correct behaviour: a session that has
--  answered 33 Pings still delivers the text message that follows.
--
--  The 33 Pings are sent back to back so the program finishes in
--  milliseconds; the bound has no time component, so the defect is the same
--  one a 30-second keepalive interval reaches after about 16 minutes.

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

procedure Repro_Websocket_1 is
   package WS renames Flyology.HTTP.WebSocket_Client;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use Repro_Support;
   use type Sockets.Selector_Status;
   use type WS.Data_Kind;

   GUID : constant String := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
   Ping_Count : constant := 33;

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
      procedure Record_Pongs (Count : Natural);
      function Pongs return Natural;
      procedure Server_Failed (Text : String);
      function Server_Note return String;
   private
      Port_Value : Sockets.Port := Sockets.Any_Port;
      Ready      : Boolean := False;
      Pong_Count : Natural := 0;
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

      procedure Record_Pongs (Count : Natural) is
      begin
         Pong_Count := Count;
      end Record_Pongs;

      function Pongs return Natural is (Pong_Count);

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
      Pongs    : Natural := 0;
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
      --  Ping_Count unmasked keepalive Pings, then one text message.
      for Index in 1 .. Ping_Count loop
         Sockets.Send_All (Peer, (16#89#, 16#00#), Timeout => 5.0);
      end loop;
      Sockets.Send_All
        (Peer,
         (16#81#, 16#05#, 16#68#, 16#65#, 16#6C#, 16#6C#, 16#6F#),
         Timeout => 5.0);
      --  Count the client's masked Pongs (opcode 10, mask bit set, no
      --  payload: 8A 80 followed by a four-byte mask).
      begin
         loop
            Sockets.Receive (Peer, Buffer, Last, Timeout => 5.0);
            exit when Last < Buffer'First;
            declare
               Index : Stream_Element_Offset := Buffer'First;
            begin
               while Index + 1 <= Last loop
                  if Buffer (Index) = 16#8A# then
                     Pongs := Pongs + 1;
                  end if;
                  Index := Index + 6;
               end loop;
            end;
         end loop;
      exception
         when Flyology.IO.Timeout_Error => null;
      end;
      Coordination.Record_Pongs (Pongs);
      Sockets.Close_Socket (Peer);
      Sockets.Close_Socket (Listener);
   exception
      when Occurrence : others =>
         Coordination.Record_Pongs (Pongs);
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
   Note ("WEBSOCKET-1: control-frame bound scoped to one Receive call");
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
      Kind    : WS.Data_Kind;
      Data    : Flyology.Bytes.Unbounded_Bytes;
      Closed  : Boolean;
      Failure : Unbounded_String;
   begin
      begin
         --  A negative Timeout is the only unlimited wait the API offers.
         WS.Receive (Client, Kind, Data, Closed, Timeout => -1.0);
         Note ("Receive returned kind = " & WS.Data_Kind'Image (Kind));
         Check (not Closed, "the session is not reported closed");
         Check (Kind = WS.Text_Message, "a text message is delivered");
         Expect_Equal
           (Flyology.Bytes.To_Byte_String (Data), "hello",
            "the text message that followed the Pings");
      exception
         when Occurrence : Flyology.HTTP.Protocol_Error =>
            Failure := To_Unbounded_String
              (Ada.Exceptions.Exception_Message (Occurrence));
            Note
              ("Receive raised Protocol_Error: " & To_String (Failure));
            Check
              (False,
               "Receive delivers the text message after"
               & Natural'Image (Ping_Count) & " keepalive Pings");
            Check
              (WS.Is_Open (Client),
               "the session survives the keepalive Pings");
      end;
   end;

   Note
     ("pongs the peer observed =" & Natural'Image (Coordination.Pongs));
   if Coordination.Server_Note /= "" then
      Note ("raw peer note: " & Coordination.Server_Note);
   end if;
   Finish;
end Repro_Websocket_1;
