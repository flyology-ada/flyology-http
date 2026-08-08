with Ada.Command_Line;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology.Cancellation;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Sockets;
with Flyology.QUIC.Test_Connections;

procedure HTTP3_H3Spec_Server is
   package App renames Flyology.HTTP.Server.Applications;
   package Sockets renames Flyology.IO.Sockets;
   package Fixtures renames Flyology.QUIC.Test_Connections;

   Port : constant Sockets.Port :=
     (if Ada.Command_Line.Argument_Count = 0 then 4_437
      else Sockets.Port'Value (Ada.Command_Line.Argument (1)));

   type Context is limited null record;
   package Routing is new Flyology.HTTP.Server.Routing (Context);

   procedure Root (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      X.Text (200, "h3spec");
   end Root;

   Routes : aliased Routing.Router
     (Capacity => 1, Slashes => Routing.Strict_Slashes);
   State  : aliased Context;
   Socket : aliased Sockets.Socket_Type;
   Stop   : aliased Flyology.Cancellation.Token;
begin
   Routes.Get ("/", Root'Access, Name => "root");
   Sockets.Create_Socket (Socket, Sockets.IPv4, Sockets.Socket_Datagram);
   Sockets.Bind_Socket
     (Socket, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port));
   Ada.Text_IO.Put_Line
     ("Ada HTTP/3 h3spec server listening on 127.0.0.1:"
      & Ada.Strings.Fixed.Trim
          (Sockets.Port'Image (Port), Ada.Strings.Both));
   Ada.Text_IO.Flush;

   Routes.Serve_HTTP_3_Listener
     (State, Socket,
      Fixtures.Server_Certificate,
      Fixtures.Server_Private_Key,
      Capacity => 32,
      Timeout => 5.0,
      Handshake_Timeout => 5.0,
      Max_Connection_Age => 15.0,
      Max_Requests => 5,
      Token => Stop'Access);
end HTTP3_H3Spec_Server;
