with Flyology.HTTP.HTTP_3_Control_Policy;
with Flyology.HTTP.HTTP_3_Stream_Policy;

package body Flyology.HTTP.HTTP_3_Connection is
   use type Ada.Streams.Stream_Element_Offset;
   use type HTTP_3_Stream_Receive_Policy.Event_Kind;
   use type HTTP_3_Stream_Receive_Policy.Receive_Status;
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

   procedure Find_Or_Open
     (Item   : in out Connection;
      ID     : QUIC.Stream_ID;
      Index  : out Optional_Slot;
      Status : out Operation_Status)
   is
      Opened : HTTP_3_Stream_Receive_Policy.Receive_Status;
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
            HTTP_3_Stream_Receive_Policy.Open
              (Item.Streams (Candidate).State, ID,
               Receive_Role (Item.Local_Role), Opened);
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
         when HTTP_3_Stream_Receive_Policy.QPACK_Decompression_Failed =>
           QPACK_Decompression_Failed,
         when HTTP_3_Stream_Receive_Policy.Message_Error => Message_Error,
         when HTTP_3_Stream_Receive_Policy.Header_Error => Header_Error);

   function Event_For
     (Value : HTTP_3_Stream_Receive_Policy.Event_Kind) return Event_Kind
   is
     (case Value is
         when HTTP_3_Stream_Receive_Policy.No_Event => No_Event,
         when HTTP_3_Stream_Receive_Policy.Settings_Received =>
           Settings_Received,
         when HTTP_3_Stream_Receive_Policy.Headers_Received =>
           Headers_Received,
         when HTTP_3_Stream_Receive_Policy.Data_Received => Data_Received,
         when HTTP_3_Stream_Receive_Policy.Push_Promise_Received =>
           Push_Promise_Received,
         when HTTP_3_Stream_Receive_Policy.QPACK_Data_Received =>
           QPACK_Data_Received);

   procedure Copy_Event
     (ID     : QUIC.Stream_ID;
      Buffer : Ada.Streams.Stream_Element_Array;
      Result : HTTP_3_Stream_Receive_Policy.Receive_Result;
      Output : out Event) is
   begin
      Output := (others => <>);
      Output.Kind := Event_For (Result.Event);
      Output.Stream := ID;
      Output.Headers := Result.Headers;
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
      Result : HTTP_3_Stream_Receive_Policy.Receive_Result;
      Length : QUIC.Stream_Offset;
      ID     : QUIC.Stream_ID;
      Slot   : Optional_Slot;
      Finish : HTTP_3_Stream_Receive_Policy.Receive_Status;
   begin
      Output := (others => <>);
      if not QUIC.Is_Connected (Transport) then
         Status := Not_Connected;
         return;
      end if;

      for Stream_Index in 1 .. QUIC.Stream_Count (Transport) loop
         ID := QUIC.Stream_At (Transport, Stream_Index);
         Find_Or_Open (Item, ID, Slot, Status);
         if Status /= Succeeded then
            return;
         end if;

         loop
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
            HTTP_3_Stream_Receive_Policy.Process
              (Item.Receive, Item.Streams (Slot).State,
               Buffer (1 .. Ada.Streams.Stream_Element_Offset (Length)),
               Result);
            Status := Status_For (Result.Status);
            if Result.Consumed > 0 then
               if Result.Event /= HTTP_3_Stream_Receive_Policy.No_Event then
                  Copy_Event (ID, Buffer, Result, Output);
               end if;
               QUIC.Consume
                 (Transport, ID, QUIC.Stream_Offset (Result.Consumed));
            end if;
            if Status /= Succeeded then
               return;
            elsif Output.Kind /= No_Event then
               return;
            end if;
         end loop;

         if QUIC.Is_Complete (Transport, ID)
           and then not Item.Streams (Slot).Finished
         then
            HTTP_3_Stream_Receive_Policy.Finish
              (Item.Receive, Item.Streams (Slot).State, Finish);
            Item.Streams (Slot).Finished := True;
            Status := Status_For (Finish);
            if Status /= Succeeded then
               return;
            end if;
         end if;
      end loop;
      Status := No_Event;
   end Poll;

   function Has_Peer_Settings (Item : Connection) return Boolean is
     (HTTP_3_Stream_Receive_Policy.Has_Peer_Settings (Item.Receive));
end Flyology.HTTP.HTTP_3_Connection;
