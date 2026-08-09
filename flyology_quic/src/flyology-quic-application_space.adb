with Flyology.QUIC.ACK_Frame_Policy;
with Flyology.QUIC.ACK_Range_Policy;
with Flyology.QUIC.Application_Frame_Policy;
with Flyology.QUIC.Debug;
with Flyology.QUIC.Initial_Frame_Policy;
with Flyology.QUIC.Stream_Frame_Policy;
with Interfaces;

package body Flyology.QUIC.Application_Space is
   package Debug renames Flyology.QUIC.Debug;
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.Unsigned_64;
   use type ACK_Frame_Policy.Encode_Status;
   use type ACK_Range_Policy.Decode_Status;
   use type Application_Connection.Build_Status;
   use type Application_Connection.Process_Status;
   use type Application_Frame_Policy.Frame_Kind;
   use type Application_Frame_Policy.Parse_Status;
   use type Flow_Control_Policy.Reserve_Status;
   use type Flow_Control_Policy.Update_Status;
   use type Recovery_Policy.Send_Status;
   use type Receive_Flow_Control_Policy.Reserve_Status;
   use type Sent_Packet_Policy.Apply_Status;
   use type Sent_Packet_Policy.Event_Kind;
   use type Sent_Packet_Policy.Packet_Number;
   use type Sent_Packet_Policy.Record_Status;
   use type Stream_Frame_Policy.Encode_Status;
   use type Stream_ID_Policy.Endpoint_Role;
   use type Stream_ID_Policy.Stream_Count;
   use type Stream_ID_Policy.Stream_Direction;
   use type Stream_ID_Policy.Open_Status;
   use type Stream_Table_Policy.Process_Status;

   function Is_Initialized (Item : State) return Boolean is
     (Item.Initialized);

   function Has_Stream
     (Item      : State;
      Stream_ID : Varint_Policy.Value_Type) return Boolean
   is
     (Stream_Table_Policy.Has_Stream (Item.Streams, Stream_ID));

   function Is_Stream_Retired
     (Item      : State;
      Stream_ID : Varint_Policy.Value_Type) return Boolean
   is
     (Receive_Flow_Control_Policy.Is_Stream_Retired
        (Item.Receive_Flow, Stream_ID));

   function Stream_Count
     (Item : State) return Stream_Table_Policy.Stream_Count_Type
   is
     (Stream_Table_Policy.Stream_Count (Item.Streams));

   function Stream_At
     (Item  : State;
      Index : Positive) return Varint_Policy.Value_Type
   is
     (Stream_Table_Policy.Stream_At (Item.Streams, Index));

   function Available_Length
     (Item      : State;
      Stream_ID : Varint_Policy.Value_Type) return Stream_Offset
   is
     (Stream_Table_Policy.Available_Length (Item.Streams, Stream_ID));

   function Is_Complete
     (Item      : State;
      Stream_ID : Varint_Policy.Value_Type) return Boolean
   is
     (Stream_Table_Policy.Is_Complete (Item.Streams, Stream_ID));

   function Was_Reset
     (Item      : State;
      Stream_ID : Varint_Policy.Value_Type) return Boolean
   is
     (Stream_Table_Policy.Was_Reset (Item.Streams, Stream_ID));

   function Reset_Error
     (Item      : State;
      Stream_ID : Varint_Policy.Value_Type) return Varint_Policy.Value_Type
   is
     (Stream_Table_Policy.Reset_Error (Item.Streams, Stream_ID));

   function Stream_Element
     (Item      : State;
      Stream_ID : Varint_Policy.Value_Type;
      Offset    : Stream_Index) return Ada.Streams.Stream_Element
   is
     (Stream_Table_Policy.Element (Item.Streams, Stream_ID, Offset));

   procedure Consume
     (Item      : in out State;
      Stream_ID : Varint_Policy.Value_Type;
      Length    : Stream_Offset) is
   begin
      Stream_Table_Policy.Consume (Item.Streams, Stream_ID, Length);
   end Consume;

   procedure Release_Stream
     (Item      : in out State;
      Stream_ID : Varint_Policy.Value_Type) is
   begin
      Flow_Control_Policy.Release_Stream (Item.Flow, Stream_ID);
      Receive_Flow_Control_Policy.Release_Stream
        (Item.Receive_Flow, Stream_ID);
      Stream_Table_Policy.Release (Item.Streams, Stream_ID);
   end Release_Stream;

   function Retained_Packets
     (Item : State) return Sent_Packet_Policy.Sent_Count
   is
     (Sent_Packet_Policy.Retained (Item.Sent));

   function Committed_Data (Item : State) return Varint_Policy.Value_Type is
     (Flow_Control_Policy.Committed_Data (Item.Flow));

   procedure Open_Stream
     (Item      : in out State;
      Direction : Stream_ID_Policy.Stream_Direction;
      ID        : out Varint_Policy.Value_Type;
      Status    : out Open_Status) is
   begin
      Stream_ID_Policy.Open_Local
        (Item.Allocator, Direction,
         (if Direction = Stream_ID_Policy.Bidirectional
          then Item.Peer_Bidi else Item.Peer_Uni),
         ID, Status);
   end Open_Stream;

   function Bytes_In_Flight (Item : State) return Recovery_Policy.Byte_Count is
     (Recovery_Policy.Bytes_In_Flight (Item.Recovery));

   function Congestion_Window (Item : State) return Recovery_Policy.Byte_Count is
     (Recovery_Policy.Congestion_Window (Item.Recovery));

   function Has_RTT_Sample (Item : State) return Boolean is
     (Recovery_Policy.Has_RTT_Sample (Item.Recovery));

   function Smoothed_RTT (Item : State) return Recovery_Policy.Duration is
     (Recovery_Policy.Smoothed_RTT (Item.Recovery));

   function PTO_Count (Item : State) return Recovery_Policy.PTO_Count_Type is
     (Recovery_Policy.PTO_Count (Item.Recovery));

   function Has_Retransmittable_Frame (Item : State) return Boolean;

   function Has_Recovery_Timeout (Item : State) return Boolean is
     (Item.Has_Latest_ACK_Eliciting
      and then
        (Sent_Packet_Policy.Retained (Item.Sent) > 0
         or else Has_Retransmittable_Frame (Item)));

   function Recovery_Deadline
     (Item              : State;
      Maximum_ACK_Delay : Recovery_Policy.Duration) return Timestamp
   is
      Timeout_Length : constant Timestamp := Probe_Timeout
        (Item, Maximum_ACK_Delay);
   begin
      if Timeout_Length > Timestamp'Last - Item.Latest_ACK_Eliciting then
         return Timestamp'Last;
      else
         return Item.Latest_ACK_Eliciting + Timeout_Length;
      end if;
   end Recovery_Deadline;

   function Probe_Timeout
     (Item              : State;
      Maximum_ACK_Delay : Recovery_Policy.Duration)
      return Recovery_Policy.Duration
   is
     (Recovery_Policy.Probe_Timeout
        (Item.Recovery, Maximum_ACK_Delay, Include_ACK_Delay => True));

   procedure On_Probe_Timeout (Item : in out State) is
   begin
      Recovery_Policy.On_Probe_Timeout (Item.Recovery);
   end On_Probe_Timeout;

   function Free_Retransmittable_Frame (Item : State) return Natural is
   begin
      for Index in Retransmittable_Index loop
         if not Item.Retransmittable (Index).Occupied then
            return Index;
         end if;
      end loop;
      return 0;
   end Free_Retransmittable_Frame;

   function Has_Retransmittable_Frame (Item : State) return Boolean is
   begin
      for Index in Retransmittable_Index loop
         if Item.Retransmittable (Index).Occupied then
            return True;
         end if;
      end loop;
      return False;
   end Has_Retransmittable_Frame;

   function Free_Packet_Frame_Mapping (Item : State) return Natural is
   begin
      for Index in Retransmittable_Index loop
         if not Item.Packet_Frames (Index).Valid then
            return Index;
         end if;
      end loop;
      return 0;
   end Free_Packet_Frame_Mapping;

   function Frame_For_Probe (Item : State) return Natural is
      First_Occupied : Natural := 0;
   begin
      for Index in Retransmittable_Index loop
         if Item.Retransmittable (Index).Occupied then
            if Item.Retransmittable (Index).Needs_Retransmission then
               return Index;
            elsif First_Occupied = 0 then
               First_Occupied := Index;
            end if;
         end if;
      end loop;
      return First_Occupied;
   end Frame_For_Probe;

   procedure Map_Packet_To_Frame
     (Item   : in out State;
      Number : Packet_Number;
      Frame  : Retransmittable_Index)
   is
      Mapping : constant Natural := Free_Packet_Frame_Mapping (Item);
   begin
      pragma Assert (Mapping in Retransmittable_Index);
      Item.Packet_Frames (Mapping) :=
        (Valid => True, Number => Number, Frame => Frame);
   end Map_Packet_To_Frame;

   procedure Retain_New_Frame
     (Item   : in out State;
      Number : Packet_Number;
      Frame  : Ada.Streams.Stream_Element_Array)
   is
      Index : constant Natural := Free_Retransmittable_Frame (Item);
   begin
      pragma Assert (Index in Retransmittable_Index);
      pragma Assert (Frame'Length <= Max_Retransmittable_Length);
      Item.Retransmittable (Index) := (others => <>);
      Item.Retransmittable (Index).Occupied := True;
      Item.Retransmittable (Index).Length := Natural (Frame'Length);
      if Frame'Length > 0 then
         Item.Retransmittable (Index).Data
           (1 .. Ada.Streams.Stream_Element_Offset (Frame'Length)) := Frame;
      end if;
      Map_Packet_To_Frame (Item, Number, Retransmittable_Index (Index));
   end Retain_New_Frame;

   procedure Resolve_Retransmittable_Frame
     (Retransmittable : in out Retransmittable_Table;
      Packet_Frames   : in out Packet_Frame_Table;
      Number       : Packet_Number;
      Acknowledged : Boolean)
   is
      Frame : Natural := 0;
   begin
      for Index in Retransmittable_Index loop
         if Packet_Frames (Index).Valid
           and then Packet_Frames (Index).Number = Number
         then
            Frame := Packet_Frames (Index).Frame;
            Packet_Frames (Index).Valid := False;
         end if;
      end loop;
      if Frame = 0 then
         return;
      elsif Acknowledged then
         for Index in Retransmittable_Index loop
            if Packet_Frames (Index).Valid
              and then Packet_Frames (Index).Frame = Frame
            then
               Packet_Frames (Index).Valid := False;
            end if;
         end loop;
         Retransmittable (Frame) := (others => <>);
      else
         Retransmittable (Frame).Needs_Retransmission := True;
      end if;
   end Resolve_Retransmittable_Frame;

   procedure Initialize
     (Item        : in out State;
      Sending     : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Receiving   : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Destination : Long_Header_Policy.Connection_ID;
      Local_ID    : Long_Header_Policy.Connection_ID;
      Role        : Stream_ID_Policy.Endpoint_Role;
      Local       : Transport_Parameter_Policy.Transport_Parameters;
      Peer        : Transport_Parameter_Policy.Transport_Parameters)
   is
      function Value_Or_Zero
        (Parameter : Transport_Parameter_Policy.Integer_Parameter)
         return Varint_Policy.Value_Type
      is (if Parameter.Present then Parameter.Value else 0);

      Limits : constant Flow_Control_Policy.Send_Limits :=
        (Connection => Value_Or_Zero (Peer.Initial_Max_Data),
         Bidi_Local =>
           Value_Or_Zero (Peer.Initial_Max_Stream_Data_Bidi_Local),
         Bidi_Remote =>
           Value_Or_Zero (Peer.Initial_Max_Stream_Data_Bidi_Remote),
         Unidirectional =>
           Value_Or_Zero (Peer.Initial_Max_Stream_Data_Uni));
      Receive_Limits : constant
        Receive_Flow_Control_Policy.Receive_Limits :=
          (Connection => Value_Or_Zero (Local.Initial_Max_Data),
           Bidi_Local =>
             Value_Or_Zero (Local.Initial_Max_Stream_Data_Bidi_Local),
           Bidi_Remote =>
             Value_Or_Zero (Local.Initial_Max_Stream_Data_Bidi_Remote),
           Unidirectional =>
             Value_Or_Zero (Local.Initial_Max_Stream_Data_Uni),
           Streams_Bidi => Value_Or_Zero (Local.Initial_Max_Streams_Bidi),
           Streams_Uni => Value_Or_Zero (Local.Initial_Max_Streams_Uni));
   begin
      Application_Connection.Initialize
        (Item.Packets, Sending, Receiving, Destination, Local_ID);
      Stream_Table_Policy.Reset (Item.Streams);
      Stream_ID_Policy.Reset (Item.Allocator, Role);
      Flow_Control_Policy.Reset (Item.Flow, Role, Limits);
      Receive_Flow_Control_Policy.Reset
        (Item.Receive_Flow, Role, Receive_Limits);
      Item.Peer_Bidi := Value_Or_Zero (Peer.Initial_Max_Streams_Bidi);
      Item.Peer_Uni := Value_Or_Zero (Peer.Initial_Max_Streams_Uni);
      Sent_Packet_Policy.Reset (Item.Sent);
      Recovery_Policy.Reset (Item.Recovery);
      Item.Retransmittable := (others => (others => <>));
      Item.Packet_Frames := (others => (others => <>));
      Item.Has_Latest_ACK_Eliciting := False;
      Item.Latest_ACK_Eliciting := 0;
      Item.Initialized := True;
   end Initialize;

   function Send_Status_For
     (Status : Application_Connection.Build_Status) return Send_Status
   is
     (case Status is
         when Application_Connection.Built => Sent,
         when Application_Connection.Packet_Number_Exhausted =>
           Packet_Number_Exhausted,
         when Application_Connection.Packet_Number_Unrepresentable =>
           Packet_Number_Unrepresentable,
         when Application_Connection.Insufficient_Protected_Payload =>
           Insufficient_Protected_Payload,
         when Application_Connection.Packet_Too_Large => Packet_Too_Large,
         when Application_Connection.Output_Too_Small => Output_Too_Small);

   function Send_Status_For
     (Status : Flow_Control_Policy.Reserve_Status) return Send_Status
   is
     (case Status is
         when Flow_Control_Policy.Reserved => Sent,
         when Flow_Control_Policy.Stream_Not_Sendable => Stream_Not_Sendable,
         when Flow_Control_Policy.Stream_Capacity_Exceeded =>
           Stream_Capacity_Exceeded,
         when Flow_Control_Policy.Stream_Flow_Blocked => Stream_Flow_Blocked,
         when Flow_Control_Policy.Connection_Flow_Blocked =>
           Connection_Flow_Blocked,
         when Flow_Control_Policy.Stream_Range_Too_Large =>
           Stream_Range_Too_Large,
         when Flow_Control_Policy.Stream_Final_Size_Mismatch =>
           Stream_Final_Size_Mismatch);

   function Stream_Was_Opened
     (Item : State; ID : Stream_ID_Policy.Stream_ID) return Boolean
   is
      Role : constant Stream_ID_Policy.Endpoint_Role :=
        Stream_ID_Policy.Local_Role (Item.Allocator);
   begin
      if Stream_ID_Policy.Is_Local (Role, ID) then
         return Stream_ID_Policy.Ordinal (ID) <=
           Stream_ID_Policy.Opened_Count
             (Item.Allocator, Stream_ID_Policy.Direction (ID));
      else
         return Stream_ID_Policy.Direction (ID) =
           Stream_ID_Policy.Bidirectional
           and then Stream_Table_Policy.Has_Stream (Item.Streams, ID);
      end if;
   end Stream_Was_Opened;

   procedure Build_Stream_Packet
     (Item      : in out State;
      Stream_ID : Varint_Policy.Value_Type;
      Offset    : Varint_Policy.Value_Type;
      Fin       : Boolean;
      Data      : Ada.Streams.Stream_Element_Array;
      Now       : Timestamp;
      Packet    : out Ada.Streams.Stream_Element_Array;
      Result    : out Send_Result)
   is
      Frame          : Stream_Frame_Policy.Encode_Result;
      Built          : Application_Connection.Build_Result;
      Record_Status  : Sent_Packet_Policy.Record_Status;
      Account_Status : Recovery_Policy.Send_Status;
      Flow_Status    : Flow_Control_Policy.Reserve_Status;
      Sent_Packet    : Sent_Packet_Policy.Sent_Packet;
   begin
      Packet := (others => 0);
      Result := (others => <>);
      if not Stream_Was_Opened (Item, Stream_ID) then
         Result.Status := Stream_Not_Sendable;
         return;
      elsif Sent_Packet_Policy.Retained (Item.Sent) =
        Sent_Packet_Policy.Max_Sent_Packets
      then
         Result.Status := Recovery_Capacity_Exceeded;
         return;
      elsif Free_Retransmittable_Frame (Item) = 0
        or else Free_Packet_Frame_Mapping (Item) = 0
      then
         Result.Status := Recovery_Capacity_Exceeded;
         return;
      elsif not Recovery_Policy.Can_Send
        (Item.Recovery,
         Sent_Packet_Policy.Packet_Byte_Count (Max_Datagram_Length))
      then
         Result.Status := Congestion_Blocked;
         return;
      end if;

      Flow_Status := Flow_Control_Policy.Check_Send
        (Item.Flow, Stream_ID, Offset, Data'Length, Fin);
      if Flow_Status /= Flow_Control_Policy.Reserved then
         Result.Status := Send_Status_For (Flow_Status);
         return;
      end if;

      Frame := Stream_Frame_Policy.Encode (Stream_ID, Offset, Fin, Data);
      if Frame.Status /= Stream_Frame_Policy.Encoded then
         Result.Status := Stream_Range_Too_Large;
         return;
      end if;
      Application_Connection.Build_One_RTT
        (Item.Packets,
         Frame.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Frame.Length)),
         Packet, Built);
      Result.Number := Built.Number;
      if Built.Status /= Application_Connection.Built then
         Result.Status := Send_Status_For (Built.Status);
         return;
      elsif Built.Packet_Length > Max_Datagram_Length then
         Result.Status := Packet_Too_Large;
         return;
      end if;

      Flow_Control_Policy.Reserve_Send
        (Item.Flow, Stream_ID, Offset, Data'Length, Fin, Flow_Status);
      if Flow_Status /= Flow_Control_Policy.Reserved then
         Result.Status := Internal_State_Error;
         return;
      end if;
      Result.Packet_Length := Built.Packet_Length;
      Sent_Packet :=
        (Number        => Built.Number,
         Sent_At       => Now,
         Bytes         => Sent_Packet_Policy.Packet_Byte_Count
           (Built.Packet_Length),
         ACK_Eliciting => True,
         In_Flight     => True);
      Sent_Packet_Policy.Record_Sent
        (Item.Sent, Sent_Packet, Record_Status);
      if Record_Status /= Sent_Packet_Policy.Recorded then
         Result.Status := Internal_State_Error;
         return;
      end if;
      Recovery_Policy.On_Packet_Sent
        (Item.Recovery, Sent_Packet, Permit_Probe => False,
         Status => Account_Status);
      if Account_Status /= Recovery_Policy.Accounted then
         Result.Status := Internal_State_Error;
         return;
      end if;
      Item.Has_Latest_ACK_Eliciting := True;
      Item.Latest_ACK_Eliciting := Now;
      Retain_New_Frame
        (Item, Built.Number,
         Frame.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Frame.Length)));
      Result.Status := Sent;
   end Build_Stream_Packet;

   procedure Build_Tracked_Frame_Packet
     (Item         : in out State;
      Plaintext    : Ada.Streams.Stream_Element_Array;
      Now          : Timestamp;
      Permit_Probe : Boolean;
      Retain_Frame : Boolean;
      Packet       : out Ada.Streams.Stream_Element_Array;
      Result       : out Send_Result)
   is
      Built          : Application_Connection.Build_Result;
      Record_Status  : Sent_Packet_Policy.Record_Status;
      Account_Status : Recovery_Policy.Send_Status;
      Sent_Packet    : Sent_Packet_Policy.Sent_Packet;
   begin
      Packet := (others => 0);
      Result := (others => <>);
      if Sent_Packet_Policy.Retained (Item.Sent) =
        Sent_Packet_Policy.Max_Sent_Packets
      then
         if Debug.Enabled then
            Debug.Log
              ("quic", "tracked-frame-recovery-capacity",
               "retained=" & Sent_Packet_Policy.Sent_Count'Image
                 (Sent_Packet_Policy.Retained (Item.Sent)));
         end if;
         Result.Status := Recovery_Capacity_Exceeded;
         return;
      elsif Retain_Frame
        and then
          (Free_Retransmittable_Frame (Item) = 0
           or else Free_Packet_Frame_Mapping (Item) = 0)
      then
         Result.Status := Recovery_Capacity_Exceeded;
         return;
      elsif not Permit_Probe
        and then not Recovery_Policy.Can_Send
        (Item.Recovery,
         Sent_Packet_Policy.Packet_Byte_Count (Max_Datagram_Length))
      then
         if Debug.Enabled then
            Debug.Log
              ("quic", "tracked-frame-congestion-blocked",
               "flight=" & Recovery_Policy.Byte_Count'Image
                 (Recovery_Policy.Bytes_In_Flight (Item.Recovery)) &
               " window=" & Recovery_Policy.Byte_Count'Image
                 (Recovery_Policy.Congestion_Window (Item.Recovery)) &
               " retained=" & Sent_Packet_Policy.Sent_Count'Image
                 (Sent_Packet_Policy.Retained (Item.Sent)));
         end if;
         Result.Status := Congestion_Blocked;
         return;
      end if;

      Application_Connection.Build_One_RTT
        (Item.Packets, Plaintext, Packet, Built);
      Result.Number := Built.Number;
      if Built.Status /= Application_Connection.Built then
         Result.Status := Send_Status_For (Built.Status);
         return;
      elsif Built.Packet_Length > Max_Datagram_Length then
         Result.Status := Packet_Too_Large;
         return;
      end if;

      Result.Packet_Length := Built.Packet_Length;
      Sent_Packet :=
        (Number        => Built.Number,
         Sent_At       => Now,
         Bytes         => Sent_Packet_Policy.Packet_Byte_Count
           (Built.Packet_Length),
         ACK_Eliciting => True,
         In_Flight     => True);
      Sent_Packet_Policy.Record_Sent
        (Item.Sent, Sent_Packet, Record_Status);
      if Record_Status /= Sent_Packet_Policy.Recorded then
         Result.Status := Internal_State_Error;
         return;
      end if;
      Recovery_Policy.On_Packet_Sent
        (Item.Recovery, Sent_Packet, Permit_Probe,
         Status => Account_Status);
      if Account_Status = Recovery_Policy.Accounted then
         Item.Has_Latest_ACK_Eliciting := True;
         Item.Latest_ACK_Eliciting := Now;
         if Retain_Frame then
            Retain_New_Frame (Item, Built.Number, Plaintext);
         end if;
         Result.Status := Sent;
      else
         Result.Status := Internal_State_Error;
      end if;
   end Build_Tracked_Frame_Packet;

   procedure Build_Max_Streams_Packet
     (Item          : in out State;
      Bidirectional : Boolean;
      Maximum       : Varint_Policy.Value_Type;
      Now           : Timestamp;
      Packet        : out Ada.Streams.Stream_Element_Array;
      Result        : out Send_Result)
   is
      Frame : constant Application_Frame_Policy.Max_Streams_Encode_Result :=
        Application_Frame_Policy.Encode_Max_Streams
          (Bidirectional, Maximum);
   begin
      Build_Tracked_Frame_Packet
        (Item,
         Frame.Data (1 .. Ada.Streams.Stream_Element_Offset (Frame.Length)),
         Now, Permit_Probe => False, Retain_Frame => True,
         Packet => Packet, Result => Result);
      if Result.Status = Sent then
         Receive_Flow_Control_Policy.Raise_Stream_Limit
           (Item.Receive_Flow, Bidirectional, Maximum);
      end if;
   end Build_Max_Streams_Packet;

   procedure Build_Receive_Credit_Packet
     (Item              : in out State;
      Connection_Window : Varint_Policy.Value_Type;
      Bidirectional     : Boolean;
      Maximum_Streams   : Varint_Policy.Value_Type;
      Now               : Timestamp;
      Packet            : out Ada.Streams.Stream_Element_Array;
      Result            : out Send_Result)
   is
      Committed : constant Varint_Policy.Value_Type :=
        Receive_Flow_Control_Policy.Committed_Data (Item.Receive_Flow);
      Maximum_Data : constant Varint_Policy.Value_Type :=
        (if Connection_Window > Varint_Policy.Value_Type'Last - Committed
         then Varint_Policy.Value_Type'Last
         else Committed + Connection_Window);
      Data_Frame : constant Application_Frame_Policy.Max_Data_Encode_Result :=
        Application_Frame_Policy.Encode_Max_Data (Maximum_Data);
      Streams_Frame : constant
        Application_Frame_Policy.Max_Streams_Encode_Result :=
          Application_Frame_Policy.Encode_Max_Streams
            (Bidirectional, Maximum_Streams);
      Plaintext : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset
                (Data_Frame.Length + Streams_Frame.Length));
   begin
      Plaintext (1 .. Ada.Streams.Stream_Element_Offset (Data_Frame.Length)) :=
        Data_Frame.Data
          (1 .. Ada.Streams.Stream_Element_Offset (Data_Frame.Length));
      Plaintext
        (Ada.Streams.Stream_Element_Offset (Data_Frame.Length + 1)
           .. Plaintext'Last) :=
          Streams_Frame.Data
            (1 .. Ada.Streams.Stream_Element_Offset (Streams_Frame.Length));
      Build_Tracked_Frame_Packet
        (Item, Plaintext, Now, Permit_Probe => False, Retain_Frame => True,
         Packet => Packet, Result => Result);
      if Result.Status = Sent then
         Receive_Flow_Control_Policy.Raise_Connection_Limit
           (Item.Receive_Flow, Maximum_Data);
         Receive_Flow_Control_Policy.Raise_Stream_Limit
           (Item.Receive_Flow, Bidirectional, Maximum_Streams);
      end if;
   end Build_Receive_Credit_Packet;

   procedure Build_Stream_Abort_Packet
     (Item              : in out State;
      Stream_ID         : Varint_Policy.Value_Type;
      Application_Error : Varint_Policy.Value_Type;
      Final_Size        : Varint_Policy.Value_Type;
      Now               : Timestamp;
      Packet            : out Ada.Streams.Stream_Element_Array;
      Result            : out Send_Result)
   is
      Frame : Application_Frame_Policy.Abort_Encode_Result;
   begin
      Packet := (others => 0);
      Result := (others => <>);
      if not Stream_Was_Opened (Item, Stream_ID)
        or else Stream_ID_Policy.Direction (Stream_ID) /=
          Stream_ID_Policy.Bidirectional
      then
         Result.Status := Stream_Not_Sendable;
         return;
      elsif (Flow_Control_Policy.Has_Stream (Item.Flow, Stream_ID)
             and then Flow_Control_Policy.Stream_Committed
               (Item.Flow, Stream_ID) /= Final_Size)
        or else (not Flow_Control_Policy.Has_Stream (Item.Flow, Stream_ID)
                 and then Final_Size /= 0)
      then
         Result.Status := Stream_Final_Size_Mismatch;
         return;
      end if;

      Frame := Application_Frame_Policy.Encode_Stream_Abort
        (Stream_ID, Application_Error, Final_Size);
      Build_Tracked_Frame_Packet
        (Item,
         Frame.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Frame.Length)),
         Now, Permit_Probe => False, Retain_Frame => True,
         Packet => Packet, Result => Result);
   end Build_Stream_Abort_Packet;

   procedure Build_ACK_Packet
     (Item      : in out State;
      ACK_Delay : Varint_Policy.Value_Type;
      Now       : Timestamp;
      Packet    : out Ada.Streams.Stream_Element_Array;
      Result    : out Send_Result)
   is
      Frame         : ACK_Frame_Policy.Encode_Result;
      Built         : Application_Connection.Build_Result;
      Record_Status : Sent_Packet_Policy.Record_Status;
   begin
      Packet := (others => 0);
      Result := (others => <>);
      Frame := Application_Connection.Encode_ACK (Item.Packets, ACK_Delay);
      if Frame.Status = ACK_Frame_Policy.Nothing_To_ACK then
         Result.Status := Nothing_To_ACK;
         return;
      end if;
      Application_Connection.Build_One_RTT
        (Item.Packets,
         Frame.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Frame.Length)),
         Packet, Built);
      Result.Number := Built.Number;
      if Built.Status /= Application_Connection.Built then
         Result.Status := Send_Status_For (Built.Status);
         return;
      elsif Built.Packet_Length > Max_Datagram_Length then
         Result.Status := Packet_Too_Large;
         return;
      end if;
      Result.Packet_Length := Built.Packet_Length;
      Sent_Packet_Policy.Record_Sent
        (Item.Sent,
         (Number        => Built.Number,
          Sent_At       => Now,
          Bytes         => Sent_Packet_Policy.Packet_Byte_Count
            (Built.Packet_Length),
          ACK_Eliciting => False,
          In_Flight     => False),
         Record_Status);
      Result.Status :=
        (if Record_Status = Sent_Packet_Policy.Not_Tracked then Sent
         else Internal_State_Error);
   end Build_ACK_Packet;

   procedure Build_Tracked_Control_Packet
     (Item   : in out State;
      Frame_Type : Ada.Streams.Stream_Element;
      Now    : Timestamp;
      Permit_Probe : Boolean;
      Retain_Frame : Boolean;
      Packet : out Ada.Streams.Stream_Element_Array;
      Result : out Send_Result)
   is
      Plaintext : constant Ada.Streams.Stream_Element_Array :=
        (1 => Frame_Type, 2 .. 3 => 0);
   begin
      Build_Tracked_Frame_Packet
        (Item, Plaintext, Now, Permit_Probe, Retain_Frame, Packet, Result);
   end Build_Tracked_Control_Packet;

   procedure Build_Handshake_Done_Packet
     (Item   : in out State;
      Now    : Timestamp;
      Packet : out Ada.Streams.Stream_Element_Array;
      Result : out Send_Result) is
   begin
      Build_Tracked_Control_Packet
        (Item, Frame_Type => 16#1E#, Now => Now, Permit_Probe => False,
         Retain_Frame => True,
         Packet => Packet, Result => Result);
   end Build_Handshake_Done_Packet;

   procedure Build_Application_Close_Packet
     (Item   : in out State;
      Application_Error : Varint_Policy.Value_Type;
      Packet : out Ada.Streams.Stream_Element_Array;
      Result : out Send_Result)
   is
      Encoded : constant Varint_Policy.Encoded_Value :=
        Varint_Policy.Encode (Application_Error);
      Plaintext : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Encoded.Length + 2)) :=
          (others => 0);
      Built : Application_Connection.Build_Result;
   begin
      --  APPLICATION_CLOSE, application error zero, and an empty reason are
      --  each represented by a one-byte QUIC variable integer. Closing is
      --  deliberately not recovery-tracked or congestion-gated: it must
      --  remain buildable when the ordinary sent-packet table is full.
      Packet := (others => 0);
      Result := (others => <>);
      Plaintext (1) := 16#1D#;
      Plaintext
        (2 .. Ada.Streams.Stream_Element_Offset (Encoded.Length + 1)) :=
          Encoded.Data
            (1 .. Ada.Streams.Stream_Element_Offset (Encoded.Length));
      Application_Connection.Build_One_RTT
        (Item.Packets, Plaintext, Packet, Built);
      Result.Number := Built.Number;
      Result.Packet_Length := Built.Packet_Length;
      Result.Status :=
        (if Built.Status = Application_Connection.Built
         then Sent else Send_Status_For (Built.Status));
   end Build_Application_Close_Packet;

   procedure Build_Transport_Close_Packet
     (Item       : in out State;
      Error_Code : Varint_Policy.Value_Type;
      Frame_Type : Varint_Policy.Value_Type;
      Packet     : out Ada.Streams.Stream_Element_Array;
      Result     : out Send_Result)
   is
      Plaintext : constant
        Initial_Frame_Policy.Transport_Close_Encode_Result :=
          Initial_Frame_Policy.Encode_Transport_Close
            (Error_Code, Frame_Type);
      Built : Application_Connection.Build_Result;
   begin
      Packet := (others => 0);
      Result := (others => <>);
      Application_Connection.Build_One_RTT
        (Item.Packets,
         Plaintext.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Plaintext.Length)),
         Packet, Built);
      Result.Number := Built.Number;
      Result.Packet_Length := Built.Packet_Length;
      Result.Status :=
        (if Built.Status = Application_Connection.Built
         then Sent else Send_Status_For (Built.Status));
   end Build_Transport_Close_Packet;

   procedure Build_Probe_Packet
     (Item   : in out State;
      Now    : Timestamp;
      Packet : out Ada.Streams.Stream_Element_Array;
      Result : out Send_Result) is
      Frame_Index    : constant Natural := Frame_For_Probe (Item);
      Built          : Application_Connection.Build_Result;
      Record_Status  : Sent_Packet_Policy.Record_Status;
      Account_Status : Recovery_Policy.Send_Status;
      Sent_Packet    : Sent_Packet_Policy.Sent_Packet;
   begin
      if Frame_Index = 0 then
         Build_Tracked_Control_Packet
           (Item, Frame_Type => 16#01#, Now => Now, Permit_Probe => True,
            Retain_Frame => False, Packet => Packet, Result => Result);
         return;
      elsif Sent_Packet_Policy.Retained (Item.Sent) =
        Sent_Packet_Policy.Max_Sent_Packets
        or else Free_Packet_Frame_Mapping (Item) = 0
      then
         Packet := (others => 0);
         Result := (others => <>);
         Result.Status := Recovery_Capacity_Exceeded;
         return;
      end if;

      Packet := (others => 0);
      Result := (others => <>);
      Application_Connection.Build_One_RTT
        (Item.Packets,
         Item.Retransmittable (Frame_Index).Data
           (1 .. Ada.Streams.Stream_Element_Offset
                   (Item.Retransmittable (Frame_Index).Length)),
         Packet, Built);
      Result.Number := Built.Number;
      if Built.Status /= Application_Connection.Built then
         Result.Status := Send_Status_For (Built.Status);
         return;
      elsif Built.Packet_Length > Max_Datagram_Length then
         Result.Status := Packet_Too_Large;
         return;
      end if;

      Result.Packet_Length := Built.Packet_Length;
      Sent_Packet :=
        (Number        => Built.Number,
         Sent_At       => Now,
         Bytes         => Sent_Packet_Policy.Packet_Byte_Count
           (Built.Packet_Length),
         ACK_Eliciting => True,
         In_Flight     => True);
      Sent_Packet_Policy.Record_Sent
        (Item.Sent, Sent_Packet, Record_Status);
      if Record_Status /= Sent_Packet_Policy.Recorded then
         Result.Status := Internal_State_Error;
         return;
      end if;
      Recovery_Policy.On_Packet_Sent
        (Item.Recovery, Sent_Packet, Permit_Probe => True,
         Status => Account_Status);
      if Account_Status /= Recovery_Policy.Accounted then
         Result.Status := Internal_State_Error;
         return;
      end if;
      Map_Packet_To_Frame
        (Item, Built.Number, Retransmittable_Index (Frame_Index));
      Item.Retransmittable (Frame_Index).Needs_Retransmission := False;
      Item.Has_Latest_ACK_Eliciting := True;
      Item.Latest_ACK_Eliciting := Now;
      Result.Status := Sent;
   end Build_Probe_Packet;

   function Decoded_ACK_Delay
     (Wire_Value : Varint_Policy.Value_Type;
      Exponent   : ACK_Delay_Exponent) return Recovery_Policy.Duration
   is
      Factor : constant Recovery_Policy.Duration := 2**Exponent;
   begin
      if Wire_Value > Varint_Policy.Value_Type
        (Recovery_Policy.Duration'Last / Factor)
      then
         return Recovery_Policy.Duration'Last;
      else
         return Recovery_Policy.Duration (Wire_Value) * Factor;
      end if;
   end Decoded_ACK_Delay;

   function Process_Status_For
     (Status : Application_Connection.Process_Status) return Process_Status
   is
     (case Status is
         when Application_Connection.Processed => Processed,
         when Application_Connection.Duplicate => Duplicate,
         when Application_Connection.Too_Old => Too_Old,
         when Application_Connection.Envelope_Rejected => Envelope_Rejected,
         when Application_Connection.Authentication_Failed =>
           Authentication_Failed,
         when Application_Connection.Invalid_Reserved_Bits =>
           Invalid_Reserved_Bits,
         when Application_Connection.Unexpected_Destination =>
           Unexpected_Destination,
         when Application_Connection.Unsupported_Key_Phase =>
           Unsupported_Key_Phase);

   function Process_Status_For
     (Status : Stream_Table_Policy.Process_Status) return Process_Status
   is
     (case Status is
         when Stream_Table_Policy.Processed => Processed,
         when Stream_Table_Policy.Frame_Truncated => Frame_Truncated,
         when Stream_Table_Policy.Unknown_Frame_Type => Unknown_Frame_Type,
         when Stream_Table_Policy.Frame_Value_Too_Large =>
           Frame_Value_Too_Large,
         when Stream_Table_Policy.Invalid_ACK_Range => Invalid_ACK_Range,
         when Stream_Table_Policy.Invalid_Connection_ID =>
           Invalid_Connection_ID,
         when Stream_Table_Policy.Stream_Capacity_Exceeded =>
           Stream_Capacity_Exceeded,
         when Stream_Table_Policy.Stream_Data_Too_Large =>
           Stream_Data_Too_Large,
         when Stream_Table_Policy.Conflicting_Stream_Data =>
           Conflicting_Stream_Data,
         when Stream_Table_Policy.Stream_Final_Size_Error =>
           Stream_Final_Size_Error,
         when Stream_Table_Policy.Stream_Reset_Conflict =>
           Stream_Reset_Conflict);

   function Process_Status_For
     (Status : Receive_Flow_Control_Policy.Reserve_Status)
      return Process_Status
   is
     (case Status is
         when Receive_Flow_Control_Policy.Reserved => Processed,
         when Receive_Flow_Control_Policy.Retired => Processed,
         when Receive_Flow_Control_Policy.Stream_Not_Receivable
            | Receive_Flow_Control_Policy.Stream_Not_Sendable
            | Receive_Flow_Control_Policy.Stream_Not_Opened =>
           Invalid_Stream_State,
         when Receive_Flow_Control_Policy.Stream_Limit_Exceeded =>
           Invalid_Stream_Limit,
         when Receive_Flow_Control_Policy.Stream_Capacity_Exceeded =>
           Stream_Capacity_Exceeded,
         when Receive_Flow_Control_Policy.Stream_Flow_Exceeded
            | Receive_Flow_Control_Policy.Connection_Flow_Exceeded =>
           Flow_Control_Error,
         when Receive_Flow_Control_Policy.Stream_Range_Too_Large =>
           Stream_Data_Too_Large,
         when Receive_Flow_Control_Policy.Stream_Final_Size_Mismatch =>
           Stream_Final_Size_Error);

   procedure Process_Stream_Frames_Transactionally
     (Item      : in out Stream_Table_Policy.Stream_Table;
      Plaintext : Ada.Streams.Stream_Element_Array;
      Result    : out Stream_Table_Policy.Process_Result)
   is
      Candidate : Stream_Table_Policy.Stream_Table := Item;
   begin
      Stream_Table_Policy.Process_Plaintext
        (Candidate, Plaintext, Result);
      if Result.Status /= Stream_Table_Policy.Processed then
         return;
      end if;
      Item := Candidate;
   end Process_Stream_Frames_Transactionally;

   procedure Process_Packet
     (Item                : in out State;
      Packet              : Ada.Streams.Stream_Element_Array;
      Now                 : Timestamp;
      ACK_Delay_Exponent  : Application_Space.ACK_Delay_Exponent;
      Maximum_ACK_Delay   : Recovery_Policy.Duration;
      Handshake_Confirmed : Boolean;
      Result              : out Process_Result)
   is
      Plaintext : Ada.Streams.Stream_Element_Array (1 .. Max_Datagram_Length);
      Stream_Plaintext : Ada.Streams.Stream_Element_Array
        (1 .. Max_Datagram_Length);
      Received  : Application_Connection.Process_Result;
      Streams   : Stream_Table_Policy.Process_Result;
      Length    : Application_Frame_Policy.Frame_Offset;
      Cursor    : Application_Frame_Policy.Frame_Offset := 0;
      Frame     : Application_Frame_Policy.Parse_Result;
      Ranges    : ACK_Range_Policy.Decode_Result;
      Applied   : Sent_Packet_Policy.Apply_Result;
      Sampled   : Boolean;
      ACKed_Ack_Eliciting : Boolean;
      Updated   : Flow_Control_Policy.Update_Status;
      Receive_Status : Receive_Flow_Control_Policy.Reserve_Status;
      Local_Bidi_Opened : constant Stream_ID_Policy.Stream_Count :=
        Stream_ID_Policy.Opened_Count
          (Item.Allocator, Stream_ID_Policy.Bidirectional);
      Local_Uni_Opened : constant Stream_ID_Policy.Stream_Count :=
        Stream_ID_Policy.Opened_Count
          (Item.Allocator, Stream_ID_Policy.Unidirectional);
      --  The stream table dominates connection-state size, so validate every
      --  frame before changing it and reserve a full table transaction for
      --  the uncommon packet that changes multiple streams. The smaller
      --  policy tables remain staged until all packet effects succeed.
      Candidate_Streams : Stream_Table_Policy.Stream_Table
        renames Item.Streams;
      Candidate_Receive : Receive_Flow_Control_Policy.State :=
        Item.Receive_Flow;
      Candidate_Flow : Flow_Control_Policy.State := Item.Flow;
      Candidate_Sent : Sent_Packet_Policy.Ledger := Item.Sent;
      Candidate_Recovery : Recovery_Policy.State := Item.Recovery;
      Candidate_Retransmittable : Retransmittable_Table
        := Item.Retransmittable;
      Candidate_Packet_Frames : Packet_Frame_Table
        := Item.Packet_Frames;
      Candidate_Peer_Bidi : Varint_Policy.Value_Type := Item.Peer_Bidi;
      Candidate_Peer_Uni : Varint_Policy.Value_Type := Item.Peer_Uni;
      Active_Stream_Frame_Count : Natural := 0;
      Stream_Plaintext_Length : Application_Frame_Policy.Frame_Offset := 0;
   begin
      Result := (others => <>);
      Application_Connection.Process_One_RTT
        (Item.Packets, Packet, Plaintext, Received);
      Result.Number := Received.Packet.Number;
      if Received.Status /= Application_Connection.Processed then
         Result.Status := Process_Status_For (Received.Status);
         return;
      end if;
      Length := Application_Frame_Policy.Frame_Offset
        (Received.Packet.Plaintext_Length);
      if Length = 0 then
         Result.Status := Protocol_Violation;
         return;
      end if;
      while Cursor < Length loop
         Frame := Application_Frame_Policy.Parse_Next
           (Plaintext (1 .. Length), Cursor);
         Result.Triggering_Frame_Type := Frame.Frame_Type;
         if Frame.Status /= Application_Frame_Policy.Parsed then
            Result.Status := Unknown_Frame_Type;
            return;
         end if;
         Result.Frame_Count := Result.Frame_Count + 1;
         if Frame.Kind not in Application_Frame_Policy.Padding
           | Application_Frame_Policy.Acknowledgment
           | Application_Frame_Policy.Transport_Close
           | Application_Frame_Policy.Application_Close
         then
            Result.ACK_Eliciting := True;
         end if;
         if Frame.Kind = Application_Frame_Policy.Handshake_Done then
            if Stream_ID_Policy.Local_Role (Item.Allocator) =
              Stream_ID_Policy.Server
            then
               Result.Status := Unexpected_Handshake_Done;
               return;
            end if;
            Result.Handshake_Done := True;
         elsif Frame.Kind = Application_Frame_Policy.Crypto then
            declare
               Data_Offset : constant Application_Frame_Policy.Frame_Offset :=
                 Frame.Base.Crypto_Data_Offset;
               Data_Length : constant Application_Frame_Policy.Frame_Offset :=
                 Frame.Base.Crypto_Length;
               Body_Length : Natural := 0;
            begin
               if Data_Length >= 4 then
                  Body_Length :=
                    Natural
                      (Plaintext
                         (Plaintext'First
                            + Ada.Streams.Stream_Element_Offset
                                (Data_Offset + 1))) * 65_536
                    + Natural
                      (Plaintext
                         (Plaintext'First
                            + Ada.Streams.Stream_Element_Offset
                                (Data_Offset + 2))) * 256
                    + Natural
                      (Plaintext
                         (Plaintext'First
                            + Ada.Streams.Stream_Element_Offset
                                (Data_Offset + 3)));
               end if;
               if Stream_ID_Policy.Local_Role (Item.Allocator) =
                    Stream_ID_Policy.Client
                 and then Frame.Base.Crypto_Offset = 0
                 and then Data_Length >= 4
                 and then Plaintext
                   (Plaintext'First
                      + Ada.Streams.Stream_Element_Offset (Data_Offset)) = 4
                 and then Body_Length = Natural (Data_Length) - 4
               then
                  --  A client that does not implement resumption may ignore
                  --  a complete post-handshake NewSessionTicket. Other
                  --  messages, including KeyUpdate, remain fatal in QUIC.
                  null;
               else
                  Result.Status := Unexpected_TLS_Message;
                  return;
               end if;
            end;
         elsif Frame.Kind = Application_Frame_Policy.New_Token
           and then Stream_ID_Policy.Local_Role (Item.Allocator) =
             Stream_ID_Policy.Server
         then
            Result.Status := Protocol_Violation;
            return;
         elsif Frame.Kind = Application_Frame_Policy.Transport_Close then
            Result.Peer_Closed := True;
            Result.Application_Close := False;
            Result.Close_Error := Frame.Base.Close_Error_Code;
         elsif Frame.Kind = Application_Frame_Policy.Application_Close then
            Result.Peer_Closed := True;
            Result.Application_Close := True;
            Result.Close_Error := Frame.Application_Error;
         elsif Frame.Kind = Application_Frame_Policy.Stream then
            Receive_Flow_Control_Policy.Reserve_Stream
              (Candidate_Receive, Frame.Stream_ID,
               Frame.Stream_Frame.Stream_Offset,
               Natural (Frame.Stream_Frame.Data_Length),
               Frame.Stream_Frame.Fin, Local_Bidi_Opened,
               Local_Uni_Opened, Receive_Status);
            if Receive_Status = Receive_Flow_Control_Policy.Retired then
               null;
            elsif Receive_Status /= Receive_Flow_Control_Policy.Reserved then
               Result.Status := Process_Status_For (Receive_Status);
               return;
            else
               Active_Stream_Frame_Count := Active_Stream_Frame_Count + 1;
            end if;
         elsif Frame.Kind = Application_Frame_Policy.Reset_Stream then
            Receive_Flow_Control_Policy.Reserve_Reset
              (Candidate_Receive, Frame.Stream_ID, Frame.Final_Size,
               Local_Bidi_Opened, Local_Uni_Opened, Receive_Status);
            if Receive_Status = Receive_Flow_Control_Policy.Retired then
               null;
            elsif Receive_Status /= Receive_Flow_Control_Policy.Reserved then
               Result.Status := Process_Status_For (Receive_Status);
               return;
            else
               Active_Stream_Frame_Count := Active_Stream_Frame_Count + 1;
            end if;
         elsif Frame.Kind = Application_Frame_Policy.Stop_Sending then
            Receive_Status :=
              Receive_Flow_Control_Policy.Check_Stop_Sending
                (Candidate_Receive, Frame.Stream_ID, Local_Bidi_Opened,
                 Local_Uni_Opened);
            if Receive_Status /= Receive_Flow_Control_Policy.Reserved
              and then Receive_Status /= Receive_Flow_Control_Policy.Retired
            then
               Result.Status := Process_Status_For (Receive_Status);
               return;
            end if;
         elsif Frame.Kind = Application_Frame_Policy.Max_Data then
            Flow_Control_Policy.Raise_Connection_Limit
              (Candidate_Flow, Frame.Maximum);
         elsif Frame.Kind = Application_Frame_Policy.Max_Stream_Data then
            Receive_Status :=
              Receive_Flow_Control_Policy.Check_Max_Stream_Data
                (Candidate_Receive, Frame.Stream_ID, Local_Bidi_Opened,
                 Local_Uni_Opened);
            if Receive_Status = Receive_Flow_Control_Policy.Retired then
               null;
            elsif Receive_Status /= Receive_Flow_Control_Policy.Reserved then
               Result.Status := Process_Status_For (Receive_Status);
               return;
            else
               Flow_Control_Policy.Raise_Stream_Limit
                 (Candidate_Flow, Frame.Stream_ID, Frame.Maximum, Updated);
               if Updated = Flow_Control_Policy.Stream_Not_Sendable then
                  Result.Status := Invalid_Stream_State;
                  return;
               elsif Updated = Flow_Control_Policy.Stream_Capacity_Exceeded
               then
                  Result.Status := Stream_Capacity_Exceeded;
                  return;
               end if;
            end if;
         elsif Frame.Kind in Application_Frame_Policy.Max_Streams_Bidi
           | Application_Frame_Policy.Max_Streams_Uni
         then
            if Frame.Maximum > Varint_Policy.Value_Type
              (2**60)
            then
               Result.Status := Frame_Value_Too_Large;
               return;
            elsif Frame.Kind = Application_Frame_Policy.Max_Streams_Bidi then
               Candidate_Peer_Bidi := Varint_Policy.Value_Type'Max
                 (Candidate_Peer_Bidi, Frame.Maximum);
            else
               Candidate_Peer_Uni := Varint_Policy.Value_Type'Max
                 (Candidate_Peer_Uni, Frame.Maximum);
            end if;
         elsif Frame.Kind in Application_Frame_Policy.Streams_Blocked_Bidi
           | Application_Frame_Policy.Streams_Blocked_Uni
           and then Frame.Maximum > 2**60
         then
            Result.Status := Frame_Value_Too_Large;
            return;
         elsif Frame.Kind = Application_Frame_Policy.Acknowledgment then
            Ranges := ACK_Range_Policy.Decode
              (Plaintext (1 .. Length), Frame.Base);
            if Ranges.Status /= ACK_Range_Policy.Decoded then
               Result.Status :=
                 (case Ranges.Status is
                     when ACK_Range_Policy.Too_Many_Ranges =>
                       ACK_Range_Capacity_Exceeded,
                     when ACK_Range_Policy.Truncated => Frame_Truncated,
                     when ACK_Range_Policy.Invalid_Range => Invalid_ACK_Range,
                     when ACK_Range_Policy.Decoded => Processed);
               return;
            end if;
            Sent_Packet_Policy.Apply_ACK
              (Candidate_Sent, Ranges, Now,
               Recovery_Policy.Loss_Delay (Candidate_Recovery), Applied);
            if Applied.Status = Sent_Packet_Policy.Acknowledges_Unsent_Packet
            then
               Result.Status := Acknowledges_Unsent_Packet;
               return;
            end if;
            Sampled := False;
            ACKed_Ack_Eliciting := False;
            for Index in 1 .. Applied.Count loop
               Resolve_Retransmittable_Frame
                 (Candidate_Retransmittable, Candidate_Packet_Frames,
                  Applied.Events (Index).Packet.Number,
                  Applied.Events (Index).Kind =
                    Sent_Packet_Policy.Acknowledged);
               if Applied.Events (Index).Kind =
                 Sent_Packet_Policy.Acknowledged
                 and then Applied.Events (Index).Packet.ACK_Eliciting
               then
                  ACKed_Ack_Eliciting := True;
               end if;
               if not Sampled
                 and then Applied.Events (Index).Kind =
                   Sent_Packet_Policy.Acknowledged
                 and then Applied.Events (Index).Packet.ACK_Eliciting
                 and then Applied.Events (Index).Packet.Number =
                   Packet_Number (Frame.Base.Largest_Acknowledged)
                 and then Now >= Applied.Events (Index).Packet.Sent_At
               then
                  Recovery_Policy.Update_RTT
                    (Candidate_Recovery,
                     Now - Applied.Events (Index).Packet.Sent_At,
                     Decoded_ACK_Delay
                       (Frame.Base.ACK_Delay, ACK_Delay_Exponent),
                     Maximum_ACK_Delay, Handshake_Confirmed);
                  Sampled := True;
               end if;
            end loop;
            if ACKed_Ack_Eliciting then
               Recovery_Policy.On_ACK_Received (Candidate_Recovery);
            end if;
            Recovery_Policy.On_Packets_Resolved
              (Candidate_Recovery, Applied.Events, Applied.Count, Now,
               Application_Limited => False);
            Result.Resolved_Count :=
              Result.Resolved_Count + Natural (Applied.Count);
         end if;
         Cursor := Cursor + Frame.Consumed;
      end loop;

      --  Rebuild just the active STREAM and RESET_STREAM frames. Retired
      --  streams are ignored before reassembly, while all control frames have
      --  already been validated and staged by their owning policies.
      Cursor := 0;
      while Cursor < Length loop
         Frame := Application_Frame_Policy.Parse_Next
           (Plaintext (1 .. Length), Cursor);
         pragma Assert (Frame.Status = Application_Frame_Policy.Parsed);
         if Frame.Kind in Application_Frame_Policy.Stream
             | Application_Frame_Policy.Reset_Stream
           and then not Receive_Flow_Control_Policy.Is_Stream_Retired
             (Candidate_Receive, Frame.Stream_ID)
         then
            pragma Assert (Frame.Consumed > 0);
            Stream_Plaintext
              (Ada.Streams.Stream_Element_Offset
                 (Stream_Plaintext_Length) + 1
               .. Ada.Streams.Stream_Element_Offset
                    (Stream_Plaintext_Length + Frame.Consumed)) :=
              Plaintext
                (Ada.Streams.Stream_Element_Offset (Cursor) + 1
                 .. Ada.Streams.Stream_Element_Offset
                      (Cursor + Frame.Consumed));
            Stream_Plaintext_Length :=
              Stream_Plaintext_Length + Frame.Consumed;
         end if;
         Cursor := Cursor + Frame.Consumed;
      end loop;

      if Active_Stream_Frame_Count = 1 then
         --  Insert and reset operations validate before mutation, so one
         --  active stream frame can commit directly after every other frame
         --  in the packet has passed validation.
         Stream_Table_Policy.Process_Plaintext
           (Candidate_Streams,
            Stream_Plaintext (1 .. Stream_Plaintext_Length), Streams);
      elsif Active_Stream_Frame_Count > 0 then
         --  Preserve packet-level atomicity when more than one stream can be
         --  changed. This slow path is bounded but deliberately pays for a
         --  full table copy.
         Process_Stream_Frames_Transactionally
           (Candidate_Streams,
            Stream_Plaintext (1 .. Stream_Plaintext_Length), Streams);
      else
         Streams := (Status => Stream_Table_Policy.Processed, others => <>);
      end if;
      if Streams.Status /= Stream_Table_Policy.Processed then
         Result.Triggering_Frame_Type := Streams.Triggering_Frame_Type;
         Result.Status := Process_Status_For (Streams.Status);
         return;
      end if;

      Item.Receive_Flow := Candidate_Receive;
      Item.Flow := Candidate_Flow;
      Item.Sent := Candidate_Sent;
      Item.Recovery := Candidate_Recovery;
      Item.Retransmittable := Candidate_Retransmittable;
      Item.Packet_Frames := Candidate_Packet_Frames;
      Item.Peer_Bidi := Candidate_Peer_Bidi;
      Item.Peer_Uni := Candidate_Peer_Uni;
      Result.Status := Processed;
   end Process_Packet;
end Flyology.QUIC.Application_Space;
