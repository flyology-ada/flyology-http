with Ada.Streams;
with Ada.Strings.Fixed;
with Flyology;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.HTTP_2;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with H2_Wire;
with Repro_Support;

--  H2-7.  RFC 9113 6.5.2, SETTINGS_INITIAL_WINDOW_SIZE: "Values above the
--  maximum flow-control window size of 2^31-1 MUST be treated as a
--  connection error (Section 5.4.1) of type FLOW_CONTROL_ERROR."
--  HTTP_2_Settings.Apply does return Settings_Flow_Control_Error
--  (src/flyology-http-http_2_settings.adb:54-58), but both engines collapse
--  every non-accepted result into Protocol_Failure with its default
--  PROTOCOL_ERROR code (server-http_2.adb:2422-2427,
--  http_2_client_connection.adb:1831-1835).
procedure Repro_H2_7 is
   use Ada.Streams;
   use Repro_Support;
   use H2_Wire;
   package App renames Flyology.HTTP.Server.Applications;
   package Client renames Flyology.HTTP.Client;
   package Connections renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;

   function Decimal (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   type Context is limited null record;

   procedure Handle (State : in out Context; X : in out App.Exchange);

   package Engine is new Flyology.HTTP.Server.HTTP_2 (Context, Handle);

   procedure Handle (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      X.Text (200, "ok");
   end Handle;

   --  SETTINGS_INITIAL_WINDOW_SIZE (0x04) = 16#8000_0000#.
   Oversized : constant Stream_Element_Array :=
     (0, 4, 16#80#, 0, 0, 0);

   Manager  : aliased Connections.Server (Capacity => 1);
   Listener : Sockets.Socket_Type;
   Address  : Sockets.Endpoint;
   State    : Context;

   Peer_Listener : Sockets.Socket_Type;
   Peer_Address  : Sockets.Endpoint;

   function Goaway_Code
     (Payload : Stream_Element_Array) return Natural
   is
     (Natural (Payload (Payload'First + 4)) * 16#100_0000# +
      Natural (Payload (Payload'First + 5)) * 16#1_0000# +
      Natural (Payload (Payload'First + 6)) * 16#100# +
      Natural (Payload (Payload'First + 7)));
begin
   Note ("H2-7: SETTINGS_INITIAL_WINDOW_SIZE above 2^31-1");
   Address := Listen_Loopback (Listener);
   Peer_Address := Listen_Loopback (Peer_Listener);

   --  Server engine ---------------------------------------------------------
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
            Timeout => 10.0, Max_Connection_Age => 10.0);
         Connections.Close (Channel);
      exception
         when others => null;
      end Server_Task;

      Socket  : Sockets.Socket_Type;
      Info    : Frame_Info;
      Payload : Stream_Element_Array (1 .. 16_384) := (others => 0);
      Code    : Integer := -1;
   begin
      Connect_Peer (Socket, Address, Oversized);
      begin
         loop
            Read_Frame_Header (Socket, Info, Wait => 5.0);
            Read_Payload (Socket, Info, Payload, Wait => 5.0);
            if Info.Kind = Goaway_Frame and then Info.Length >= 8 then
               Code := Integer (Goaway_Code (Payload (1 .. 8)));
               exit;
            end if;
         end loop;
      exception
         when others => null;
      end;
      Note ("  server GOAWAY error code" & Integer'Image (Code));
      Expect_Equal
        (Code, 3,
         "the server answers an oversized INITIAL_WINDOW_SIZE with " &
         "FLOW_CONTROL_ERROR (0x3)");
      Sockets.Close_Socket (Socket);
   end;

   --  Client engine ---------------------------------------------------------
   declare
      task Peer_Task is
         pragma Task_Info (Flyology.Native_Task);
      end Peer_Task;

      Observed : Integer := -1;

      task body Peer_Task is
         Socket  : Sockets.Socket_Type;
         Where   : Sockets.Endpoint;
         Opening : Stream_Element_Array (1 .. Preface'Length);
         Info    : Frame_Info;
         Payload : Stream_Element_Array (1 .. 16_384) := (others => 0);
      begin
         Sockets.Accept_Connection
           (Peer_Listener, Socket, Where, Timeout => 15.0);
         Sockets.Receive_Exactly (Socket, Opening, Timeout => 10.0);
         Send_Frame (Socket, Settings_Frame, 0, 0, Oversized);
         loop
            Read_Frame_Header (Socket, Info, Wait => 10.0);
            Read_Payload (Socket, Info, Payload, Wait => 10.0);
            if Info.Kind = Goaway_Frame and then Info.Length >= 8 then
               Observed := Integer (Goaway_Code (Payload (1 .. 8)));
               exit;
            end if;
         end loop;
         delay 0.20;
         Sockets.Close_Socket (Socket);
      exception
         when others => null;
      end Peer_Task;

      Origin : constant String :=
        "http://127.0.0.1:" & Decimal (Natural (Peer_Address.Port));
      Session : aliased Client.Client (Capacity => 1);
   begin
      Client.Configure
        (Session, Flyology.HTTP.Parse_Origin (Origin),
         Client.HTTP_2_Prior_Knowledge);
      declare
         Ask : Client.Request;
      begin
         Client.Set_Target (Ask, "/");
         declare
            Reply : Client.Response :=
              Client.Execute (Session, Ask, Timeout => 8.0);
            pragma Unreferenced (Reply);
         begin
            null;
         end;
      exception
         when others => null;
      end;
      Client.Shutdown (Session, Timeout => 5.0);
      Note ("  client GOAWAY error code" & Integer'Image (Observed));
      Expect_Equal
        (Observed, 3,
         "the client answers an oversized INITIAL_WINDOW_SIZE with " &
         "FLOW_CONTROL_ERROR (0x3)");
   end;

   Sockets.Close_Socket (Peer_Listener);
   Sockets.Close_Socket (Listener);
   Finish;
end Repro_H2_7;
