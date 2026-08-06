with Ada.Command_Line;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Connections;
with Flyology.IO.Connections.TLS;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with Flyology.IO.TLS.ALPN;
with Flyology.IO.TLS.OpenSSL;

--  Single-connection HTTP/2 server used by the independent Python peer test.
procedure HTTP2_Conformance_Server is
   package App renames Flyology.HTTP.Server.Applications;
   package Connections renames Flyology.IO.Connections;
   package Connection_TLS renames Flyology.IO.Connections.TLS;
   package Sockets renames Flyology.IO.Sockets;
   package ALPN renames Flyology.IO.TLS.ALPN;
   package OpenSSL renames Flyology.IO.TLS.OpenSSL;

   type Context is limited null record;
   package Routing is new Flyology.HTTP.Server.Routing (Context);

   function Decimal (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   procedure Basic (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      if X.Request_Target = "/first" then
         delay 0.05;
      end if;
      X.Add_Header ("X-Protocol", "h2");
      X.Text (200, X.Request_Target);
   end Basic;

   procedure Echo (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      X.Text (200, X.Content);
   end Echo;

   procedure Large (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      X.Begin_Stream (200, "application/octet-stream");
      for Index in 1 .. 128 loop
         X.Write_Chunk (String'(1 .. 1_024 => Character'Val (Index mod 251)));
      end loop;
      X.End_Stream;
   end Large;

   procedure Reset_Target
     (State : in out Context; X : in out App.Exchange)
   is
      pragma Unreferenced (State);
   begin
      --  Keep received DATA retained long enough for the peer to reset the
      --  stream. The following request then verifies connection-window credit
      --  was reclaimed from that discarded body.
      delay 0.50;
      X.No_Content;
   end Reset_Target;

   Port_File : constant String :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Ada.Command_Line.Argument (1)
      else raise Constraint_Error with "port-file argument is required");
   Transport : constant String :=
     (if Ada.Command_Line.Argument_Count >= 2
      then Ada.Command_Line.Argument (2) else "plain");
   Certificate : constant String :=
     (if Ada.Command_Line.Argument_Count >= 3
      then Ada.Command_Line.Argument (3)
      else "tests/fixtures/tls/server-cert.pem");
   Private_Key : constant String :=
     (if Ada.Command_Line.Argument_Count >= 4
      then Ada.Command_Line.Argument (4)
      else "tests/fixtures/tls/server-key.pem");
   Use_TLS : constant Boolean := Transport = "tls";

   Routes : Routing.Router
     (Capacity => 6, Slashes => Routing.Strict_Slashes);
   Manager : aliased Connections.Server (Capacity => 1);
   Backend : OpenSSL.OpenSSL_Provider;
   Listener : Sockets.Socket_Type;
   Address : Sockets.Endpoint;
   Channel : aliased Connections.Connection;
   Peer : Sockets.Endpoint;
   State : Context;
begin
   if Use_TLS then
      OpenSSL.Initialize_Server
        (Backend, Certificate, Private_Key,
         Protocols => ALPN."&" (ALPN.Offer ("h2"), "http/1.1"));
   elsif Transport /= "plain" then
      raise Constraint_Error with "transport must be plain or tls";
   end if;

   Routes.Get ("/basic", Basic'Access, Name => "basic");
   Routes.Get ("/first", Basic'Access, Name => "first");
   Routes.Get ("/second", Basic'Access, Name => "second");
   Routes.Get ("/large", Large'Access, Name => "large");
   Routes.Post
     ("/echo", Echo'Access, Name => "echo",
      Policy =>
        (Body_Handling => App.Buffer_Body,
         Max_Body => 200_000,
         others => <>));
   Routes.Post
     ("/reset", Reset_Target'Access, Name => "reset",
      Policy =>
        (Body_Handling => App.Stream_Body,
         Max_Body => 200_000,
         others => <>));

   Sockets.Create_Socket (Listener);
   Sockets.Set_Socket_Option
     (Listener, Sockets.Socket_Level, (Sockets.Reuse_Address, True));
   Sockets.Bind_Socket
     (Listener, Sockets.Network_Endpoint
       (Sockets.Loopback_IPv4, Sockets.Any_Port));
   Sockets.Listen_Socket (Listener, Length => 1);
   Address := Sockets.Get_Socket_Name (Listener);
   declare
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Port_File);
      Ada.Text_IO.Put_Line (File, Decimal (Natural (Address.Port)));
      Ada.Text_IO.Close (File);
   end;

   Connections.Accept_Connection
     (Manager, Listener, Channel, Peer, Timeout => 15.0);
   if Use_TLS then
      Connection_TLS.Upgrade
        (Channel, Backend, Flyology.IO.TLS.Server, "",
         Protocols => ALPN.Empty_Protocol_List,
         Timeout => 10.0);
   end if;
   Routes.Serve
     (State, Channel, Peer,
      Mode =>
        (if Use_TLS then Flyology.HTTP.Server.ALPN_Negotiated
         else Flyology.HTTP.Server.HTTP_2_Only),
      Timeout => 10.0,
      Max_Connection_Age => 30.0);
   Connections.Close (Channel);
   Sockets.Close_Socket (Listener);
end HTTP2_Conformance_Server;
