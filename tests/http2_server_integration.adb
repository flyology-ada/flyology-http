with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology;
with Flyology.Bytes;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Methods;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;

procedure HTTP2_Server_Integration is
   package Client renames Flyology.HTTP.Client;
   package App renames Flyology.HTTP.Server.Applications;
   package Connections renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;
   use type Flyology.HTTP.Protocol;
   use type Ada.Streams.Stream_Element_Offset;

   function Decimal (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   type Unknown_String_Source
     (Data : not null access constant String)
   is limited new Client.Request_Body_Source with record
      Cursor : Natural := 1;
   end record;

   overriding function Declared_Length
     (Item : Unknown_String_Source) return Client.Body_Length is
     (Client.Unknown_Length);

   overriding procedure Read
     (Item     : in out Unknown_String_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
      Count : constant Natural := Natural'Min
        (Natural (Data'Length), Item.Data'Length - Item.Cursor + 1);
   begin
      Last := Data'First - 1;
      if Count > 0 then
         for Offset in 0 .. Count - 1 loop
            Data (Data'First + Ada.Streams.Stream_Element_Offset (Offset)) :=
              Ada.Streams.Stream_Element
                (Character'Pos (Item.Data (Item.Cursor + Offset)));
         end loop;
         Last := Data'First + Ada.Streams.Stream_Element_Offset (Count - 1);
      end if;
      Item.Cursor := Item.Cursor + Count;
      Finished := Item.Cursor > Item.Data'Length;
   end Read;

   type Sparse_Five_GiB_Source is
     limited new Client.Request_Body_Source with null record;

   overriding function Declared_Length
     (Item : Sparse_Five_GiB_Source) return Client.Body_Length is
     (Client.Known_Length (5 * 1_024 * 1_024 * 1_024));

   overriding procedure Read
     (Item     : in out Sparse_Five_GiB_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token) is
   begin
      pragma Unreferenced (Item, Timeout, Token);
      Data := (others => 0);
      Last := Data'First - 1;
      Finished := True;
   end Read;

   type Context is limited null record;

   package Routing is new Flyology.HTTP.Server.Routing (Context);
   Routes : Routing.Router
     (Capacity => 5,
      Slashes  => Routing.Strict_Slashes);

   procedure Identify_Protocol
     (State : in out Context;
      X     : in out App.Exchange;
      Next  : in out Routing.Components.Next_Handler) is
   begin
      X.Add_Header ("X-Middleware", "visited");
      Next.Call (State, X);
   end Identify_Protocol;

   procedure Basic (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      pragma Assert
        (X.Request_Protocol =
           (if X.Request_Target = "/http1"
            then Flyology.HTTP.HTTP_1_1_Protocol
            else Flyology.HTTP.HTTP_2_Protocol));
      if X.Request_Target = "/first" then
         delay 0.05;
      end if;
      X.Add_Header ("X-Protocol", "h2");
      X.Text (200, X.Request_Target);
   end Basic;

   procedure Echo (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      pragma Assert (X.Request_Authority /= "");
      if X.Request_Trailer_Count > 0 then
         pragma Assert (X.Request_Trailer_Count = 2);
         pragma Assert
           (X.Request_Trailer ("x-amz-checksum-sha256") = "checksum");
         pragma Assert
           (X.Request_Trailer_Name (2) = "x-amz-trailer-signature");
      end if;
      X.Text (200, X.Content);
   end Echo;

   procedure Large (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      X.Begin_Stream (200, "application/octet-stream");
      for Index in 1 .. 80 loop
         X.Write_Chunk
           (String'(1 .. 1_024 => Character'Val (Index mod 256)));
      end loop;
      X.End_Stream;
   end Large;

   Manager  : aliased Connections.Server (Capacity => 1);
   Listener : Sockets.Socket_Type;
   Address  : Sockets.Endpoint;
   State    : Context;
begin
   Routes.Add_Middleware (Identify_Protocol'Access);
   Routes.Get ("/first", Basic'Access, Name => "first");
   Routes.Get ("/second", Basic'Access, Name => "second");
   Routes.Get ("/large", Large'Access, Name => "large");
   Routes.Get ("/http1", Basic'Access, Name => "http1");
   Routes.Post
     ("/echo", Echo'Access, Name => "echo",
      Policy =>
        (Body_Handling => App.Buffer_Body,
         Max_Body => 6 * 1_024 * 1_024 * 1_024,
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
      task Server_Task is
         pragma Task_Info (Flyology.Native_Task);
      end Server_Task;

      task body Server_Task is
         Channel : Connections.Connection;
         Peer : Sockets.Endpoint;
      begin
         Connections.Accept_Connection
           (Manager, Listener, Channel, Peer, Timeout => 10.0);
         Routes.Serve
           (State, Channel, Peer,
            Mode => Flyology.HTTP.Server.HTTP_2_Only,
            Timeout => 10.0,
            Max_Connection_Age => 30.0,
            Alt_Svc => "h3="":443""; ma=86400");
         Connections.Close (Channel);
         Connections.Accept_Connection
           (Manager, Listener, Channel, Peer, Timeout => 10.0);
         Routes.Serve
           (State, Channel, Peer,
            Mode => Flyology.HTTP.Server.HTTP_1_Only,
            Timeout => 10.0,
            Max_Connection_Age => 30.0,
            Max_Requests => 1,
            Alt_Svc => "h3="":443""; ma=86400");
         Connections.Close (Channel);
      end Server_Task;

      HTTP : aliased Client.Client (Capacity => 1);

      procedure Check (Target, Expected : String) is
         Request : Client.Request;
      begin
         Client.Set_Target (Request, Target);
         declare
            Reply : Client.Response :=
              Client.Execute (HTTP, Request, Timeout => 10.0);
         begin
            pragma Assert (Client.Status (Reply) = 200);
            pragma Assert
              (Client.Negotiated_Protocol (Reply) =
                 Flyology.HTTP.HTTP_2_Protocol);
            pragma Assert
              (Client.Header (Reply, "X-Middleware") = "visited");
            pragma Assert
              (Client.Header (Reply, "Alt-Svc") =
                 "h3="":443""; ma=86400");
            pragma Assert
              (Flyology.Bytes.To_Byte_String (Client.Read_All (Reply)) =
                 Expected);
         end;
      end Check;
   begin
      Client.Configure
        (HTTP,
         Flyology.HTTP.Parse_Origin
           ("http://127.0.0.1:" & Decimal (Natural (Address.Port))),
         Client.HTTP_2_Prior_Knowledge);

      declare
         protected Coordination is
            entry Start;
            procedure Release;
            procedure Complete (Passed : Boolean);
            entry Wait (Passed : out Boolean);
         private
            Released  : Boolean := False;
            Completed : Natural := 0;
            All_Passed : Boolean := True;
         end Coordination;

         protected body Coordination is
            entry Start when Released is
            begin
               null;
            end Start;

            procedure Release is
            begin
               Released := True;
            end Release;

            procedure Complete (Passed : Boolean) is
            begin
               All_Passed := All_Passed and Passed;
               Completed := Completed + 1;
            end Complete;

            entry Wait (Passed : out Boolean) when Completed = 2 is
            begin
               Passed := All_Passed;
            end Wait;
         end Coordination;

         task First;
         task Second;

         task body First is
         begin
            Coordination.Start;
            begin
               Check ("/first", "/first");
               Coordination.Complete (True);
            exception
               when others => Coordination.Complete (False);
            end;
         end First;

         task body Second is
         begin
            Coordination.Start;
            begin
               Check ("/second", "/second");
               Coordination.Complete (True);
            exception
               when others => Coordination.Complete (False);
            end;
         end Second;

         Passed : Boolean;
      begin
         Coordination.Release;
         Coordination.Wait (Passed);
         pragma Assert (Passed);
      end;

      --  Exercise 64-bit request framing without retaining or transmitting a
      --  multi-gigabyte payload. The source deliberately ends immediately;
      --  the client must detect the premature EOF, abandon only that stream,
      --  and leave the multiplexed connection usable.
      declare
         Request : Client.Request;
         Source  : Sparse_Five_GiB_Source;
         Raised  : Boolean := False;
      begin
         Client.Set_Target (Request, "/echo");
         Client.Set_Method (Request, Flyology.HTTP.Methods.POST);
         begin
            declare
               Unexpected : Client.Response :=
                 Client.Execute (HTTP, Request, Source, Timeout => 10.0);
               pragma Unreferenced (Unexpected);
            begin
               null;
            end;
         exception
            when Client.Request_Body_Error => Raised := True;
         end;
         pragma Assert (Raised);
      end;
      Check ("/second", "/second");

      declare
         Request : Client.Request;
         Payload : aliased constant String := (1 .. 120_000 => 'e');
         Source  : Unknown_String_Source (Payload'Access);
      begin
         Client.Set_Target (Request, "/echo");
         Client.Set_Method (Request, Flyology.HTTP.Methods.POST);
         Client.Add_Trailer
           (Request, "x-amz-checksum-sha256", "checksum");
         Client.Add_Trailer
           (Request, "x-amz-trailer-signature", "signature");
         declare
            Reply : Client.Response :=
              Client.Execute (HTTP, Request, Source, Timeout => 10.0);
         begin
            pragma Assert
              (Flyology.Bytes.To_Byte_String
                 (Client.Read_All (Reply, Maximum => 200_000)) = Payload);
         end;
      end;

      declare
         Request : Client.Request;
      begin
         Client.Set_Target (Request, "/large");
         declare
            Reply : Client.Response :=
              Client.Execute (HTTP, Request, Timeout => 10.0);
            Value : constant Ada.Streams.Stream_Element_Array :=
              Flyology.Bytes.To_Array
                (Client.Read_All (Reply, Maximum => 100_000));
         begin
            pragma Assert (Value'Length = 80 * 1_024);
         end;
      end;

      Client.Shutdown (HTTP, Timeout => 5.0);

      declare
         HTTP_1 : aliased Client.Client (Capacity => 1);
         Request : Client.Request;
      begin
         Client.Configure
           (HTTP_1,
            Flyology.HTTP.Parse_Origin
              ("http://127.0.0.1:" & Decimal (Natural (Address.Port))));
         Client.Set_Target (Request, "/http1");
         declare
            Reply : Client.Response :=
              Client.Execute (HTTP_1, Request, Timeout => 10.0);
         begin
            pragma Assert (Client.Status (Reply) = 200);
            pragma Assert
              (Client.Negotiated_Protocol (Reply) =
                 Flyology.HTTP.HTTP_1_1_Protocol);
            pragma Assert
              (Client.Header (Reply, "X-Middleware") = "visited");
            pragma Assert
              (Client.Header (Reply, "Alt-Svc") =
                 "h3="":443""; ma=86400");
            pragma Assert
              (Flyology.Bytes.To_Byte_String (Client.Read_All (Reply)) =
                 "/http1");
         end;
         Client.Shutdown (HTTP_1, Timeout => 5.0);
      end;
   end;
   Sockets.Close_Socket (Listener);
   Ada.Text_IO.Put_Line ("HTTP/2 server integration passed");
end HTTP2_Server_Integration;
