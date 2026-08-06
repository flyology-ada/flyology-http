with Ada.Command_Line;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Connections;
with Flyology.IO.Connections.TLS;
with Flyology.IO.Sockets;
with Flyology.IO.Structured_Servers;
with Flyology.IO.TLS;
with Flyology.IO.TLS.ALPN;
with Flyology.IO.TLS.OpenSSL;

--  HTTP/2 server used by the independent Python peer and h2spec tests.
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
   Connection_Limit : constant Natural :=
     (if Ada.Command_Line.Argument_Count >= 5
      then Natural'Value (Ada.Command_Line.Argument (5)) else 1);
   Use_TLS : constant Boolean := Transport = "tls";

   type Server_Context is limited record
      Application : Context;
      Routes : Routing.Router
        (Capacity => 6, Slashes => Routing.Strict_Slashes);
      Backend : OpenSSL.OpenSSL_Provider;
   end record;

   procedure Handle_Connection
     (State        : in out Server_Context;
      Connection   : in out Connections.Connection;
      Peer         : Sockets.Endpoint;
      Cancellation : not null access Connections.Cancellation_Token) is
   begin
      if Use_TLS then
         Connection_TLS.Upgrade
           (Connection, State.Backend, Flyology.IO.TLS.Server, "",
            Protocols => ALPN.Empty_Protocol_List,
            Timeout => 10.0,
            Token => Cancellation);
      end if;
      State.Routes.Serve
        (State.Application, Connection, Peer,
         Mode =>
           (if Use_TLS then Flyology.HTTP.Server.ALPN_Negotiated
            else Flyology.HTTP.Server.HTTP_2_Only),
         Timeout => 10.0,
         Max_Connection_Age => 30.0,
         Token => Cancellation);
   end Handle_Connection;

   package Concurrent_Server is new Flyology.IO.Structured_Servers
     (Handler_Context => Server_Context,
      Handle          => Handle_Connection,
      Handler_Model   => Flyology.Native_Task);

   Manager : aliased Connections.Server (Capacity => 1);
   Multi_Server : aliased Concurrent_Server.Server (Capacity => 64);
   Shared : aliased Server_Context;
   Listener : Sockets.Socket_Type;
   Address : Sockets.Endpoint;
   Channel : aliased Connections.Connection;
   Peer : Sockets.Endpoint;
   Served : Natural := 0;
begin
   if Use_TLS then
      OpenSSL.Initialize_Server
        (Shared.Backend, Certificate, Private_Key,
         Protocols => ALPN."&" (ALPN.Offer ("h2"), "http/1.1"));
   elsif Transport /= "plain" then
      raise Constraint_Error with "transport must be plain or tls";
   end if;

   Shared.Routes.Get ("/basic", Basic'Access, Name => "basic");
   Shared.Routes.Get ("/first", Basic'Access, Name => "first");
   Shared.Routes.Get ("/second", Basic'Access, Name => "second");
   Shared.Routes.Get ("/large", Large'Access, Name => "large");
   Shared.Routes.Post
     ("/echo", Echo'Access, Name => "echo",
      Policy =>
        (Body_Handling => App.Buffer_Body,
         Max_Body => 200_000,
         others => <>));
   Shared.Routes.Post
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
   Sockets.Listen_Socket
     (Listener, Length => (if Connection_Limit = 0 then 64 else 1));
   Address := Sockets.Get_Socket_Name (Listener);
   declare
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Port_File);
      Ada.Text_IO.Put_Line (File, Decimal (Natural (Address.Port)));
      Ada.Text_IO.Close (File);
   end;

   if Connection_Limit = 0 then
      Concurrent_Server.Serve (Multi_Server, Listener, Shared);
   end if;
   while Served < Connection_Limit loop
      Connections.Accept_Connection
        (Manager, Listener, Channel, Peer, Timeout => -1.0);
      begin
         if Use_TLS then
            Connection_TLS.Upgrade
              (Channel, Shared.Backend, Flyology.IO.TLS.Server, "",
               Protocols => ALPN.Empty_Protocol_List,
               Timeout => 10.0);
         end if;
         Shared.Routes.Serve
           (Shared.Application, Channel, Peer,
            Mode =>
              (if Use_TLS then Flyology.HTTP.Server.ALPN_Negotiated
               else Flyology.HTTP.Server.HTTP_2_Only),
            Timeout => 10.0,
            Max_Connection_Age => 30.0);
      exception
         when others => null;
      end;
      Connections.Close (Channel);
      Served := Served + 1;
   end loop;
   Sockets.Close_Socket (Listener);
end HTTP2_Conformance_Server;
