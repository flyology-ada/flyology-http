with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Flyology;
with Flyology.Bytes;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Headers;
with Flyology.HTTP.Server;
with Flyology.HTTP.WebSocket_Client;
with Flyology.IO;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;

procedure WebSocket_Client_Smoke is
   package WS renames Flyology.HTTP.WebSocket_Client;
   package HTTP_Server renames Flyology.HTTP.Server;
   package Connections renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use type Sockets.Selector_Status;
   use type HTTP_Server.WebSocket_Data_Kind;
   use type WS.Data_Kind;
   use type WS.WebSocket_Scheme;

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

   function Text (Value : Stream_Element_Array) return String is
      Result : String (1 .. Natural (Value'Length));
      Cursor : Natural := 0;
   begin
      for Element of Value loop
         Cursor := Cursor + 1;
         Result (Cursor) := Character'Val (Element);
      end loop;
      return Result;
   end Text;

   function Decimal (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal;

   protected Coordination is
      procedure Publish (Value : Sockets.Port);
      procedure Finish (Passed : Boolean);
      entry Wait_Ready (Value : out Sockets.Port);
      entry Wait_Done (Passed : out Boolean);
   private
      Port_Value : Sockets.Port := Sockets.Any_Port;
      Ready : Boolean := False;
      Done  : Boolean := False;
      OK    : Boolean := True;
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

      entry Wait_Ready (Value : out Sockets.Port) when Ready is
      begin
         Value := Port_Value;
      end Wait_Ready;

      entry Wait_Done (Passed : out Boolean) when Done is
      begin
         Passed := OK;
      end Wait_Done;
   end Coordination;

   type Server_Mode is
     (Exchange_Data, Peer_Close, Masked_Frame, Oversized_Message,
      Partial_Timeout, Queued_Before_Close, Registered_Close,
      Wrong_Status, Missing_Status_Separator, Wrong_Accept, Empty_Protocol,
      Unoffered_Protocol, Unexpected_Extension, Malformed_Upgrade_List,
      Malformed_Connection_List, Framed_Content_Length,
      Framed_Transfer_Encoding, Malformed_Head, Oversized_Head,
      Stalled_Handshake_Timeout, Stalled_Handshake_Cancel,
      Stalled_Receive_Cancel, Stalled_Close_Timeout,
      Stalled_Close_Cancel, Send_Timeout, Send_Cancel);

   function Mutates_Handshake (Mode : Server_Mode) return Boolean is
     (Mode in Wrong_Status | Missing_Status_Separator | Wrong_Accept |
        Empty_Protocol | Unoffered_Protocol | Unexpected_Extension |
        Malformed_Upgrade_List | Malformed_Connection_List |
        Framed_Content_Length | Framed_Transfer_Encoding | Malformed_Head |
        Oversized_Head);

   type Matrix_Transport
     (Channel : not null access Connections.Connection;
      Mode    : Server_Mode)
   is limited new HTTP_Server.Transport with record
      Handshake_Sent : Boolean := False;
   end record;

   overriding procedure Receive
     (Item    : in out Matrix_Transport;
      Data    : out Stream_Element_Array;
      Last    : out Stream_Element_Offset;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);

   overriding procedure Send_All
     (Item    : in out Matrix_Transport;
      Data    : Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token);

   overriding procedure Receive
     (Item    : in out Matrix_Transport;
      Data    : out Stream_Element_Array;
      Last    : out Stream_Element_Offset;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token) is
   begin
      Connections.Receive
        (Item.Channel.all, Data, Last, Timeout, Token => Token);
   end Receive;

   overriding procedure Send_All
     (Item    : in out Matrix_Transport;
      Data    : Stream_Element_Array;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token)
   is
      use Ada.Strings.Unbounded;
      Wire : constant String := Text (Data);
      Output : Unbounded_String := To_Unbounded_String (Wire);
      Position : Natural;
   begin
      if not Item.Handshake_Sent and then Mutates_Handshake (Item.Mode) then
         Item.Handshake_Sent := True;
         case Item.Mode is
            when Wrong_Status =>
               Position := Ada.Strings.Fixed.Index (Wire, "HTTP/1.1 101");
               pragma Assert (Position /= 0);
               declare
                  Changed : String := Wire;
               begin
                  Changed (Position + 9 .. Position + 11) := "400";
                  Output := To_Unbounded_String (Changed);
               end;
            when Missing_Status_Separator =>
               Position := Ada.Strings.Fixed.Index (Wire, "HTTP/1.1 101 ");
               pragma Assert (Position /= 0);
               declare
                  Changed : String := Wire;
               begin
                  Changed (Position + 12) := Character'Val (9);
                  Output := To_Unbounded_String (Changed);
               end;
            when Wrong_Accept =>
               declare
                  Prefix : constant String := "Sec-WebSocket-Accept: ";
                  Changed : String := Wire;
               begin
                  Position := Ada.Strings.Fixed.Index (Wire, Prefix);
                  pragma Assert (Position /= 0);
                  Position := Position + Prefix'Length;
                  Changed (Position) :=
                    (if Changed (Position) = 'A' then 'B' else 'A');
                  Output := To_Unbounded_String (Changed);
               end;
            when Empty_Protocol | Unoffered_Protocol =>
               declare
                  Prefix : constant String := "Sec-WebSocket-Protocol: ";
                  Changed : String := Wire;
               begin
                  Position := Ada.Strings.Fixed.Index (Wire, Prefix);
                  pragma Assert (Position /= 0);
                  Position := Position + Prefix'Length;
                  Changed (Position .. Position + 3) :=
                    (if Item.Mode = Empty_Protocol then "    " else "nope");
                  Output := To_Unbounded_String (Changed);
               end;
            when Unexpected_Extension | Malformed_Upgrade_List |
                 Malformed_Connection_List | Framed_Content_Length |
                 Framed_Transfer_Encoding | Malformed_Head | Oversized_Head =>
               Position := Ada.Strings.Fixed.Index (Wire, CRLF & CRLF);
               pragma Assert (Position /= 0);
               declare
                  Inserted : constant String :=
                    (case Item.Mode is
                       when Unexpected_Extension =>
                         "Sec-WebSocket-Extensions: permessage-deflate",
                       when Malformed_Upgrade_List => "Upgrade: ,",
                       when Malformed_Connection_List => "Connection: upgrade,",
                       when Framed_Content_Length => "Content-Length: 0",
                       when Framed_Transfer_Encoding =>
                         "Transfer-Encoding: chunked",
                       when Malformed_Head => " folded: yes",
                       when Oversized_Head =>
                         "X-Large: " & String'
                           (1 .. Flyology.HTTP.Headers.Default_Max_Bytes + 1 =>
                              'x'),
                       when others => "");
               begin
                  Output := To_Unbounded_String
                    (Wire (Wire'First .. Position + 1) & Inserted & CRLF &
                     Wire (Position + 2 .. Wire'Last));
               end;
            when others =>
               null;
         end case;
      end if;
      Connections.Send_All
        (Item.Channel.all, Bytes (To_String (Output)), Timeout,
         Token => Token);
   end Send_All;

   task Server_Task is
      pragma Task_Info (Flyology.Native_Task);
   end Server_Task;

   task body Server_Task is
      Listener : Sockets.Socket_Type;
      Manager  : aliased Connections.Server (Capacity => 1);

      procedure Serve (Mode : Server_Mode) is
         Socket  : Sockets.Socket_Type;
         Address : Sockets.Endpoint;
         Status  : Sockets.Selector_Status;
         Channel : aliased Connections.Connection;
      begin
         Sockets.Accept_Socket
           (Listener, Socket, Address, Timeout => 5.0, Status => Status);
         pragma Assert (Status = Sockets.Completed);
         Connections.Take (Manager, Socket, Channel);
         declare
            Transport : aliased Matrix_Transport (Channel'Access, Mode);
            Connection : HTTP_Server.Connection (Transport'Access);
            Request : HTTP_Server.Request;
            Request_Closed : Boolean;
         begin
            HTTP_Server.Read_Request
              (Connection, Request, Request_Closed, Timeout => 5.0);
            pragma Assert (not Request_Closed);
            pragma Assert (HTTP_Server.Target (Request) = "/socket?room=ada");
            pragma Assert (HTTP_Server.Header (Request, "X-Test") = "yes");
            if Mode in
              Stalled_Handshake_Timeout | Stalled_Handshake_Cancel
            then
               delay 0.1;
            else
               HTTP_Server.Accept_WebSocket
                 (Connection, Request, Protocol => "chat",
                  Origin_Policy => HTTP_Server.Require_Exact_Origin,
                  Allowed_Origin => "https://app.example", Timeout => 5.0);
            end if;

            if Mutates_Handshake (Mode)
              or else Mode in
                Stalled_Handshake_Timeout | Stalled_Handshake_Cancel
            then
               null;
            elsif Mode = Peer_Close then
               HTTP_Server.Close_WebSocket
                 (Connection, Code => 1_001, Reason => "server done",
                  Timeout => 5.0);
            elsif Mode = Queued_Before_Close then
               HTTP_Server.Send_WebSocket
                 (Connection, "queued-before-close", Timeout => 5.0);
               HTTP_Server.Close_WebSocket
                 (Connection, Code => 1_000, Reason => "queued",
                  Timeout => 5.0);
            elsif Mode = Registered_Close then
               HTTP_Server.Close_WebSocket
                 (Connection, Code => 1_012, Reason => "restart",
                  Timeout => 5.0);
            elsif Mode = Masked_Frame then
               Connections.Send_All
                 (Channel, [16#81#, 16#80#, 1, 2, 3, 4], Timeout => 5.0);
            elsif Mode = Oversized_Message then
               Connections.Send_All
                 (Channel,
                  [16#81#, 6, Character'Pos ('1'), Character'Pos ('2'),
                   Character'Pos ('3'), Character'Pos ('4'),
                   Character'Pos ('5'), Character'Pos ('6')],
                  Timeout => 5.0);
            elsif Mode = Partial_Timeout then
               Connections.Send_All
                 (Channel, [16#81#, 5, Character'Pos ('a')], Timeout => 5.0);
               delay 0.1;
            elsif Mode in
              Stalled_Receive_Cancel | Stalled_Close_Timeout |
                Stalled_Close_Cancel | Send_Timeout | Send_Cancel
            then
               delay 0.1;
            else
               --  One fragmented text message with an interleaved ping.
               Connections.Send_All
                 (Channel,
                  [16#01#, 3, Character'Pos ('h'), Character'Pos ('e'),
                   Character'Pos ('l'),
                   16#89#, 1, Character'Pos ('p'),
                   16#80#, 2, Character'Pos ('l'), Character'Pos ('o')],
                  Timeout => 5.0);
               declare
                  Kind : HTTP_Server.WebSocket_Data_Kind;
                  Data : Flyology.Bytes.Unbounded_Bytes;
                  Closed : Boolean;
               begin
                  HTTP_Server.Receive_WebSocket
                    (Connection, Kind, Data, Closed, Timeout => 5.0,
                     Message_Timeout => 5.0);
                  pragma Assert (not Closed);
                  pragma Assert (Kind = HTTP_Server.Text_Frame);
                  pragma Assert
                    (Flyology.Bytes.To_Byte_String (Data) = "from-client");
               end;
               HTTP_Server.Send_WebSocket
                 (Connection, HTTP_Server.Binary_Frame,
                  Stream_Element_Array'[1, 2, 3], Timeout => 5.0);
               declare
                  Kind : HTTP_Server.WebSocket_Data_Kind;
                  Data : Flyology.Bytes.Unbounded_Bytes;
                  Closed : Boolean;
               begin
                  HTTP_Server.Receive_WebSocket
                    (Connection, Kind, Data, Closed, Timeout => 5.0,
                     Message_Timeout => 5.0);
                  pragma Assert (Closed);
               end;
            end if;
         end;
         Connections.Close (Channel);
      end Serve;
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener);
      Coordination.Publish (Sockets.Get_Socket_Name (Listener).Port);
      for Lane in 1 .. 2 loop
         Serve (Exchange_Data);
         Serve (Peer_Close);
         Serve (Masked_Frame);
         Serve (Oversized_Message);
         Serve (Partial_Timeout);
         Serve (Queued_Before_Close);
         Serve (Registered_Close);
         Serve (Wrong_Status);
         Serve (Missing_Status_Separator);
         Serve (Wrong_Accept);
         Serve (Empty_Protocol);
         Serve (Unoffered_Protocol);
         Serve (Unexpected_Extension);
         Serve (Malformed_Upgrade_List);
         Serve (Malformed_Connection_List);
         Serve (Framed_Content_Length);
         Serve (Framed_Transfer_Encoding);
         Serve (Malformed_Head);
         Serve (Oversized_Head);
         Serve (Stalled_Handshake_Timeout);
         Serve (Stalled_Handshake_Cancel);
         Serve (Stalled_Receive_Cancel);
         Serve (Stalled_Close_Timeout);
         Serve (Stalled_Close_Cancel);
         Serve (Send_Timeout);
         Serve (Send_Cancel);
      end loop;
      Sockets.Close_Socket (Listener);
      Coordination.Finish (True);
   exception
      when Occurrence : others =>
         Ada.Text_IO.Put_Line
           ("WebSocket client server failed: " &
            Ada.Exceptions.Exception_Information (Occurrence));
         if Sockets.Is_Open (Listener) then
            Sockets.Close_Socket (Listener);
         end if;
         Coordination.Finish (False);
   end Server_Task;

   procedure Exercise is
      Port : Sockets.Port;
      Client : WS.Client;
      Request : WS.Request;
      Origin : WS.WebSocket_Origin;

      procedure Expect_Handshake_Rejection (Mode : Server_Mode) is
         Rejected : Boolean := False;
         Metadata_Hidden : Boolean := False;
      begin
         begin
            WS.Connect (Client, Request, Timeout => 5.0);
         exception
            when Flyology.HTTP.Protocol_Error => Rejected := True;
         end;
         begin
            declare
               Count : constant Natural := WS.Header_Count (Client);
               pragma Unreferenced (Count);
            begin
               null;
            end;
         exception
            when Program_Error => Metadata_Hidden := True;
         end;
         pragma Assert
           (Rejected
            and then Metadata_Hidden
            and then not WS.Is_Open (Client),
            "handshake mode was accepted: " & Server_Mode'Image (Mode));
      end Expect_Handshake_Rejection;

      procedure Expect_Cancellation
        (Action : not null access procedure
           (Token : access Flyology.Cancellation.Token))
      is
         Token : aliased Flyology.Cancellation.Token;
         Cancelled : Boolean := False;
         task Trigger;
         task body Trigger is
         begin
            delay 0.02;
            Token.Request;
         end Trigger;
      begin
         begin
            Action (Token'Access);
         exception
            when Flyology.Cancellation.Operation_Cancelled =>
               Cancelled := True;
         end;
         pragma Assert (Cancelled and then not WS.Is_Open (Client));
      end Expect_Cancellation;

      procedure Cancel_Connect
        (Token : access Flyology.Cancellation.Token) is
      begin
         WS.Connect (Client, Request, Timeout => -1.0, Token => Token);
      end Cancel_Connect;

      procedure Cancel_Receive
        (Token : access Flyology.Cancellation.Token)
      is
         Kind : WS.Data_Kind;
         Data : Flyology.Bytes.Unbounded_Bytes;
         Closed : Boolean;
      begin
         WS.Receive
           (Client, Kind, Data, Closed, Timeout => -1.0, Token => Token);
      end Cancel_Receive;

      procedure Cancel_Close
        (Token : access Flyology.Cancellation.Token) is
      begin
         WS.Close (Client, Timeout => -1.0, Token => Token);
      end Cancel_Close;

      procedure Cancel_Send
        (Token : access Flyology.Cancellation.Token)
      is
         type Data_Access is access Stream_Element_Array;
         procedure Free is new Ada.Unchecked_Deallocation
           (Stream_Element_Array, Data_Access);
         Data : Data_Access := new Stream_Element_Array
           (1 .. Stream_Element_Offset (WS.Max_Frame_Length));
      begin
         Data.all := (others => 0);
         WS.Send
           (Client, WS.Binary_Message, Data.all, Timeout => -1.0,
            Token => Token);
         Free (Data);
      exception
         when others =>
            Free (Data);
            raise;
      end Cancel_Send;
   begin
      Coordination.Wait_Ready (Port);
      Origin := WS.Parse_Origin
        ("WS://127.0.0.1:" & Decimal (Natural (Port)));
      pragma Assert (WS.Scheme (Origin) = WS.Plain_WS);
      pragma Assert (WS.Host (Origin) = "127.0.0.1");
      pragma Assert (Natural (WS.Port (Origin)) = Natural (Port));
      pragma Assert
        (WS.Image (Origin) =
           "ws://127.0.0.1:" & Decimal (Natural (Port)));
      WS.Configure (Client, Origin);

      declare
         Plain : constant WS.WebSocket_Origin :=
           WS.Parse_Origin ("ws://Example.COM/");
         Secure : constant WS.WebSocket_Origin :=
           WS.Parse_Origin ("wss://[::1]");
         Rejected : Boolean := False;
      begin
         pragma Assert (WS.Image (Plain) = "ws://example.com");
         pragma Assert (Natural (WS.Port (Plain)) = 80);
         pragma Assert (WS.Scheme (Secure) = WS.Secure_WSS);
         pragma Assert (WS.Host (Secure) = "::1");
         pragma Assert (Natural (WS.Port (Secure)) = 443);
         pragma Assert (WS.Image (Secure) = "wss://[::1]");
         begin
            declare
               Invalid : constant WS.WebSocket_Origin :=
                 WS.Parse_Origin ("http://example.com");
               pragma Unreferenced (Invalid);
            begin
               null;
            end;
         exception
            when Constraint_Error => Rejected := True;
         end;
         pragma Assert (Rejected);
      end;

      declare
         Legacy : WS.Client;
      begin
         WS.Configure
           (Legacy, Flyology.HTTP.Parse_Origin ("http://127.0.0.1"));
      end;

      declare
         Missing_TLS : WS.Client;
         Rejected : Boolean := False;
      begin
         begin
            WS.Configure (Missing_TLS, WS.Parse_Origin ("wss://localhost"));
         exception
            when Program_Error => Rejected := True;
         end;
         pragma Assert (Rejected);
      end;

      declare
         Rejected : Boolean := False;
      begin
         begin
            WS.Add_Header (Request, "Sec-WebSocket-Key", "owned");
         exception
            when Constraint_Error => Rejected := True;
         end;
         pragma Assert (Rejected);
      end;
      WS.Set_Target (Request, "/socket?room=ada");
      WS.Set_Origin (Request, "https://app.example");
      WS.Offer_Protocol (Request, "chat");
      WS.Offer_Protocol (Request, "fallback");
      WS.Add_Header (Request, "X-Test", "yes");

      declare
         Bounded : WS.Request;
         Rejected : Boolean := False;
      begin
         begin
            WS.Offer_Protocol
              (Bounded, String'(1 .. WS.Max_Protocol_Length + 1 => 'x'));
         exception
            when Constraint_Error => Rejected := True;
         end;
         pragma Assert (Rejected);
      end;

      declare
         Bounded : WS.Request;
         Rejected : Boolean := False;
      begin
         begin
            WS.Set_Origin
              (Bounded, String'(1 .. 16 * 1_024 => 'x'));
         exception
            when Constraint_Error => Rejected := True;
         end;
         pragma Assert (Rejected);
      end;

      declare
         Bounded : WS.Request;
         Rejected : Boolean := False;
      begin
         for Index in 1 .. WS.Max_Protocol_Count - 1 loop
            declare
               Value : String (1 .. WS.Max_Protocol_Length) :=
                 (others => 'a');
            begin
               Value (Value'Last) := Character'Val
                 (Character'Pos ('A') + Index - 1);
               WS.Offer_Protocol (Bounded, Value);
            end;
         end loop;
         begin
            WS.Offer_Protocol
              (Bounded, String'(1 .. WS.Max_Protocol_Length => 'z'));
         exception
            when Constraint_Error => Rejected := True;
         end;
         pragma Assert (Rejected);
      end;

      declare
         Bounded : WS.Request;
         Rejected : Boolean := False;
      begin
         for Index in 1 .. WS.Max_Protocol_Count loop
            WS.Offer_Protocol (Bounded, "p" & Decimal (Index));
         end loop;
         begin
            WS.Offer_Protocol (Bounded, "overflow");
         exception
            when Constraint_Error => Rejected := True;
         end;
         pragma Assert (Rejected);
      end;

      declare
         Token : aliased Flyology.Cancellation.Token;
         Cancelled : Boolean := False;
      begin
         Token.Request;
         begin
            WS.Connect
              (Client, Request, Timeout => -1.0, Token => Token'Access);
         exception
            when Flyology.Cancellation.Operation_Cancelled =>
               Cancelled := True;
         end;
         pragma Assert (Cancelled and then not WS.Is_Open (Client));
      end;

      WS.Connect (Client, Request, Timeout => 5.0);
      pragma Assert (WS.Is_Open (Client));
      pragma Assert (WS.Negotiated_Protocol (Client) = "chat");
      pragma Assert (WS.Header_Count (Client, "upgrade") = 1);
      pragma Assert (WS.Header_Count (Client) >= 3);
      pragma Assert (WS.Header_Name (Client, 1) /= "");
      pragma Assert (WS.Header_Value (Client, 1) /= "");
      pragma Assert (WS.Header (Client, "Sec-WebSocket-Accept") /= "");
      declare
         type String_Access is access String;
         procedure Free is new Ada.Unchecked_Deallocation
           (String, String_Access);
         Value : String_Access := new String'
           (1 .. WS.Max_Frame_Length + 1 => 'x');
         Rejected : Boolean := False;
      begin
         begin
            WS.Send (Client, Value.all, Timeout => 5.0);
         exception
            when Constraint_Error => Rejected := True;
         end;
         Free (Value);
         pragma Assert (Rejected);
      exception
         when others =>
            Free (Value);
            raise;
      end;
      declare
         Kind : WS.Data_Kind;
         Data : Flyology.Bytes.Unbounded_Bytes;
         Closed : Boolean;
      begin
         WS.Receive
           (Client, Kind, Data, Closed, Max_Message => 5, Timeout => 5.0);
         pragma Assert (not Closed and then Kind = WS.Text_Message);
         pragma Assert (Flyology.Bytes.To_Byte_String (Data) = "hello");
      end;
      WS.Send (Client, "from-client", Timeout => 5.0);
      declare
         Kind : WS.Data_Kind;
         Data : Flyology.Bytes.Unbounded_Bytes;
         Closed : Boolean;
      begin
         WS.Receive (Client, Kind, Data, Closed, Timeout => 5.0);
         pragma Assert (not Closed and then Kind = WS.Binary_Message);
         pragma Assert (Flyology.Bytes.To_Array (Data) = [1, 2, 3]);
      end;
      WS.Close (Client, Reason => "client done", Timeout => 5.0);
      pragma Assert (not WS.Is_Open (Client));
      pragma Assert (WS.Close_Code (Client) = 1_000);
      pragma Assert (WS.Close_Reason (Client) = "client done");

      WS.Connect (Client, Request, Timeout => 5.0);
      declare
         Kind : WS.Data_Kind;
         Data : Flyology.Bytes.Unbounded_Bytes;
         Closed : Boolean;
      begin
         WS.Receive (Client, Kind, Data, Closed, Timeout => 5.0);
         pragma Assert (Closed);
      end;
      pragma Assert (WS.Close_Code (Client) = 1_001);
      pragma Assert (WS.Close_Reason (Client) = "server done");

      WS.Connect (Client, Request, Timeout => 5.0);
      declare
         Kind : WS.Data_Kind;
         Data : Flyology.Bytes.Unbounded_Bytes;
         Closed : Boolean;
         Rejected : Boolean := False;
      begin
         begin
            WS.Receive (Client, Kind, Data, Closed, Timeout => 5.0);
         exception
            when Flyology.HTTP.Protocol_Error => Rejected := True;
         end;
         pragma Assert (Rejected and then not WS.Is_Open (Client));
      end;

      WS.Connect (Client, Request, Timeout => 5.0);
      declare
         Kind : WS.Data_Kind;
         Data : Flyology.Bytes.Unbounded_Bytes;
         Closed : Boolean;
         Rejected : Boolean := False;
      begin
         begin
            WS.Receive
              (Client, Kind, Data, Closed, Max_Message => 5, Timeout => 5.0);
         exception
            when WS.Message_Too_Large => Rejected := True;
         end;
         pragma Assert (Rejected and then not WS.Is_Open (Client));
      end;

      WS.Connect (Client, Request, Timeout => 5.0);
      declare
         Kind : WS.Data_Kind;
         Data : Flyology.Bytes.Unbounded_Bytes;
         Closed : Boolean;
         Timed_Out : Boolean := False;
      begin
         begin
            WS.Receive (Client, Kind, Data, Closed, Timeout => 0.02);
         exception
            when Flyology.IO.Timeout_Error => Timed_Out := True;
         end;
         pragma Assert (Timed_Out and then not WS.Is_Open (Client));
      end;

      --  Data already queued before the peer observes our Close is discarded
      --  while the client continues the closing handshake.
      WS.Connect (Client, Request, Timeout => 5.0);
      WS.Close (Client, Timeout => 5.0);
      pragma Assert (WS.Close_Code (Client) = 1_000);
      pragma Assert (WS.Close_Reason (Client) = "queued");

      WS.Connect (Client, Request, Timeout => 5.0);
      declare
         Kind : WS.Data_Kind;
         Data : Flyology.Bytes.Unbounded_Bytes;
         Closed : Boolean;
      begin
         WS.Receive (Client, Kind, Data, Closed, Timeout => 5.0);
         pragma Assert (Closed);
      end;
      pragma Assert (WS.Close_Code (Client) = 1_012);
      pragma Assert (WS.Close_Reason (Client) = "restart");

      for Mode in Wrong_Status .. Oversized_Head loop
         pragma Assert (Mutates_Handshake (Mode));
         Expect_Handshake_Rejection (Mode);
      end loop;

      declare
         Timed_Out : Boolean := False;
      begin
         begin
            WS.Connect (Client, Request, Timeout => 0.02);
         exception
            when Flyology.IO.Timeout_Error => Timed_Out := True;
         end;
         pragma Assert (Timed_Out and then not WS.Is_Open (Client));
      end;

      Expect_Cancellation (Cancel_Connect'Access);

      WS.Connect (Client, Request, Timeout => 5.0);
      Expect_Cancellation (Cancel_Receive'Access);

      WS.Connect (Client, Request, Timeout => 5.0);
      declare
         Timed_Out : Boolean := False;
      begin
         begin
            WS.Close (Client, Timeout => 0.02);
         exception
            when Flyology.IO.Timeout_Error => Timed_Out := True;
         end;
         pragma Assert (Timed_Out and then not WS.Is_Open (Client));
      end;

      WS.Connect (Client, Request, Timeout => 5.0);
      Expect_Cancellation (Cancel_Close'Access);

      WS.Connect (Client, Request, Timeout => 5.0);
      declare
         type Data_Access is access Stream_Element_Array;
         procedure Free is new Ada.Unchecked_Deallocation
           (Stream_Element_Array, Data_Access);
         Data : Data_Access := new Stream_Element_Array
           (1 .. Stream_Element_Offset (WS.Max_Frame_Length));
         Timed_Out : Boolean := False;
      begin
         Data.all := (others => 0);
         begin
            WS.Send
              (Client, WS.Binary_Message, Data.all, Timeout => 0.02);
         exception
            when Flyology.IO.Timeout_Error => Timed_Out := True;
         end;
         Free (Data);
         pragma Assert (Timed_Out and then not WS.Is_Open (Client));
      exception
         when others =>
            Free (Data);
            raise;
      end;

      WS.Connect (Client, Request, Timeout => 5.0);
      Expect_Cancellation (Cancel_Send'Access);
   end Exercise;

   generic
      Model : Flyology.Execution_Model;
   procedure Run;

   procedure Run is
      protected Outcome is
         procedure Finish (Passed : Boolean);
         entry Wait (Passed : out Boolean);
      private
         Done : Boolean := False;
         OK   : Boolean := False;
      end Outcome;

      protected body Outcome is
         procedure Finish (Passed : Boolean) is
         begin
            OK := Passed;
            Done := True;
         end Finish;

         entry Wait (Passed : out Boolean) when Done is
         begin
            Passed := OK;
         end Wait;
      end Outcome;

      task Caller is
         pragma Task_Info (Model);
      end Caller;

      task body Caller is
      begin
         Exercise;
         Outcome.Finish (True);
      exception
         when Occurrence : others =>
            Ada.Text_IO.Put_Line
              ("WebSocket client failed: " &
               Ada.Exceptions.Exception_Information (Occurrence));
            Outcome.Finish (False);
      end Caller;

      Passed : Boolean;
   begin
      Outcome.Wait (Passed);
      pragma Assert (Passed);
   end Run;

   procedure Run_Native is new Run (Flyology.Native_Task);
   procedure Run_Lightweight is new Run (Flyology.Lightweight_Task);
begin
   Run_Native;
   Run_Lightweight;
   declare
      Passed : Boolean;
   begin
      Coordination.Wait_Done (Passed);
      pragma Assert (Passed);
   end;
end WebSocket_Client_Smoke;
