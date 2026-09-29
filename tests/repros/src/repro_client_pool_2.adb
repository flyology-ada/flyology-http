--  CLIENT-POOL-2.  flyology-http-client.ads:222-227 (Set_Expect_Continue)
--  promises: "A positive wait expiry with no partial response sends the body
--  ... A 417 final response received BEFORE BODY TRANSMISSION is retried once
--  on a fresh transport without the expectation".
--
--  The wrapper's 417 branch (src/flyology-http-client.adb:6636-6647) tests
--  only Status = 417, Current.Expect_Continue and not Retried.  It never asks
--  whether the body was transmitted, and it hands the SAME Request_Body_Source
--  object, at its current position, to the next Execute_Operation_Once without
--  rewinding it or requiring it to be rewindable.  The Body_Sent input existed
--  as a proved guard, Client_Policy.Classify_Expectation_Response, until
--  commit f0d630d removed its last caller (see CLIENT-POOL-5).
--
--  This program drives the contract's own "wait expires, body is sent" case
--  and then has the origin answer 417, which RFC 9110 s10.1.1 permits at any
--  point.  It asserts the contract: the body was already transmitted, so the
--  417 is the caller's response and no second request is made.
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Methods;
with Flyology.IO;
with Flyology.IO.Sockets;
with Repro_Support;

procedure Repro_Client_Pool_2 is
   package Client renames Flyology.HTTP.Client;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use Repro_Support;
   use type Sockets.Selector_Status;

   Payload : constant String := "late-417-body-xyz";   --  17 bytes
   Hexadecimal_Length : constant String := "11";        --  17 in hexadecimal

   Listener : Sockets.Socket_Type;
   Address  : Sockets.Endpoint;

   protected Peer_Log is
      procedure Set_First_Head (Text : String);
      procedure Set_First_Body (Text : String);
      procedure Set_Second (Text : String);
      procedure Set_Error (Text : String);
      procedure Set_Chunk_Body (Text : String);
      procedure Set_Chunk_Retry (Text : String);
      function First_Head return String;
      function First_Body return String;
      function Second return String;
      function Error_Text return String;
      function Chunk_Body return String;
      function Chunk_Retry return String;
   private
      H1 : Unbounded_String;
      B1 : Unbounded_String;
      R2 : Unbounded_String;
      E  : Unbounded_String;
      CB : Unbounded_String;
      CR : Unbounded_String;
   end Peer_Log;

   protected body Peer_Log is
      procedure Set_First_Head (Text : String) is
      begin
         H1 := To_Unbounded_String (Text);
      end Set_First_Head;
      procedure Set_First_Body (Text : String) is
      begin
         B1 := To_Unbounded_String (Text);
      end Set_First_Body;
      procedure Set_Second (Text : String) is
      begin
         R2 := To_Unbounded_String (Text);
      end Set_Second;
      procedure Set_Error (Text : String) is
      begin
         E := To_Unbounded_String (Text);
      end Set_Error;
      procedure Set_Chunk_Body (Text : String) is
      begin
         CB := To_Unbounded_String (Text);
      end Set_Chunk_Body;
      procedure Set_Chunk_Retry (Text : String) is
      begin
         CR := To_Unbounded_String (Text);
      end Set_Chunk_Retry;
      function First_Head return String is (To_String (H1));
      function First_Body return String is (To_String (B1));
      function Second return String is (To_String (R2));
      function Error_Text return String is (To_String (E));
      function Chunk_Body return String is (To_String (CB));
      function Chunk_Retry return String is (To_String (CR));
   end Peer_Log;

   function Decimal (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal;

   --  A one-shot (non-rewindable) known-length source, the ordinary shape of
   --  a streamed upload.
   type One_Shot_Source is new Client.Request_Body_Source with record
      Position : Natural := 0;
      Reads    : Natural := 0;
   end record;

   overriding function Declared_Length
     (Item : One_Shot_Source) return Client.Body_Length is
     (Client.Known_Length (Payload'Length));

   overriding procedure Read
     (Item     : in out One_Shot_Source;
      Data     : out Stream_Element_Array;
      Last     : out Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
      Count : Natural;
   begin
      Item.Reads := Item.Reads + 1;
      Last := Data'First - 1;
      if Item.Position >= Payload'Length then
         Finished := True;
         return;
      end if;
      Count := Natural'Min
        (Natural (Data'Length), Payload'Length - Item.Position);
      for Offset in 0 .. Count - 1 loop
         Data (Data'First + Stream_Element_Offset (Offset)) :=
           Stream_Element
             (Character'Pos (Payload (Payload'First + Item.Position + Offset)));
      end loop;
      Item.Position := Item.Position + Count;
      Last := Data'First + Stream_Element_Offset (Count) - 1;
      Finished := Item.Position = Payload'Length;
   end Read;

   --  The same one-shot payload declared as Unknown_Length, so the engine
   --  frames it with chunked transfer coding.
   type Chunked_Source is new Client.Request_Body_Source with record
      Position : Natural := 0;
      Reads    : Natural := 0;
   end record;

   overriding function Declared_Length
     (Item : Chunked_Source) return Client.Body_Length is
     (Client.Unknown_Length);

   overriding procedure Read
     (Item     : in out Chunked_Source;
      Data     : out Stream_Element_Array;
      Last     : out Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
      Count : Natural;
   begin
      Item.Reads := Item.Reads + 1;
      Last := Data'First - 1;
      if Item.Position >= Payload'Length then
         Finished := True;
         return;
      end if;
      Count := Natural'Min
        (Natural (Data'Length), Payload'Length - Item.Position);
      for Offset in 0 .. Count - 1 loop
         Data (Data'First + Stream_Element_Offset (Offset)) :=
           Stream_Element
             (Character'Pos
                (Payload (Payload'First + Item.Position + Offset)));
      end loop;
      Item.Position := Item.Position + Count;
      Last := Data'First + Stream_Element_Offset (Count) - 1;
      Finished := Item.Position = Payload'Length;
   end Read;

   Status_Seen    : Integer := -1;
   Client_Failure : Unbounded_String;
   Source_Reads   : Natural := 0;

   Chunked_Status  : Integer := -1;
   Chunked_Failure : Unbounded_String;
begin
   Sockets.Create_Socket (Listener, Sockets.IPv4);
   Sockets.Bind_Socket
     (Listener,
      Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
   Sockets.Listen_Socket (Listener);
   Address := Sockets.Get_Socket_Name (Listener);

   declare
      task Server_Task;

      task body Server_Task is
         Peer         : Sockets.Socket_Type;
         Peer_Address : Sockets.Endpoint;
         Accepted     : Sockets.Selector_Status;
         Pending      : Unbounded_String;

         procedure Accept_Peer (Limit : Duration) is
         begin
            Sockets.Accept_Socket
              (Listener, Peer, Peer_Address, Timeout => Limit,
               Status => Accepted);
         end Accept_Peer;

         --  Read until Pending holds a complete head; return the head and
         --  keep any body bytes already received in Pending.
         function Read_Head return String is
            Buffer : Stream_Element_Array (1 .. 4_096);
            Last   : Stream_Element_Offset;
            Marker : Natural;
         begin
            loop
               Marker := Ada.Strings.Fixed.Index
                 (To_String (Pending), CRLF & CRLF);
               exit when Marker /= 0;
               Sockets.Receive (Peer, Buffer, Last, Timeout => 3.0);
               exit when Last < Buffer'First;
               for Index in Buffer'First .. Last loop
                  Append (Pending, Character'Val (Buffer (Index)));
               end loop;
            end loop;
            Marker := Ada.Strings.Fixed.Index
              (To_String (Pending), CRLF & CRLF);
            if Marker = 0 then
               return To_String (Pending);
            end if;
            declare
               Text : constant String := To_String (Pending);
               Head : constant String := Text (Text'First .. Marker + 3);
            begin
               Pending := To_Unbounded_String
                 (Text (Marker + 4 .. Text'Last));
               return Head;
            end;
         end Read_Head;

         function Read_Body (Count : Natural) return String is
            Buffer : Stream_Element_Array (1 .. 4_096);
            Last   : Stream_Element_Offset;
         begin
            while Length (Pending) < Count loop
               Sockets.Receive (Peer, Buffer, Last, Timeout => 3.0);
               exit when Last < Buffer'First;
               for Index in Buffer'First .. Last loop
                  Append (Pending, Character'Val (Buffer (Index)));
               end loop;
            end loop;
            declare
               Text : constant String := To_String (Pending);
            begin
               Pending := Null_Unbounded_String;
               return Text;
            end;
         end Read_Body;

         --  Read until the chunked terminator "0" CRLF CRLF.
         function Read_Chunked return String is
            Buffer : Stream_Element_Array (1 .. 4_096);
            Last   : Stream_Element_Offset;
         begin
            while Ada.Strings.Fixed.Index
              (To_String (Pending), "0" & CRLF & CRLF) = 0
            loop
               Sockets.Receive (Peer, Buffer, Last, Timeout => 3.0);
               exit when Last < Buffer'First;
               for Index in Buffer'First .. Last loop
                  Append (Pending, Character'Val (Buffer (Index)));
               end loop;
            end loop;
            declare
               Text : constant String := To_String (Pending);
            begin
               Pending := Null_Unbounded_String;
               return Text;
            end;
         end Read_Chunked;

         procedure Send (Value : String) is
         begin
            Sockets.Send_All (Peer, B (Value), Timeout => 3.0);
         end Send;
      begin
         Accept_Peer (5.0);
         if Accepted /= Sockets.Completed then
            Peer_Log.Set_Error ("no client connected");
         else
            Peer_Log.Set_First_Head (Read_Head);

            --  Send no interim response at all.  The client's 20 ms
            --  Continue_Wait expires and the contract says it then sends the
            --  body.
            delay 0.30;

            begin
               Peer_Log.Set_First_Body (Read_Body (Payload'Length));
            exception
               when Error : others =>
                  Peer_Log.Set_First_Body
                    ("<no body: " &
                     Ada.Exceptions.Exception_Name (Error) & ">");
            end;

            --  RFC 9110 s10.1.1 does not require a 417 to precede the body.
            Send
              ("HTTP/1.1 417 Expectation Failed" & CRLF &
               "Content-Length: 0" & CRLF &
               "Connection: close" & CRLF & CRLF);
            if Sockets.Is_Open (Peer) then
               Sockets.Close_Socket (Peer);
            end if;

            --  Per the contract there must be no second request: the body
            --  was transmitted, so this 417 is the caller's response.
            Pending := Null_Unbounded_String;
            Accept_Peer (3.0);
            if Accepted = Sockets.Completed then
               begin
                  Peer_Log.Set_Second (Read_Head);
               exception
                  when Error : others =>
                     Peer_Log.Set_Second
                       ("<connected, no head: " &
                        Ada.Exceptions.Exception_Name (Error) & ">");
               end;
               if Sockets.Is_Open (Peer) then
                  Sockets.Close_Socket (Peer);
               end if;
            end if;

            --  Phase 2: the same race with an Unknown_Length source, framed
            --  chunked.  Here the retry does not fail; it silently re-sends
            --  the POST with an empty body.
            Pending := Null_Unbounded_String;
            Accept_Peer (5.0);
            if Accepted = Sockets.Completed then
               declare
                  Ignored : constant String := Read_Head;
                  pragma Unreferenced (Ignored);
               begin
                  null;
               end;
               delay 0.30;
               begin
                  Peer_Log.Set_Chunk_Body (Read_Chunked);
               exception
                  when Error : others =>
                     Peer_Log.Set_Chunk_Body
                       ("<no body: " &
                        Ada.Exceptions.Exception_Name (Error) & ">");
               end;
               Send
                 ("HTTP/1.1 417 Expectation Failed" & CRLF &
                  "Content-Length: 0" & CRLF &
                  "Connection: close" & CRLF & CRLF);
               if Sockets.Is_Open (Peer) then
                  Sockets.Close_Socket (Peer);
               end if;

               Pending := Null_Unbounded_String;
               Accept_Peer (3.0);
               if Accepted = Sockets.Completed then
                  begin
                     declare
                        Head : constant String := Read_Head;
                     begin
                        Peer_Log.Set_Chunk_Retry (Head & Read_Chunked);
                     end;
                     Send
                       ("HTTP/1.1 200 OK" & CRLF &
                        "Content-Length: 0" & CRLF &
                        "Connection: close" & CRLF & CRLF);
                  exception
                     when Error : others =>
                        Peer_Log.Set_Chunk_Retry
                          ("<connected, incomplete: " &
                           Ada.Exceptions.Exception_Name (Error) & ">");
                  end;
                  if Sockets.Is_Open (Peer) then
                     Sockets.Close_Socket (Peer);
                  end if;
               end if;
            end if;
         end if;
      exception
         when Error : others =>
            Peer_Log.Set_Error (Ada.Exceptions.Exception_Information (Error));
            if Sockets.Is_Open (Peer) then
               Sockets.Close_Socket (Peer);
            end if;
      end Server_Task;

      HTTP   : aliased Client.Client (Capacity => 1);
      Origin : constant Flyology.HTTP.Origin :=
        Flyology.HTTP.Parse_Origin
          ("http://127.0.0.1:" & Decimal (Natural (Address.Port)));
      Source : One_Shot_Source;
      Streamed : Chunked_Source;
   begin
      Client.Configure (HTTP, Origin, Client.HTTP_1_Only);
      declare
         Request : Client.Request;
      begin
         Client.Set_Method (Request, Flyology.HTTP.Methods.POST);
         Client.Set_Target (Request, "/late-417");
         Client.Set_Expect_Continue (Request, Wait_Timeout => 0.02);
         declare
            Reply : Client.Response :=
              Client.Execute (HTTP, Request, Source, Timeout => 10.0);
         begin
            Status_Seen := Client.Status (Reply);
         end;
      exception
         when Error : others =>
            Client_Failure := To_Unbounded_String
              (Ada.Exceptions.Exception_Name (Error) & ": " &
               Ada.Exceptions.Exception_Message (Error));
      end;
      Source_Reads := Source.Reads;

      declare
         Request : Client.Request;
      begin
         Client.Set_Method (Request, Flyology.HTTP.Methods.POST);
         Client.Set_Target (Request, "/late-417-chunked");
         Client.Set_Expect_Continue (Request, Wait_Timeout => 0.02);
         declare
            Reply : Client.Response :=
              Client.Execute (HTTP, Request, Streamed, Timeout => 10.0);
         begin
            Chunked_Status := Client.Status (Reply);
         end;
      exception
         when Error : others =>
            Chunked_Failure := To_Unbounded_String
              (Ada.Exceptions.Exception_Name (Error) & ": " &
               Ada.Exceptions.Exception_Message (Error));
      end;
      Client.Shutdown (HTTP);
   end;

   if Sockets.Is_Open (Listener) then
      Sockets.Close_Socket (Listener);
   end if;

   Note ("request 1 head: " & Printable (B (Peer_Log.First_Head)));
   Note ("request 1 body: [" & Peer_Log.First_Body & "]");
   Note ("request 2 head: " & Printable (B (Peer_Log.Second)));
   if Peer_Log.Error_Text /= "" then
      Note ("peer error: " & Peer_Log.Error_Text);
   end if;
   if Client_Failure /= Null_Unbounded_String then
      Note ("Execute raised: " & To_String (Client_Failure));
   end if;
   Note ("source reads:" & Source_Reads'Image);

   --  Scenario precondition: the wait expired and the body really was sent.
   Expect_Equal
     (Peer_Log.First_Body, Payload,
      "precondition: the whole declared body reached the origin before 417");

   Check
     (Client_Failure = Null_Unbounded_String,
      "Execute returns the 417 instead of failing on a consumed source");
   Expect_Equal
     (Status_Seen, 417,
      "the 417 received after body transmission is the caller's response");
   Expect_Equal
     (Peer_Log.Second, "",
      "no second request: the .ads retries only a 417 received BEFORE body "
      & "transmission");

   Note ("chunked request 1 body: " & Printable (B (Peer_Log.Chunk_Body)));
   Note ("chunked retry on the wire: "
         & Printable (B (Peer_Log.Chunk_Retry)));
   if Chunked_Failure /= Null_Unbounded_String then
      Note ("chunked Execute raised: " & To_String (Chunked_Failure));
   end if;
   Note ("chunked status:" & Chunked_Status'Image);

   Expect_Equal
     (Peer_Log.Chunk_Body,
      Hexadecimal_Length & CRLF & Payload & CRLF & "0" & CRLF & CRLF,
      "precondition: the whole chunked body reached the origin before 417");
   Expect_Equal
     (Peer_Log.Chunk_Retry, "",
      "Unknown_Length: no second POST is sent after body transmission");
   Expect_Equal
     (Chunked_Status, 417,
      "Unknown_Length: the 417 is the caller's response");

   Finish;
end Repro_Client_Pool_2;
