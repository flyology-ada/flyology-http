separate (Flyology.HTTP.Client)
--  Continues an owner-driven HTTP/3 response whose head was produced by the
--  composable exchange engine and transferred to the synchronous Response.
package body HTTP_3_Internals is
   use Ada.Streams;

   Connection_Race_Lost : exception;

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
      Event  : H3.Event;
      Status : H3.Operation_Status;

      procedure Wait_For_Stream is
         Stream_FD   : Flyology.IO.Descriptor;
         Shutdown_FD : Flyology.IO.Descriptor;
         Token_FD    : Flyology.IO.Descriptor :=
           Flyology.IO.Invalid_Descriptor;
         Ready       : Boolean;
         Stopping    : Boolean;
         Cancelled   : Boolean := False;
         Selected    : Natural;
      begin
         H3_Connections.Wait_Source
           (Item.Data.Connection.HTTP_3_Streams,
            Item.Data.HTTP_3_Handle, Stream_FD, Ready);
         if Ready then
            return;
         end if;
         Item.Data.Owner.Pool.Shutdown_Source (Shutdown_FD, Stopping);
         if Stopping then
            raise Client_Closed;
         end if;
         if Token /= null then
            Token.Wait_Source (Token_FD, Cancelled);
            if Cancelled then
               raise Flyology.Cancellation.Operation_Cancelled;
            end if;
         end if;
         if Token = null then
            declare
               Sources : Flyology.IO.Wait_Request_Array (1 .. 2);
            begin
               Sources (1) :=
                 (FD => Stream_FD, Condition => Flyology.IO.For_Read);
               Sources (2) :=
                 (FD => Shutdown_FD, Condition => Flyology.IO.For_Read);
               Selected := Flyology.IO.Wait_Any
                 (Sources,
                  Remaining (Item.Data.Started, Item.Data.Timeout));
            end;
         else
            declare
               Sources : Flyology.IO.Wait_Request_Array (1 .. 3);
            begin
               Sources (1) :=
                 (FD => Stream_FD, Condition => Flyology.IO.For_Read);
               Sources (2) :=
                 (FD => Shutdown_FD, Condition => Flyology.IO.For_Read);
               Sources (3) :=
                 (FD => Token_FD, Condition => Flyology.IO.For_Read);
               Selected := Flyology.IO.Wait_Any
                 (Sources,
                  Remaining (Item.Data.Started, Item.Data.Timeout));
            end;
         end if;
         if Selected = 0 then
            raise Flyology.IO.Timeout_Error;
         elsif Selected = 2 then
            raise Client_Closed;
         elsif Selected = 3 then
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
      end Wait_For_Stream;

      procedure Pump_One is
         Claimed  : Boolean;
         Published : Boolean;
      begin
         H3_Connections.Try_Claim_Pump
           (Item.Data.Connection.HTTP_3_Streams,
            Item.Data.HTTP_3_Handle, Claimed);
         if not Claimed then
            Wait_For_Stream;
            return;
         end if;
         begin
            loop
               H3.Poll
                 (Item.Data.Connection.HTTP_3,
                  Item.Data.Connection.QUIC_Transport, Event, Status);
               if Status = H3.Succeeded then
                  H3_Connections.Publish
                    (Item.Data.Connection.HTTP_3_Streams,
                     Event, Published);
                  if Event.Kind = H3.Goaway_Received then
                     Item.Data.Connection.HTTP_3_Goaway := True;
                  end if;
                  exit;
               elsif Status = H3.No_Event then
                  Receive_One
                    (Item.Data.Owner, Item.Data.Connection,
                     Item.Data.Started, Item.Data.Timeout, Token);
               else
                  H3_Connections.Fail_All
                    (Item.Data.Connection.HTTP_3_Streams);
                  raise Protocol_Error with
                    "HTTP/3 response body failed: " &
                      H3.Operation_Status'Image (Status);
               end if;
            end loop;
         exception
            when others =>
               H3_Connections.Release_Pump
                 (Item.Data.Connection.HTTP_3_Streams,
                  Item.Data.HTTP_3_Handle);
               raise;
         end;
         H3_Connections.Release_Pump
           (Item.Data.Connection.HTTP_3_Streams,
            Item.Data.HTTP_3_Handle);
      end Pump_One;

      procedure Return_Credit_If_Due is
         Claimed : Boolean;
         Packet  : QUIC.Datagram;
         Credit_Status : QUIC.Send_Status;
      begin
         if not HTTP_3_Receive_Credit_Due
           (Item.Data.Connection.all,
            Item.Data.HTTP_3_Decoded_Length,
            Item.Data.HTTP_3_Last_Stream_Credit)
         then
            return;
         end if;
         H3_Connections.Try_Claim_Pump
           (Item.Data.Connection.HTTP_3_Streams,
            Item.Data.HTTP_3_Handle, Claimed);
         if not Claimed then
            return;
         end if;
         begin
            loop
               Build_HTTP_3_Receive_Credit
                 (Item.Data.Connection.all,
                  Item.Data.HTTP_3_Decoded_Length,
                  Item.Data.HTTP_3_Last_Stream_Credit,
                  Now (Item.Data.Connection.all),
                  Packet, Credit_Status);
               exit when Credit_Status = QUIC.Sent;
               if Credit_Status /= QUIC.Congestion_Blocked then
                  raise Protocol_Error with
                    "HTTP/3 receive-credit update failed: " &
                      QUIC.Send_Status'Image (Credit_Status);
               end if;
               Receive_One
                 (Item.Data.Owner, Item.Data.Connection,
                  Item.Data.Started, Item.Data.Timeout, Token);
            end loop;
            Send
              (Item.Data.Owner, Item.Data.Connection, Packet,
               Item.Data.Started, Item.Data.Timeout, Token);
         exception
            when others =>
               H3_Connections.Release_Pump
                 (Item.Data.Connection.HTTP_3_Streams,
                  Item.Data.HTTP_3_Handle);
               raise;
         end;
         H3_Connections.Release_Pump
           (Item.Data.Connection.HTTP_3_Streams,
            Item.Data.HTTP_3_Handle);
      end Return_Credit_If_Due;
   begin
      Last := Data'First - 1;
      Finished := False;
      if Item.Data.HTTP_3_Handle /= H3_Connections.No_Stream then
         loop
            declare
               Body_State : H3_Connections.Body_Result;
            begin
               H3_Connections.Read
                 (Item.Data.Connection.HTTP_3_Streams,
                  Item.Data.HTTP_3_Handle, Data, Last, Finished,
                  Body_State, Item.Data.Trailers);
               case Body_State is
                  when H3_Connections.Body_Progress =>
                     if Last >= Data'First then
                        Item.Data.HTTP_3_Decoded_Length :=
                          Item.Data.HTTP_3_Decoded_Length +
                            QUIC.Stream_Offset (Last - Data'First + 1);
                     end if;
                     Return_Credit_If_Due;
                     return;
                  when H3_Connections.Body_Finished =>
                     if Last >= Data'First then
                        Item.Data.HTTP_3_Decoded_Length :=
                          Item.Data.HTTP_3_Decoded_Length +
                            QUIC.Stream_Offset (Last - Data'First + 1);
                     end if;
                     Return_Credit_If_Due;
                     H3_Connections.Release_Stream
                       (Item.Data.Connection.HTTP_3_Streams,
                        Item.Data.HTTP_3_Handle);
                     Item.Data.HTTP_3_Handle := H3_Connections.No_Stream;
                     Release_Lease
                       (Item.Data.all,
                        not Item.Data.Request_Incomplete
                          and then Is_Usable (Item.Data.Connection));
                     return;
                  when H3_Connections.Body_Would_Block =>
                     Pump_One;
                  when H3_Connections.Body_Connection_Failed |
                       H3_Connections.Body_Stream_Failed =>
                     H3_Connections.Release_Stream
                       (Item.Data.Connection.HTTP_3_Streams,
                        Item.Data.HTTP_3_Handle);
                     Item.Data.HTTP_3_Handle := H3_Connections.No_Stream;
                     Release_Lease (Item.Data.all, False);
                     raise Protocol_Error with
                       "HTTP/3 response stream failed before body completion";
               end case;
            end;
         end loop;
      end if;
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
              (Item.Data.all,
               not Item.Data.Request_Incomplete
                 and then Is_Usable (Item.Data.Connection));
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
