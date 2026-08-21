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

   Source_Failure : exception;
   type Adversarial_Kind is
     (Zero_Progress, Overrun, Source_Exception, Cancelled_Source,
      Expired_Source, Early_Final_Source);
   type Adversarial_Source (Kind : Adversarial_Kind) is limited new
     Client.Request_Body_Source with record
      Reads : Natural := 0;
   end record;

   overriding function Declared_Length
     (Item : Adversarial_Source) return Client.Body_Length is
     (case Item.Kind is
         when Zero_Progress | Source_Exception => Client.Unknown_Length,
         when Overrun | Cancelled_Source | Expired_Source =>
           Client.Known_Length (1),
         when Early_Final_Source =>
           Client.Known_Length (64 * 1_024 * 1_024 * 1_024));

   overriding procedure Read
     (Item     : in out Adversarial_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token) is
   begin
      Item.Reads := Item.Reads + 1;
      Last := Data'First - 1;
      Finished := False;
      case Item.Kind is
         when Zero_Progress =>
            null;
         when Overrun =>
            Data (Data'First .. Data'First + 1) := (others => 1);
            Last := Data'First + 1;
            Finished := True;
         when Source_Exception =>
            raise Source_Failure;
         when Cancelled_Source =>
            pragma Assert (Token /= null);
            Token.Request;
            Data (Data'First) := 1;
            Last := Data'First;
            Finished := True;
         when Expired_Source =>
            pragma Assert (Timeout >= 0.0);
            delay 0.02;
            Data (Data'First) := 1;
            Last := Data'First;
            Finished := True;
         when Early_Final_Source =>
            Data := (others => 1);
            Last := Data'Last;
      end case;
   end Read;

   type Context is limited null record;

   package Routing is new Flyology.HTTP.Server.Routing (Context);
   Routes : Routing.Router
     (Capacity => 10,
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

   procedure Fixed_Large
     (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      X.Begin_Stream
        (200, "application/octet-stream", Content_Length => 80 * 1_024);
      for Index in 1 .. 80 loop
         X.Write_Chunk
           (String'(1 .. 1_024 => Character'Val (Index mod 256)));
      end loop;
      X.End_Stream;
   end Fixed_Large;

   procedure Fixed_One_Byte
     (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
      Value : constant String := "fixed";
   begin
      X.Begin_Stream (200, "text/plain", Content_Length => Value'Length);
      for Item of Value loop
         X.Write_Chunk (String'(1 => Item));
      end loop;
      X.End_Stream;
   end Fixed_One_Byte;

   procedure Fixed_Zero
     (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      X.Begin_Stream
        (200, "application/octet-stream", Content_Length => 0);
      X.End_Stream;
   end Fixed_Zero;

   procedure Fixed_Head
     (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      X.Begin_Stream
        (200, "application/octet-stream",
         Content_Length => 5 * 1_024 * 1_024 * 1_024 + 9);
      --  Let the server emit HEADERS before End_Stream. This deterministically
      --  exercises the legal empty DATA END_STREAM completion path for HEAD.
      delay 0.01;
      X.End_Stream;
   end Fixed_Head;

   procedure Early (State : in out Context; X : in out App.Exchange) is
      pragma Unreferenced (State);
   begin
      X.Text (409, "upload stopped");
   end Early;

   Manager  : aliased Connections.Server (Capacity => 1);
   Listener : Sockets.Socket_Type;
   Address  : Sockets.Endpoint;
   State    : Context;
begin
   Routes.Add_Middleware (Identify_Protocol'Access);
   Routes.Get ("/first", Basic'Access, Name => "first");
   Routes.Get ("/second", Basic'Access, Name => "second");
   Routes.Get ("/large", Large'Access, Name => "large");
   Routes.Get ("/fixed-large", Fixed_Large'Access, Name => "fixed.large");
   Routes.Get
     ("/fixed-one", Fixed_One_Byte'Access, Name => "fixed.one");
   Routes.Get ("/fixed-zero", Fixed_Zero'Access, Name => "fixed.zero");
   Routes.Get ("/fixed-head", Fixed_Head'Access, Name => "fixed.head");
   Routes.Get ("/http1", Basic'Access, Name => "http1");
   Routes.Post
     ("/echo", Echo'Access, Name => "echo",
      Policy =>
        (Body_Handling => App.Buffer_Body,
         Max_Body => 6 * 1_024 * 1_024 * 1_024,
         others => <>));
   Routes.Post
     ("/early", Early'Access, Name => "early",
      Policy =>
        (Body_Handling => App.Stream_Body,
         Max_Body => 64 * 1_024 * 1_024 * 1_024,
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

      declare
         Request : Client.Request;
      begin
         Client.Set_Target (Request, "/fixed-large");
         declare
            Reply : Client.Response :=
              Client.Execute (HTTP, Request, Timeout => 10.0);
            Value : constant Ada.Streams.Stream_Element_Array :=
              Flyology.Bytes.To_Array
                (Client.Read_All (Reply, Maximum => 100_000));
         begin
            pragma Assert
              (Client.Header (Reply, "content-length") = "81920");
            pragma Assert
              (Client.Header (Reply, "transfer-encoding") = "");
            pragma Assert (Value'Length = 80 * 1_024);
         end;
      end;

      declare
         Request : Client.Request;
      begin
         Client.Set_Target (Request, "/fixed-one");
         declare
            Reply : Client.Response :=
              Client.Execute (HTTP, Request, Timeout => 10.0);
         begin
            pragma Assert (Client.Header (Reply, "content-length") = "5");
            pragma Assert
              (Flyology.Bytes.To_Byte_String (Client.Read_All (Reply)) =
                 "fixed");
         end;
      end;

      declare
         Request : Client.Request;
      begin
         Client.Set_Target (Request, "/fixed-zero");
         declare
            Reply : Client.Response :=
              Client.Execute (HTTP, Request, Timeout => 10.0);
         begin
            pragma Assert
              (Client.Header (Reply, "content-length") = "0");
            pragma Assert
              (Flyology.Bytes.Length (Client.Read_All (Reply)) = 0);
         end;
      end;

      declare
         Request : Client.Request;
      begin
         Client.Set_Target (Request, "/fixed-head");
         Client.Set_Method (Request, Flyology.HTTP.Methods.HEAD);
         declare
            Reply : Client.Response :=
              Client.Execute (HTTP, Request, Timeout => 10.0);
         begin
            pragma Assert
              (Client.Header (Reply, "content-length") = "5368709129");
            pragma Assert
              (Flyology.Bytes.Length (Client.Read_All (Reply)) = 0);
         end;
      end;

      Check ("/second", "/second");

      --  These are protocol-specific borrowed-source contract cases. Each
      --  failure happens after stream allocation, then a normal request proves
      --  the multiplexed connection remains usable.
      for Kind in Zero_Progress .. Expired_Source loop
         declare
            Request : Client.Request;
            Source  : Adversarial_Source (Kind);
            Stop    : aliased Flyology.Cancellation.Token;
            Raised  : Boolean := False;
         begin
            Client.Set_Target (Request, "/echo");
            Client.Set_Method (Request, Flyology.HTTP.Methods.POST);
            begin
               declare
                  Unexpected : Client.Response := Client.Execute
                    (HTTP, Request, Source,
                     Timeout => (if Kind = Expired_Source then 0.005 else 10.0),
                     Token =>
                       (if Kind = Cancelled_Source then Stop'Access else null));
                  pragma Unreferenced (Unexpected);
               begin
                  null;
               end;
            exception
               when Client.Request_Body_Error =>
                  Raised := Kind in Zero_Progress | Overrun;
               when Source_Failure =>
                  Raised := Kind = Source_Exception;
               when Flyology.Cancellation.Operation_Cancelled =>
                  Raised := Kind = Cancelled_Source;
               when Flyology.IO.Timeout_Error =>
                  Raised := Kind = Expired_Source;
            end;
            pragma Assert (Raised);
            Check ("/second", "/second");
         end;
      end loop;

      --  The route sends a final response without consuming the body. The
      --  generated 64 GiB source must stop well before completion, and only
      --  its stream is retired.
      declare
         Request : Client.Request;
         Source  : Adversarial_Source (Early_Final_Source);
      begin
         Client.Set_Target (Request, "/early");
         Client.Set_Method (Request, Flyology.HTTP.Methods.POST);
         declare
            Reply : Client.Response :=
              Client.Execute (HTTP, Request, Source, Timeout => 10.0);
         begin
            pragma Assert (Client.Status (Reply) = 409);
            pragma Assert (Source.Reads > 0 and then Source.Reads < 1_024);
            pragma Assert
              (Flyology.Bytes.To_Byte_String (Client.Read_All (Reply)) =
                 "upload stopped");
         end;
      end;
      Check ("/second", "/second");

      --  A 120,000-byte response fills three complete 16 KiB output slots and
      --  leaves less than one fragment free. Repeating the transfer exercises
      --  both size-aware backpressure and publication in the final
      --  poll-before-sleep window while preserving trailer order.
      for Attempt in 1 .. 32 loop
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
      end loop;

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
