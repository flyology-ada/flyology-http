with Ada.Command_Line;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology.HTTP;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Sockets;
with Flyology.QUIC.Test_Connections;

procedure HTTP3_Interop_Server is
   package App renames Flyology.HTTP.Server.Applications;
   package Sockets renames Flyology.IO.Sockets;
   package Fixtures renames Flyology.QUIC.Test_Connections;
   use type Flyology.HTTP.Protocol;

   Port : constant Sockets.Port :=
     (if Ada.Command_Line.Argument_Count = 0 then 4_434
      else Sockets.Port'Value (Ada.Command_Line.Argument (1)));

   type Context is limited null record;
   package Routing is new Flyology.HTTP.Server.Routing (Context);

   procedure Hello (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      pragma Assert (X.Request_Protocol = Flyology.HTTP.HTTP_3_Protocol);
      X.Text (200, "hello");
   end Hello;

   Routes : Routing.Router
     (Capacity => 1, Slashes => Routing.Strict_Slashes);
   State : Context;
   Socket : aliased Sockets.Socket_Type;
begin
   Routes.Get ("/hello", Hello'Access, Name => "hello");
   Sockets.Create_Socket (Socket, Sockets.IPv4, Sockets.Socket_Datagram);
   Sockets.Bind_Socket
     (Socket, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port));
   Ada.Text_IO.Put_Line
     ("Ada HTTP/3 routed server listening on 127.0.0.1:"
      & Ada.Strings.Fixed.Trim
          (Sockets.Port'Image (Port), Ada.Strings.Both));
   Ada.Text_IO.Flush;

   Routes.Serve_HTTP_3
     (State, Socket,
      Fixtures.Server_Certificate,
      Fixtures.Server_Private_Key,
      Timeout => 10.0,
      Handshake_Timeout => 10.0,
      Max_Connection_Age => 20.0,
      Max_Requests => 1);

   Ada.Text_IO.Put_Line
     ("Ada HTTP/3 routed server interoperated with aioquic");
   Sockets.Close_Socket (Socket);
end HTTP3_Interop_Server;
