--  CLIENT-POOL-1.  Resolve_Redirect (src/flyology-http-client.adb:6301)
--  selects its absolute-URI branch with an UNANCHORED scan:
--
--     elsif Ada.Strings.Fixed.Index (Reference, "://") /= 0 then
--
--  so an ordinary same-origin relative redirect that carries an absolute URL
--  inside its query -- the standard "return to" / OAuth redirect_uri shape --
--  is classified as an absolute reference.  The text before the "://" becomes
--  the scheme name, which is neither "http" nor "https", and Redirect_Error
--  "unsupported redirect URI scheme" is raised.
--
--  flyology-http-client.ads:46 promises Follow_Same_Origin "Follow eligible
--  redirects within the client origin".  This program asserts that promise:
--  a 302 to "/next?u=https://example.com/home" must be followed and must
--  yield the 200 served at that target.
--
--  This is the same defect class as the previous audit's finding 2, the
--  identical unanchored "://" scan in the server's Raw_Path
--  (src/flyology-http-server-routing.adb).  That site was fixed with an
--  anchored scheme-prefix test; this one was not.
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology.Bytes;
with Flyology.IO;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.IO.Sockets;
with Repro_Support;

procedure Repro_Client_Pool_1 is
   package Client renames Flyology.HTTP.Client;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use Repro_Support;
   use type Sockets.Selector_Status;

   --  A same-origin relative-path reference whose query carries an absolute
   --  URL.  RFC 3986 s4.2: a reference beginning with "/" is a relative
   --  reference; its scheme component is absent.
   Location_Value : constant String := "/next?u=https://example.com/home";

   Listener : Sockets.Socket_Type;
   Address  : Sockets.Endpoint;

   protected Peer_Log is
      procedure Set_First (Text : String);
      procedure Set_Second (Text : String);
      procedure Set_Error (Text : String);
      function First return String;
      function Second return String;
      function Error_Text return String;
   private
      First_Line  : Unbounded_String;
      Second_Line : Unbounded_String;
      Failure     : Unbounded_String;
   end Peer_Log;

   protected body Peer_Log is
      procedure Set_First (Text : String) is
      begin
         First_Line := To_Unbounded_String (Text);
      end Set_First;

      procedure Set_Second (Text : String) is
      begin
         Second_Line := To_Unbounded_String (Text);
      end Set_Second;

      procedure Set_Error (Text : String) is
      begin
         Failure := To_Unbounded_String (Text);
      end Set_Error;

      function First return String is (To_String (First_Line));
      function Second return String is (To_String (Second_Line));
      function Error_Text return String is (To_String (Failure));
   end Peer_Log;

   function Decimal (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal;

   Status_Seen    : Integer := -1;
   Body_Seen      : Unbounded_String;
   Client_Failure : Unbounded_String;
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

         function Read_Head return String is
            Buffer : Stream_Element_Array (1 .. 4_096);
            Last   : Stream_Element_Offset;
            Data   : Unbounded_String;
         begin
            loop
               Sockets.Receive (Peer, Buffer, Last, Timeout => 3.0);
               exit when Last < Buffer'First;
               for Index in Buffer'First .. Last loop
                  Append (Data, Character'Val (Buffer (Index)));
               end loop;
               exit when Ada.Strings.Fixed.Index
                 (To_String (Data), CRLF & CRLF) /= 0;
            end loop;
            return To_String (Data);
         end Read_Head;

         function Request_Line (Wire : String) return String is
            Stop : constant Natural :=
              Ada.Strings.Fixed.Index (Wire, CRLF);
         begin
            if Stop = 0 then
               return Wire;
            end if;
            return Wire (Wire'First .. Stop - 1);
         end Request_Line;

         procedure Send (Value : String) is
         begin
            Sockets.Send_All (Peer, B (Value), Timeout => 3.0);
         end Send;
      begin
         Sockets.Accept_Socket
           (Listener, Peer, Peer_Address, Timeout => 5.0,
            Status => Accepted);
         if Accepted /= Sockets.Completed then
            Peer_Log.Set_Error ("no client connected");
         else
            Peer_Log.Set_First (Request_Line (Read_Head));
            Send
              ("HTTP/1.1 302 Found" & CRLF &
               "Location: " & Location_Value & CRLF &
               "Content-Length: 0" & CRLF & CRLF);

            --  The client should now request the resolved same-origin target
            --  on this reused transport.  If it raises Redirect_Error instead
            --  it never sends anything and this read ends in EOF or a
            --  timeout.
            begin
               Peer_Log.Set_Second (Request_Line (Read_Head));
               Send
                 ("HTTP/1.1 200 OK" & CRLF &
                  "Content-Length: 2" & CRLF &
                  "Connection: close" & CRLF & CRLF & "ok");
            exception
               when Flyology.IO.Timeout_Error =>
                  Peer_Log.Set_Second ("<no second request: read timed out>");
               when Error : others =>
                  Peer_Log.Set_Second
                    ("<no second request: " &
                     Ada.Exceptions.Exception_Name (Error) & ">");
            end;
         end if;

         if Sockets.Is_Open (Peer) then
            Sockets.Close_Socket (Peer);
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
   begin
      Client.Configure (HTTP, Origin);
      declare
         Request : Client.Request;
      begin
         Client.Set_Target (Request, "/login");
         Client.Set_Redirects (Request, Client.Default_Same_Origin_Redirects);
         declare
            Reply : Client.Response :=
              Client.Execute (HTTP, Request, Timeout => 5.0);
         begin
            Status_Seen := Client.Status (Reply);
            Body_Seen := To_Unbounded_String
              (Flyology.Bytes.To_Byte_String (Client.Read_All (Reply)));
         end;
      exception
         when Error : others =>
            Client_Failure := To_Unbounded_String
              (Ada.Exceptions.Exception_Name (Error) & ": " &
               Ada.Exceptions.Exception_Message (Error));
      end;
      Client.Shutdown (HTTP);
   end;

   if Sockets.Is_Open (Listener) then
      Sockets.Close_Socket (Listener);
   end if;

   Note ("Location served: " & Location_Value);
   Note ("peer saw request 1: " & Peer_Log.First);
   Note ("peer saw request 2: " & Peer_Log.Second);
   if Peer_Log.Error_Text /= "" then
      Note ("peer error: " & Peer_Log.Error_Text);
   end if;
   if Client_Failure /= Null_Unbounded_String then
      Note ("Execute raised: " & To_String (Client_Failure));
   end if;

   Check
     (Client_Failure = Null_Unbounded_String,
      "Execute follows a same-origin relative redirect whose query "
      & "contains ""://"" instead of raising Redirect_Error");
   Expect_Equal
     (Peer_Log.Second,
      "GET /next?u=https://example.com/home HTTP/1.1",
      "the resolved same-origin target is requested on the reused transport");
   Expect_Equal
     (Status_Seen, 200, "Execute returns the status served at the target");
   Expect_Equal
     (To_String (Body_Seen), "ok", "Execute returns the target's body");

   Finish;
end Repro_Client_Pool_1;
