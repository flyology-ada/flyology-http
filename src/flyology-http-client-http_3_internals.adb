separate (Flyology.HTTP.Client)
--  Drives one exclusive, sequential HTTP/3 connection through the same
--  synchronous request and response API as the HTTP/1 and HTTP/2 engines.
package body HTTP_3_Internals is
   use Ada.Streams;

   ALPN : constant Stream_Element_Array := Byte_Array ("h3");
   Request_Chunk_Size : constant Positive := 1_024;
   Maximum_Retained_Request : constant Natural := 16_384;

   function Now (Item : Pooled_Connection) return QUIC.Timestamp is
      Elapsed : constant Duration := Ada.Real_Time.To_Duration
        (Ada.Real_Time.Clock - Item.HTTP_3_Epoch);
   begin
      return QUIC.Timestamp (Long_Long_Integer (Elapsed * 1_000_000.0));
   end Now;

   procedure Interrupts
     (State   : not null Client_State_Access;
      Token   : access Flyology.Cancellation.Token;
      Race_Token : access Flyology.Cancellation.Token;
      Sources : out Flyology.IO.Interrupt_Set;
      Count   : out Natural)
   is
      FD        : Flyology.IO.Descriptor;
      Requested : Boolean;
   begin
      Count := 0;
      State.Pool.Shutdown_Source (FD, Requested);
      if Requested then
         raise Client_Closed;
      end if;
      Count := Count + 1;
      Sources (Sources'First) := FD;
      if Token /= null then
         Token.Wait_Source (FD, Requested);
         if Requested then
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         Count := Count + 1;
         Sources (Sources'First + 1) := FD;
      end if;
      if Race_Token /= null then
         Race_Token.Wait_Source (FD, Requested);
         if Requested then
            raise Connection_Race_Lost;
         end if;
         Count := Count + 1;
         Sources (Sources'First + Count - 1) := FD;
      end if;
   end Interrupts;

   procedure Translate_Interrupt
     (State : not null Client_State_Access;
      Token : access Flyology.Cancellation.Token;
      Race_Token : access Flyology.Cancellation.Token)
   is
      FD        : Flyology.IO.Descriptor;
      Requested : Boolean;
   begin
      State.Pool.Shutdown_Source (FD, Requested);
      if Requested then
         raise Client_Closed;
      elsif Token /= null and then Token.Requested then
         raise Flyology.Cancellation.Operation_Cancelled;
      elsif Race_Token /= null and then Race_Token.Requested then
         raise Connection_Race_Lost;
      else
         raise Flyology.Cancellation.Operation_Cancelled;
      end if;
   end Translate_Interrupt;

   procedure Send_Bytes
     (State      : not null Client_State_Access;
      Connection : not null Pooled_Connection_Access;
      Data       : Stream_Element_Array;
      Started    : Ada.Real_Time.Time;
      Timeout    : Duration;
      Token      : access Flyology.Cancellation.Token;
      Race_Token : access Flyology.Cancellation.Token := null)
   is
      Last    : Stream_Element_Offset;
      Sources : Flyology.IO.Interrupt_Set (1 .. 3);
      Count   : Natural;
   begin
      Interrupts (State, Token, Race_Token, Sources, Count);
      Sockets.Send
        (Connection.UDP, Data, Last, Remaining (Started, Timeout),
         Sources (1 .. Count));
      if Last /= Data'Last then
         raise Flyology.IO.Device_Error with "partial HTTP/3 datagram send";
      end if;
   exception
      when Sockets.Operation_Interrupted =>
         Translate_Interrupt (State, Token, Race_Token);
   end Send_Bytes;

   procedure Send
     (State      : not null Client_State_Access;
      Connection : not null Pooled_Connection_Access;
      Packet     : QUIC.Datagram;
      Started    : Ada.Real_Time.Time;
      Timeout    : Duration;
      Token      : access Flyology.Cancellation.Token;
      Race_Token : access Flyology.Cancellation.Token := null) is
   begin
      if Packet.Length > 0 then
         Send_Bytes
           (State, Connection,
            Packet.Data (1 .. Stream_Element_Offset (Packet.Length)),
            Started, Timeout, Token, Race_Token);
      end if;
   end Send;

   procedure Send
     (State      : not null Client_State_Access;
      Connection : not null Pooled_Connection_Access;
      Flight     : QUIC.Datagram_Batch;
      Started    : Ada.Real_Time.Time;
      Timeout    : Duration;
      Token      : access Flyology.Cancellation.Token;
      Race_Token : access Flyology.Cancellation.Token := null) is
   begin
      for Index in 1 .. Flight.Count loop
         Send
           (State, Connection, Flight.Items (Index), Started, Timeout, Token,
            Race_Token);
      end loop;
   end Send;

   function Receive_Timeout
     (Connection : Pooled_Connection; Maximum : Duration) return Duration
   is
      Result  : Duration := Maximum;
      Current : constant QUIC.Timestamp := Now (Connection);
   begin
      if QUIC.Has_Recovery_Timeout (Connection.QUIC_Transport) then
         declare
            Deadline : constant QUIC.Timestamp :=
              QUIC.Recovery_Deadline (Connection.QUIC_Transport);
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

   procedure Process_Recovery
     (State      : not null Client_State_Access;
      Connection : not null Pooled_Connection_Access;
      Started    : Ada.Real_Time.Time;
      Timeout    : Duration;
      Token      : access Flyology.Cancellation.Token;
      Race_Token : access Flyology.Cancellation.Token := null)
   is
      Flight : QUIC.Datagram_Batch;
      Status : QUIC.Timeout_Status;
   begin
      QUIC.Process_Timeout
        (Connection.QUIC_Transport, Now (Connection.all), Flight, Status);
      case Status is
         when QUIC.Probes_Ready =>
            Send
              (State, Connection, Flight, Started, Timeout, Token,
               Race_Token);
         when QUIC.Not_Due | QUIC.No_Pending_Recovery =>
            null;
         when others =>
            raise Flyology.IO.Device_Error with
              "QUIC recovery failed: " & QUIC.Timeout_Status'Image (Status);
      end case;
   end Process_Recovery;

   procedure Receive_One
     (State      : not null Client_State_Access;
      Connection : not null Pooled_Connection_Access;
      Started    : Ada.Real_Time.Time;
      Timeout    : Duration;
      Token      : access Flyology.Cancellation.Token;
      Race_Token : access Flyology.Cancellation.Token := null)
   is
      Packet  : Stream_Element_Array (1 .. QUIC.Max_Datagram_Length);
      Last    : Stream_Element_Offset;
      Flight  : QUIC.Datagram_Batch;
      Status  : QUIC.Operation_Status;
      Sources : Flyology.IO.Interrupt_Set (1 .. 3);
      Count   : Natural;
      Wait    : constant Duration := Receive_Timeout
        (Connection.all, Remaining (Started, Timeout));
   begin
      Interrupts (State, Token, Race_Token, Sources, Count);
      begin
         Sockets.Receive
           (Connection.UDP, Packet, Last, Wait, Sources (1 .. Count));
      exception
         when Flyology.IO.Timeout_Error =>
            if QUIC.Has_Recovery_Timeout (Connection.QUIC_Transport)
              and then QUIC.Recovery_Deadline (Connection.QUIC_Transport) <=
                Now (Connection.all)
            then
               Process_Recovery
                 (State, Connection, Started, Timeout, Token, Race_Token);
               return;
            end if;
            raise;
         when Sockets.Operation_Interrupted =>
            Translate_Interrupt (State, Token, Race_Token);
      end;
      if Last < Packet'First then
         return;
      end if;
      QUIC.Process_Datagram
        (Connection.QUIC_Transport, Packet (Packet'First .. Last), Flight,
         Status, Now (Connection.all));
      case Status is
         when QUIC.Succeeded | QUIC.Waiting_For_More =>
            Send
              (State, Connection, Flight, Started, Timeout, Token,
               Race_Token);
         when QUIC.Connection_Closed =>
            raise Protocol_Error with "HTTP/3 peer closed the QUIC connection";
         when others =>
            raise Protocol_Error with
              "QUIC receive failed: " & QUIC.Operation_Status'Image (Status);
      end case;
   end Receive_One;

   procedure Start_Connection
     (State      : not null Client_State_Access;
      Connection : not null Pooled_Connection_Access;
      Started    : Ada.Real_Time.Time;
      Timeout    : Duration;
      Token      : access Flyology.Cancellation.Token;
      Race_Token : access Flyology.Cancellation.Token := null)
   is
      Destination : constant QUIC.Connection_ID := QUIC.Random_Connection_ID;
      Source      : constant QUIC.Connection_ID := QUIC.Random_Connection_ID;
      Flight      : QUIC.Datagram_Batch;
      Status      : QUIC.Operation_Status;
      H3_Status   : H3.Operation_Status;
      Control     : QUIC.Datagram;
   begin
      Connection.Protocol := HTTP_3_Transport;
      Connection.HTTP_3_Epoch := Ada.Real_Time.Clock;
      QUIC.Initialize_Client
        (Connection.QUIC_Transport,
         ALPN,
         QUIC.Transport_Settings'(others => <>),
         Flyology.Bytes.To_Array (State.HTTP_3_Certificate),
         Destination.Data (1 .. Stream_Element_Offset (Destination.Length)),
         Destination,
         Source);
      QUIC.Start_Client (Connection.QUIC_Transport, Flight, Status);
      if Status /= QUIC.Succeeded then
         raise Protocol_Error with
           "QUIC client start failed: " & QUIC.Operation_Status'Image (Status);
      end if;
      Send
        (State, Connection, Flight, Started, Timeout, Token, Race_Token);
      while not QUIC.Is_Connected (Connection.QUIC_Transport) loop
         Receive_One
           (State, Connection, Started, Timeout, Token, Race_Token);
      end loop;
      H3.Initialize (Connection.HTTP_3, H3.Client);
      H3.Start
        (Connection.HTTP_3, Connection.QUIC_Transport,
         Now (Connection.all), Control, H3_Status);
      if H3_Status /= H3.Succeeded then
         raise Protocol_Error with
           "HTTP/3 session start failed: " &
             H3.Operation_Status'Image (H3_Status);
      end if;
      Send
        (State, Connection, Control, Started, Timeout, Token, Race_Token);
   end Start_Connection;

   procedure Await_Send_Credit
     (Data   : in out Response_Data;
      Packet : out QUIC.Datagram;
      Status : in out H3.Operation_Status;
      Token  : access Flyology.Cancellation.Token;
      Send_Operation : not null access procedure
        (Packet : out QUIC.Datagram; Status : out H3.Operation_Status))
   is
   begin
      loop
         Send_Operation (Packet, Status);
         exit when Status /= H3.Transport_Blocked;
         Receive_One
           (Data.Owner, Data.Connection, Data.Started, Data.Timeout, Token);
      end loop;
   end Await_Send_Credit;

   procedure Execute_Request
     (Data            : in out Response_Data;
      Value           : Request;
      Authority       : String;
      Retained_Length : Natural;
      Token           : access Flyology.Cancellation.Token)
   is
      Headers   : H3.Header_Block;
      Stream    : QUIC.Stream_ID;
      Packet    : QUIC.Datagram;
      Status    : H3.Operation_Status;
      Event_Value : HTTP_3_Event_Access;

      procedure Add (Name, Field_Value : String) is
      begin
         if H3.Header_Count (Headers) = H3.Max_Fields then
            raise Flyology.HTTP.Headers.Headers_Too_Large;
         end if;
         H3.Append (Headers, H3.Make_Field (Name, Field_Value));
      end Add;

      procedure Send_Head
        (Output : out QUIC.Datagram; Result : out H3.Operation_Status) is
      begin
         H3.Send_Headers
           (Data.Connection.HTTP_3, Data.Connection.QUIC_Transport, Stream,
            Headers, Fin => Retained_Length = 0,
            Now => Now (Data.Connection.all),
            Packet => Output, Status => Result);
      end Send_Head;
   begin
      if Data.Connection.HTTP_3_Event = null then
         Data.Connection.HTTP_3_Event := new H3.Event;
      end if;
      Event_Value := Data.Connection.HTTP_3_Event;
      if Value.Expect_Continue then
         raise Constraint_Error with
           "HTTP/3 Expect: 100-continue is not yet supported";
      elsif Retained_Length > Maximum_Retained_Request then
         raise Request_Body_Error with
           "HTTP/3 retained request exceeds current 16384-byte stream credit";
      end if;
      Add (":method", Image (Value.Method_Value));
      Add (":scheme", "https");
      Add (":path", To_String (Value.Target_Value));
      Add (":authority", Authority);
      for Index in 1 .. Flyology.HTTP.Headers.Count (Value.Fields) loop
         Add
           (Ada.Characters.Handling.To_Lower
              (Flyology.HTTP.Headers.Name (Value.Fields, Index)),
            Flyology.HTTP.Headers.Value (Value.Fields, Index));
      end loop;
      if Retained_Length > 0 then
         Add ("content-length", Decimal (Retained_Length));
      end if;

      loop
         H3.Open_Request
           (Data.Connection.HTTP_3, Data.Connection.QUIC_Transport,
            Stream, Status);
         exit when Status /= H3.Stream_Limit_Reached;
         Receive_One
           (Data.Owner, Data.Connection, Data.Started, Data.Timeout, Token);
      end loop;
      if Status /= H3.Succeeded then
         raise Protocol_Error with
           "HTTP/3 request stream open failed: " &
             H3.Operation_Status'Image (Status);
      end if;
      Data.Engine := HTTP_3_Response;
      Data.HTTP_3_Stream := Stream;
      Await_Send_Credit
        (Data, Packet, Status, Token, Send_Head'Access);
      if Status /= H3.Succeeded then
         raise Protocol_Error with
           "HTTP/3 request headers failed: " &
             H3.Operation_Status'Image (Status);
      end if;
      Send
        (Data.Owner, Data.Connection, Packet, Data.Started, Data.Timeout,
         Token);

      if Retained_Length > 0 then
         declare
            Payload : constant Stream_Element_Array :=
              Flyology.Bytes.To_Array (Value.Body_Value);
            Cursor : Stream_Element_Offset := Payload'First;
         begin
            while Cursor <= Payload'Last loop
               declare
                  Last : constant Stream_Element_Offset :=
                    Stream_Element_Offset'Min
                      (Payload'Last,
                       Cursor +
                         Stream_Element_Offset (Request_Chunk_Size - 1));
                  Final : constant Boolean := Last = Payload'Last;
                  procedure Send_Chunk
                    (Output : out QUIC.Datagram;
                     Result : out H3.Operation_Status) is
                  begin
                     H3.Send_Data
                       (Data.Connection.HTTP_3,
                        Data.Connection.QUIC_Transport,
                        Stream, Payload (Cursor .. Last), Final,
                        Now (Data.Connection.all), Output, Result);
                  end Send_Chunk;
               begin
                  Await_Send_Credit
                    (Data, Packet, Status, Token, Send_Chunk'Access);
                  if Status /= H3.Succeeded then
                     raise Protocol_Error with
                       "HTTP/3 request data failed: " &
                         H3.Operation_Status'Image (Status);
                  end if;
                  Send
                    (Data.Owner, Data.Connection, Packet, Data.Started,
                     Data.Timeout, Token);
                  Cursor := Last + 1;
               end;
            end loop;
         end;
      end if;

      loop
         declare
            Event : H3.Event renames Event_Value.all;
            Code  : Natural := 0;
            Has_Status : Boolean := False;
         begin
            H3.Poll
              (Data.Connection.HTTP_3, Data.Connection.QUIC_Transport,
               Event, Status);
            if Status = H3.No_Event then
               Receive_One
                 (Data.Owner, Data.Connection, Data.Started, Data.Timeout,
                  Token);
            elsif Status /= H3.Succeeded then
               raise Protocol_Error with
                 "HTTP/3 response failed: " &
                   H3.Operation_Status'Image (Status);
            elsif Event.Kind = H3.Goaway_Received then
               Data.Connection.HTTP_3_Goaway := True;
            elsif Event.Stream = Stream
              and then Event.Kind = H3.Headers_Received
            then
               for Index in 1 .. H3.Header_Count (Event.Headers) loop
                  declare
                     Field : constant H3.Header_Field :=
                       H3.Field_At (Event.Headers, Index);
                     Name  : constant String := H3.Field_Name (Field);
                     Field_Value : constant String := H3.Field_Value (Field);
                  begin
                     if Name = ":status" then
                        if Field_Value'Length /= 3
                          or else
                            (for some Character_Value of Field_Value =>
                               Character_Value not in '0' .. '9')
                        then
                           raise Protocol_Error with
                             "invalid HTTP/3 response status";
                        end if;
                        Code := Natural'Value (Field_Value);
                        Has_Status := True;
                     elsif Name (Name'First) = ':' then
                        raise Protocol_Error with
                          "unexpected HTTP/3 response pseudo-field";
                     else
                        Flyology.HTTP.Headers.Add
                          (Data.Fields, Name, Field_Value);
                     end if;
                  end;
               end loop;
               if not Has_Status or else Code not in 100 .. 599 then
                  raise Protocol_Error with "missing HTTP/3 response status";
               elsif Code < 200 then
                  Flyology.HTTP.Headers.Clear (Data.Fields);
                  Data.Informational_Count := Next_Informational_Count
                    (Data.Informational_Count);
               else
                  Data.Status_Value := Status_Code (Code);
                  Data.Protocol_Value := HTTP_3_Protocol;
                  Data.Saw_Response_Bytes := True;
                  return;
               end if;
            elsif Event.Stream = Stream
              and then Event.Kind in H3.Data_Received | H3.Stream_Ended
            then
               raise Protocol_Error with
                 "HTTP/3 response body preceded final headers";
            elsif Event.Stream = Stream and then Event.Kind = H3.Stream_Reset
            then
               raise Protocol_Error with "HTTP/3 request stream was reset";
            end if;
         end;
      end loop;
   end Execute_Request;

   procedure Copy_Pending
     (Item : in out Response_Data;
      Data : out Stream_Element_Array;
      Last : out Stream_Element_Offset)
   is
      Available : constant Natural :=
        Flyology.Bytes.Length (Item.HTTP_3_Pending) -
          Item.HTTP_3_Pending_Offset;
      Count : constant Natural := Natural'Min (Available, Data'Length);
   begin
      Last := Data'First - 1;
      if Count > 0 then
         for Offset in 0 .. Count - 1 loop
            Data (Data'First + Stream_Element_Offset (Offset)) :=
              Flyology.Bytes.Element
                (Item.HTTP_3_Pending,
                 Item.HTTP_3_Pending_Offset + Offset + 1);
         end loop;
         Last := Data'First + Stream_Element_Offset (Count) - 1;
         Item.HTTP_3_Pending_Offset := Item.HTTP_3_Pending_Offset + Count;
      end if;
      if Item.HTTP_3_Pending_Offset =
        Flyology.Bytes.Length (Item.HTTP_3_Pending)
      then
         Flyology.Bytes.Clear (Item.HTTP_3_Pending);
         Item.HTTP_3_Pending_Offset := 0;
      end if;
   end Copy_Pending;

   function Is_Usable
     (Connection : Pooled_Connection_Access) return Boolean is
     (Connection /= null
        and then QUIC.State (Connection.QUIC_Transport) = QUIC.Connected
        and then not Connection.HTTP_3_Goaway);

   procedure Read_Response_Body
     (Item     : in out Response;
      Data     : out Stream_Element_Array;
      Last     : out Stream_Element_Offset;
      Finished : out Boolean;
      Token    : access Flyology.Cancellation.Token)
   is
      Event_Value : constant HTTP_3_Event_Access :=
        Item.Data.Connection.HTTP_3_Event;
      Event  : H3.Event renames Event_Value.all;
      Status : H3.Operation_Status;
   begin
      Last := Data'First - 1;
      Finished := False;
      if Flyology.Bytes.Length (Item.Data.HTTP_3_Pending) > 0 then
         Copy_Pending (Item.Data.all, Data, Last);
         return;
      end if;
      loop
         H3.Poll
           (Item.Data.Connection.HTTP_3,
            Item.Data.Connection.QUIC_Transport, Event, Status);
         if Status = H3.No_Event then
            Receive_One
              (Item.Data.Owner, Item.Data.Connection, Item.Data.Started,
               Item.Data.Timeout, Token);
         elsif Status /= H3.Succeeded then
            raise Protocol_Error with
              "HTTP/3 response body failed: " &
                H3.Operation_Status'Image (Status);
         elsif Event.Kind = H3.Goaway_Received then
            Item.Data.Connection.HTTP_3_Goaway := True;
         elsif Event.Stream = Item.Data.HTTP_3_Stream
           and then Event.Kind = H3.Data_Received
         then
            if Event.Data_Length > 0 then
               Flyology.Bytes.Append
                 (Item.Data.HTTP_3_Pending,
                  Event.Data (1 .. Stream_Element_Offset (Event.Data_Length)));
               Copy_Pending (Item.Data.all, Data, Last);
               return;
            end if;
         elsif Event.Stream = Item.Data.HTTP_3_Stream
           and then Event.Kind = H3.Headers_Received
         then
            for Index in 1 .. H3.Header_Count (Event.Headers) loop
               declare
                  Field : constant H3.Header_Field :=
                    H3.Field_At (Event.Headers, Index);
                  Name : constant String := H3.Field_Name (Field);
               begin
                  if Name (Name'First) = ':' then
                     raise Protocol_Error with
                       "pseudo-field in HTTP/3 response trailers";
                  end if;
                  Flyology.HTTP.Headers.Add
                    (Item.Data.Trailers, Name, H3.Field_Value (Field));
               end;
            end loop;
         elsif Event.Stream = Item.Data.HTTP_3_Stream
           and then Event.Kind = H3.Stream_Ended
         then
            Item.Data.HTTP_3_Stream_Ended := True;
            Release_Lease
              (Item.Data.all, Is_Usable (Item.Data.Connection));
            Finished := True;
            return;
         elsif Event.Stream = Item.Data.HTTP_3_Stream
           and then Event.Kind = H3.Stream_Reset
         then
            Release_Lease (Item.Data.all, False);
            raise Protocol_Error with "HTTP/3 response stream was reset";
         end if;
      end loop;
   end Read_Response_Body;
end HTTP_3_Internals;
