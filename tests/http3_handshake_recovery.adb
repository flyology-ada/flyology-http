with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology.Bytes;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Routing;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.QUIC.Test_Connections;

--  End-to-end proof that the HTTP/3 client and server drive the RFC 9002
--  handshake probe timeout.
--
--  A UDP relay sits between the two endpoints and silently discards one
--  handshake flight. Neither side is told; the exchange can only complete if
--  the losing endpoint rearms its own probe timer and retransmits.
procedure HTTP3_Handshake_Recovery is
   package App renames Flyology.HTTP.Server.Applications;
   package Client renames Flyology.HTTP.Client;
   package Sockets renames Flyology.IO.Sockets;
   package Fixtures renames Flyology.QUIC.Test_Connections;

   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Flyology.HTTP.Protocol;
   use type Sockets.Endpoint;

   function Decimal (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   type Context is limited null record;
   package Routing is new Flyology.HTTP.Server.Routing (Context);

   procedure Hello (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      pragma Assert (X.Request_Protocol = Flyology.HTTP.HTTP_3_Protocol);
      X.Text (200, "recovered");
   end Hello;

   --  Which handshake flight the relay swallows exactly once.
   --  @enum Client_Initial The client's first Initial never reaches the server
   --  @enum Server_Handshake The server's Handshake flight never reaches the
   --    client, leaving it stalled after the ServerHello
   type Loss_Kind is (Client_Initial, Server_Handshake);

   --  QUIC v1 long-header packet types are visible without keys, which is all
   --  a path element needs to drop one specific flight.
   function Is_Long_Header (First : Ada.Streams.Stream_Element) return Boolean
   is ((First and 16#80#) /= 0 and then (First and 16#40#) /= 0);

   function Is_Initial (First : Ada.Streams.Stream_Element) return Boolean is
     (Is_Long_Header (First) and then (First and 16#30#) = 16#00#);

   function Is_Handshake (First : Ada.Streams.Stream_Element) return Boolean is
     (Is_Long_Header (First) and then (First and 16#30#) = 16#20#);

   Payload_Limit : constant := 2_048;

   procedure Run (Loss : Loss_Kind) is
      Server_Socket : aliased Sockets.Socket_Type;
      Relay_Socket  : Sockets.Socket_Type;
      Server_Address, Relay_Address : Sockets.Endpoint;
      State  : Context;
      Routes : Routing.Router
        (Capacity => 1, Slashes => Routing.Strict_Slashes);

      --  Written by the client lane and read by the relay lane after the
      --  exchange settles; both are single-writer flags.
      Finished : Boolean := False;
      pragma Volatile (Finished);
      Drops    : Natural := 0;
      pragma Volatile (Drops);
      Relay_Error : Flyology.Bytes.Unbounded_Bytes;
      Server_Error : Flyology.Bytes.Unbounded_Bytes;
   begin
      Routes.Get ("/hello", Hello'Access, Name => "hello");
      Sockets.Create_Socket
        (Server_Socket, Sockets.IPv4, Sockets.Socket_Datagram);
      Sockets.Bind_Socket
        (Server_Socket,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Server_Address := Sockets.Get_Socket_Name (Server_Socket);
      Sockets.Create_Socket
        (Relay_Socket, Sockets.IPv4, Sockets.Socket_Datagram);
      Sockets.Bind_Socket
        (Relay_Socket,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Relay_Address := Sockets.Get_Socket_Name (Relay_Socket);

      declare
         task Server_Task;
         task Relay_Task;

         task body Server_Task is
         begin
            Routes.Serve_HTTP_3
              (State, Server_Socket,
               Fixtures.Server_Certificate,
               Fixtures.Server_Private_Key,
               Timeout => 20.0,
               Handshake_Timeout => 20.0,
               Max_Connection_Age => 30.0,
               Max_Requests => 1);
         exception
            when Error : others =>
               Server_Error := Flyology.Bytes.From_Byte_String
                 (Ada.Exceptions.Exception_Information (Error));
         end Server_Task;

         --  Forward every datagram between the client and the server except
         --  the one flight this scenario drops.
         task body Relay_Task is
            Buffer   : Ada.Streams.Stream_Element_Array (1 .. Payload_Limit);
            Last     : Ada.Streams.Stream_Element_Offset;
            Sent     : Ada.Streams.Stream_Element_Offset;
            Metadata : Sockets.Datagram_Metadata;
            Client_Address : Sockets.Endpoint;
            Have_Client : Boolean := False;
            From_Client : Boolean;
            Drop : Boolean;
         begin
            while not Finished loop
               begin
                  Sockets.Receive_Datagram
                    (Relay_Socket, Buffer, Last, Metadata, Timeout => 0.25);
               exception
                  when Flyology.IO.Timeout_Error =>
                     goto Continue;
               end;
               if Last < Buffer'First then
                  goto Continue;
               end if;

               From_Client := not Have_Client
                 or else Metadata.Source /= Server_Address;
               if From_Client then
                  Client_Address := Metadata.Source;
                  Have_Client := True;
               end if;

               Drop := False;
               if Drops = 0 then
                  case Loss is
                     when Client_Initial =>
                        Drop := From_Client
                          and then Is_Initial (Buffer (Buffer'First));
                     when Server_Handshake =>
                        Drop := not From_Client
                          and then Is_Handshake (Buffer (Buffer'First));
                  end case;
               end if;
               if Drop then
                  Drops := Drops + 1;
                  goto Continue;
               end if;

               Sockets.Send_Datagram
                 (Relay_Socket, Buffer (Buffer'First .. Last), Sent,
                  Destination =>
                    (if From_Client then Server_Address else Client_Address),
                  Timeout => 2.0);
               <<Continue>>
            end loop;
         exception
            when Error : others =>
               Relay_Error := Flyology.Bytes.From_Byte_String
                 (Ada.Exceptions.Exception_Information (Error));
         end Relay_Task;

         HTTP : aliased Client.Client (Capacity => 1);
         Request : Client.Request;
      begin
         Client.Configure
           (HTTP,
            Flyology.HTTP.Parse_Origin
              ("https://127.0.0.1:"
               & Decimal (Natural (Relay_Address.Port))),
            Client.Require_HTTP_3,
            HTTP_3_Certificate_DER => Fixtures.Server_Certificate);
         Client.Set_Target (Request, "/hello");
         declare
            Reply : Client.Response :=
              Client.Execute (HTTP, Request, Timeout => 20.0);
         begin
            pragma Assert (Client.Status (Reply) = 200);
            pragma Assert
              (Flyology.Bytes.To_Byte_String (Client.Read_All (Reply)) =
                 "recovered");
         end;
         Client.Shutdown (HTTP, Timeout => 5.0);
         Finished := True;
      exception
         when others =>
            Finished := True;
            raise;
      end;

      if Flyology.Bytes.Length (Relay_Error) > 0 then
         raise Program_Error with
           "relay failed: " & Flyology.Bytes.To_Byte_String (Relay_Error);
      elsif Flyology.Bytes.Length (Server_Error) > 0 then
         raise Program_Error with
           "server failed: " & Flyology.Bytes.To_Byte_String (Server_Error);
      end if;
      --  The scenario is only meaningful when the flight really was lost.
      pragma Assert (Drops = 1);
      Sockets.Close_Socket (Relay_Socket);
      Sockets.Close_Socket (Server_Socket);
      Ada.Text_IO.Put_Line
        ("HTTP/3 handshake recovered after dropping "
         & Loss_Kind'Image (Loss));
   end Run;
begin
   Run (Client_Initial);
   Run (Server_Handshake);
   Ada.Text_IO.Put_Line
     ("flyology_http HTTP/3 handshake probe timeout verified");
end HTTP3_Handshake_Recovery;
