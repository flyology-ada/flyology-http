with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Flyology.Bytes;
with Flyology.HTTP.Client;
with Flyology.IO.Sockets;
with H2_Wire;
with Repro_Support;

--  H2-1.  RFC 9113 6.5.2 permits a server to send SETTINGS_ENABLE_PUSH with
--  the value 0; only the value 1 is a connection error for a client.  This
--  spike asserts that permitted behaviour twice: once against
--  HTTP_2_Settings.Apply directly, and once end to end against a raw HTTP/2
--  server peer whose first SETTINGS frame carries ENABLE_PUSH = 0.
procedure Flyology.HTTP.HTTP_2_Settings.Repro_H2_1 is
   use Ada.Streams;
   use Repro_Support;
   package Client renames Flyology.HTTP.Client;
   package Sockets renames Flyology.IO.Sockets;
   use H2_Wire;

   function Decimal (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   --  SETTINGS_ENABLE_PUSH (0x02) = 0, which RFC 9113 6.5.2 explicitly
   --  allows a server to include.
   Server_Push_Off : constant Stream_Element_Array :=
     (0, 2, 0, 0, 0, 0);

   --  The complete SETTINGS payload an unmodified h2 4.3.0 server sends in
   --  its first flight, byte for byte (see
   --  review/evidence/h2_1_h2_server_settings.log).  h2 4.3.0 is the pinned
   --  peer in tests/requirements-http2.txt and
   --  tests/requirements-client-differential.txt.
   Pinned_Peer_Settings : constant Stream_Element_Array :=
     (16#00#, 16#01#, 16#00#, 16#00#, 16#10#, 16#00#,
      16#00#, 16#02#, 16#00#, 16#00#, 16#00#, 16#00#,
      16#00#, 16#04#, 16#00#, 16#00#, 16#FF#, 16#FF#,
      16#00#, 16#05#, 16#00#, 16#00#, 16#40#, 16#00#,
      16#00#, 16#08#, 16#00#, 16#00#, 16#00#, 16#00#,
      16#00#, 16#03#, 16#00#, 16#00#, 16#00#, 16#64#,
      16#00#, 16#06#, 16#00#, 16#01#, 16#00#, 16#00#);

   Item   : State;
   Result : Apply_Result;

   Listener : Sockets.Socket_Type;
   Address  : Sockets.Endpoint;
begin
   Note ("H2-1: a server may send SETTINGS_ENABLE_PUSH = 0 (RFC 9113 6.5.2)");

   --  1. The settings unit itself, with the default Peer_Is_Server => True
   --  that both engines use for a server peer.
   Apply (Item, Pinned_Peer_Settings, Result);
   Check
     (Result = Settings_Accepted,
      "Apply accepts the pinned h2 4.3.0 server's first SETTINGS payload");
   Note ("  Apply returned " & Apply_Result'Image (Result));
   Apply (Item, Server_Push_Off, Result);
   Check
     (Result = Settings_Accepted,
      "Apply accepts ENABLE_PUSH = 0 from a server peer");
   Note ("  Apply returned " & Apply_Result'Image (Result));
   if Result = Settings_Accepted then
      Check (not Item.Enable_Push, "ENABLE_PUSH = 0 disables push");
   end if;

   --  The value 1 from a server is the only case RFC 9113 6.5.2 makes an
   --  error, and it must stay one.
   Apply (Item, (0, 2, 0, 0, 0, 1), Result);
   Check
     (Result = Settings_Protocol_Error,
      "Apply still rejects ENABLE_PUSH = 1 from a server peer");

   --  2. End to end: the library client against a raw peer that sends the
   --  permitted setting and then a complete 200 response.
   Address := Listen_Loopback (Listener);

   declare
      task Peer_Task is
         pragma Task_Info (Flyology.Native_Task);
      end Peer_Task;

      task body Peer_Task is
         Socket  : Sockets.Socket_Type;
         Where   : Sockets.Endpoint;
         Opening : Stream_Element_Array (1 .. Preface'Length);
         Info    : Frame_Info;
         Payload : Stream_Element_Array (1 .. 16_384) := (others => 0);
         Opened  : Natural := 0;
      begin
         Sockets.Accept_Connection
           (Listener, Socket, Where, Timeout => 10.0);
         Sockets.Receive_Exactly (Socket, Opening, Timeout => 10.0);
         Send_Frame (Socket, Settings_Frame, 0, 0, Pinned_Peer_Settings);
         while Opened = 0 loop
            Read_Frame_Header (Socket, Info, Wait => 10.0);
            Read_Payload (Socket, Info, Payload, Wait => 10.0);
            if Info.Kind = Settings_Frame
              and then (Info.Flags and Ack_Flag) = 0
            then
               Send_Frame (Socket, Settings_Frame, Ack_Flag, 0, Empty);
            elsif Info.Kind = Goaway_Frame then
               exit;
            elsif Info.Kind = Headers_Frame then
               Opened := Info.Stream_ID;
            end if;
         end loop;
         if Opened /= 0 then
            --  Indexed field 8 is ":status: 200".
            Send_Frame
              (Socket, Headers_Frame, End_Headers_Flag, Opened,
               Stream_Element_Array'(1 => 16#88#));
            Send_Frame
              (Socket, Data_Frame, End_Stream_Flag, Opened,
               Text_Bytes ("ok"));
            delay 0.50;
         end if;
         Sockets.Close_Socket (Socket);
      exception
         when others => null;
      end Peer_Task;

      Origin : constant String :=
        "http://127.0.0.1:" & Decimal (Natural (Address.Port));
      Session : aliased Client.Client (Capacity => 1);
      Served  : Boolean := False;
      Detail  : String (1 .. 200) := (others => ' ');
      Detail_Last : Natural := 0;
   begin
      Client.Configure
        (Session, Flyology.HTTP.Parse_Origin (Origin),
         Client.HTTP_2_Prior_Knowledge);
      declare
         Ask : Client.Request;
      begin
         Client.Set_Target (Ask, "/push-off");
         declare
            Reply : Client.Response :=
              Client.Execute (Session, Ask, Timeout => 10.0);
            Content : constant String :=
              Flyology.Bytes.To_Byte_String (Client.Read_All (Reply));
         begin
            Served := Client.Status (Reply) = 200 and then Content = "ok";
         end;
      exception
         when Event : others =>
            declare
               Text : constant String :=
                 Ada.Exceptions.Exception_Name (Event) & ": " &
                 Ada.Exceptions.Exception_Message (Event);
            begin
               Detail_Last := Natural'Min (Text'Length, Detail'Length);
               Detail (1 .. Detail_Last) := Text (1 .. Detail_Last);
            end;
      end;
      if Detail_Last > 0 then
         Note ("  client raised " & Detail (1 .. Detail_Last));
      end if;
      Check
        (Served,
         "the client serves a request to a server that sent ENABLE_PUSH = 0");
      Client.Shutdown (Session, Timeout => 5.0);
   end;

   Sockets.Close_Socket (Listener);
   Finish;
end Flyology.HTTP.HTTP_2_Settings.Repro_H2_1;
