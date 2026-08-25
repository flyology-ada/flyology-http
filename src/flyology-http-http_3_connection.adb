with Flyology.HTTP.HTTP_3_Control_Policy;
with Flyology.HTTP.HTTP_3_Frame_Policy;
with Flyology.HTTP.HTTP_3_Header_Policy;
with Flyology.HTTP.HTTP_3_Stream_Policy;

package body Flyology.HTTP.HTTP_3_Connection is
   use type Ada.Streams.Stream_Element_Offset;
   use type HTTP_3_Stream_Receive_Policy.Event_Kind;
   use type HTTP_3_Stream_Receive_Policy.Receive_Status;
   use type HTTP_3_Stream_Receive_Policy.Stream_Kind;
   use type HTTP_3_Header_Policy.Validation_Status;
   use type HTTP_3_Message_Policy.Finish_Status;
   use type HTTP_3_Message_Policy.Request_Phase;
   use type HTTP_3_Message_Policy.Response_Phase;
   use type HTTP_3_Message_Policy.Update_Status;
   use type QPACK_Field_Section_Policy.Encode_Status;
   use type QUIC.Open_Status;
   use type QUIC.Send_Status;
   use type QUIC.Stream_Offset;

   subtype Optional_Slot is Natural range 0 .. Max_Streams;

   function Receive_Role
     (Role : Endpoint_Role) return HTTP_3_Stream_Policy.Endpoint_Role
   is
     (case Role is
         when Client => HTTP_3_Stream_Policy.Client,
         when Server => HTTP_3_Stream_Policy.Server);

   procedure Initialize
     (Item     : in out Connection;
      Role     : Endpoint_Role;
      Settings : HTTP_3_Settings_Policy.Settings) is
   begin
      Item.Local_Role := Role;
      Item.Local_Settings := Settings;
   end Initialize;

   function Send_Status_For
     (Value : QUIC.Send_Status) return Operation_Status
   is
     (case Value is
         when QUIC.Sent => Succeeded,
         when QUIC.Congestion_Blocked => Transport_Blocked,
         when QUIC.Stream_Capacity_Exceeded => Stream_Capacity_Exceeded,
         when QUIC.Stream_Flow_Blocked | QUIC.Connection_Flow_Blocked =>
           Transport_Blocked,
         when others => Transport_Error);

   procedure Start
     (Item      : in out Connection;
      Transport : in out QUIC.Connection;
      Now       : QUIC.Timestamp;
      Packet    : out QUIC.Datagram;
      Status    : out Operation_Status)
   is
      ID      : QUIC.Stream_ID;
      Opened  : QUIC.Open_Status;
      Sent    : QUIC.Send_Status;
      Preface : constant HTTP_3_Control_Policy.Preface_Result :=
        HTTP_3_Control_Policy.Build_Local_Preface (Item.Local_Settings);
   begin
      Packet := (others => <>);
      if not QUIC.Is_Connected (Transport) then
         Status := Not_Connected;
         return;
      elsif Item.Started then
         Status := Already_Started;
         return;
      end if;

      QUIC.Open_Stream (Transport, QUIC.Unidirectional, ID, Opened);
      if Opened /= QUIC.Opened then
         Status :=
           (if Opened = QUIC.Stream_Limit_Reached
            then Stream_Limit_Reached else Transport_Error);
         return;
      end if;
      QUIC.Build_Stream_Datagram
        (Transport, ID, 0, Fin => False,
         Data => Preface.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Preface.Length)),
         Now => Now, Packet => Packet, Status => Sent);
      Status := Send_Status_For (Sent);
      if Status = Succeeded then
         Item.Started := True;
         Item.Local_Control_ID := ID;
         Item.Local_Control_Offset := QUIC.Stream_Offset (Preface.Length);
      end if;
   end Start;

   function Find
     (Item : Connection; ID : QUIC.Stream_ID) return Optional_Slot is
   begin
      for Index in Slot_Index loop
         if Item.Streams (Index).Occupied
           and then Item.Streams (Index).ID = ID
         then
            return Index;
         end if;
      end loop;
      return 0;
   end Find;

   function Is_Released_Message
     (Item      : Connection;
      Transport : QUIC.Connection;
      ID        : QUIC.Stream_ID) return Boolean is
     (ID mod 4 = 0
      and then
        ((ID / 4 <= QUIC.Stream_ID (Message_Ordinal'Last)
          and then Item.Released_Messages (Message_Ordinal (ID / 4)))
         or else QUIC.Is_Stream_Retired (Transport, ID))
      and then Find (Item, ID) = 0);

   procedure Release_Message
     (Item      : in out Connection;
      Transport : in out QUIC.Connection;
      ID        : QUIC.Stream_ID;
      Slot      : Slot_Index)
   is
   begin
      if ID mod 4 = 0
        and then ID / 4 <= QUIC.Stream_ID (Message_Ordinal'Last)
      then
         Item.Released_Messages (Message_Ordinal (ID / 4)) := True;
      end if;
      Item.Streams (Slot) := (others => <>);
      Item.Count := Item.Count - 1;
      QUIC.Release_Stream (Transport, ID);

      --  A client retains request-send state until the response finishes so
      --  HEAD response validation remains available. The completed response
      --  is the point at which that compact state can be recycled.
      if Item.Local_Role = Client then
         for Index in Slot_Index loop
            if Item.Sending (Index).Occupied
              and then Item.Sending (Index).ID = ID
            then
               Item.Sending (Index) := (others => <>);
               Item.Send_Count := Item.Send_Count - 1;
               exit;
            end if;
         end loop;
      end if;
   end Release_Message;

   procedure Abandon_Message
     (Item      : in out Connection;
      Transport : in out QUIC.Connection;
      ID        : QUIC.Stream_ID)
   is
      Receive_Slot : constant Optional_Slot := Find (Item, ID);
   begin
      if ID mod 4 = 0
        and then ID / 4 <= QUIC.Stream_ID (Message_Ordinal'Last)
      then
         Item.Released_Messages (Message_Ordinal (ID / 4)) := True;
      end if;
      if Receive_Slot /= 0 then
         Item.Streams (Receive_Slot) := (others => <>);
         Item.Count := Item.Count - 1;
      end if;
      for Index in Slot_Index loop
         if Item.Sending (Index).Occupied
           and then Item.Sending (Index).ID = ID
         then
            Item.Sending (Index) := (others => <>);
            Item.Send_Count := Item.Send_Count - 1;
            exit;
         end if;
      end loop;
      if QUIC.Has_Stream (Transport, ID)
        and then
          (QUIC.Is_Complete (Transport, ID)
             or else QUIC.Was_Reset (Transport, ID))
      then
         QUIC.Release_Stream (Transport, ID);
      end if;
   end Abandon_Message;

   procedure Find_Or_Open
     (Item   : in out Connection;
      ID     : QUIC.Stream_ID;
      Index  : out Optional_Slot;
      Status : out Operation_Status)
   is
      Opened          : HTTP_3_Stream_Receive_Policy.Receive_Status;
      Request_Is_Head : Boolean := False;
   begin
      Index := Find (Item, ID);
      if Index /= 0 then
         Status := Succeeded;
         return;
      elsif Item.Count = Max_Streams then
         Status := Stream_Capacity_Exceeded;
         return;
      end if;

      for Candidate in Slot_Index loop
         if not Item.Streams (Candidate).Occupied then
            for Sending in Slot_Index loop
               if Item.Sending (Sending).Occupied
                 and then Item.Sending (Sending).ID = ID
               then
                  Request_Is_Head := Item.Sending (Sending).Request.Is_Head;
               end if;
            end loop;
            HTTP_3_Stream_Receive_Policy.Open
              (Item.Streams (Candidate).State, ID,
               Receive_Role (Item.Local_Role), Opened,
               Request_Is_Head => Request_Is_Head);
            if Opened /= HTTP_3_Stream_Receive_Policy.Consumed then
               Status := Stream_Creation_Error;
               return;
            end if;
            Item.Streams (Candidate).Occupied := True;
            Item.Streams (Candidate).ID := ID;
            Item.Streams (Candidate).Finished := False;
            Item.Count := Item.Count + 1;
            Index := Candidate;
            Status := Succeeded;
            return;
         end if;
      end loop;
      Status := Stream_Capacity_Exceeded;
   end Find_Or_Open;

   function Status_For
     (Value : HTTP_3_Stream_Receive_Policy.Receive_Status)
      return Operation_Status
   is
     (case Value is
         when HTTP_3_Stream_Receive_Policy.Consumed => Succeeded,
         when HTTP_3_Stream_Receive_Policy.Need_More_Data => No_Event,
         when HTTP_3_Stream_Receive_Policy.Stream_Creation_Error =>
           Stream_Creation_Error,
         when HTTP_3_Stream_Receive_Policy.Closed_Critical_Stream =>
           Closed_Critical_Stream,
         when HTTP_3_Stream_Receive_Policy.Missing_Settings =>
           Missing_Settings,
         when HTTP_3_Stream_Receive_Policy.Frame_Unexpected =>
           Frame_Unexpected,
         when HTTP_3_Stream_Receive_Policy.Settings_Error => Settings_Error,
         when HTTP_3_Stream_Receive_Policy.Frame_Error => Frame_Error,
         when HTTP_3_Stream_Receive_Policy.ID_Error => ID_Error,
         when HTTP_3_Stream_Receive_Policy.QPACK_Decompression_Failed =>
           QPACK_Decompression_Failed,
         when HTTP_3_Stream_Receive_Policy.QPACK_Encoder_Stream_Error =>
           QPACK_Encoder_Stream_Error,
         when HTTP_3_Stream_Receive_Policy.QPACK_Decoder_Stream_Error =>
           QPACK_Decoder_Stream_Error,
         when HTTP_3_Stream_Receive_Policy.Message_Error => Message_Error,
         when HTTP_3_Stream_Receive_Policy.Header_Error => Header_Error);

   function Event_For
     (Value : HTTP_3_Stream_Receive_Policy.Event_Kind) return Event_Kind
   is
     (case Value is
         when HTTP_3_Stream_Receive_Policy.No_Event => No_Event,
         when HTTP_3_Stream_Receive_Policy.Settings_Received =>
           Settings_Received,
         when HTTP_3_Stream_Receive_Policy.Goaway_Received =>
           Goaway_Received,
         when HTTP_3_Stream_Receive_Policy.Headers_Received =>
           Headers_Received,
         when HTTP_3_Stream_Receive_Policy.Data_Received => Data_Received);

   procedure Reset_Event (Output : out Event) is
   begin
      Output.Kind := No_Event;
      Output.Stream := 0;
      Output.Identifier := 0;
      Output.Headers.Count := 0;
      Output.Data_Length := 0;
      Output.Application_Error := 0;
   end Reset_Event;

   procedure Copy_Event
     (ID     : QUIC.Stream_ID;
      Buffer : Ada.Streams.Stream_Element_Array;
      Result : HTTP_3_Stream_Receive_Policy.Compact_Receive_Result;
      Output : out Event) is
   begin
      Output.Kind := Event_For (Result.Event);
      Output.Stream := ID;
      Output.Identifier := Result.Identifier;
      Output.Data_Length := Result.Payload_Length;
      if Result.Payload_Length > 0 then
         Output.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Result.Payload_Length)) :=
             Buffer
               (Buffer'First
                  + Ada.Streams.Stream_Element_Offset (Result.Payload_Offset)
                .. Buffer'First
                     + Ada.Streams.Stream_Element_Offset
                         (Result.Payload_Offset + Result.Payload_Length - 1));
      end if;
   end Copy_Event;

   procedure Poll
     (Item      : in out Connection;
      Transport : in out QUIC.Connection;
      Output    : out Event;
      Status    : out Operation_Status)
   is
      Buffer : Ada.Streams.Stream_Element_Array (1 .. Max_Event_Data);
      Result : HTTP_3_Stream_Receive_Policy.Compact_Receive_Result;
      Length : QUIC.Stream_Offset;
      ID     : QUIC.Stream_ID;
      Slot   : Optional_Slot;
      Finish : HTTP_3_Stream_Receive_Policy.Receive_Status;
      Reset_Handled : Boolean;

      procedure Handle_Reset
        (ID     : QUIC.Stream_ID;
         Slot   : Slot_Index;
         Output : out Event;
         Status : out Operation_Status)
      is
         Kind : constant HTTP_3_Stream_Receive_Policy.Stream_Kind :=
           HTTP_3_Stream_Receive_Policy.Kind (Item.Streams (Slot).State);
      begin
         Reset_Event (Output);
         Item.Streams (Slot).Finished := True;
         if Kind in
           HTTP_3_Stream_Receive_Policy.Control_Stream |
           HTTP_3_Stream_Receive_Policy.QPACK_Encoder_Stream |
           HTTP_3_Stream_Receive_Policy.QPACK_Decoder_Stream
         then
            Status := Closed_Critical_Stream;
         elsif Kind in
           HTTP_3_Stream_Receive_Policy.Request_Stream |
           HTTP_3_Stream_Receive_Policy.Response_Stream
         then
            Output.Kind := Stream_Reset;
            Output.Stream := ID;
            Output.Application_Error := QUIC.Reset_Error (Transport, ID);
            Status := Succeeded;
            Release_Message (Item, Transport, ID, Slot);
         else
            Status := No_Event;
         end if;
      end Handle_Reset;
   begin
      Reset_Event (Output);
      if not QUIC.Is_Connected (Transport) then
         Status := Not_Connected;
         return;
      end if;

      for Stream_Index in 1 .. QUIC.Stream_Count (Transport) loop
         Reset_Handled := False;
         ID := QUIC.Stream_At (Transport, Stream_Index);
         if Is_Released_Message (Item, Transport, ID) then
            Length := QUIC.Available_Length (Transport, ID);
            if Length > 0 then
               QUIC.Consume (Transport, ID, Length);
            end if;
            if QUIC.Is_Complete (Transport, ID)
              or else QUIC.Was_Reset (Transport, ID)
            then
               QUIC.Release_Stream (Transport, ID);
               --  Releasing compacts the QUIC stream table, so restart on a
               --  later bounded Poll rather than indexing the changed table.
               Status := No_Event;
               return;
            end if;
            --  A locally abandoned stream can remain open at the peer while
            --  sibling streams make progress.  Its tombstone drains any late
            --  bytes, but must not starve those siblings.
            goto Next_Stream;
         end if;
         Find_Or_Open (Item, ID, Slot, Status);
         if Status /= Succeeded then
            return;
         end if;

         if QUIC.Was_Reset (Transport, ID)
           and then not Item.Streams (Slot).Finished
           and then HTTP_3_Stream_Receive_Policy.Kind
             (Item.Streams (Slot).State) /=
               HTTP_3_Stream_Receive_Policy.Awaiting_Type
         then
            Handle_Reset (ID, Slot_Index (Slot), Output, Status);
            Reset_Handled := True;
            if Status /= No_Event or else Output.Kind /= No_Event then
               return;
            end if;
         end if;

         while not Reset_Handled loop
            if QUIC.Was_Reset (Transport, ID)
              and then not Item.Streams (Slot).Finished
              and then HTTP_3_Stream_Receive_Policy.Kind
                (Item.Streams (Slot).State) /=
                  HTTP_3_Stream_Receive_Policy.Awaiting_Type
            then
               Handle_Reset (ID, Slot_Index (Slot), Output, Status);
               Reset_Handled := True;
               exit;
            end if;
            Length := QUIC.Available_Length (Transport, ID);
            exit when Length = 0;
            if Length > QUIC.Stream_Offset (Max_Event_Data) then
               Status := Frame_Error;
               return;
            end if;
            for Offset in 0 .. Length - 1 loop
               Buffer
                 (1 + Ada.Streams.Stream_Element_Offset (Offset)) :=
                   QUIC.Element (Transport, ID, Offset);
            end loop;
            HTTP_3_Stream_Receive_Policy.Process_Compact
              (Item.Receive, Item.Streams (Slot).State,
               Buffer (1 .. Ada.Streams.Stream_Element_Offset (Length)),
               Output.Headers, Result);
            Status := Status_For (Result.Status);
            if Result.Consumed > 0 then
               if Result.Event /= HTTP_3_Stream_Receive_Policy.No_Event then
                  Copy_Event (ID, Buffer, Result, Output);
               end if;
               QUIC.Consume
                 (Transport, ID, QUIC.Stream_Offset (Result.Consumed));
            end if;
            if Item.Local_Role = Client
              and then Status in Message_Error | Header_Error
            then
               --  RFC 9114 assigns malformed HTTP message semantics to this
               --  response stream. Surface a stream-local failure so another
               --  multiplexed response remains usable; the client commits
               --  H3_MESSAGE_ERROR before releasing this state. Server-side
               --  request diagnostics retain their existing typed status.
               Item.Streams (Slot).Finished := True;
               Output.Kind := Stream_Reset;
               Output.Stream := ID;
               Output.Application_Error := 16#10E#;
               Status := Succeeded;
               return;
            end if;
            if Status = No_Event
              and then QUIC.Is_Complete (Transport, ID)
            then
               if HTTP_3_Stream_Receive_Policy.Kind
                 (Item.Streams (Slot).State) in
                   HTTP_3_Stream_Receive_Policy.Control_Stream |
                   HTTP_3_Stream_Receive_Policy.Request_Stream |
                   HTTP_3_Stream_Receive_Policy.Response_Stream
               then
                  --  A clean FIN proves that a partial frame can never be
                  --  completed, which RFC 9114 classifies as H3_FRAME_ERROR.
                  Status := Frame_Error;
                  return;
               end if;
               exit;
            elsif Status /= Succeeded then
               return;
            elsif Output.Kind /= No_Event then
               return;
            end if;
         end loop;

         if Output.Kind /= No_Event
           or else Status not in Succeeded | No_Event
         then
            return;
         elsif QUIC.Was_Reset (Transport, ID)
           and then not Item.Streams (Slot).Finished
         then
            --  A peer may reset an unidirectional stream before its type is
            --  complete. Such a stream has no known critical role.
            Item.Streams (Slot).Finished := True;
         end if;

         if QUIC.Is_Complete (Transport, ID)
           and then not Item.Streams (Slot).Finished
         then
            HTTP_3_Stream_Receive_Policy.Finish
              (Item.Receive, Item.Streams (Slot).State, Finish);
            Item.Streams (Slot).Finished := True;
            Status := Status_For (Finish);
            if Status /= Succeeded then
               return;
            elsif HTTP_3_Stream_Receive_Policy.Kind
              (Item.Streams (Slot).State) not in
                HTTP_3_Stream_Receive_Policy.Request_Stream |
                HTTP_3_Stream_Receive_Policy.Response_Stream
            then
               --  Completion of non-message streams is transport bookkeeping,
               --  not an HTTP request or response event.
               null;
            else
               Output.Kind := Stream_Ended;
               Output.Stream := ID;
               if Item.Local_Role = Client then
                  Release_Message
                    (Item, Transport, ID, Slot_Index (Slot));
               end if;
               return;
            end if;
         end if;
         <<Next_Stream>>
      end loop;
      Status := No_Event;
   end Poll;

   procedure Release_Request
     (Item      : in out Connection;
      Transport : in out QUIC.Connection;
      Stream    : QUIC.Stream_ID;
      Status    : out Operation_Status)
   is
      Slot : constant Optional_Slot := Find (Item, Stream);
   begin
      if Item.Local_Role /= Server then
         Status := Wrong_Role;
      elsif Slot = 0
        or else not Item.Streams (Slot).Finished
        or else not HTTP_3_Stream_Policy.Is_Request_Stream (Stream)
      then
         Status := Stream_Creation_Error;
      else
         Release_Message
           (Item, Transport, Stream, Slot_Index (Slot));
         Status := Succeeded;
      end if;
   end Release_Request;

   function Has_Peer_Settings (Item : Connection) return Boolean is
     (HTTP_3_Stream_Receive_Policy.Has_Peer_Settings (Item.Receive));

   function Peer_Settings
     (Item : Connection) return HTTP_3_Settings_Policy.Settings is
     (HTTP_3_Stream_Receive_Policy.Peer_Settings (Item.Receive));

   function Has_Peer_Goaway (Item : Connection) return Boolean is
     (HTTP_3_Stream_Receive_Policy.Has_Peer_Goaway (Item.Receive));

   function Peer_Goaway_ID
     (Item : Connection) return QUIC.Stream_Offset is
     (HTTP_3_Stream_Receive_Policy.Peer_Goaway_ID (Item.Receive));

   function Find_Send
     (Item : Connection; ID : QUIC.Stream_ID) return Optional_Slot is
   begin
      for Index in Slot_Index loop
         if Item.Sending (Index).Occupied
           and then Item.Sending (Index).ID = ID
         then
            return Index;
         end if;
      end loop;
      return 0;
   end Find_Send;

   procedure Add_Send
     (Item   : in out Connection;
      ID     : QUIC.Stream_ID;
      Kind   : Send_Stream_Kind;
      Index  : out Optional_Slot;
      Status : out Operation_Status;
      Request_Is_Head : Boolean := False)
   is
   begin
      Index := Find_Send (Item, ID);
      if Index /= 0 then
         Status := Succeeded;
         return;
      elsif Item.Send_Count = Max_Streams then
         Status := Stream_Capacity_Exceeded;
         return;
      end if;
      for Candidate in Slot_Index loop
         if not Item.Sending (Candidate).Occupied then
            Item.Sending (Candidate) :=
              (Occupied => True, ID => ID, Kind => Kind,
               Response =>
                 (Request_Is_Head => Request_Is_Head, others => <>),
               others => <>);
            Item.Send_Count := Item.Send_Count + 1;
            Index := Candidate;
            Status := Succeeded;
            return;
         end if;
      end loop;
      Status := Stream_Capacity_Exceeded;
   end Add_Send;

   procedure Find_Or_Add_Message
     (Item      : in out Connection;
      Transport : QUIC.Connection;
      Stream    : QUIC.Stream_ID;
      Index     : out Optional_Slot;
      Status    : out Operation_Status);

   procedure Open_Request
     (Item      : in out Connection;
      Transport : in out QUIC.Connection;
      Stream    : out QUIC.Stream_ID;
      Status    : out Operation_Status)
   is
      Opened : QUIC.Open_Status;
      Slot   : Optional_Slot;
   begin
      Stream := 0;
      if not QUIC.Is_Connected (Transport) then
         Status := Not_Connected;
      elsif Item.Local_Role /= Client then
         Status := Wrong_Role;
      elsif Has_Peer_Goaway (Item) then
         Status := Connection_Draining;
      else
         QUIC.Open_Stream (Transport, QUIC.Bidirectional, Stream, Opened);
         if Opened = QUIC.Opened then
            Add_Send (Item, Stream, Request_Message, Slot, Status);
         elsif Opened = QUIC.Stream_Limit_Reached then
            Status := Stream_Limit_Reached;
         else
            Status := Transport_Error;
         end if;
      end if;
   end Open_Request;

   procedure Build_Request_Cancellation
     (Item              : in out Connection;
      Transport         : in out QUIC.Connection;
      Stream            : QUIC.Stream_ID;
      Application_Error : QUIC.Stream_Offset;
      Now               : QUIC.Timestamp;
      Packet            : out QUIC.Datagram;
      Status            : out Operation_Status)
   is
      Slot : Optional_Slot;
      Sent : QUIC.Send_Status;
   begin
      Packet := (others => <>);
      if not QUIC.Is_Connected (Transport) then
         Status := Not_Connected;
         return;
      elsif not HTTP_3_Stream_Policy.Is_Request_Stream (Stream) then
         Status := ID_Error;
         return;
      elsif Application_Error not in 16#10B# | 16#10C# | 16#10E# then
         Status := Transport_Error;
         return;
      elsif Item.Local_Role = Client
        and then Application_Error = 16#10B#
      then
         Status := Wrong_Role;
         return;
      end if;

      Find_Or_Add_Message (Item, Transport, Stream, Slot, Status);
      if Status /= Succeeded then
         return;
      elsif Item.Sending (Slot).Cancelled then
         Status := Frame_Unexpected;
         return;
      end if;

      QUIC.Build_Stream_Abort_Datagram
        (Transport, Stream, Application_Error,
         Item.Sending (Slot).Offset, Now, Packet, Sent);
      Status := Send_Status_For (Sent);
      if Status = Succeeded then
         Item.Sending (Slot).Finished := True;
         Item.Sending (Slot).Cancelled := True;
         if Item.Local_Role = Client then
            --  A composable client owns the complete exchange lifecycle and
            --  has no later Release_Request call. Retire its local message
            --  state once RESET_STREAM/STOP_SENDING has been built. The
            --  server keeps request state until its normal Release_Request
            --  step.
            Abandon_Message (Item, Transport, Stream);
         end if;
      end if;
   end Build_Request_Cancellation;

   procedure Build_Goaway
     (Item       : in out Connection;
      Transport  : in out QUIC.Connection;
      Identifier : QUIC.Stream_Offset;
      Now        : QUIC.Timestamp;
      Packet     : out QUIC.Datagram;
      Status     : out Operation_Status)
   is
      Encoded : constant HTTP_3_Frame_Policy.Varint_Policy.Encoded_Value :=
        HTTP_3_Frame_Policy.Varint_Policy.Encode (Identifier);
      Frame   : HTTP_3_Frame_Policy.Encode_Result;
      Sent    : QUIC.Send_Status;
   begin
      Packet := (others => <>);
      if not QUIC.Is_Connected (Transport) then
         Status := Not_Connected;
         return;
      elsif not Item.Started then
         Status := Not_Started;
         return;
      elsif Item.Local_Role = Server
        and then not HTTP_3_Stream_Policy.Is_Request_Stream (Identifier)
      then
         Status := ID_Error;
         return;
      elsif Item.Local_Goaway_Seen
        and then Identifier > Item.Local_Goaway
      then
         Status := ID_Error;
         return;
      end if;

      Frame := HTTP_3_Frame_Policy.Encode
        (HTTP_3_Frame_Policy.Goaway_Frame,
         Encoded.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Encoded.Length)));
      QUIC.Build_Stream_Datagram
        (Transport, Item.Local_Control_ID, Item.Local_Control_Offset,
         Fin => False,
         Data => Frame.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Frame.Length)),
         Now => Now, Packet => Packet, Status => Sent);
      Status := Send_Status_For (Sent);
      if Status = Succeeded then
         Item.Local_Control_Offset :=
           Item.Local_Control_Offset + QUIC.Stream_Offset (Frame.Length);
         Item.Local_Goaway_Seen := True;
         Item.Local_Goaway := Identifier;
      end if;
   end Build_Goaway;

   procedure Find_Or_Add_Message
     (Item      : in out Connection;
      Transport : QUIC.Connection;
      Stream    : QUIC.Stream_ID;
      Index     : out Optional_Slot;
      Status    : out Operation_Status) is
      Receive_Slot : Optional_Slot;
   begin
      Index := Find_Send (Item, Stream);
      if Index /= 0 then
         Status := Succeeded;
      elsif Item.Local_Role = Server
        and then QUIC.Has_Stream (Transport, Stream)
        and then HTTP_3_Stream_Policy.Is_Request_Stream (Stream)
      then
         Receive_Slot := Find (Item, Stream);
         Add_Send
           (Item, Stream, Response_Message, Index, Status,
            Request_Is_Head =>
              (Receive_Slot /= 0
               and then HTTP_3_Stream_Receive_Policy.Request_Is_Head
                 (Item.Streams (Receive_Slot).State)));
      else
         Status := Stream_Creation_Error;
      end if;
   end Find_Or_Add_Message;

   procedure Build_Headers
     (Item      : in out Connection;
      Transport : in out QUIC.Connection;
      Stream    : QUIC.Stream_ID;
      Headers   : QPACK_Field_Section_Policy.Header_Block;
      Fin       : Boolean;
      Now       : QUIC.Timestamp;
      Packet    : out QUIC.Datagram;
      Status    : out Operation_Status)
   is
      Slot       : Optional_Slot;
      Validation : HTTP_3_Header_Policy.Validation_Result;
      Header     : HTTP_3_Message_Policy.Header_Kind;
      Request    : HTTP_3_Message_Policy.Request_Update;
      Response   : HTTP_3_Message_Policy.Response_Update;
      Encoded    : QPACK_Field_Section_Policy.Encode_Result;
      Frame      : HTTP_3_Frame_Policy.Encode_Result;
      Sent       : QUIC.Send_Status;
      Peer       : HTTP_3_Settings_Policy.Settings;
   begin
      Packet := (others => <>);
      if not QUIC.Is_Connected (Transport) then
         Status := Not_Connected;
         return;
      end if;
      Find_Or_Add_Message (Item, Transport, Stream, Slot, Status);
      if Status /= Succeeded or else Item.Sending (Slot).Finished then
         if Status = Succeeded then
            Status := Frame_Unexpected;
         end if;
         return;
      end if;

      if Has_Peer_Settings (Item) then
         Peer := Peer_Settings (Item);
         if Peer.Has_Max_Field_Size
           and then HTTP_3_Settings_Policy.Varint_Policy.Value_Type
             (QPACK_Field_Section_Policy.Field_Section_Size (Headers)) >
               Peer.Max_Field_Size
         then
            Status := Peer_Field_Section_Too_Large;
            return;
         end if;
      end if;

      if Item.Sending (Slot).Kind = Request_Message then
         if Item.Sending (Slot).Request.Phase =
           HTTP_3_Message_Policy.Expecting_Request
         then
            Validation := HTTP_3_Header_Policy.Validate_Request (Headers);
            Header := HTTP_3_Message_Policy.Request_Headers;
         else
            Validation := HTTP_3_Header_Policy.Validate_Trailers (Headers);
            Header := HTTP_3_Message_Policy.Trailer_Headers;
         end if;
         Request := HTTP_3_Message_Policy.On_Request_Frame
           (Item.Sending (Slot).Request,
            HTTP_3_Frame_Policy.Headers_Frame, Header,
            Validation.Has_Content_Length,
            Validation.Content_Length,
            Is_Head => Validation.Is_Head);
         if Validation.Status /= HTTP_3_Header_Policy.Valid then
            Status := Header_Error;
            return;
         elsif Request.Status /= HTTP_3_Message_Policy.Accepted
           or else
             (Fin and then HTTP_3_Message_Policy.Finish_Request
                (Request.State) /= HTTP_3_Message_Policy.Message_Complete)
         then
            Status := Message_Error;
            return;
         end if;
      else
         if Item.Sending (Slot).Response.Phase in
           HTTP_3_Message_Policy.Expecting_Response |
           HTTP_3_Message_Policy.Awaiting_Final
         then
            Validation := HTTP_3_Header_Policy.Validate_Response (Headers);
            Header :=
              (if Validation.Is_Interim
               then HTTP_3_Message_Policy.Interim_Response_Headers
               else HTTP_3_Message_Policy.Final_Response_Headers);
         else
            Validation := HTTP_3_Header_Policy.Validate_Trailers (Headers);
            Header := HTTP_3_Message_Policy.Trailer_Headers;
         end if;
         Response := HTTP_3_Message_Policy.On_Response_Frame
           (Item.Sending (Slot).Response,
            HTTP_3_Frame_Policy.Headers_Frame, Header,
            Response_Code => Validation.Response_Code,
            Has_Content_Length => Validation.Has_Content_Length,
            Content_Length => Validation.Content_Length);
         if Validation.Status /= HTTP_3_Header_Policy.Valid then
            Status := Header_Error;
            return;
         elsif Response.Status /= HTTP_3_Message_Policy.Accepted
           or else
             (Fin and then HTTP_3_Message_Policy.Finish_Response
                (Response.State) /= HTTP_3_Message_Policy.Message_Complete)
         then
            Status := Message_Error;
            return;
         end if;
      end if;

      Encoded := QPACK_Field_Section_Policy.Encode (Headers);
      if Encoded.Status /= QPACK_Field_Section_Policy.Encoded then
         Status := QPACK_Decompression_Failed;
         return;
      end if;
      Frame := HTTP_3_Frame_Policy.Encode
        (HTTP_3_Frame_Policy.Headers_Frame,
         Encoded.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Encoded.Length)));
      if Frame.Length > QUIC.Max_Stream_Payload then
         Status := Frame_Too_Large;
         return;
      end if;
      QUIC.Build_Stream_Datagram
        (Transport, Stream, Item.Sending (Slot).Offset, Fin,
         Frame.Data (1 .. Ada.Streams.Stream_Element_Offset (Frame.Length)),
         Now, Packet, Sent);
      Status := Send_Status_For (Sent);
      if Status = Succeeded then
         Item.Sending (Slot).Offset :=
           Item.Sending (Slot).Offset + QUIC.Stream_Offset (Frame.Length);
         Item.Sending (Slot).Finished := Fin;
         if Item.Sending (Slot).Kind = Request_Message then
            Item.Sending (Slot).Request := Request.State;
         else
            Item.Sending (Slot).Response := Response.State;
         end if;
         if Fin and then Item.Local_Role = Server then
            Item.Sending (Slot) := (others => <>);
            Item.Send_Count := Item.Send_Count - 1;
         end if;
      end if;
   end Build_Headers;

   procedure Prepare_Response
     (Item      : in out Connection;
      Transport : QUIC.Connection;
      Stream    : QUIC.Stream_ID;
      Headers   : QPACK_Field_Section_Policy.Header_Block;
      Data      : Ada.Streams.Stream_Element_Array;
      Output    : out Prepared_Response;
      Status    : out Operation_Status)
   is
      Slot        : Optional_Slot;
      Validation  : HTTP_3_Header_Policy.Validation_Result;
      Head_Update : HTTP_3_Message_Policy.Response_Update;
      Data_Update : HTTP_3_Message_Policy.Response_Update;
      Encoded     : QPACK_Field_Section_Policy.Encode_Result;
      Head_Frame  : HTTP_3_Frame_Policy.Encode_Result;
      Data_Frame  : HTTP_3_Frame_Policy.Encode_Result;
      Length      : Natural;
      Peer        : HTTP_3_Settings_Policy.Settings;
   begin
      Output := (others => <>);
      if not QUIC.Is_Connected (Transport) then
         Status := Not_Connected;
         return;
      elsif Item.Local_Role /= Server then
         Status := Wrong_Role;
         return;
      elsif Data'Length > HTTP_3_Frame_Policy.Max_Payload_Length then
         Status := Frame_Too_Large;
         return;
      end if;

      if Has_Peer_Settings (Item) then
         Peer := Peer_Settings (Item);
         if Peer.Has_Max_Field_Size
           and then HTTP_3_Settings_Policy.Varint_Policy.Value_Type
             (QPACK_Field_Section_Policy.Field_Section_Size (Headers)) >
               Peer.Max_Field_Size
         then
            Status := Peer_Field_Section_Too_Large;
            return;
         end if;
      end if;

      Validation := HTTP_3_Header_Policy.Validate_Response (Headers);
      if Validation.Status /= HTTP_3_Header_Policy.Valid then
         Status := Header_Error;
         return;
      elsif Validation.Is_Interim then
         Status := Message_Error;
         return;
      end if;
      Encoded := QPACK_Field_Section_Policy.Encode (Headers);
      if Encoded.Status /= QPACK_Field_Section_Policy.Encoded then
         Status := QPACK_Decompression_Failed;
         return;
      end if;
      Head_Frame := HTTP_3_Frame_Policy.Encode
        (HTTP_3_Frame_Policy.Headers_Frame,
         Encoded.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Encoded.Length)));
      Data_Frame := HTTP_3_Frame_Policy.Encode
        (HTTP_3_Frame_Policy.Data_Frame, Data);
      Length := Head_Frame.Length + Data_Frame.Length;
      if Length > QUIC.Max_Stream_Payload then
         Status := Frame_Too_Large;
         return;
      end if;

      Find_Or_Add_Message (Item, Transport, Stream, Slot, Status);
      if Status /= Succeeded or else Item.Sending (Slot).Finished then
         if Status = Succeeded then
            Status := Frame_Unexpected;
         end if;
         return;
      elsif Item.Sending (Slot).Kind /= Response_Message then
         Status := Frame_Unexpected;
         return;
      end if;
      Head_Update := HTTP_3_Message_Policy.On_Response_Frame
        (Item.Sending (Slot).Response,
         HTTP_3_Frame_Policy.Headers_Frame,
         HTTP_3_Message_Policy.Final_Response_Headers,
         Response_Code => Validation.Response_Code,
         Has_Content_Length => Validation.Has_Content_Length,
         Content_Length => Validation.Content_Length);
      if Head_Update.Status /= HTTP_3_Message_Policy.Accepted then
         Status := Message_Error;
         return;
      end if;
      Data_Update := HTTP_3_Message_Policy.On_Response_Frame
        (Head_Update.State, HTTP_3_Frame_Policy.Data_Frame,
         Data_Length => QUIC.Stream_Offset (Data'Length));
      if Data_Update.Status /= HTTP_3_Message_Policy.Accepted
        or else HTTP_3_Message_Policy.Finish_Response (Data_Update.State) /=
          HTTP_3_Message_Policy.Message_Complete
      then
         Status := Message_Error;
         return;
      end if;

      Output.Stream := Stream;
      Output.Length := Length;
      Output.Data
        (1 .. Ada.Streams.Stream_Element_Offset (Head_Frame.Length)) :=
          Head_Frame.Data
            (1 .. Ada.Streams.Stream_Element_Offset (Head_Frame.Length));
      Output.Data
        (Ada.Streams.Stream_Element_Offset (Head_Frame.Length + 1)
           .. Ada.Streams.Stream_Element_Offset (Length)) :=
          Data_Frame.Data
            (1 .. Ada.Streams.Stream_Element_Offset (Data_Frame.Length));
      Output.Response_Code := Validation.Response_Code;
      Output.Has_Content_Length := Validation.Has_Content_Length;
      Output.Content_Length := Validation.Content_Length;
      Output.Body_Length := QUIC.Stream_Offset (Data'Length);
      Output.Ready := True;
      Status := Succeeded;
   end Prepare_Response;

   procedure Build_Response
     (Item      : in out Connection;
      Transport : in out QUIC.Connection;
      Stream    : QUIC.Stream_ID;
      Headers   : QPACK_Field_Section_Policy.Header_Block;
      Data      : Ada.Streams.Stream_Element_Array;
      Now       : QUIC.Timestamp;
      Packet    : out QUIC.Datagram;
      Status    : out Operation_Status;
      ACK_Included : out Boolean)
   is
      Slot        : Optional_Slot;
      Validation  : HTTP_3_Header_Policy.Validation_Result;
      Head_Update : HTTP_3_Message_Policy.Response_Update;
      Data_Update : HTTP_3_Message_Policy.Response_Update;
      Encoded     : QPACK_Field_Section_Policy.Encode_Result;
      Head_Frame  : HTTP_3_Frame_Policy.Encode_Result;
      Data_Frame  : HTTP_3_Frame_Policy.Encode_Result;
      Combined    : Ada.Streams.Stream_Element_Array
        (1 .. QUIC.Max_Stream_Payload) := (others => 0);
      Length      : Natural;
      Sent        : QUIC.Send_Status;
      Peer        : HTTP_3_Settings_Policy.Settings;
   begin
      Packet := (others => <>);
      ACK_Included := False;
      if not QUIC.Is_Connected (Transport) then
         Status := Not_Connected;
         return;
      elsif Item.Local_Role /= Server then
         Status := Wrong_Role;
         return;
      elsif Data'Length > HTTP_3_Frame_Policy.Max_Payload_Length then
         Status := Frame_Too_Large;
         return;
      end if;

      if Has_Peer_Settings (Item) then
         Peer := Peer_Settings (Item);
         if Peer.Has_Max_Field_Size
           and then HTTP_3_Settings_Policy.Varint_Policy.Value_Type
             (QPACK_Field_Section_Policy.Field_Section_Size (Headers)) >
               Peer.Max_Field_Size
         then
            Status := Peer_Field_Section_Too_Large;
            return;
         end if;
      end if;

      Validation := HTTP_3_Header_Policy.Validate_Response (Headers);
      if Validation.Status /= HTTP_3_Header_Policy.Valid then
         Status := Header_Error;
         return;
      elsif Validation.Is_Interim then
         Status := Message_Error;
         return;
      end if;

      Encoded := QPACK_Field_Section_Policy.Encode (Headers);
      if Encoded.Status /= QPACK_Field_Section_Policy.Encoded then
         Status := QPACK_Decompression_Failed;
         return;
      end if;
      Head_Frame := HTTP_3_Frame_Policy.Encode
        (HTTP_3_Frame_Policy.Headers_Frame,
         Encoded.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Encoded.Length)));
      Data_Frame := HTTP_3_Frame_Policy.Encode
        (HTTP_3_Frame_Policy.Data_Frame, Data);
      Length := Head_Frame.Length + Data_Frame.Length;
      if Length > QUIC.Max_Stream_Payload then
         Status := Frame_Too_Large;
         return;
      end if;

      Find_Or_Add_Message (Item, Transport, Stream, Slot, Status);
      if Status /= Succeeded or else Item.Sending (Slot).Finished then
         if Status = Succeeded then
            Status := Frame_Unexpected;
         end if;
         return;
      elsif Item.Sending (Slot).Kind /= Response_Message then
         Status := Frame_Unexpected;
         return;
      end if;

      Head_Update := HTTP_3_Message_Policy.On_Response_Frame
        (Item.Sending (Slot).Response,
         HTTP_3_Frame_Policy.Headers_Frame,
         HTTP_3_Message_Policy.Final_Response_Headers,
         Response_Code => Validation.Response_Code,
         Has_Content_Length => Validation.Has_Content_Length,
         Content_Length => Validation.Content_Length);
      if Head_Update.Status /= HTTP_3_Message_Policy.Accepted then
         Status := Message_Error;
         return;
      end if;
      Data_Update := HTTP_3_Message_Policy.On_Response_Frame
        (Head_Update.State, HTTP_3_Frame_Policy.Data_Frame,
         Data_Length => QUIC.Stream_Offset (Data'Length));
      if Data_Update.Status /= HTTP_3_Message_Policy.Accepted
        or else HTTP_3_Message_Policy.Finish_Response (Data_Update.State) /=
          HTTP_3_Message_Policy.Message_Complete
      then
         Status := Message_Error;
         return;
      end if;

      Combined
        (1 .. Ada.Streams.Stream_Element_Offset (Head_Frame.Length)) :=
          Head_Frame.Data
            (1 .. Ada.Streams.Stream_Element_Offset (Head_Frame.Length));
      Combined
        (Ada.Streams.Stream_Element_Offset (Head_Frame.Length + 1)
           .. Ada.Streams.Stream_Element_Offset (Length)) :=
          Data_Frame.Data
            (1 .. Ada.Streams.Stream_Element_Offset (Data_Frame.Length));
      QUIC.Build_Stream_Datagram_With_ACK
        (Transport, Stream, Item.Sending (Slot).Offset, Fin => True,
         Data => Combined (1 .. Ada.Streams.Stream_Element_Offset (Length)),
         Now => Now, Packet => Packet, Status => Sent,
         ACK_Included => ACK_Included);
      Status := Send_Status_For (Sent);
      if Status = Succeeded then
         Item.Sending (Slot) := (others => <>);
         Item.Send_Count := Item.Send_Count - 1;
      end if;
   end Build_Response;

   procedure Build_Prepared_Responses
     (Item         : in out Connection;
      Transport    : in out QUIC.Connection;
      Responses    : Prepared_Response_Array;
      Now          : QUIC.Timestamp;
      Packet       : out QUIC.Datagram;
      Status       : out Operation_Status;
      ACK_Included : out Boolean)
   is
      Fragments : QUIC.Stream_Fragment_Array (Responses'Range);
      Combined  : Ada.Streams.Stream_Element_Array
        (1 .. QUIC.Max_Stream_Payload) := (others => 0);
      Length    : Natural := 0;
      Slot      : Optional_Slot;
      Head_Update : HTTP_3_Message_Policy.Response_Update;
      Data_Update : HTTP_3_Message_Policy.Response_Update;
      Sent      : QUIC.Send_Status;

      procedure Validate (Response : Prepared_Response) is
      begin
         if not Response.Ready then
            Status := Frame_Unexpected;
            return;
         end if;
         Slot := Find_Send (Item, Response.Stream);
         if Slot = 0
           or else Item.Sending (Slot).Finished
           or else Item.Sending (Slot).Kind /= Response_Message
         then
            Status := Frame_Unexpected;
            return;
         end if;
         Head_Update := HTTP_3_Message_Policy.On_Response_Frame
           (Item.Sending (Slot).Response,
            HTTP_3_Frame_Policy.Headers_Frame,
            HTTP_3_Message_Policy.Final_Response_Headers,
            Response_Code => Response.Response_Code,
            Has_Content_Length => Response.Has_Content_Length,
            Content_Length => Response.Content_Length);
         Data_Update := HTTP_3_Message_Policy.On_Response_Frame
           (Head_Update.State, HTTP_3_Frame_Policy.Data_Frame,
            Data_Length => Response.Body_Length);
         if Head_Update.Status /= HTTP_3_Message_Policy.Accepted
           or else Data_Update.Status /= HTTP_3_Message_Policy.Accepted
           or else HTTP_3_Message_Policy.Finish_Response (Data_Update.State) /=
             HTTP_3_Message_Policy.Message_Complete
         then
            Status := Message_Error;
         end if;
      end Validate;
   begin
      Packet := (others => <>);
      ACK_Included := False;
      if not QUIC.Is_Connected (Transport) then
         Status := Not_Connected;
         return;
      elsif Item.Local_Role /= Server then
         Status := Wrong_Role;
         return;
      elsif Responses'Length not in 1 .. Max_Prepared_Responses then
         Status := Frame_Too_Large;
         return;
      end if;

      Status := Succeeded;
      for Index in Responses'Range loop
         Validate (Responses (Index));
         exit when Status /= Succeeded;
         for Prior in Responses'First .. Index - 1 loop
            if Responses (Prior).Stream = Responses (Index).Stream then
               Status := Frame_Unexpected;
            end if;
         end loop;
         exit when Status /= Succeeded;
         if Responses (Index).Length > QUIC.Max_Stream_Payload - Length then
            Status := Frame_Too_Large;
            return;
         end if;
         Slot := Find_Send (Item, Responses (Index).Stream);
         Fragments (Index) :=
           (ID     => Responses (Index).Stream,
            Offset => Item.Sending (Slot).Offset,
            Length => Responses (Index).Length,
            Fin    => True);
         Combined
           (Ada.Streams.Stream_Element_Offset (Length + 1)
              .. Ada.Streams.Stream_Element_Offset
                   (Length + Responses (Index).Length)) :=
             Responses (Index).Data
               (1 .. Ada.Streams.Stream_Element_Offset
                    (Responses (Index).Length));
         Length := Length + Responses (Index).Length;
      end loop;
      if Status /= Succeeded then
         return;
      end if;

      if Responses'Length = 1 then
         QUIC.Build_Stream_Datagram_With_ACK
           (Transport, Fragments (Responses'First).ID,
            Fragments (Responses'First).Offset, Fin => True,
            Data => Combined (1 .. Ada.Streams.Stream_Element_Offset (Length)),
            Now => Now, Packet => Packet, Status => Sent,
            ACK_Included => ACK_Included);
      else
         QUIC.Build_Stream_Batch_Datagram_With_ACK
           (Transport, Fragments,
            Combined (1 .. Ada.Streams.Stream_Element_Offset (Length)),
            Now, Packet, Sent, ACK_Included);
      end if;
      if Sent = QUIC.Packet_Too_Large then
         Status := Frame_Too_Large;
         return;
      end if;
      Status := Send_Status_For (Sent);
      if Status /= Succeeded then
         return;
      end if;

      for Response of Responses loop
         Slot := Find_Send (Item, Response.Stream);
         Item.Sending (Slot) := (others => <>);
         Item.Send_Count := Item.Send_Count - 1;
      end loop;
   end Build_Prepared_Responses;

   procedure Build_Data
     (Item      : in out Connection;
      Transport : in out QUIC.Connection;
      Stream    : QUIC.Stream_ID;
      Data      : Ada.Streams.Stream_Element_Array;
      Fin       : Boolean;
      Now       : QUIC.Timestamp;
      Packet    : out QUIC.Datagram;
      Status    : out Operation_Status)
   is
      Slot     : Optional_Slot;
      Request  : HTTP_3_Message_Policy.Request_Update;
      Response : HTTP_3_Message_Policy.Response_Update;
      Frame    : HTTP_3_Frame_Policy.Encode_Result;
      Sent     : QUIC.Send_Status;
   begin
      Packet := (others => <>);
      if not QUIC.Is_Connected (Transport) then
         Status := Not_Connected;
         return;
      elsif Data'Length > HTTP_3_Frame_Policy.Max_Payload_Length then
         Status := Frame_Too_Large;
         return;
      end if;
      Find_Or_Add_Message (Item, Transport, Stream, Slot, Status);
      if Status /= Succeeded or else Item.Sending (Slot).Finished then
         if Status = Succeeded then
            Status := Frame_Unexpected;
         end if;
         return;
      end if;

      if Item.Sending (Slot).Kind = Request_Message then
         Request := HTTP_3_Message_Policy.On_Request_Frame
           (Item.Sending (Slot).Request, HTTP_3_Frame_Policy.Data_Frame,
            Data_Length => QUIC.Stream_Offset (Data'Length));
         if Request.Status /= HTTP_3_Message_Policy.Accepted
           or else
             (Fin and then HTTP_3_Message_Policy.Finish_Request
                (Request.State) /= HTTP_3_Message_Policy.Message_Complete)
         then
            Status := Message_Error;
            return;
         end if;
      else
         Response := HTTP_3_Message_Policy.On_Response_Frame
           (Item.Sending (Slot).Response, HTTP_3_Frame_Policy.Data_Frame,
            Data_Length => QUIC.Stream_Offset (Data'Length));
         if Response.Status /= HTTP_3_Message_Policy.Accepted
           or else
             (Fin and then HTTP_3_Message_Policy.Finish_Response
                (Response.State) /= HTTP_3_Message_Policy.Message_Complete)
         then
            Status := Message_Error;
            return;
         end if;
      end if;

      Frame := HTTP_3_Frame_Policy.Encode
        (HTTP_3_Frame_Policy.Data_Frame, Data);
      if Frame.Length > QUIC.Max_Stream_Payload then
         Status := Frame_Too_Large;
         return;
      end if;
      QUIC.Build_Stream_Datagram
        (Transport, Stream, Item.Sending (Slot).Offset, Fin,
         Frame.Data (1 .. Ada.Streams.Stream_Element_Offset (Frame.Length)),
         Now, Packet, Sent);
      Status := Send_Status_For (Sent);
      if Status = Succeeded then
         Item.Sending (Slot).Offset :=
           Item.Sending (Slot).Offset + QUIC.Stream_Offset (Frame.Length);
         Item.Sending (Slot).Finished := Fin;
         if Item.Sending (Slot).Kind = Request_Message then
            Item.Sending (Slot).Request := Request.State;
         else
            Item.Sending (Slot).Response := Response.State;
         end if;
         if Fin and then Item.Local_Role = Server then
            Item.Sending (Slot) := (others => <>);
            Item.Send_Count := Item.Send_Count - 1;
         end if;
      end if;
   end Build_Data;
end Flyology.HTTP.HTTP_3_Connection;
