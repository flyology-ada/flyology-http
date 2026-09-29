--  CLIENT-POOL-4.  One synchronous safe-method exchange can spend two stale
--  replays, not one.
--
--  flyology-http-client.ads:162-163 documents Client_Diagnostics.Stale_Retries
--  as "Idempotent exchanges retried ONCE after an existing transport failed
--  before producing response bytes".
--
--  Two independent retry sites can both fire for one Execute:
--    * the engine's internal stale retry, src/flyology-http-client.adb:925-957,
--      guarded by Safe_Retry_Used, which re-enters Exchange_Idle and lets the
--      next Checkout_Idle set Was_Reused := True again (:5455-5459); and
--    * the synchronous wrapper's retry, :6529-6548, guarded by its own
--      Retried flag, which the engine's retry never touches.
--  Admission is monotonic across the engine retry (the code says so at :946),
--  so after the first handoff it stays Possibly_Admitted, which satisfies the
--  wrapper predicate too.
--
--  This program primes two idle HTTP/1 transports, has the origin drop each
--  one only after reading the retried head, and then asserts the documented
--  "retried once".
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology.Bytes;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.IO;
with Flyology.IO.Sockets;
with Repro_Support;

procedure Repro_Client_Pool_4 is
   package Client renames Flyology.HTTP.Client;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use Repro_Support;
   use type Ada.Real_Time.Time;
   use type Sockets.Selector_Status;

   Listener : Sockets.Socket_Type;
   Address  : Sockets.Endpoint;

   protected Peer_Log is
      procedure Bump_Stale_Heads;
      procedure Set_Error (Text : String);
      function Stale_Heads return Natural;
      function Error_Text return String;
   private
      Heads : Natural := 0;
      E     : Unbounded_String;
   end Peer_Log;

   protected body Peer_Log is
      procedure Bump_Stale_Heads is
      begin
         Heads := Heads + 1;
      end Bump_Stale_Heads;
      procedure Set_Error (Text : String) is
      begin
         E := To_Unbounded_String (Text);
      end Set_Error;
      function Stale_Heads return Natural is (Heads);
      function Error_Text return String is (To_String (E));
   end Peer_Log;

   function Decimal (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal;

   Final_Status : Integer := -1;
   Final_Body   : Unbounded_String;
   Retry_Count  : Integer := -1;
   Client_Fail  : Unbounded_String;
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
         Peer_A, Peer_B, Peer_C : Sockets.Socket_Type;
         Peer_Address : Sockets.Endpoint;
         Accepted     : Sockets.Selector_Status;
         A_Open, B_Open : Boolean := True;

         procedure Read_Head
           (Peer : Sockets.Socket_Type; Limit : Duration) is
            Buffer : Stream_Element_Array (1 .. 4_096);
            Last   : Stream_Element_Offset;
            Data   : Unbounded_String;
         begin
            loop
               Sockets.Receive (Peer, Buffer, Last, Timeout => Limit);
               exit when Last < Buffer'First;
               for Index in Buffer'First .. Last loop
                  Append (Data, Character'Val (Buffer (Index)));
               end loop;
               exit when Ada.Strings.Fixed.Index
                 (To_String (Data), CRLF & CRLF) /= 0;
            end loop;
         end Read_Head;

         procedure Send (Peer : Sockets.Socket_Type; Value : String) is
         begin
            Sockets.Send_All (Peer, B (Value), Timeout => 3.0);
         end Send;

         --  Poll one still-open pooled peer for the retried head.  Close it
         --  when it arrives, exactly as tests/http_client_composable_stale_
         --  reuse.adb does, so the failure happens AFTER handoff.
         procedure Drop_On_Head
           (Peer : in out Sockets.Socket_Type; Open : in out Boolean) is
         begin
            if Open then
               Read_Head (Peer, 0.2);
               Sockets.Close_Socket (Peer);
               Open := False;
               Peer_Log.Bump_Stale_Heads;
            end if;
         exception
            when Flyology.IO.Timeout_Error =>
               null;
            when others =>
               if Open then
                  Sockets.Close_Socket (Peer);
                  Open := False;
               end if;
         end Drop_On_Head;

         Deadline : Ada.Real_Time.Time;
      begin
         --  Prime two idle transports: accept both heads before answering
         --  either, so the two exchanges really overlap.
         Sockets.Accept_Socket
           (Listener, Peer_A, Peer_Address, Timeout => 5.0,
            Status => Accepted);
         if Accepted /= Sockets.Completed then
            Peer_Log.Set_Error ("first prime never connected");
         else
            Read_Head (Peer_A, 5.0);
            Sockets.Accept_Socket
              (Listener, Peer_B, Peer_Address, Timeout => 5.0,
               Status => Accepted);
            if Accepted /= Sockets.Completed then
               Peer_Log.Set_Error ("second prime never connected");
            else
               Read_Head (Peer_B, 5.0);
               Send
                 (Peer_A,
                  "HTTP/1.1 200 OK" & CRLF & "Content-Length: 0" & CRLF
                  & CRLF);
               Send
                 (Peer_B,
                  "HTTP/1.1 200 OK" & CRLF & "Content-Length: 0" & CRLF
                  & CRLF);

               --  Both transports are now idle in the pool.  Drop each one
               --  only once the client has handed the retried head to it.
               Deadline := Ada.Real_Time.Clock
                 + Ada.Real_Time.To_Time_Span (4.0);
               while Ada.Real_Time.Clock < Deadline
                 and then (A_Open or else B_Open)
               loop
                  Drop_On_Head (Peer_A, A_Open);
                  Drop_On_Head (Peer_B, B_Open);
               end loop;
               if A_Open then
                  Sockets.Close_Socket (Peer_A);
               end if;
               if B_Open then
                  Sockets.Close_Socket (Peer_B);
               end if;

               --  Whatever the retry count, the exchange must finish on a
               --  fresh transport.
               Sockets.Accept_Socket
                 (Listener, Peer_C, Peer_Address, Timeout => 8.0,
                  Status => Accepted);
               if Accepted = Sockets.Completed then
                  Read_Head (Peer_C, 5.0);
                  Send
                    (Peer_C,
                     "HTTP/1.1 200 OK" & CRLF & "Content-Length: 2" & CRLF
                     & "Connection: close" & CRLF & CRLF & "ok");
                  Sockets.Close_Socket (Peer_C);
               else
                  Peer_Log.Set_Error ("no fresh transport was created");
               end if;
            end if;
         end if;
      exception
         when Error : others =>
            Peer_Log.Set_Error (Ada.Exceptions.Exception_Information (Error));
      end Server_Task;

      HTTP   : aliased Client.Client (Capacity => 2);
      Origin : constant Flyology.HTTP.Origin :=
        Flyology.HTTP.Parse_Origin
          ("http://127.0.0.1:" & Decimal (Natural (Address.Port)));

      task type Primer;
      task body Primer is
         Request : Client.Request;
      begin
         Client.Set_Target (Request, "/prime");
         declare
            Reply : Client.Response :=
              Client.Execute (HTTP, Request, Timeout => 10.0);
            Ignored : constant Flyology.Bytes.Unbounded_Bytes :=
              Client.Read_All (Reply);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when Error : others =>
            Peer_Log.Set_Error
              ("primer: " & Ada.Exceptions.Exception_Information (Error));
      end Primer;
   begin
      Client.Configure
        (HTTP, Origin, Client.HTTP_1_Only,
         Pool => (Max_Idle => 2, others => <>));
      declare
         Prime_1, Prime_2 : Primer;
      begin
         null;
      end;

      declare
         Before : constant Natural :=
           Client.Diagnostics (HTTP).Stale_Retries;
         Request : Client.Request;
      begin
         Client.Set_Target (Request, "/retry");
         begin
            declare
               Reply : Client.Response :=
                 Client.Execute (HTTP, Request, Timeout => 20.0);
            begin
               Final_Status := Client.Status (Reply);
               Final_Body := To_Unbounded_String
                 (Flyology.Bytes.To_Byte_String (Client.Read_All (Reply)));
            end;
         exception
            when Error : others =>
               Client_Fail := To_Unbounded_String
                 (Ada.Exceptions.Exception_Name (Error) & ": " &
                  Ada.Exceptions.Exception_Message (Error));
         end;
         Retry_Count :=
           Client.Diagnostics (HTTP).Stale_Retries - Before;
      end;
      Client.Shutdown (HTTP, Timeout => 5.0);
   end;

   if Sockets.Is_Open (Listener) then
      Sockets.Close_Socket (Listener);
   end if;

   if Peer_Log.Error_Text /= "" then
      Note ("peer: " & Peer_Log.Error_Text);
   end if;
   if Client_Fail /= Null_Unbounded_String then
      Note ("Execute raised: " & To_String (Client_Fail));
   end if;
   Note
     ("pooled transports that received the retried head:"
      & Peer_Log.Stale_Heads'Image);
   Note ("Stale_Retries charged to the exchange:" & Retry_Count'Image);

   Check
     (Client_Fail = Null_Unbounded_String, "Execute completes the exchange");
   Expect_Equal (Final_Status, 200, "the fresh transport answers 200");
   Expect_Equal (To_String (Final_Body), "ok", "the response body arrives");
   Expect_Equal
     (Retry_Count, 1,
      "the .ads documents Stale_Retries as an idempotent exchange "
      & "'retried once'");

   Finish;
end Repro_Client_Pool_4;
