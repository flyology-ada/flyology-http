--  Regression coverage for the 2026-08-07 audit findings in the HTTP client
--  and connection pool. Every fix lands its failing reproduction here before
--  the fix itself.
--
--  Finding 6  Expect: 100-continue with a suppressed body must not return an
--             incomplete HTTP/1.1 message's transport to the pool, whether
--             the final response is a routine 401 or a 417 arriving when the
--             expectation retry has already been spent.
--
--  Each finding runs on its own listener so a desynchronized script cannot
--  contaminate the evidence of the next one.
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.Bytes;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Methods;
with Flyology.IO.Sockets;

procedure HTTP_Client_Audit is
   package Client renames Flyology.HTTP.Client;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use type Sockets.Selector_Status;

   CRLF : constant String := Character'Val (13) & Character'Val (10);


   protected Ledger is
      procedure Record_Failure;
      function Failures return Natural;
   private
      Count : Natural := 0;
   end Ledger;

   protected body Ledger is
      procedure Record_Failure is
      begin
         Count := Count + 1;
      end Record_Failure;

      function Failures return Natural is (Count);
   end Ledger;

   procedure Report (Note : String) is
   begin
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, "http client audit: " & Note);
      Ledger.Record_Failure;
   end Report;

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

   function Decimal (Value : Natural) return String is
      Result : constant String := Natural'Image (Value);
   begin
      return Result (Result'First + 1 .. Result'Last);
   end Decimal;

   function Printable (Value : String) return String is
      Result : Unbounded_String;
   begin
      for Item of Value loop
         if Item = Character'Val (13) then
            Append (Result, "\r");
         elsif Item = Character'Val (10) then
            Append (Result, "\n");
         else
            Append (Result, Item);
         end if;
      end loop;
      return To_String (Result);
   end Printable;

   type Upload_Source is
     new Client.Rewindable_Request_Body_Source with record
      Value    : Unbounded_String;
      Position : Natural := 0;
      Reads    : Natural := 0;
      Rewinds  : Natural := 0;
   end record;

   overriding procedure Rewind (Item : in out Upload_Source);

   overriding function Declared_Length
     (Item : Upload_Source) return Client.Body_Length is
     (Client.Known_Length (Client.Body_Size (Length (Item.Value))));

   overriding procedure Read
     (Item     : in out Upload_Source;
      Data     : out Stream_Element_Array;
      Last     : out Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
      Text  : constant String := To_String (Item.Value);
      Count : constant Natural := Natural'Min
        (Natural (Data'Length), Text'Length - Item.Position);
   begin
      Item.Reads := Item.Reads + 1;
      Last := Data'First - 1;
      for Offset in 0 .. Count - 1 loop
         Data (Data'First + Stream_Element_Offset (Offset)) :=
           Stream_Element
             (Character'Pos (Text (Text'First + Item.Position + Offset)));
      end loop;
      Item.Position := Item.Position + Count;
      Last := Data'First + Stream_Element_Offset (Count) - 1;
      Finished := Item.Position = Text'Length;
   end Read;

   procedure Rewind (Item : in out Upload_Source) is
   begin
      Item.Position := 0;
      Item.Rewinds := Item.Rewinds + 1;
   end Rewind;

   --  Scripted peer shared by every lane. Script is the server side of one
   --  finding's exchange sequence and Exercise is the client side; the lane
   --  runs both against a private loopback listener.
   generic
      with procedure Script;
      with procedure Exercise (Origin : Flyology.HTTP.Origin);
   procedure Run_Lane (Name : String);

   --  Peer state of the lane currently running. One lane runs at a time, so
   --  the scripted procedures address it directly.
   Listener : Sockets.Socket_Type;
   Peer     : Sockets.Socket_Type;

   procedure Accept_Peer is
      Peer_Address : Sockets.Endpoint;
      Status       : Sockets.Selector_Status;
   begin
      Sockets.Accept_Socket
        (Listener, Peer, Peer_Address, Timeout => 5.0, Status => Status);
      pragma Assert (Status = Sockets.Completed);
   end Accept_Peer;

   procedure Send (Value : String) is
   begin
      Sockets.Send_All (Peer, Bytes (Value), Timeout => 5.0);
   end Send;

   procedure Send_Empty (Status_Line : String) is
   begin
      Send
        ("HTTP/1.1 " & Status_Line & CRLF & "Content-Length: 0" & CRLF & CRLF);
   end Send_Empty;

   procedure Close_Peer is
   begin
      if Sockets.Is_Open (Peer) then
         Sockets.Close_Socket (Peer);
      end if;
   exception
      when others => null;
   end Close_Peer;

   --  Read one request head. The scripted exchanges never transmit a request
   --  body, so anything past the blank line is a framing surprise.
   function Read_Head (Expected : String) return String is
      Buffer : Stream_Element_Array (1 .. 4_096);
      Last   : Stream_Element_Offset;
      Data   : Unbounded_String;
   begin
      loop
         Sockets.Receive (Peer, Buffer, Last, Timeout => 5.0);
         pragma Assert (Last >= Buffer'First);
         for Index in Buffer'First .. Last loop
            Append (Data, Character'Val (Buffer (Index)));
         end loop;
         exit when Ada.Strings.Fixed.Index
           (To_String (Data), CRLF & CRLF) /= 0;
      end loop;
      declare
         Text : constant String := To_String (Data);
      begin
         if Ada.Strings.Fixed.Index (Text, Expected & CRLF) /= 1 then
            Report
              ("expected request line " & Printable (Expected) &
               " but received " & Printable (Text));
         end if;
         return Text;
      end;
   end Read_Head;

   --  A transport the client must have destroyed reports orderly closure
   --  before anything else arrives, or resets when bytes the client never
   --  read were still queued. A reused transport arrives here carrying the
   --  next request, which is exactly the pool desynchronization.
   procedure Require_Destroyed (Note : String) is
      Buffer : Stream_Element_Array (1 .. 1_024);
      Last   : Stream_Element_Offset;
   begin
      Sockets.Receive (Peer, Buffer, Last, Timeout => 5.0);
      if Last >= Buffer'First then
         declare
            Text : String (1 .. Natural (Last - Buffer'First + 1));
         begin
            for Index in Text'Range loop
               Text (Index) := Character'Val
                 (Buffer (Buffer'First + Stream_Element_Offset (Index - 1)));
            end loop;
            Report
              (Note & ": transport was reused, peer received " &
               Printable (Text));
         end;
      end if;
      Close_Peer;
   exception
      when Sockets.Socket_Error =>
         Close_Peer;
   end Require_Destroyed;

   procedure Require_Status
     (Note     : String;
      Reply    : Client.Response;
      Expected : Flyology.HTTP.Status_Code) is
   begin
      if Client.Status (Reply) /= Expected then
         Report
           (Note & ": expected" & Flyology.HTTP.Status_Code'Image (Expected) &
            " but observed" &
            Flyology.HTTP.Status_Code'Image (Client.Status (Reply)));
      end if;
   end Require_Status;

   procedure Require_Body
     (Note : String; Reply : in out Client.Response; Expected : String)
   is
      Text : constant String :=
        Flyology.Bytes.To_Byte_String (Client.Read_All (Reply));
   begin
      if Text /= Expected then
         Report
           (Note & ": expected body " & Printable (Expected) &
            " but read " & Printable (Text));
      end if;
   end Require_Body;

   procedure Run_Lane (Name : String) is
      Address : Sockets.Endpoint;
   begin
      Sockets.Create_Socket (Listener, Sockets.IPv4);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener);
      Address := Sockets.Get_Socket_Name (Listener);
      declare
         task Server_Task;
         task Client_Task is
            pragma Task_Info (Flyology.Native_Task);
         end Client_Task;

         task body Server_Task is
         begin
            Script;
            Close_Peer;
         exception
            when Error : others =>
               Report
                 (Name & " server: " &
                  Ada.Exceptions.Exception_Information (Error));
               Close_Peer;
         end Server_Task;

         task body Client_Task is
         begin
            Exercise
              (Flyology.HTTP.Parse_Origin
                 ("http://127.0.0.1:" & Decimal (Natural (Address.Port))));
         exception
            when Error : others =>
               Report
                 (Name & " client: " &
                  Ada.Exceptions.Exception_Information (Error));
         end Client_Task;
      begin
         null;
      end;
      if Sockets.Is_Open (Listener) then
         Sockets.Close_Socket (Listener);
      end if;
   end Run_Lane;

   ------------------------------------------------------------------
   --  Finding 6. Expect: 100-continue with a suppressed request body
   ------------------------------------------------------------------

   procedure Expectation_Script is
   begin
      --  A routine 401 on the headers ends the exchange before the declared
      --  13-byte body is transmitted, so the request message is incomplete.
      Accept_Peer;
      declare
         Head : constant String := Read_Head ("POST /expect-reject HTTP/1.1");
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Head, "Expect: 100-continue" & CRLF) /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Head, "Content-Length: 13" & CRLF) /= 0);
      end;
      Send_Empty ("401 Unauthorized");
      Require_Destroyed ("finding 6a (401 before the declared body)");

      Accept_Peer;
      declare
         Head : constant String := Read_Head ("GET /after-reject HTTP/1.1");
         pragma Unreferenced (Head);
      begin
         Send
           ("HTTP/1.1 200 OK" & CRLF & "Content-Length: 5" & CRLF & CRLF &
            "clean");
      end;
      Close_Peer;

      --  Priming and then dropping a pooled transport spends the one stale
      --  retry, so the 417 that follows cannot retry without the expectation
      --  and leaves the same incomplete message behind.
      Accept_Peer;
      declare
         Head : constant String := Read_Head ("GET /prime HTTP/1.1");
         pragma Unreferenced (Head);
      begin
         Send_Empty ("200 OK");
      end;
      Close_Peer;

      Accept_Peer;
      declare
         Head : constant String := Read_Head ("PUT /late-417 HTTP/1.1");
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Head, "Expect: 100-continue" & CRLF) /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index (Head, "Content-Length: 10" & CRLF) /= 0);
      end;
      Send_Empty ("417 Expectation Failed");
      Require_Destroyed ("finding 6b (417 with the retry already spent)");

      Accept_Peer;
      declare
         Head : constant String := Read_Head ("GET /after-417 HTTP/1.1");
         pragma Unreferenced (Head);
      begin
         Send
           ("HTTP/1.1 200 OK" & CRLF & "Content-Length: 5" & CRLF & CRLF &
            "clean");
      end;
   end Expectation_Script;

   procedure Expectation_Exercise (Origin : Flyology.HTTP.Origin) is
      HTTP : aliased Client.Client (Capacity => 1);
   begin
      Client.Configure (HTTP, Origin);

      declare
         Request : Client.Request;
         Source  : Upload_Source :=
           (Value    => To_Unbounded_String ("must-not-send"),
            Position => 0, Reads => 0, Rewinds => 0);
      begin
         Client.Set_Method (Request, Flyology.HTTP.Methods.POST);
         Client.Set_Target (Request, "/expect-reject");
         Client.Set_Expect_Continue (Request, Wait_Timeout => 1.0);
         declare
            Reply : constant Client.Response :=
              Client.Execute (HTTP, Request, Source, Timeout => 5.0);
         begin
            Require_Status ("finding 6a", Reply, 401);
         end;
         if Source.Reads /= 0 or else Source.Position /= 0 then
            Report ("finding 6a: the suppressed body was transmitted");
         end if;
      end;

      declare
         Request : Client.Request;
      begin
         Client.Set_Target (Request, "/after-reject");
         declare
            Reply : Client.Response :=
              Client.Execute (HTTP, Request, Timeout => 5.0);
         begin
            Require_Body ("finding 6a follow-up", Reply, "clean");
         end;
      end;

      declare
         Request : Client.Request;
      begin
         Client.Set_Target (Request, "/prime");
         declare
            Reply : constant Client.Response :=
              Client.Execute (HTTP, Request, Timeout => 5.0);
         begin
            pragma Assert (Client.Body_Complete (Reply));
         end;
      end;

      declare
         Request : Client.Request;
         Source  : Upload_Source :=
           (Value    => To_Unbounded_String ("late-body!"),
            Position => 0, Reads => 0, Rewinds => 0);
      begin
         Client.Set_Method (Request, Flyology.HTTP.Methods.PUT);
         Client.Set_Target (Request, "/late-417");
         Client.Set_Expect_Continue (Request, Wait_Timeout => 1.0);
         declare
            Reply : constant Client.Response :=
              Client.Execute (HTTP, Request, Source, Timeout => 5.0);
         begin
            Require_Status ("finding 6b", Reply, 417);
         end;
         if Source.Reads /= 0 or else Source.Position /= 0 then
            Report ("finding 6b: the suppressed body was transmitted");
         elsif Source.Rewinds /= 1 then
            Report ("finding 6b: the stale retry was not taken");
         end if;
      end;

      declare
         Request : Client.Request;
      begin
         Client.Set_Target (Request, "/after-417");
         declare
            Reply : Client.Response :=
              Client.Execute (HTTP, Request, Timeout => 5.0);
         begin
            Require_Body ("finding 6b follow-up", Reply, "clean");
         end;
      end;

      Client.Shutdown (HTTP);
   end Expectation_Exercise;

   procedure Run_Expectation is new Run_Lane
     (Expectation_Script, Expectation_Exercise);

begin
   Run_Expectation ("finding 6");
   pragma Assert (Ledger.Failures = 0);
   Ada.Text_IO.Put_Line ("HTTP client audit passed");
end HTTP_Client_Audit;
