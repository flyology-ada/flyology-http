with Ada.Characters.Handling;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;
with Flyology.Bytes;
with Flyology.Channels.Bounded;
with Flyology.HTTP.HTTP_3;
with Flyology.HTTP.Server.Applications.Internals;
with Flyology.HTTP.Server.Exchange_Backends;
with Flyology.IO;
with Flyology.QUIC.Debug;

package body Flyology.HTTP.Server.HTTP_3 is
   use Ada.Streams;
   use type Ada.Real_Time.Time;
   use type Flyology.HTTP.Server.Applications.Response_State;

   package Bytes renames Flyology.Bytes;
   package H3 renames Flyology.HTTP.HTTP_3;
   package Backends renames Flyology.HTTP.Server.Exchange_Backends;
   package QUIC renames Flyology.QUIC.Connections;
   package Debug renames Flyology.QUIC.Debug;
   package Sockets renames Flyology.IO.Sockets;

   use type H3.Event_Kind;
   use type H3.Operation_Status;
   use type QUIC.Operation_Status;
   use type QUIC.Connection_State;
   use type QUIC.Server_Initialize_Status;
   use type QUIC.Send_Status;
   use type QUIC.Stream_ID;
   use type QUIC.Timeout_Status;

   CRLF : constant String := Character'Val (13) & Character'Val (10);
   ALPN : constant Stream_Element_Array :=
     (1 => Character'Pos ('h'), 2 => Character'Pos ('3'));
   Maximum_Request_Streams : constant Positive := 8;
   Response_Chunk_Size : constant Positive := 1_024;

   type Received_Datagram is record
      Data     : Stream_Element_Array (1 .. QUIC.Max_Datagram_Length) :=
        (others => 0);
      Length   : Natural range 0 .. QUIC.Max_Datagram_Length := 0;
      Metadata : Sockets.Datagram_Metadata;
      Starts_Connection : Boolean := False;
      Source   : QUIC.Connection_ID;
   end record;

   package Datagram_Channels is new Flyology.Channels.Bounded
     (Received_Datagram, (others => <>));
   use type Datagram_Channels.Try_Send_Result;

   type Datagram_Channel_Access is access all Datagram_Channels.Channel;

   type Boolean_Array is array (Positive range <>) of Boolean;
   type Connection_ID_Array is
     array (Positive range <>) of QUIC.Connection_ID;
   type Endpoint_Array is array (Positive range <>) of Sockets.Endpoint;

   function Same_ID (Left, Right : QUIC.Connection_ID) return Boolean is
   begin
      return Left.Length = Right.Length
        and then
          (Left.Length = 0
           or else Left.Data
             (1 .. Stream_Element_Offset (Left.Length)) =
               Right.Data (1 .. Stream_Element_Offset (Right.Length)));
   end Same_ID;

   protected type Connection_Registry (Capacity : Positive) is
      procedure Resolve
        (Header    : QUIC.Datagram_Header;
         Peer      : Sockets.Endpoint;
         Candidate : QUIC.Connection_ID;
         Index     : out Natural;
         Starts    : out Boolean;
         Source    : out QUIC.Connection_ID);
      procedure Release (Index : Positive);
   private
      Used      : Boolean_Array (1 .. Capacity) := (others => False);
      Peers     : Endpoint_Array (1 .. Capacity);
      Sources   : Connection_ID_Array (1 .. Capacity);
      Originals : Connection_ID_Array (1 .. Capacity);
   end Connection_Registry;

   protected body Connection_Registry is
      procedure Resolve
        (Header    : QUIC.Datagram_Header;
         Peer      : Sockets.Endpoint;
         Candidate : QUIC.Connection_ID;
         Index     : out Natural;
         Starts    : out Boolean;
         Source    : out QUIC.Connection_ID)
      is
         use type Sockets.Endpoint;
      begin
         Index := 0;
         Starts := False;
         Source := (others => <>);
         if not Header.Valid then
            return;
         end if;
         for Slot in Used'Range loop
            if Used (Slot)
              and then Peers (Slot) = Peer
              and then
                (Same_ID (Sources (Slot), Header.Destination)
                 or else Same_ID (Originals (Slot), Header.Destination))
            then
               Index := Slot;
               Source := Sources (Slot);
               return;
            end if;
         end loop;
         if Header.Is_Initial then
            for Slot in Used'Range loop
               if not Used (Slot) and then Index = 0 then
                  Used (Slot) := True;
                  Peers (Slot) := Peer;
                  Sources (Slot) := Candidate;
                  Originals (Slot) := Header.Destination;
                  Index := Slot;
                  Starts := True;
                  Source := Candidate;
               end if;
            end loop;
         end if;
      end Resolve;

      procedure Release (Index : Positive) is
      begin
         if Index in Used'Range then
            Used (Index) := False;
            Peers (Index) := Sockets.No_Endpoint;
            Sources (Index) := (others => <>);
            Originals (Index) := (others => <>);
         end if;
      end Release;
   end Connection_Registry;

   type Connection_State;
   type Connection_State_Access is access all Connection_State;

   type Connection_State is limited record
      Socket    : access Sockets.Socket_Type;
      Inbox     : Datagram_Channel_Access := null;
      Peer      : Sockets.Endpoint;
      Local     : Sockets.Endpoint;
      Token     : access Flyology.Cancellation.Token;
      Epoch     : Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Transport : QUIC.Connection;
      Session   : H3.Session;
      Response_Headers : H3.Header_Block;
      H3_Started : Boolean := False;
      ACK_Pending : Boolean := False;
      Closed    : Boolean := False;
   end record;

   procedure Free_Connection_State is new Ada.Unchecked_Deallocation
     (Connection_State, Connection_State_Access);

   function Now (Item : Connection_State) return QUIC.Timestamp is
      Elapsed : constant Duration :=
        Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Item.Epoch);
   begin
      return QUIC.Timestamp (Long_Long_Integer (Elapsed * 1_000_000.0));
   end Now;

   function Remaining (Deadline : Ada.Real_Time.Time) return Duration is
   begin
      if Deadline = Ada.Real_Time.Time_Last then
         return -1.0;
      elsif Ada.Real_Time.Clock >= Deadline then
         return 0.0;
      else
         return Ada.Real_Time.To_Duration (Deadline - Ada.Real_Time.Clock);
      end if;
   end Remaining;

   function Receive_Timeout
     (Item : Connection_State; Maximum : Duration) return Duration
   is
      Result : Duration := Maximum;
      Current : constant QUIC.Timestamp := Now (Item);
   begin
      if QUIC.Has_Recovery_Timeout (Item.Transport) then
         declare
            Deadline : constant QUIC.Timestamp :=
              QUIC.Recovery_Deadline (Item.Transport);
            Recovery : constant Duration :=
              (if Deadline <= Current then 0.0
               else Duration (Deadline - Current) / 1_000_000.0);
         begin
            if Result < 0.0 or else Recovery < Result then
               Result := Recovery;
            end if;
         end;
      end if;
      return Result;
   end Receive_Timeout;

   procedure Send_Bytes
     (Item : in out Connection_State;
      Data : Stream_Element_Array;
      Timeout : Duration)
   is
      Last : Stream_Element_Offset;
   begin
      if Item.Token = null and then Item.Inbox = null then
         Sockets.Send (Item.Socket.all, Data, Last, Timeout);
      elsif Item.Token = null then
         Sockets.Send_Datagram
           (Item.Socket.all, Data, Last, Item.Peer, Item.Local, Timeout);
      else
         declare
            FD : Flyology.IO.Descriptor;
            Cancelled : Boolean;
         begin
            Item.Token.Wait_Source (FD, Cancelled);
            if Cancelled then
               raise Flyology.Cancellation.Operation_Cancelled;
            end if;
            if Item.Inbox = null then
               Sockets.Send
                 (Item.Socket.all, Data, Last, Timeout, (1 => FD));
            else
               Sockets.Send_Datagram
                 (Item.Socket.all, Data, Last, Item.Peer, Item.Local,
                  Timeout, (1 => FD));
            end if;
         exception
            when Sockets.Operation_Interrupted =>
               raise Flyology.Cancellation.Operation_Cancelled;
         end;
      end if;
      if Last /= Data'Last then
         raise Flyology.IO.Device_Error with "partial HTTP/3 datagram send";
      end if;
   end Send_Bytes;

   procedure Send
     (Item : in out Connection_State;
      Packet : QUIC.Datagram;
      Timeout : Duration)
   is
   begin
      if Packet.Length > 0 then
         Send_Bytes
           (Item,
            Packet.Data
              (1 .. Stream_Element_Offset (Packet.Length)),
            Timeout);
      end if;
   end Send;

   procedure Send
     (Item : in out Connection_State;
      Flight : QUIC.Datagram_Batch;
      Timeout : Duration)
   is
   begin
      for Index in 1 .. Flight.Count loop
         Send (Item, Flight.Items (Index), Timeout);
      end loop;
   end Send;

   function Application_Error_For
     (Status : H3.Operation_Status) return QUIC.Stream_Offset
   is
     (case Status is
         when H3.Stream_Creation_Error => 16#103#,
         when H3.Closed_Critical_Stream => 16#104#,
         when H3.Frame_Unexpected => 16#105#,
         when H3.Frame_Too_Large | H3.Frame_Error => 16#106#,
         when H3.Stream_Capacity_Exceeded
            | H3.Peer_Field_Section_Too_Large => 16#107#,
         when H3.ID_Error => 16#108#,
         when H3.Settings_Error => 16#109#,
         when H3.Missing_Settings => 16#10A#,
         when H3.Message_Error | H3.Header_Error => 16#10E#,
         when H3.QPACK_Decompression_Failed => 16#200#,
         when H3.QPACK_Encoder_Stream_Error => 16#201#,
         when H3.QPACK_Decoder_Stream_Error => 16#202#,
         when H3.Transport_Error | H3.Transport_Blocked => 16#102#,
         when H3.Succeeded | H3.No_Event | H3.Uninitialized
            | H3.Not_Connected | H3.Not_Started | H3.Already_Started
            | H3.Connection_Draining | H3.Wrong_Role
            | H3.Stream_Limit_Reached => 16#101#);

   procedure Close_For_H3_Error
     (Item    : in out Connection_State;
      Status  : H3.Operation_Status;
      Timeout : Duration)
   is
      Packet : QUIC.Datagram;
      Sent   : QUIC.Send_Status;
   begin
      if Debug.Enabled then
         Debug.Log
           ("h3", "application-close",
            "status=" & H3.Operation_Status'Image (Status) &
            " code=" & QUIC.Stream_Offset'Image
              (Application_Error_For (Status)));
      end if;
      QUIC.Build_Application_Close_Datagram
        (Item.Transport, Application_Error_For (Status), Packet, Sent);
      if Sent /= QUIC.Sent then
         raise Flyology.IO.Device_Error with
           "HTTP/3 application close failed: " & QUIC.Send_Status'Image (Sent);
      end if;
      Send (Item, Packet, Timeout);
      Item.Closed := True;
   end Close_For_H3_Error;

   procedure Process_Recovery
     (Item : in out Connection_State; Timeout : Duration)
   is
      Flight : QUIC.Datagram_Batch;
      Status : QUIC.Timeout_Status;
   begin
      QUIC.Process_Timeout (Item.Transport, Now (Item), Flight, Status);
      case Status is
         when QUIC.Probes_Ready =>
            Send (Item, Flight, Timeout);
         when QUIC.Not_Due | QUIC.No_Pending_Recovery =>
            null;
         when others =>
            raise Flyology.IO.Device_Error with
              "QUIC recovery failed: " & QUIC.Timeout_Status'Image (Status);
      end case;
   end Process_Recovery;

   procedure Flush_Pending_ACK
     (Item : in out Connection_State; Timeout : Duration)
   is
      Packet : QUIC.Datagram;
      Status : QUIC.Send_Status;
   begin
      if not Item.ACK_Pending or else not QUIC.Is_Connected (Item.Transport)
      then
         return;
      end if;
      QUIC.Build_ACK_Datagram
        (Item.Transport, ACK_Delay => 0, Now => Now (Item),
         Packet => Packet, Status => Status);
      case Status is
         when QUIC.Sent =>
            Send (Item, Packet, Timeout);
            Item.ACK_Pending := False;
         when QUIC.Nothing_To_ACK =>
            Item.ACK_Pending := False;
         when others =>
            raise Flyology.IO.Device_Error with
              "QUIC deferred ACK failed: " & QUIC.Send_Status'Image (Status);
      end case;
   end Flush_Pending_ACK;

   procedure Receive_One
     (Item : in out Connection_State; Timeout : Duration)
   is
      Packet : Stream_Element_Array (1 .. QUIC.Max_Datagram_Length);
      Last   : Stream_Element_Offset;
      Flight : QUIC.Datagram_Batch;
      Status : QUIC.Operation_Status;
      ACK_Deferred : Boolean := False;
      Wait   : constant Duration := Receive_Timeout (Item, Timeout);

      procedure Receive is
      begin
         if Item.Inbox /= null then
            declare
               Message : Received_Datagram;
            begin
               Datagram_Channels.Timed_Receive
                 (Item.Inbox.all, Message, Wait);
               Last := Stream_Element_Offset (Message.Length);
               if Message.Length > 0 then
                  Packet (1 .. Last) := Message.Data (1 .. Last);
               end if;
            exception
               when Datagram_Channels.Timeout_Error =>
                  raise Flyology.IO.Timeout_Error;
               when Datagram_Channels.Channel_Closed =>
                  raise Flyology.Cancellation.Operation_Cancelled;
            end;
         elsif Item.Token = null then
            Sockets.Receive (Item.Socket.all, Packet, Last, Wait);
         else
            declare
               FD : Flyology.IO.Descriptor;
               Cancelled : Boolean;
            begin
               Item.Token.Wait_Source (FD, Cancelled);
               if Cancelled then
                  raise Flyology.Cancellation.Operation_Cancelled;
               end if;
               Sockets.Receive
                 (Item.Socket.all, Packet, Last, Wait, (1 => FD));
            exception
               when Sockets.Operation_Interrupted =>
                  raise Flyology.Cancellation.Operation_Cancelled;
            end;
         end if;
      end Receive;
   begin
      Flush_Pending_ACK (Item, Timeout);
      begin
         Receive;
      exception
         when Flyology.IO.Timeout_Error =>
            if QUIC.Has_Recovery_Timeout (Item.Transport)
              and then QUIC.Recovery_Deadline (Item.Transport) <= Now (Item)
            then
               Process_Recovery (Item, Timeout);
               return;
            end if;
            raise;
      end;
      if Last < Packet'First then
         return;
      end if;
      if Item.H3_Started and then QUIC.Is_Connected (Item.Transport) then
         QUIC.Process_Datagram
           (Item.Transport, Packet (Packet'First .. Last), Flight, Status,
            Now (Item), Defer_Application_ACK => True,
            ACK_Deferred => ACK_Deferred);
         Item.ACK_Pending := Item.ACK_Pending or else ACK_Deferred;
      else
         QUIC.Process_Datagram
           (Item.Transport, Packet (Packet'First .. Last), Flight, Status,
            Now (Item));
      end if;
      case Status is
         when QUIC.Succeeded | QUIC.Waiting_For_More =>
            Send (Item, Flight, Timeout);
            if QUIC.State (Item.Transport) = QUIC.Failed then
               if Debug.Enabled then
                  Debug.Log
                    ("h3", "transport-failed",
                     "operation=" & QUIC.Operation_Status'Image (Status));
               end if;
               Item.Closed := True;
            end if;
         when QUIC.Connection_Closed =>
            Item.Closed := True;
         when others =>
            raise Protocol_Error with
              "QUIC receive failed: " & QUIC.Operation_Status'Image (Status);
      end case;
   end Receive_One;

   type Stream_Backend is limited new Backends.Backend with record
      Owner            : Connection_State_Access;
      Stream           : QUIC.Stream_ID := 0;
      Payload_Bytes    : Bytes.Unbounded_Bytes;
      Body_Cursor      : Natural := 1;
      Body_Limit       : Natural := Max_Request_Body;
      Deadline         : Ada.Real_Time.Time := Ada.Real_Time.Time_Last;
      Head_Request     : Boolean := False;
      Response_Begun   : Boolean := False;
      Response_Ended   : Boolean := False;
   end record;

   overriding function Response_Started
     (Item : Stream_Backend) return Boolean;
   overriding procedure Narrow_Deadline
     (Item : in out Stream_Backend; Deadline : Ada.Real_Time.Time);
   overriding function Body_Complete
     (Item : Stream_Backend) return Boolean;
   overriding function Body_Bytes (Item : Stream_Backend) return Natural;
   overriding procedure Narrow_Body_Limit
     (Item : in out Stream_Backend; Maximum : Natural);
   overriding procedure Read_Body
     (Item     : in out Stream_Backend;
      Data     : out Stream_Element_Array;
      Last     : out Stream_Element_Offset;
      Finished : out Boolean;
      Token    : access Flyology.Cancellation.Token);
   overriding procedure Accept_Body
     (Item  : in out Stream_Backend;
      Token : access Flyology.Cancellation.Token);
   overriding procedure Buffer_Body
     (Item  : in out Stream_Backend;
      Value : in out Request;
      Token : access Flyology.Cancellation.Token);
   overriding procedure Discard_Body
     (Item  : in out Stream_Backend;
      Token : access Flyology.Cancellation.Token);
   overriding procedure Respond
     (Item          : in out Stream_Backend;
      Status        : Positive;
      Content_Type  : String;
      Payload       : String;
      Extra_Headers : String;
      Close         : Boolean;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token);
   overriding procedure Begin_Response_Stream
     (Item          : in out Stream_Backend;
      Status        : Positive;
      Content_Type  : String;
      Extra_Headers : String;
      Close         : Boolean;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token);
   overriding procedure Write_Response_Chunk
     (Item : in out Stream_Backend; Data : String; Timeout : Duration;
      Token : access Flyology.Cancellation.Token);
   overriding procedure Write_Response_Chunk
     (Item : in out Stream_Backend; Data : Stream_Element_Array;
      Timeout : Duration; Token : access Flyology.Cancellation.Token);
   overriding procedure End_Response_Stream
     (Item : in out Stream_Backend; Timeout : Duration;
      Token : access Flyology.Cancellation.Token);
   overriding procedure Begin_SSE
     (Item : in out Stream_Backend; Extra_Headers : String;
      Timeout : Duration; Token : access Flyology.Cancellation.Token);
   overriding procedure Send_Event
     (Item : in out Stream_Backend; Data, Event, Id : String;
      Retry : Natural; Timeout : Duration;
      Token : access Flyology.Cancellation.Token;
      Include_Id, Include_Retry : Boolean);
   overriding procedure Send_SSE_Comment
     (Item : in out Stream_Backend; Comment : String; Timeout : Duration;
      Token : access Flyology.Cancellation.Token);
   overriding procedure End_SSE
     (Item : in out Stream_Backend; Timeout : Duration;
      Token : access Flyology.Cancellation.Token);
   overriding procedure Mark_Failed (Item : in out Stream_Backend);

   overriding function Response_Started
     (Item : Stream_Backend) return Boolean is (Item.Response_Begun);

   overriding procedure Narrow_Deadline
     (Item : in out Stream_Backend; Deadline : Ada.Real_Time.Time) is
   begin
      Item.Deadline := Deadline;
   end Narrow_Deadline;

   overriding function Body_Complete
     (Item : Stream_Backend) return Boolean is
     (Item.Body_Cursor > Bytes.Length (Item.Payload_Bytes));

   overriding function Body_Bytes (Item : Stream_Backend) return Natural is
     (Bytes.Length (Item.Payload_Bytes));

   overriding procedure Narrow_Body_Limit
     (Item : in out Stream_Backend; Maximum : Natural) is
   begin
      if Maximum > Item.Body_Limit then
         raise Protocol_Error with "request body limit cannot be widened";
      elsif Bytes.Length (Item.Payload_Bytes) > Maximum then
         raise Payload_Too_Large;
      end if;
      Item.Body_Limit := Maximum;
   end Narrow_Body_Limit;

   overriding procedure Read_Body
     (Item     : in out Stream_Backend;
      Data     : out Stream_Element_Array;
      Last     : out Stream_Element_Offset;
      Finished : out Boolean;
      Token    : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Token);
      Count : constant Natural :=
        (if Item.Body_Cursor > Bytes.Length (Item.Payload_Bytes) then 0
         else Natural'Min
           (Data'Length,
            Bytes.Length (Item.Payload_Bytes) - Item.Body_Cursor + 1));
   begin
      Last := Data'First - 1;
      if Count > 0 then
         for Offset in 0 .. Count - 1 loop
            Data (Data'First + Stream_Element_Offset (Offset)) :=
              Bytes.Element (Item.Payload_Bytes, Item.Body_Cursor + Offset);
         end loop;
         Last := Data'First + Stream_Element_Offset (Count) - 1;
         Item.Body_Cursor := Item.Body_Cursor + Count;
      end if;
      Finished := Body_Complete (Item);
   end Read_Body;

   overriding procedure Accept_Body
     (Item  : in out Stream_Backend;
      Token : access Flyology.Cancellation.Token) is
      pragma Unreferenced (Item, Token);
   begin
      null;
   end Accept_Body;

   overriding procedure Buffer_Body
     (Item  : in out Stream_Backend;
      Value : in out Request;
      Token : access Flyology.Cancellation.Token) is
      pragma Unreferenced (Token);
   begin
      Value.Body_Value := To_Unbounded_String
        (Bytes.To_Byte_String (Item.Payload_Bytes));
      Item.Body_Cursor := Bytes.Length (Item.Payload_Bytes) + 1;
   end Buffer_Body;

   overriding procedure Discard_Body
     (Item  : in out Stream_Backend;
      Token : access Flyology.Cancellation.Token) is
      pragma Unreferenced (Token);
   begin
      Item.Body_Cursor := Bytes.Length (Item.Payload_Bytes) + 1;
   end Discard_Body;

   procedure Wait_For_Transport (Item : in out Stream_Backend) is
      Wait : constant Duration := Remaining (Item.Deadline);
   begin
      if Wait = 0.0 then
         raise Flyology.IO.Timeout_Error;
      end if;
      Receive_One (Item.Owner.all, Wait);
      if Item.Owner.Closed then
         raise Flyology.IO.Device_Error with "HTTP/3 peer closed";
      end if;
   end Wait_For_Transport;

   procedure Send_Headers
     (Item : in out Stream_Backend; Fields : H3.Header_Block;
      Fin : Boolean)
   is
      Packet : QUIC.Datagram;
      Status : H3.Operation_Status;
   begin
      loop
         H3.Send_Headers
           (Item.Owner.Session, Item.Owner.Transport, Item.Stream, Fields,
            Fin, Now (Item.Owner.all), Packet, Status);
         exit when Status = H3.Succeeded;
         if Status /= H3.Transport_Blocked then
            raise Flyology.IO.Device_Error with
              "HTTP/3 response headers failed: " &
              H3.Operation_Status'Image (Status);
         end if;
         Wait_For_Transport (Item);
      end loop;
      Send (Item.Owner.all, Packet, Remaining (Item.Deadline));
      Item.Response_Begun := True;
      Item.Response_Ended := Fin;
   end Send_Headers;

   procedure Send_Data
     (Item : in out Stream_Backend; Data : Stream_Element_Array;
      Fin : Boolean)
   is
      Packet : QUIC.Datagram;
      Status : H3.Operation_Status;
   begin
      loop
         H3.Send_Data
           (Item.Owner.Session, Item.Owner.Transport, Item.Stream, Data, Fin,
            Now (Item.Owner.all), Packet, Status);
         exit when Status = H3.Succeeded;
         if Status /= H3.Transport_Blocked then
            raise Flyology.IO.Device_Error with
              "HTTP/3 response data failed: " &
              H3.Operation_Status'Image (Status);
         end if;
         Wait_For_Transport (Item);
      end loop;
      Send (Item.Owner.all, Packet, Remaining (Item.Deadline));
      Item.Response_Ended := Fin;
   end Send_Data;

   procedure Try_Send_Response
     (Item     : in out Stream_Backend;
      Fields   : H3.Header_Block;
      Data     : Stream_Element_Array;
      Combined : out Boolean)
   is
      Packet : QUIC.Datagram;
      Status : H3.Operation_Status;
      ACK_Included : Boolean;
   begin
      loop
         H3.Send_Response
           (Item.Owner.Session, Item.Owner.Transport, Item.Stream, Fields,
            Data, Now (Item.Owner.all), Packet, Status, ACK_Included);
         exit when Status in H3.Succeeded | H3.Frame_Too_Large;
         if Status /= H3.Transport_Blocked then
            raise Flyology.IO.Device_Error with
              "HTTP/3 complete response failed: " &
              H3.Operation_Status'Image (Status);
         end if;
         Wait_For_Transport (Item);
      end loop;
      Combined := Status = H3.Succeeded;
      if not Combined then
         return;
      end if;
      Send (Item.Owner.all, Packet, Remaining (Item.Deadline));
      if ACK_Included then
         Item.Owner.ACK_Pending := False;
      end if;
      Item.Response_Begun := True;
      Item.Response_Ended := True;
   end Try_Send_Response;

   procedure Append_Field
     (Fields : in out H3.Header_Block; Name, Value : String) is
   begin
      if H3.Header_Count (Fields) = H3.Max_Fields
        or else Name'Length not in 1 .. H3.Max_Name_Length
        or else Value'Length > H3.Max_Value_Length
      then
         raise Program_Error with "HTTP/3 response field section is too large";
      end if;
      H3.Append (Fields, H3.Make_Field (Name, Value));
   end Append_Field;

   procedure Add_Extra_Headers
     (Fields : in out H3.Header_Block; Text : String)
   is
      Position : Natural := Text'First;
   begin
      while Position <= Text'Last loop
         declare
            Marker : constant Natural :=
              Ada.Strings.Fixed.Index (Text (Position .. Text'Last), CRLF);
         begin
            if Marker = 0 then
               raise Program_Error with "malformed HTTP response header";
            end if;
            declare
               Line_Last : constant Natural := Marker - 1;
               Colon : constant Natural := Ada.Strings.Fixed.Index
                 (Text (Position .. Line_Last), ":");
            begin
               if Colon <= Position then
                  raise Program_Error with "malformed HTTP response header";
               end if;
               declare
                  Name : constant String := Ada.Characters.Handling.To_Lower
                    (Text (Position .. Colon - 1));
                  First : Natural := Colon + 1;
               begin
                  while First <= Line_Last
                    and then Text (First) in ' ' | Character'Val (9)
                  loop
                     First := First + 1;
                  end loop;
                  if Name = "content-length" then
                     raise Program_Error with
                       "content-length is managed by the HTTP/3 adapter";
                  end if;
                  Append_Field
                    (Fields, Name,
                     (if First > Line_Last then ""
                      else Text (First .. Line_Last)));
               end;
               Position := Marker + 2;
            end;
         end;
      end loop;
   end Add_Extra_Headers;

   procedure Build_Response_Fields
     (Fields : in out H3.Header_Block; Status : Positive;
      Content_Type, Extra_Headers : String;
      Has_Content_Length : Boolean; Content_Length : Natural)
   is
      Status_Text : constant String :=
        Ada.Strings.Fixed.Trim (Positive'Image (Status), Ada.Strings.Both);
   begin
      H3.Clear (Fields);
      if Status not in Status_Code then
         raise Constraint_Error with "invalid HTTP/3 response status";
      end if;
      Append_Field (Fields, ":status", Status_Text);
      if Content_Type /= "" then
         Append_Field (Fields, "content-type", Content_Type);
      end if;
      if Has_Content_Length then
         Append_Field
           (Fields, "content-length",
            Ada.Strings.Fixed.Trim
              (Natural'Image (Content_Length), Ada.Strings.Both));
      end if;
      Add_Extra_Headers (Fields, Extra_Headers);
   end Build_Response_Fields;

   procedure Send_Response_Head
     (Item : in out Stream_Backend; Status : Positive;
      Content_Type, Extra_Headers : String;
      Has_Content_Length : Boolean; Content_Length : Natural;
      Fin : Boolean)
   is
      Fields : H3.Header_Block renames Item.Owner.Response_Headers;
   begin
      Build_Response_Fields
        (Fields, Status, Content_Type, Extra_Headers,
         Has_Content_Length, Content_Length);
      Send_Headers (Item, Fields, Fin);
   end Send_Response_Head;

   procedure Send_All_Data
     (Item : in out Stream_Backend; Data : Stream_Element_Array)
   is
      Cursor : Stream_Element_Offset := Data'First;
   begin
      while Cursor <= Data'Last loop
         declare
            Count : constant Natural := Natural'Min
              (Response_Chunk_Size, Natural (Data'Last - Cursor + 1));
            Last : constant Stream_Element_Offset :=
              Cursor + Stream_Element_Offset (Count) - 1;
         begin
            Send_Data (Item, Data (Cursor .. Last), Fin => Last = Data'Last);
            Cursor := Last + 1;
         end;
      end loop;
   end Send_All_Data;

   overriding procedure Respond
     (Item          : in out Stream_Backend;
      Status        : Positive;
      Content_Type  : String;
      Payload       : String;
      Extra_Headers : String;
      Close         : Boolean;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Close, Timeout, Token);
      Forbidden : constant Boolean := Status in 204 | 205 | 304;
      Has_Data : constant Boolean :=
        not Item.Head_Request and then not Forbidden and then Payload /= "";
   begin
      if Forbidden and then Payload /= "" then
         raise Program_Error with "HTTP status does not permit content";
      end if;
      if Has_Data then
         declare
            Fields   : H3.Header_Block renames Item.Owner.Response_Headers;
            Data     : constant Stream_Element_Array :=
              Bytes.To_Array (Bytes.From_Byte_String (Payload));
            Combined : Boolean;
         begin
            Build_Response_Fields
              (Fields, Status, Content_Type, Extra_Headers,
               Has_Content_Length => True,
               Content_Length => Payload'Length);
            Try_Send_Response (Item, Fields, Data, Combined);
            if not Combined then
               Send_Headers (Item, Fields, Fin => False);
               Send_All_Data (Item, Data);
            end if;
         end;
      else
         Send_Response_Head
           (Item, Status, Content_Type, Extra_Headers,
            Has_Content_Length => Status not in 204 | 304,
            Content_Length => Payload'Length, Fin => True);
      end if;
   end Respond;

   overriding procedure Begin_Response_Stream
     (Item          : in out Stream_Backend;
      Status        : Positive;
      Content_Type  : String;
      Extra_Headers : String;
      Close         : Boolean;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Close, Timeout, Token);
   begin
      if not Body_Complete (Item) then
         raise Program_Error with
           "streaming response requires a consumed request body";
      elsif Status in 204 | 205 | 304 then
         raise Program_Error with
           "HTTP status does not permit a streaming response";
      end if;
      Send_Response_Head
        (Item, Status, Content_Type, Extra_Headers,
         Has_Content_Length => False, Content_Length => 0, Fin => False);
   end Begin_Response_Stream;

   overriding procedure Write_Response_Chunk
     (Item : in out Stream_Backend; Data : String; Timeout : Duration;
      Token : access Flyology.Cancellation.Token) is
      pragma Unreferenced (Timeout, Token);
   begin
      if not Item.Head_Request and then Data /= "" then
         declare
            Value : constant Stream_Element_Array :=
              Bytes.To_Array (Bytes.From_Byte_String (Data));
            Cursor : Stream_Element_Offset := Value'First;
         begin
            while Cursor <= Value'Last loop
               declare
                  Count : constant Natural := Natural'Min
                    (Response_Chunk_Size,
                     Natural (Value'Last - Cursor + 1));
                  Last : constant Stream_Element_Offset :=
                    Cursor + Stream_Element_Offset (Count) - 1;
               begin
                  Send_Data (Item, Value (Cursor .. Last), Fin => False);
                  Cursor := Last + 1;
               end;
            end loop;
         end;
      end if;
   end Write_Response_Chunk;

   overriding procedure Write_Response_Chunk
     (Item : in out Stream_Backend; Data : Stream_Element_Array;
      Timeout : Duration; Token : access Flyology.Cancellation.Token) is
      pragma Unreferenced (Timeout, Token);
      Cursor : Stream_Element_Offset := Data'First;
   begin
      if not Item.Head_Request then
         while Cursor <= Data'Last loop
            declare
               Count : constant Natural := Natural'Min
                 (Response_Chunk_Size, Natural (Data'Last - Cursor + 1));
               Last : constant Stream_Element_Offset :=
                 Cursor + Stream_Element_Offset (Count) - 1;
            begin
               Send_Data (Item, Data (Cursor .. Last), Fin => False);
               Cursor := Last + 1;
            end;
         end loop;
      end if;
   end Write_Response_Chunk;

   overriding procedure End_Response_Stream
     (Item : in out Stream_Backend; Timeout : Duration;
      Token : access Flyology.Cancellation.Token) is
      pragma Unreferenced (Timeout, Token);
      Empty : Stream_Element_Array (1 .. 0);
   begin
      Send_Data (Item, Empty, Fin => True);
   end End_Response_Stream;

   overriding procedure Begin_SSE
     (Item : in out Stream_Backend; Extra_Headers : String;
      Timeout : Duration; Token : access Flyology.Cancellation.Token) is
      pragma Unreferenced (Timeout, Token);
   begin
      if Item.Head_Request then
         raise Program_Error with "SSE is not available for HEAD";
      elsif not Body_Complete (Item) then
         raise Program_Error with "SSE request body has not been consumed";
      end if;
      Send_Response_Head
        (Item, 200, "text/event-stream",
         "Cache-Control: no-cache" & CRLF & Extra_Headers,
         Has_Content_Length => False, Content_Length => 0, Fin => False);
   end Begin_SSE;

   procedure Validate_SSE_Field (Value, Name : String) is
   begin
      if Ada.Strings.Fixed.Index
        (Value, String'(1 => Character'Val (10))) /= 0
        or else Ada.Strings.Fixed.Index
          (Value, String'(1 => Character'Val (13))) /= 0
      then
         raise Program_Error with Name & " contains a newline";
      end if;
   end Validate_SSE_Field;

   function Valid_UTF8 (Value : String) return Boolean is
      Index : Natural := Value'First;

      function Byte (Offset : Natural) return Natural is
        (Character'Pos (Value (Index + Offset)));

      function Continuation (Offset : Natural) return Boolean is
        (Index + Offset <= Value'Last
         and then Byte (Offset) in 16#80# .. 16#BF#);
   begin
      while Index <= Value'Last loop
         if Byte (0) <= 16#7F# then
            Index := Index + 1;
         elsif Byte (0) in 16#C2# .. 16#DF#
           and then Continuation (1)
         then
            Index := Index + 2;
         elsif Byte (0) = 16#E0#
           and then Index + 2 <= Value'Last
           and then Byte (1) in 16#A0# .. 16#BF#
           and then Continuation (2)
         then
            Index := Index + 3;
         elsif Byte (0) in 16#E1# .. 16#EC# | 16#EE# .. 16#EF#
           and then Continuation (1)
           and then Continuation (2)
         then
            Index := Index + 3;
         elsif Byte (0) = 16#ED#
           and then Index + 2 <= Value'Last
           and then Byte (1) in 16#80# .. 16#9F#
           and then Continuation (2)
         then
            Index := Index + 3;
         elsif Byte (0) = 16#F0#
           and then Index + 3 <= Value'Last
           and then Byte (1) in 16#90# .. 16#BF#
           and then Continuation (2)
           and then Continuation (3)
         then
            Index := Index + 4;
         elsif Byte (0) in 16#F1# .. 16#F3#
           and then Continuation (1)
           and then Continuation (2)
           and then Continuation (3)
         then
            Index := Index + 4;
         elsif Byte (0) = 16#F4#
           and then Index + 3 <= Value'Last
           and then Byte (1) in 16#80# .. 16#8F#
           and then Continuation (2)
           and then Continuation (3)
         then
            Index := Index + 4;
         else
            return False;
         end if;
      end loop;
      return True;
   end Valid_UTF8;

   function Decimal (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   overriding procedure Send_Event
     (Item : in out Stream_Backend; Data, Event, Id : String;
      Retry : Natural; Timeout : Duration;
      Token : access Flyology.Cancellation.Token;
      Include_Id, Include_Retry : Boolean)
   is
      pragma Unreferenced (Timeout, Token);
      Payload : Unbounded_String;
      First : Integer := Data'First;
   begin
      Validate_SSE_Field (Event, "SSE event name");
      Validate_SSE_Field (Id, "SSE id");
      if not Valid_UTF8 (Data)
        or else not Valid_UTF8 (Event)
        or else not Valid_UTF8 (Id)
        or else Ada.Strings.Fixed.Index
          (Id, String'(1 => Character'Val (0))) /= 0
      then
         raise Program_Error with "SSE fields must contain valid UTF-8";
      end if;
      if Event /= "" then
         Append (Payload, "event: " & Event & Character'Val (10));
      end if;
      if Id /= "" or else Include_Id then
         Append (Payload, "id: " & Id & Character'Val (10));
      end if;
      if Retry > 0 or else Include_Retry then
         Append (Payload, "retry: " & Decimal (Retry) & Character'Val (10));
      end if;
      if Data = "" then
         Append (Payload, "data:" & Character'Val (10));
      else
         while First <= Data'Last loop
            declare
               Break : Natural := 0;
               Last : Integer;
            begin
               for Index in First .. Data'Last loop
                  if Data (Index) in Character'Val (10) | Character'Val (13)
                  then
                     Break := Index;
                     exit;
                  end if;
               end loop;
               Last := (if Break = 0 then Data'Last else Break - 1);
               Append (Payload, "data:");
               if Last >= First then
                  Append (Payload, " " & Data (First .. Last));
               end if;
               Append (Payload, Character'Val (10));
               exit when Break = 0;
               First := Break + 1;
               if Data (Break) = Character'Val (13)
                 and then First <= Data'Last
                 and then Data (First) = Character'Val (10)
               then
                  First := First + 1;
               end if;
            end;
         end loop;
      end if;
      Append (Payload, Character'Val (10));
      Write_Response_Chunk
        (Item, To_String (Payload), Remaining (Item.Deadline), null);
   end Send_Event;

   overriding procedure Send_SSE_Comment
     (Item : in out Stream_Backend; Comment : String; Timeout : Duration;
      Token : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
      Payload : Unbounded_String;
      First : Integer := Comment'First;
   begin
      if not Valid_UTF8 (Comment) then
         raise Program_Error with "SSE comment must contain valid UTF-8";
      end if;
      if Comment = "" then
         Append (Payload, ":" & Character'Val (10));
      else
         while First <= Comment'Last loop
            declare
               Break : Natural := 0;
               Last : Integer;
            begin
               for Index in First .. Comment'Last loop
                  if Comment (Index) in
                    Character'Val (10) | Character'Val (13)
                  then
                     Break := Index;
                     exit;
                  end if;
               end loop;
               Last := (if Break = 0 then Comment'Last else Break - 1);
               Append (Payload, ":");
               if Last >= First then
                  Append (Payload, " " & Comment (First .. Last));
               end if;
               Append (Payload, Character'Val (10));
               exit when Break = 0;
               First := Break + 1;
               if Comment (Break) = Character'Val (13)
                 and then First <= Comment'Last
                 and then Comment (First) = Character'Val (10)
               then
                  First := First + 1;
               end if;
            end;
         end loop;
      end if;
      Append (Payload, Character'Val (10));
      Write_Response_Chunk
        (Item, To_String (Payload), Remaining (Item.Deadline), null);
   end Send_SSE_Comment;

   overriding procedure End_SSE
     (Item : in out Stream_Backend; Timeout : Duration;
      Token : access Flyology.Cancellation.Token) is
   begin
      End_Response_Stream (Item, Timeout, Token);
   end End_SSE;

   overriding procedure Mark_Failed (Item : in out Stream_Backend) is
      Packet : QUIC.Datagram;
      Status : H3.Operation_Status;
   begin
      if Item.Response_Ended then
         return;
      end if;
      H3.Cancel_Request
        (Item.Owner.Session, Item.Owner.Transport, Item.Stream,
         H3.Cancel_Processing, Now (Item.Owner.all), Packet, Status);
      if Status = H3.Succeeded then
         Send (Item.Owner.all, Packet, Remaining (Item.Deadline));
      end if;
      Item.Response_Ended := True;
   end Mark_Failed;

   type Header_Block_Access is access H3.Header_Block;

   procedure Free_Header_Block is new Ada.Unchecked_Deallocation
     (H3.Header_Block, Header_Block_Access);

   type Request_Slot is record
      Occupied    : Boolean := False;
      Stream      : QUIC.Stream_ID := 0;
      Headers     : Header_Block_Access := null;
      Saw_Headers : Boolean := False;
      Payload_Bytes : Bytes.Unbounded_Bytes;
      Started     : Ada.Real_Time.Time := Ada.Real_Time.Time_Last;
   end record;
   type Request_Array is
     array (Positive range 1 .. Maximum_Request_Streams) of Request_Slot;
   type Request_Array_Access is access all Request_Array;

   procedure Free_Request_Array is new Ada.Unchecked_Deallocation
     (Request_Array, Request_Array_Access);

   function Find (Requests : Request_Array; Stream : QUIC.Stream_ID)
      return Natural is
   begin
      for Index in Requests'Range loop
         if Requests (Index).Occupied
           and then Requests (Index).Stream = Stream
         then
            return Index;
         end if;
      end loop;
      return 0;
   end Find;

   procedure Serve_Connection
     (Context            : in out App_Context;
      Socket             : not null access Sockets.Socket_Type;
      Inbox              : Datagram_Channel_Access;
      First              : Received_Datagram;
      Certificate_DER    : Stream_Element_Array;
      Private_Key        : QUIC.Ed25519_Private_Key;
      Source             : QUIC.Connection_ID;
      Transport_Settings : QUIC.Transport_Settings := (others => <>);
      Timeout            : Duration := 30.0;
      Handshake_Timeout  : Duration := 10.0;
      Max_Connection_Age : Duration := 300.0;
      Max_Requests       : Positive := Default_Requests_Per_Connection;
      Token              : access Flyology.Cancellation.Token := null)
   is
      State : Connection_State_Access := new Connection_State'
        (Socket => Socket, Inbox => Inbox, Token => Token, others => <>);
      Initialized : QUIC.Server_Initialize_Status;
      Flight : QUIC.Datagram_Batch;
      QUIC_Status : QUIC.Operation_Status;
      H3_Status : H3.Operation_Status;
      Control : QUIC.Datagram;
      Requests : Request_Array_Access := new Request_Array;
      Served : Natural := 0;
      Value : H3.Event;
      Poll_Status : H3.Operation_Status;
      Last_Credit_Data : QUIC.Stream_Offset := 0;
      Stream_Credit_Interval : constant Positive :=
        Positive
          (QUIC.Stream_Offset'Min
             (QUIC.Stream_Offset (Positive'Last),
              QUIC.Stream_Offset'Max
                (1, Transport_Settings.Max_Streams_Bidi / 2)));
      Data_Credit_Interval : constant QUIC.Stream_Offset :=
        QUIC.Stream_Offset'Max (1, Transport_Settings.Max_Data / 2);
      Connection_Deadline : constant Ada.Real_Time.Time :=
        (if Max_Connection_Age < 0.0 then Ada.Real_Time.Time_Last
         else State.Epoch + Ada.Real_Time.To_Time_Span (Max_Connection_Age));

      procedure Start_HTTP_3 is
      begin
         H3.Initialize (State.Session, H3.Server);
         loop
            H3.Start
              (State.Session, State.Transport, Now (State.all), Control,
               H3_Status);
            exit when H3_Status = H3.Succeeded;
            if H3_Status /= H3.Transport_Blocked then
               raise Protocol_Error with
                 "HTTP/3 startup failed: " &
                 H3.Operation_Status'Image (H3_Status);
            end if;
            Receive_One (State.all, Handshake_Timeout);
         end loop;
         State.H3_Started := True;
         Send (State.all, Control, Handshake_Timeout);
      end Start_HTTP_3;

      function Header_Value
        (Fields : H3.Header_Block; Name : String) return String is
      begin
         for Index in 1 .. H3.Header_Count (Fields) loop
            if H3.Field_Name (H3.Field_At (Fields, Index)) = Name then
               return H3.Field_Value (H3.Field_At (Fields, Index));
            end if;
         end loop;
         return "";
      end Header_Value;

      procedure Dispatch_Request (Slot : Positive) is
         Method : constant String := Header_Value
           (Requests (Slot).Headers.all, ":method");
         Target : constant String := Header_Value
           (Requests (Slot).Headers.all, ":path");
         Authority : constant String := Header_Value
           (Requests (Slot).Headers.all, ":authority");
         Validated : constant Flyology.HTTP.Method := To_Method (Method);
         pragma Unreferenced (Validated);
         Backend : aliased Stream_Backend;
         Value : aliased Request;
         Deadline : constant Ada.Real_Time.Time :=
           (if Timeout < 0.0 then Ada.Real_Time.Time_Last
            else Requests (Slot).Started +
              Ada.Real_Time.To_Time_Span (Timeout));
         X : Applications.Exchange := Applications.Internals.Create
           (Value, Backend'Access, State.Peer, Token, Deadline,
            Secure_HTTPS);
      begin
         if Method = "CONNECT" or else Target = "" then
            raise Protocol_Error with
              "HTTP/3 CONNECT is not supported by the application adapter";
         end if;
         Value.Method_Value := To_Unbounded_String (Method);
         Value.Target_Value := To_Unbounded_String (Target);
         Value.Version_Value := HTTP_1_1;
         Value.Protocol_Value := HTTP_3_Protocol;
         Value.Keep_Alive := True;
         for Index in 1 .. H3.Header_Count (Requests (Slot).Headers.all) loop
            declare
               Field : constant H3.Header_Field :=
                 H3.Field_At (Requests (Slot).Headers.all, Index);
               Name : constant String := H3.Field_Name (Field);
            begin
               if Name'Length > 0 and then Name (Name'First) /= ':' then
                  Append
                    (Value.Header_Block,
                     Name & ": " & H3.Field_Value (Field) & CRLF);
               end if;
            end;
         end loop;
         if Authority /= "" and then Header_Value
           (Requests (Slot).Headers.all, "host") = ""
         then
            Append (Value.Header_Block, "Host: " & Authority & CRLF);
         end if;
         Backend.Owner := State;
         Backend.Stream := Requests (Slot).Stream;
         Backend.Payload_Bytes := Requests (Slot).Payload_Bytes;
         Backend.Deadline := Deadline;
         Backend.Head_Request := Method = "HEAD";
         begin
            Handle (Context, X);
            if X.Response = Applications.Not_Started then
               X.No_Content;
            elsif X.Response in
              Applications.Streaming_Response | Applications.Streaming_SSE |
              Applications.Upgraded | Applications.Failed
            then
               X.Mark_Failed;
            end if;
         exception
            when others =>
               if not X.Wire_Response_Started then
                  begin
                     X.Problem
                       (500, "internal-server-error", "Internal server error");
                  exception
                     when others => X.Mark_Failed;
                  end;
               else
                  X.Mark_Failed;
               end if;
         end;
         Served := Served + 1;
         if Debug.Enabled
           and then
             (Served <= 4
              or else Served mod 256 = 0)
         then
            Debug.Log
              ("h3", "request-progress",
               "served=" & Natural'Image (Served) &
               " stream=" & QUIC.Stream_ID'Image
                 (Requests (Slot).Stream));
         end if;
      end Dispatch_Request;

      procedure Return_Request_Credit is
         Packet : QUIC.Datagram;
         Status : QUIC.Send_Status;
         Limit  : constant QUIC.Stream_Offset :=
           QUIC.Stream_Offset'Min
             (2**60,
              Transport_Settings.Max_Streams_Bidi
                + QUIC.Stream_Offset (Served));
      begin
         loop
            QUIC.Build_Receive_Credit_Datagram
              (State.Transport,
               Connection_Window => Transport_Settings.Max_Data,
               Direction => QUIC.Bidirectional,
               Maximum_Streams => Limit,
               Now => Now (State.all), Packet => Packet, Status => Status);
            exit when Status = QUIC.Sent;
            if Status /= QUIC.Congestion_Blocked then
               raise Protocol_Error with
                 "QUIC receive-credit update failed: " &
                 QUIC.Send_Status'Image (Status);
            end if;
            Receive_One (State.all, Remaining (Connection_Deadline));
         end loop;
         Send (State.all, Packet, Remaining (Connection_Deadline));
         Last_Credit_Data := QUIC.Received_Data (State.Transport);
      end Return_Request_Credit;

      function Request_Credit_Due return Boolean is
         Current : constant QUIC.Stream_Offset :=
           QUIC.Received_Data (State.Transport);
      begin
         return Served mod Stream_Credit_Interval = 0
           or else Current - Last_Credit_Data >= Data_Credit_Interval;
      end Request_Credit_Due;

      procedure Release (Slot : Positive) is
      begin
         Requests (Slot).Occupied := False;
         Requests (Slot).Stream := 0;
         Requests (Slot).Saw_Headers := False;
         if Requests (Slot).Headers /= null then
            H3.Clear (Requests (Slot).Headers.all);
         end if;
         Requests (Slot).Started := Ada.Real_Time.Time_Last;
         Bytes.Clear (Requests (Slot).Payload_Bytes);
      end Release;

      procedure Process_Event (Value : H3.Event) is
         Slot : Natural := Find (Requests.all, Value.Stream);
      begin
         case Value.Kind is
            when H3.Headers_Received =>
               if Slot = 0 then
                  for Index in Requests.all'Range loop
                     if not Requests (Index).Occupied and then Slot = 0 then
                        Slot := Index;
                     end if;
                  end loop;
                  if Slot = 0 then
                     raise Resource_Exhausted with
                       "HTTP/3 request capacity is full";
                  end if;
                  Requests (Slot).Occupied := True;
                  Requests (Slot).Stream := Value.Stream;
                  Requests (Slot).Started := Ada.Real_Time.Clock;
                  if Requests (Slot).Headers = null then
                     Requests (Slot).Headers := new H3.Header_Block;
                  end if;
               end if;
               if not Requests (Slot).Saw_Headers then
                  H3.Clear (Requests (Slot).Headers.all);
                  for Index in 1 .. H3.Header_Count (Value.Headers) loop
                     H3.Append
                       (Requests (Slot).Headers.all,
                        H3.Field_At (Value.Headers, Index));
                  end loop;
                  Requests (Slot).Saw_Headers := True;
               end if;
            when H3.Data_Received =>
               if Slot = 0 or else not Requests (Slot).Saw_Headers then
                  raise Protocol_Error with
                    "HTTP/3 DATA preceded request HEADERS";
               elsif Bytes.Length (Requests (Slot).Payload_Bytes)
                 + Value.Data_Length >
                 Max_Request_Body
               then
                  raise Payload_Too_Large;
               elsif Value.Data_Length > 0 then
                  Bytes.Append
                    (Requests (Slot).Payload_Bytes,
                     Value.Data
                       (1 .. Stream_Element_Offset (Value.Data_Length)));
               end if;
            when H3.Stream_Ended =>
               if Slot = 0 or else not Requests (Slot).Saw_Headers then
                  raise Protocol_Error with
                    "HTTP/3 stream ended without request";
               end if;
               Dispatch_Request (Positive (Slot));
               H3.Release_Request
                 (State.Session, State.Transport,
                  Requests (Slot).Stream, H3_Status);
               if H3_Status /= H3.Succeeded then
                  raise Protocol_Error with
                    "HTTP/3 request release failed: " &
                    H3.Operation_Status'Image (H3_Status);
               end if;
               Release (Positive (Slot));
               if Served < Max_Requests and then Request_Credit_Due then
                  Return_Request_Credit;
               end if;
            when H3.Stream_Reset =>
               if Slot /= 0 then
                  Release (Positive (Slot));
               end if;
            when H3.Settings_Received | H3.Goaway_Received | H3.No_Event =>
               null;
         end case;
      end Process_Event;

      procedure Cleanup is
      begin
         if Requests /= null then
            for Index in Requests.all'Range loop
               if Requests (Index).Headers /= null then
                  Free_Header_Block (Requests (Index).Headers);
               end if;
            end loop;
            Free_Request_Array (Requests);
         end if;
         if State /= null then
            Free_Connection_State (State);
         end if;
      end Cleanup;
   begin
      if Max_Requests > Maximum_Requests_Per_Connection then
         raise Constraint_Error with
           "HTTP/3 request limit exceeds the bounded connection profile";
      elsif Handshake_Timeout <= 0.0 then
         raise Constraint_Error with
           "HTTP/3 handshake timeout must be positive";
      end if;
      if First.Length = 0 or else First.Metadata.Truncated then
         raise Protocol_Error with "invalid first QUIC datagram";
      end if;
      State.Peer := First.Metadata.Source;
      State.Local := First.Metadata.Destination;
      if Inbox = null then
         Sockets.Connect_Socket (Socket.all, State.Peer);
      end if;
      QUIC.Initialize_Server_From_Initial
        (State.Transport, ALPN, Transport_Settings, Certificate_DER,
         Private_Key, Source,
         First.Data (1 .. Stream_Element_Offset (First.Length)), Initialized);
      if Initialized /= QUIC.Initialized then
         raise Protocol_Error with
           "QUIC server initialization failed: " &
           QUIC.Server_Initialize_Status'Image (Initialized);
      end if;
      QUIC.Process_Datagram
        (State.Transport,
         First.Data (1 .. Stream_Element_Offset (First.Length)), Flight,
         QUIC_Status, Now (State.all));
      if QUIC_Status not in QUIC.Succeeded | QUIC.Waiting_For_More then
         raise Protocol_Error with
           "QUIC Initial failed: " & QUIC.Operation_Status'Image (QUIC_Status);
      end if;
      Send (State.all, Flight, Handshake_Timeout);
      if QUIC.State (State.Transport) = QUIC.Failed then
         Cleanup;
         return;
      end if;
      while not QUIC.Is_Connected (State.Transport) loop
         if Remaining (State.Epoch + Ada.Real_Time.To_Time_Span
           (Handshake_Timeout)) = 0.0
         then
            raise Flyology.IO.Timeout_Error;
         end if;
         Receive_One
           (State.all, Remaining
             (State.Epoch + Ada.Real_Time.To_Time_Span (Handshake_Timeout)));
         if State.Closed then
            Cleanup;
            return;
         end if;
      end loop;
      Start_HTTP_3;

      while not State.Closed
        and then Served < Max_Requests
        and then Remaining (Connection_Deadline) /= 0.0
      loop
         begin
            H3.Poll (State.Session, State.Transport, Value, Poll_Status);
            case Poll_Status is
               when H3.Succeeded =>
                  Process_Event (Value);
               when H3.No_Event =>
                  Receive_One (State.all, Remaining (Connection_Deadline));
               when others =>
                  Close_For_H3_Error
                    (State.all, Poll_Status,
                     Remaining (Connection_Deadline));
            end case;
         exception
            when Flyology.IO.Timeout_Error =>
               exit when Remaining (Connection_Deadline) = 0.0;
         end;
      end loop;
      Cleanup;
   exception
      when others =>
         Cleanup;
         raise;
   end Serve_Connection;

   procedure Serve
     (Context            : in out App_Context;
      Socket             : aliased in out Sockets.Socket_Type;
      Certificate_DER    : Stream_Element_Array;
      Private_Key        : QUIC.Ed25519_Private_Key;
      Source             : QUIC.Connection_ID;
      Transport_Settings : QUIC.Transport_Settings := (others => <>);
      Timeout            : Duration := 30.0;
      Handshake_Timeout  : Duration := 10.0;
      Max_Connection_Age : Duration := 300.0;
      Max_Requests       : Positive := Default_Requests_Per_Connection;
      Token              : access Flyology.Cancellation.Token := null)
   is
      First : Received_Datagram;
      Last  : Stream_Element_Offset;
   begin
      if Token = null then
         Sockets.Receive_Datagram
           (Socket, First.Data, Last, First.Metadata, Handshake_Timeout);
      else
         declare
            FD : Flyology.IO.Descriptor;
            Cancelled : Boolean;
         begin
            Token.Wait_Source (FD, Cancelled);
            if Cancelled then
               raise Flyology.Cancellation.Operation_Cancelled;
            end if;
            Sockets.Receive_Datagram
              (Socket, First.Data, Last, First.Metadata, Handshake_Timeout,
               (1 => FD));
         exception
            when Sockets.Operation_Interrupted =>
               raise Flyology.Cancellation.Operation_Cancelled;
         end;
      end if;
      First.Length :=
        (if Last < First.Data'First then 0
         else Natural (Last - First.Data'First + 1));
      First.Starts_Connection := True;
      Serve_Connection
        (Context, Socket'Unchecked_Access, null, First, Certificate_DER,
         Private_Key, Source, Transport_Settings, Timeout,
         Handshake_Timeout, Max_Connection_Age, Max_Requests, Token);
   end Serve;

   procedure Serve_Listener
     (Context            : aliased in out App_Context;
      Socket             : aliased in out Sockets.Socket_Type;
      Certificate_DER    : Stream_Element_Array;
      Private_Key        : QUIC.Ed25519_Private_Key;
      Capacity           : Positive := Default_Connection_Capacity;
      Transport_Settings : QUIC.Transport_Settings := (others => <>);
      Timeout            : Duration := 30.0;
      Handshake_Timeout  : Duration := 10.0;
      Max_Connection_Age : Duration := 300.0;
      Max_Requests       : Positive := Default_Requests_Per_Connection;
      Token              : not null access Flyology.Cancellation.Token)
   is
      subtype Slot_Index is Positive range 1 .. Capacity;
      subtype Inbox is Datagram_Channels.Channel (Capacity => 32);
      type Inbox_Array is array (Slot_Index) of aliased Inbox;
      type Inbox_Array_Access is access Inbox_Array;
      type Registry_Access is access Connection_Registry;

      Inboxes  : constant Inbox_Array_Access := new Inbox_Array;
      Registry : constant Registry_Access :=
        new Connection_Registry (Capacity);

      task type Worker is
         pragma Task_Info (Handler_Model);
         entry Start (Index : Slot_Index);
      end Worker;
      for Worker'Storage_Size use 4 * 1_024 * 1_024;

      task body Worker is
         Slot    : Slot_Index := Slot_Index'First;
         Message : Received_Datagram;
      begin
         accept Start (Index : Slot_Index) do
            Slot := Index;
         end Start;
         loop
            begin
               Inboxes (Slot).Receive (Message);
               if Message.Starts_Connection then
                  begin
                     Serve_Connection
                       (Context, Socket'Unchecked_Access,
                        Inboxes (Slot)'Unchecked_Access, Message,
                        Certificate_DER, Private_Key, Message.Source,
                        Transport_Settings, Timeout, Handshake_Timeout,
                        Max_Connection_Age, Max_Requests, Token);
                  exception
                     when Error : others =>
                        if Debug.Enabled then
                           Debug.Log
                             ("h3", "worker-exception",
                              Ada.Exceptions.Exception_Information (Error));
                        end if;
                  end;
                  Registry.Release (Slot);
               end if;
            exception
               when Datagram_Channels.Channel_Closed =>
                  exit;
            end;
         end loop;
      end Worker;

      type Worker_Array is array (Slot_Index) of Worker;
      type Worker_Array_Access is access Worker_Array;
      Workers : constant Worker_Array_Access := new Worker_Array;

      procedure Close_Inboxes is
      begin
         for Index in Inboxes.all'Range loop
            Inboxes (Index).Close;
         end loop;
      end Close_Inboxes;
   begin
      if Capacity > Maximum_Connection_Capacity then
         raise Constraint_Error with
           "HTTP/3 listener capacity exceeds the bounded worker profile";
      elsif Max_Requests > Maximum_Requests_Per_Connection then
         raise Constraint_Error with
           "HTTP/3 request limit exceeds the bounded connection profile";
      elsif Handshake_Timeout <= 0.0 then
         raise Constraint_Error with
           "HTTP/3 handshake timeout must be positive";
      end if;

      Sockets.Enable_Datagram_Metadata (Socket);
      for Index in Workers.all'Range loop
         Workers (Index).Start (Index);
      end loop;

      loop
         exit when Token.Requested;
         declare
            Message   : Received_Datagram;
            Last      : Stream_Element_Offset;
            FD        : Flyology.IO.Descriptor;
            Cancelled : Boolean;
            Header    : QUIC.Datagram_Header;
            Candidate : QUIC.Connection_ID;
            Index     : Natural;
            Starts    : Boolean;
            Source    : QUIC.Connection_ID;
            Sent      : Datagram_Channels.Try_Send_Result;
         begin
            Token.Wait_Source (FD, Cancelled);
            exit when Cancelled;
            Sockets.Receive_Datagram
              (Socket, Message.Data, Last, Message.Metadata,
               Timeout => -1.0, Interrupts => (1 => FD));
            if Last >= Message.Data'First
              and then not Message.Metadata.Truncated
            then
               Message.Length :=
                 Natural (Last - Message.Data'First + 1);
               Header := QUIC.Inspect_Datagram_Header
                 (Message.Data (1 .. Stream_Element_Offset (Message.Length)));
               Candidate :=
                 (if Header.Is_Initial then QUIC.Random_Connection_ID
                  else (others => <>));
               Registry.Resolve
                 (Header, Message.Metadata.Source, Candidate,
                  Index, Starts, Source);
               if Index /= 0 then
                  Message.Starts_Connection := Starts;
                  Message.Source := Source;
                  Inboxes (Positive (Index)).Try_Send (Message, Sent);
                  if Starts
                    and then Sent /= Datagram_Channels.Item_Sent
                  then
                     Registry.Release (Positive (Index));
                  end if;
               end if;
            end if;
         exception
            when Sockets.Operation_Interrupted =>
               exit when Token.Requested;
               raise;
         end;
      end loop;
      Close_Inboxes;
   exception
      when others =>
         Close_Inboxes;
         raise;
   end Serve_Listener;

   procedure Serve
     (Context            : in out App_Context;
      Socket             : aliased in out Flyology.IO.Sockets.Socket_Type;
      Certificate_DER    : Ada.Streams.Stream_Element_Array;
      Private_Key        : Flyology.QUIC.Connections.Ed25519_Private_Key;
      Transport_Settings : Flyology.QUIC.Connections.Transport_Settings :=
        (others => <>);
      Timeout            : Duration := 30.0;
      Handshake_Timeout  : Duration := 10.0;
      Max_Connection_Age : Duration := 300.0;
      Max_Requests       : Positive := Default_Requests_Per_Connection;
      Token              : access Flyology.Cancellation.Token := null) is
   begin
      Serve
        (Context, Socket, Certificate_DER, Private_Key,
         QUIC.Random_Connection_ID, Transport_Settings, Timeout,
         Handshake_Timeout, Max_Connection_Age, Max_Requests, Token);
   end Serve;

end Flyology.HTTP.Server.HTTP_3;
