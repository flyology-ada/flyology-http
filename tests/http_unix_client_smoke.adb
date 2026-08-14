with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology;
with Flyology.Bytes;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Routing;
with Flyology.IO;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with GNAT.OS_Lib;

procedure HTTP_Unix_Client_Smoke is
   package App renames Flyology.HTTP.Server.Applications;
   package Client renames Flyology.HTTP.Client;
   package Connections renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;
   package Unbounded renames Ada.Strings.Unbounded;

   use Ada.Streams;
   use type Flyology.HTTP.Protocol;

   CRLF : constant String := Character'Val (13) & Character'Val (10);

   function Decimal (Value : Integer) return String is
     (Ada.Strings.Fixed.Trim (Integer'Image (Value), Ada.Strings.Both));

   Prefix : constant String :=
     Ada.Environment_Variables.Value ("TMPDIR", "/tmp");
   Stem : constant String :=
     Prefix & (if Prefix (Prefix'Last) = '/' then "" else "/") &
     "flyology-http-unix-" &
     Decimal (GNAT.OS_Lib.Pid_To_Integer (GNAT.OS_Lib.Current_Process_Id));

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

   procedure Remove_Path (Path : String) is
      Success : Boolean;
   begin
      GNAT.OS_Lib.Delete_File (Path, Success);
   end Remove_Path;

   procedure Close_Quietly (Socket : in out Sockets.Socket_Type) is
   begin
      if Sockets.Is_Open (Socket) then
         Sockets.Close_Socket (Socket);
      end if;
   exception
      when others => null;
   end Close_Quietly;

   procedure Listen
     (Socket : in out Sockets.Socket_Type; Path : String) is
   begin
      Remove_Path (Path);
      Sockets.Create_Unix_Stream_Socket (Socket);
      Sockets.Bind_Socket (Socket, Sockets.Unix_Pathname (Path));
      Sockets.Listen_Socket (Socket, Length => 8);
   end Listen;

   function Read_Request
     (Socket : Sockets.Socket_Type; Body_Bytes : Natural) return String
   is
      Buffer : Stream_Element_Array (1 .. 4_096);
      Last   : Stream_Element_Offset;
      Value  : Unbounded.Unbounded_String;
      Header_End : Natural := 0;
   begin
      loop
         Sockets.Receive (Socket, Buffer, Last, Timeout => 5.0);
         pragma Assert (Last >= Buffer'First);
         for Index in Buffer'First .. Last loop
            Unbounded.Append (Value, Character'Val (Buffer (Index)));
         end loop;
         Header_End := Ada.Strings.Fixed.Index
           (Unbounded.To_String (Value), CRLF & CRLF);
         exit when Header_End /= 0
           and then Unbounded.Length (Value) >=
             Header_End + 3 + Body_Bytes;
      end loop;
      return Unbounded.To_String (Value);
   end Read_Request;

   procedure Send (Socket : Sockets.Socket_Type; Value : String) is
   begin
      Sockets.Send_All (Socket, Bytes (Value), Timeout => 5.0);
   end Send;

   procedure Check_Response
     (HTTP : aliased in out Client.Client;
      Target : String;
      Expected : String)
   is
      Ask : Client.Request;
   begin
      Client.Set_Target (Ask, Target);
      declare
         Reply : Client.Response := Client.Execute (HTTP, Ask, Timeout => 5.0);
      begin
         pragma Assert (Client.Status (Reply) = 200);
         pragma Assert
           (Flyology.Bytes.To_Byte_String (Client.Read_All (Reply)) =
              Expected);
      end;
   end Check_Response;

   procedure Check_Empty_Response
     (HTTP : aliased in out Client.Client;
      Target : String;
      Expected_Status : Flyology.HTTP.Status_Code)
   is
      Ask : Client.Request;
   begin
      Client.Set_Target (Ask, Target);
      declare
         Reply : Client.Response := Client.Execute (HTTP, Ask, Timeout => 5.0);
      begin
         pragma Assert (Client.Status (Reply) = Expected_Status);
         pragma Assert
           (Flyology.Bytes.Length (Client.Read_All (Reply)) = 0);
      end;
   end Check_Empty_Response;

begin
   -------------------------------------------------------------------------
   --  HTTP/1.1 retains an authority independent from the socket pathname,
   --  reuses one transport, and reconnects after the listener is replaced.
   -------------------------------------------------------------------------
   declare
      Path     : constant String := Stem & "-h1.sock";
      Listener : Sockets.Socket_Type;

      protected Restart is
         procedure Ready;
         entry Wait;
      private
         Is_Ready : Boolean := False;
      end Restart;

      protected body Restart is
         procedure Ready is
         begin
            Is_Ready := True;
         end Ready;

         entry Wait when Is_Ready is
         begin
            null;
         end Wait;
      end Restart;
   begin
      Listen (Listener, Path);
      declare
         task Server is
            pragma Task_Info (Flyology.Native_Task);
         end Server;

         task body Server is
            Peer : Sockets.Socket_Type;
         begin
            Sockets.Accept_Connection (Listener, Peer, Timeout => 5.0);
            declare
               Request : constant String := Read_Request (Peer, 12);
            begin
               pragma Assert
                 (Ada.Strings.Fixed.Index
                    (Request, "POST /body HTTP/1.1" & CRLF) = 1);
               pragma Assert
                 (Ada.Strings.Fixed.Index
                    (Request, CRLF & "Host: docker.local" & CRLF) /= 0);
               pragma Assert
                 (Request (Request'Last - 11 .. Request'Last) =
                    "hello-docker");
            end;
            Send
              (Peer, "HTTP/1.1 200 OK" & CRLF & "Content-Length: 4" &
                 CRLF & CRLF & "post");

            declare
               Request : constant String := Read_Request (Peer, 0);
            begin
               pragma Assert
                 (Ada.Strings.Fixed.Index
                    (Request, "GET /no-content HTTP/1.1" & CRLF) = 1);
            end;
            --  Docker uses this formally forbidden but unambiguous framing
            --  on successful DELETE and POST operations.
            Send
              (Peer, "HTTP/1.1 204 No Content" & CRLF &
                 "Content-Length: 0" & CRLF & CRLF);

            declare
               Request : constant String := Read_Request (Peer, 0);
            begin
               pragma Assert
                 (Ada.Strings.Fixed.Index
                    (Request, "GET /pooled HTTP/1.1" & CRLF) = 1);
            end;
            Send
              (Peer, "HTTP/1.1 200 OK" & CRLF & "Content-Length: 6" &
                 CRLF & CRLF & "pooled");
            Close_Quietly (Peer);
            Close_Quietly (Listener);

            --  A daemon restart replaces the filesystem entry. The client
            --  owns neither the entry nor the listener lifecycle.
            Listen (Listener, Path);
            Restart.Ready;
            Sockets.Accept_Connection (Listener, Peer, Timeout => 5.0);
            declare
               Request : constant String := Read_Request (Peer, 0);
            begin
               pragma Assert
                 (Ada.Strings.Fixed.Index
                    (Request, "GET /stream HTTP/1.1" & CRLF) = 1);
            end;
            Send
              (Peer, "HTTP/1.1 200 OK" & CRLF &
                 "Transfer-Encoding: chunked" & CRLF & CRLF & "4" & CRLF &
                 "Wiki" & CRLF);
            delay 0.02;
            Send (Peer, "5" & CRLF & "pedia" & CRLF & "0" & CRLF & CRLF);
            Close_Quietly (Peer);
            Close_Quietly (Listener);
         end Server;

         HTTP : aliased Client.Client (Capacity => 1);
         Post : Client.Request;
      begin
         Client.Configure
           (HTTP,
            Flyology.HTTP.Parse_Origin ("http://docker.local"),
            Client.Unix_Socket (Path),
            Pool =>
              (Max_Idle => 1, Idle_Timeout => 30.0,
               Max_Connection_Age => 300.0,
               Max_Requests_Per_Connection => 0));
         Client.Set_Method (Post, Flyology.HTTP.To_Method ("POST"));
         Client.Set_Target (Post, "/body");
         Client.Set_Body (Post, "hello-docker");
         declare
            Reply : Client.Response := Client.Execute (HTTP, Post);
         begin
            pragma Assert
              (Flyology.Bytes.To_Byte_String (Client.Read_All (Reply)) =
                 "post");
         end;
         Check_Empty_Response (HTTP, "/no-content", 204);
         Check_Response (HTTP, "/pooled", "pooled");
         declare
            Before : constant Client.Client_Diagnostics :=
              Client.Diagnostics (HTTP);
         begin
            pragma Assert (Before.Transports_Created = 1);
            pragma Assert (Before.Transport_Reuses >= 1);
         end;

         Restart.Wait;
         declare
            Ask      : Client.Request;
            Buffer   : Stream_Element_Array (1 .. 3);
            Last     : Stream_Element_Offset;
            Finished : Boolean := False;
            Content  : Unbounded.Unbounded_String;
         begin
            Client.Set_Target (Ask, "/stream");
            declare
               Reply : Client.Response :=
                 Client.Execute (HTTP, Ask, Timeout => 5.0);
            begin
               while not Finished loop
                  Client.Read_Body (Reply, Buffer, Last, Finished);
                  for Index in Buffer'First .. Last loop
                     Unbounded.Append
                       (Content, Character'Val (Buffer (Index)));
                  end loop;
               end loop;
            end;
            pragma Assert (Unbounded.To_String (Content) = "Wikipedia");
         end;
         declare
            After : constant Client.Client_Diagnostics :=
              Client.Diagnostics (HTTP);
         begin
            pragma Assert (After.Transports_Created = 2);
            pragma Assert (After.Stale_Retries = 1);
         end;
         Client.Shutdown (HTTP);
      end;
      Remove_Path (Path);
   end;

   -------------------------------------------------------------------------
   --  HTTP/2 prior knowledge multiplexes concurrent streams over one Unix
   --  transport and lets ordinary client shutdown terminate the server loop.
   -------------------------------------------------------------------------
   declare
      Path     : constant String := Stem & "-h2.sock";
      Listener : Sockets.Socket_Type;
      Manager  : aliased Connections.Server (Capacity => 1);
      type Context is limited null record;
      package Routes is new Flyology.HTTP.Server.Routing (Context);
      Router : Routes.Router (Capacity => 2, Slashes => Routes.Strict_Slashes);
      State  : Context;

      procedure Reply
        (Shared : in out Context; X : in out App.Exchange) is
         pragma Unreferenced (Shared);
      begin
         pragma Assert (X.Request_Header ("host") = "docker.local");
         if X.Request_Target = "/first" then
            delay 0.05;
         end if;
         X.Text (200, X.Request_Target);
      end Reply;

      protected Results is
         procedure Report (Passed : Boolean; Detail : String := "");
         entry Wait;
         function Passed return Boolean;
         function Detail return String;
      private
         Count   : Natural := 0;
         All_OK  : Boolean := True;
         Message : Unbounded.Unbounded_String;
      end Results;

      protected body Results is
         procedure Report (Passed : Boolean; Detail : String := "") is
         begin
            Count := Count + 1;
            All_OK := All_OK and Passed;
            if not Passed and then Unbounded.Length (Message) = 0 then
               Message := Unbounded.To_Unbounded_String (Detail);
            end if;
         end Report;

         entry Wait when Count = 2 is
         begin
            null;
         end Wait;

         function Passed return Boolean is (All_OK);
         function Detail return String is (Unbounded.To_String (Message));
      end Results;
   begin
      Router.Get ("/first", Reply'Access, Name => "first");
      Router.Get ("/second", Reply'Access, Name => "second");
      Listen (Listener, Path);
      declare
         task Server is
            pragma Task_Info (Flyology.Native_Task);
         end Server;

         task body Server is
            Socket  : Sockets.Socket_Type;
            Channel : aliased Connections.Connection (Manager'Access);
         begin
            Sockets.Accept_Connection (Listener, Socket, Timeout => 5.0);
            Connections.Take (Manager, Socket, Channel);
            Router.Serve
              (State, Channel, Sockets.No_Endpoint,
               Mode => Flyology.HTTP.Server.HTTP_2_Only,
               Timeout => 5.0, Max_Connection_Age => 30.0);
            Connections.Close (Channel);
         exception
            when Flyology.Cancellation.Operation_Cancelled => null;
         end Server;

         HTTP : aliased Client.Client (Capacity => 1);

         task type Caller (Second : Boolean) is
            pragma Task_Info (Flyology.Native_Task);
         end Caller;

         task body Caller is
            Target : constant String := (if Second then "/second" else "/first");
            Ask    : Client.Request;
         begin
            Client.Set_Target (Ask, Target);
            declare
               Response : Client.Response :=
                 Client.Execute (HTTP, Ask, Timeout => 5.0);
               Content  : constant String := Flyology.Bytes.To_Byte_String
                 (Client.Read_All (Response));
            begin
               Results.Report
                 (Client.Negotiated_Protocol (Response) =
                    Flyology.HTTP.HTTP_2_Protocol
                    and then Content = Target);
            end;
         exception
            when Event : others =>
               Results.Report
                 (False, Ada.Exceptions.Exception_Information (Event));
         end Caller;
      begin
         Client.Configure
           (HTTP,
            Flyology.HTTP.Parse_Origin ("http://docker.local"),
            Client.Unix_Socket (Path),
            Client.HTTP_2_Prior_Knowledge);
         declare
            First  : Caller (False);
            Second : Caller (True);
         begin
            Results.Wait;
         end;
         pragma Assert (Results.Passed, Results.Detail);
         declare
            Snapshot : constant Client.Client_Diagnostics :=
              Client.Diagnostics (HTTP);
         begin
            pragma Assert (Snapshot.Transports_Created = 1);
            pragma Assert (Snapshot.Transport_Reuses >= 1);
         end;
         Client.Shutdown (HTTP, Timeout => 5.0);
      end;
      Close_Quietly (Listener);
      Remove_Path (Path);
   end;

   -------------------------------------------------------------------------
   --  Unix establishment and exchange waits retain ordinary deadline and
   --  cancellation behavior. Invalid and missing paths fail explicitly.
   -------------------------------------------------------------------------
   declare
      Path     : constant String := Stem & "-wait.sock";
      Missing  : constant String := Stem & "-missing.sock";
      Listener : Sockets.Socket_Type;
   begin
      begin
         declare
            Unused : constant Client.Unix_Socket_Transport :=
              Client.Unix_Socket ("");
            pragma Unreferenced (Unused);
         begin
            raise Program_Error with "empty Unix path was accepted";
         end;
      exception
         when Constraint_Error => null;
      end;
      begin
         declare
            Unused : constant Client.Unix_Socket_Transport :=
              Client.Unix_Socket ("bad" & Character'Val (0) & "path");
            pragma Unreferenced (Unused);
         begin
            raise Program_Error with "NUL Unix path was accepted";
         end;
      exception
         when Constraint_Error => null;
      end;
      begin
         declare
            Unused : constant Client.Unix_Socket_Transport :=
              Client.Unix_Socket (String'(1 .. 512 => 'x'));
            pragma Unreferenced (Unused);
         begin
            raise Program_Error with "overlong Unix path was accepted";
         end;
      exception
         when Constraint_Error => null;
      end;

      Remove_Path (Missing);
      declare
         HTTP : aliased Client.Client;
         Ask  : Client.Request;
         Failed : Boolean := False;
      begin
         Client.Configure
           (HTTP, Flyology.HTTP.Parse_Origin ("http://localhost"),
            Client.Unix_Socket (Missing));
         begin
            declare
               Response : constant Client.Response :=
                 Client.Execute (HTTP, Ask, Timeout => 0.2);
            begin
               pragma Unreferenced (Response);
            end;
         exception
            when Client.Connection_Error => Failed := True;
         end;
         pragma Assert (Failed);
      end;

      Listen (Listener, Path);
      declare
         task Server is
            pragma Task_Info (Flyology.Native_Task);
         end Server;

         task body Server is
            Peer   : Sockets.Socket_Type;
            Buffer : Stream_Element_Array (1 .. 4_096);
            Last   : Stream_Element_Offset;
         begin
            for Attempt in 1 .. 2 loop
               Sockets.Accept_Connection (Listener, Peer, Timeout => 5.0);
               Sockets.Receive (Peer, Buffer, Last, Timeout => 5.0);
               delay 0.20;
               Close_Quietly (Peer);
            end loop;
         end Server;

         Deadline_Client : aliased Client.Client;
         Cancel_Client   : aliased Client.Client;
         Ask             : Client.Request;
      begin
         Client.Configure
           (Deadline_Client,
            Flyology.HTTP.Parse_Origin ("http://localhost"),
            Client.Unix_Socket (Path));
         begin
            declare
               Response : constant Client.Response :=
                 Client.Execute (Deadline_Client, Ask, Timeout => 0.05);
            begin
               pragma Unreferenced (Response);
            end;
            raise Program_Error with "Unix response deadline was ignored";
         exception
            when Flyology.IO.Timeout_Error => null;
         end;

         Client.Configure
           (Cancel_Client,
            Flyology.HTTP.Parse_Origin ("http://localhost"),
            Client.Unix_Socket (Path));
         declare
            Stop : aliased Flyology.Cancellation.Token;
            task Trigger;
            task body Trigger is
            begin
               delay 0.05;
               Stop.Request;
            end Trigger;
         begin
            begin
               declare
                  Response : constant Client.Response :=
                    Client.Execute
                      (Cancel_Client, Ask, Timeout => 2.0,
                       Token => Stop'Access);
               begin
                  pragma Unreferenced (Response);
               end;
               raise Program_Error with "Unix response cancellation was ignored";
            exception
               when Flyology.Cancellation.Operation_Cancelled => null;
            end;
         end;
      end;
      Close_Quietly (Listener);
      Remove_Path (Path);
   end;
end HTTP_Unix_Client_Smoke;
