--  H1-CLIENT-5.  Once a composable buffer exchange decides
--  Response_Body_Too_Large -- at head time for a known length
--  (client.adb:4013-4025) or inside Deliver for a streamed one
--  (client.adb:3868-3869, 3892-3895) -- every later slice is discarded and
--  Receive_Content_Step (client.adb:4042-4062) keeps calling Receive_One
--  until the framing completes.  Nothing consults Pending_Result to stop.
--
--  The repository answers this question the other way on its two sibling
--  paths: Drain stops at Max_Redirect_Drain_Bytes = 64 KiB and destroys the
--  transport ("Past this bound the transport costs more than it saves",
--  client.adb:67-70, the fix for prior finding 36), and Read_All calls
--  Abandon_Response on the first overflow (client.adb:7255-7267).
--
--  This program measures the drain: the raw peer counts the response body
--  bytes it manages to write before the exchange terminalizes.  The
--  assertion is the repository-consistent one -- the client does not consume
--  an entire over-capacity body it has already decided to discard.
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.Buffers;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.Operations;
with Repro_Support;

procedure Repro_H1_Client_5 is
   package Buffers renames Flyology.Buffers;
   package HC renames Flyology.HTTP.Client;
   package Operations renames Flyology.Operations;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use Repro_Support;
   use type HC.Exchange_Result_Kind;
   use type Sockets.Selector_Status;

   Capacity   : constant := 4_096;
   Body_Bytes : constant := 8 * 1_024 * 1_024;
   Chunk      : constant := 8 * 1_024;

   function Decimal (Value : Long_Long_Integer) return String is
      Text : constant String := Long_Long_Integer'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Decimal;

   protected Coordination is
      procedure Publish (Value : Sockets.Port);
      entry Wait_Ready (Value : out Sockets.Port);
      procedure Record_Sent (Count : Natural);
      function Sent return Natural;
      procedure Server_Failed (Text : String);
      function Server_Note return String;
   private
      Port_Value : Sockets.Port := Sockets.Any_Port;
      Ready      : Boolean := False;
      Written    : Natural := 0;
      Message    : Unbounded_String;
   end Coordination;

   protected body Coordination is
      procedure Publish (Value : Sockets.Port) is
      begin
         Port_Value := Value;
         Ready := True;
      end Publish;

      entry Wait_Ready (Value : out Sockets.Port) when Ready is
      begin
         Value := Port_Value;
      end Wait_Ready;

      procedure Record_Sent (Count : Natural) is
      begin
         Written := Count;
      end Record_Sent;

      function Sent return Natural is (Written);

      procedure Server_Failed (Text : String) is
      begin
         Message := To_Unbounded_String (Text);
      end Server_Failed;

      function Server_Note return String is (To_String (Message));
   end Coordination;

begin
   Note ("destination capacity is" & Natural'Image (Capacity)
         & " bytes; the response declares" & Natural'Image (Body_Bytes)
         & " body bytes");
   declare
      task Raw_Server is
         pragma Task_Info (Flyology.Native_Task);
      end Raw_Server;

      task body Raw_Server is
         Listener : Sockets.Socket_Type;
         Peer     : Sockets.Socket_Type;
         Address  : Sockets.Endpoint;
         Status   : Sockets.Selector_Status;
         Buffer   : Stream_Element_Array (1 .. 4_096);
         Last     : Stream_Element_Offset;
         Seen     : Unbounded_String;
         Piece    : constant Stream_Element_Array (1 .. Chunk) :=
           (others => Character'Pos ('z'));
         Written  : Natural := 0;
      begin
         Sockets.Create_Socket (Listener);
         Sockets.Bind_Socket
           (Listener,
            Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
         Sockets.Listen_Socket (Listener);
         Coordination.Publish (Sockets.Get_Socket_Name (Listener).Port);
         Sockets.Accept_Socket
           (Listener, Peer, Address, Timeout => 20.0, Status => Status);
         if Status /= Sockets.Completed then
            raise Program_Error with "raw peer accept did not complete";
         end if;
         loop
            Sockets.Receive (Peer, Buffer, Last, Timeout => 20.0);
            exit when Last < Buffer'First;
            for Index in Buffer'First .. Last loop
               Append (Seen, Character'Val (Buffer (Index)));
            end loop;
            exit when Ada.Strings.Fixed.Index (To_String (Seen), CRLF & CRLF)
              /= 0;
         end loop;
         Sockets.Send_All
           (Peer,
            B ("HTTP/1.1 200 OK" & CRLF
               & "Content-Length:" & Natural'Image (Body_Bytes) & CRLF
               & "Connection: close" & CRLF & CRLF),
            Timeout => 10.0);
         begin
            while Written < Body_Bytes loop
               Sockets.Send_All (Peer, Piece, Timeout => 3.0);
               Written := Written + Chunk;
            end loop;
         exception
            when Flyology.IO.Timeout_Error | Flyology.IO.Device_Error
               | Sockets.Socket_Error =>
               null;
         end;
         Coordination.Record_Sent (Written);
         if Sockets.Is_Open (Peer) then
            Sockets.Close_Socket (Peer);
         end if;
         Sockets.Close_Socket (Listener);
      exception
         when Occurrence : others =>
            Coordination.Record_Sent (Written);
            Coordination.Server_Failed
              (Ada.Exceptions.Exception_Information (Occurrence));
            if Sockets.Is_Open (Peer) then
               Sockets.Close_Socket (Peer);
            end if;
            if Sockets.Is_Open (Listener) then
               Sockets.Close_Socket (Listener);
            end if;
      end Raw_Server;

      task Caller is
         pragma Task_Info (Flyology.Native_Task);
      end Caller;

      task body Caller is
         Port        : Sockets.Port;
         Item        : aliased HC.Client (Capacity => 1);
         Pool        : aliased Buffers.Pool
           (Block_Size => Capacity, Capacity => 1);
         Destination : aliased Buffers.Unique_Buffer (Pool'Access);
         Ask         : aliased HC.Request;
      begin
         Coordination.Wait_Ready (Port);
         HC.Configure
           (Item,
            Flyology.HTTP.Parse_Origin
              ("http://127.0.0.1:" & Decimal (Long_Long_Integer (Port))));
         HC.Set_Target (Ask, "/over-capacity");
         Buffers.Acquire (Destination);
         declare
            Set : aliased Operations.Completion_Set (3);
            Op  : HC.Exchange_Operation := HC.Exchange_To_Buffer
              (Set'Access, Item'Access, Ask'Access, Destination,
               HC.Deadline_After (20.0));
            Result : HC.Exchange_Result;
            Reply  : HC.Response;
         begin
            Operations.Wait_All (Set);
            HC.Finish (Op, Result, Reply, Destination);
            Note ("exchange result is "
                  & HC.Exchange_Result_Kind'Image (HC.Kind (Result)));
            Check (HC.Kind (Result) = HC.Response_Body_Too_Large,
                   "control: the typed result is Response_Body_Too_Large");
         end;
         HC.Shutdown (Item);
      exception
         when Occurrence : others =>
            Check (False,
                   "the exchange terminalizes without an exception, got "
                   & Ada.Exceptions.Exception_Name (Occurrence) & ": "
                   & Ada.Exceptions.Exception_Message (Occurrence));
            HC.Shutdown (Item);
      end Caller;
   begin
      null;
   end;
   if Coordination.Server_Note /= "" then
      Ada.Text_IO.Put_Line ("raw peer note: " & Coordination.Server_Note);
   end if;
   Note ("response body bytes the peer managed to write:"
         & Natural'Image (Coordination.Sent) & " of"
         & Natural'Image (Body_Bytes));
   Check (Coordination.Sent < Body_Bytes,
          "the client does not consume the whole over-capacity body it has"
          & " already decided to discard");
   Finish;
end Repro_H1_Client_5;
