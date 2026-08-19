with Flyology.QUIC.ACK_Frame_Policy;
with Flyology.QUIC.ACK_Range_Policy;
with Flyology.QUIC.Crypto_Frame_Policy;
with Flyology.QUIC.Initial_Frame_Policy;

package body Flyology.QUIC.Initial_Space is
   use type Ada.Streams.Stream_Element_Offset;
   use type ACK_Frame_Policy.Encode_Status;
   use type ACK_Range_Policy.Decode_Status;
   use type Crypto_Frame_Policy.Encode_Status;
   use type Crypto_Reassembly_Policy.Insert_Status;
   use type Crypto_Flight.Retain_Status;
   use type Initial_Connection.Build_Status;
   use type Initial_Connection.Endpoint_Role;
   use type Initial_Connection.Process_Status;
   use type Initial_Frame_Policy.Frame_Kind;
   use type Initial_Frame_Policy.Parse_Status;
   use type Sent_Packet_Policy.Apply_Status;
   use type Sent_Packet_Policy.Event_Kind;
   use type Sent_Packet_Policy.Record_Status;
   use type Varint_Policy.Value_Type;

   --  One CRYPTO range plus a bounded ACK frame ahead of it.
   Max_ACK_Prefix : constant := 128;
   Max_Plaintext  : constant :=
     Max_Crypto_Payload + 17 + Max_ACK_Prefix;

   --  PING followed by PADDING. Header protection samples sixteen octets from
   --  four bytes past the packet number, so a bare one-octet probe has too
   --  little protected payload to be sent.
   Ping_Frame : constant Ada.Streams.Stream_Element_Array (1 .. 8) :=
     (1 => 16#01#, others => 16#00#);

   function Is_Initialized (Item : State) return Boolean is
     (Item.Initialized);

   function Needs_ACK (Item : State) return Boolean is
     (Item.ACK_Owed);

   function Has_Unacknowledged (Item : State) return Boolean is
     (Crypto_Flight.Has_Pending (Item.Outgoing) or else Item.Ping_Sent);

   function Contiguous_Length
     (Item : State) return Crypto_Reassembly_Policy.Stream_Offset is
     (Crypto_Reassembly_Policy.Contiguous_Length (Item.Crypto));

   function Crypto_Element
     (Item  : State;
      Index : Crypto_Reassembly_Policy.Stream_Index)
      return Ada.Streams.Stream_Element is
     (Crypto_Reassembly_Policy.Element (Item.Crypto, Index));

   --  The sent-packet ledger keeps QUIC's strictly sequential packet numbers
   --  and is never reset while the space can still send, so retirement is
   --  recorded on the retained flight instead.
   procedure Acknowledge_Flight (Item : in out State) is
   begin
      Crypto_Flight.Acknowledge_All (Item.Outgoing);
      Item.Ping_Sent := False;
   end Acknowledge_Flight;

   procedure Initialize
     (Item                    : in out State;
      Role                    : Initial_Connection.Endpoint_Role;
      Original_Destination_ID : Ada.Streams.Stream_Element_Array;
      Destination             : Long_Header_Policy.Connection_ID;
      Source                  : Long_Header_Policy.Connection_ID) is
   begin
      Initial_Connection.Initialize
        (Item.Packets, Role, Original_Destination_ID, Destination, Source);
      Crypto_Reassembly_Policy.Reset (Item.Crypto);
      Sent_Packet_Policy.Reset (Item.Sent);
      Crypto_Flight.Reset (Item.Outgoing);
      Item.ACK_Owed := False;
      Item.Ping_Sent := False;
      Item.Role := Role;
      Item.Initialized := True;
   end Initialize;

   function Build_Status_For
     (Status : Initial_Connection.Build_Status) return Build_Status is
     (case Status is
         when Initial_Connection.Built => Built,
         when Initial_Connection.Packet_Number_Exhausted =>
           Packet_Number_Exhausted,
         when Initial_Connection.Packet_Number_Unrepresentable =>
           Packet_Number_Unrepresentable,
         when Initial_Connection.Insufficient_Protected_Payload
            | Initial_Connection.Packet_Too_Large => Packet_Too_Large,
         when Initial_Connection.Output_Too_Small => Output_Too_Small);

   --  Prefix Frame with an ACK when this space owes one and the combined
   --  plaintext still fits.
   procedure Compose
     (Item     : in out State;
      Frame    : Ada.Streams.Stream_Element_Array;
      Data     : out Ada.Streams.Stream_Element_Array;
      Length   : out Natural;
      Included : out Boolean)
   is
      ACK : ACK_Frame_Policy.Encode_Result;
   begin
      Data := (others => 0);
      Length := 0;
      Included := False;
      if Item.ACK_Owed then
         ACK := Initial_Connection.Encode_ACK (Item.Packets, ACK_Delay => 0);
         if ACK.Status = ACK_Frame_Policy.Encoded
           and then ACK.Length <= Max_ACK_Prefix
           and then Ada.Streams.Stream_Element_Offset
             (ACK.Length) + Frame'Length <= Data'Length
         then
            Data (Data'First .. Data'First
                    + Ada.Streams.Stream_Element_Offset (ACK.Length) - 1) :=
              ACK.Data (1 .. Ada.Streams.Stream_Element_Offset (ACK.Length));
            Length := ACK.Length;
            Included := True;
         end if;
      end if;
      if Frame'Length > 0 then
         Data (Data'First + Ada.Streams.Stream_Element_Offset (Length)
                 .. Data'First + Ada.Streams.Stream_Element_Offset (Length)
                      + Frame'Length - 1) := Frame;
         Length := Length + Natural (Frame'Length);
      end if;
   end Compose;

   --  Build one ack-eliciting Initial and account for it in the ledger. The
   --  caller retains or rebinds any CRYPTO range the packet carries.
   procedure Emit
     (Item          : in out State;
      Plaintext     : Ada.Streams.Stream_Element_Array;
      ACK_Included  : Boolean;
      ACK_Eliciting : Boolean;
      Now           : Timestamp;
      Packet        : out Ada.Streams.Stream_Element_Array;
      Result        : out Build_Result)
   is
      Built_Packet  : Initial_Connection.Build_Result;
      Record_Status : Sent_Packet_Policy.Record_Status;
      Minimum : constant Natural :=
        (if Item.Role = Initial_Connection.Client then 1_200 else 0);
   begin
      Result := (others => <>);
      if ACK_Eliciting
        and then Sent_Packet_Policy.Retained (Item.Sent) =
          Sent_Packet_Policy.Max_Sent_Packets
      then
         Packet := (others => 0);
         Result.Status := Recovery_Capacity_Exceeded;
         return;
      end if;
      Initial_Connection.Build_Initial_At_Least
        (Item.Packets, (1 .. 0 => 0), Plaintext, Minimum, Packet,
         Built_Packet);
      Result.Number := Built_Packet.Number;
      Result.Status := Build_Status_For (Built_Packet.Status);
      if Built_Packet.Status /= Initial_Connection.Built then
         return;
      end if;
      Result.Packet_Length := Built_Packet.Packet_Length;
      Sent_Packet_Policy.Record_Sent
        (Item.Sent,
         (Number        => Built_Packet.Number,
          Sent_At       => Now,
          Bytes         => Sent_Packet_Policy.Packet_Byte_Count
            (Built_Packet.Packet_Length),
          ACK_Eliciting => ACK_Eliciting,
          In_Flight     => ACK_Eliciting),
         Record_Status);
      if (ACK_Eliciting and then Record_Status /= Sent_Packet_Policy.Recorded)
        or else
          (not ACK_Eliciting
           and then Record_Status /= Sent_Packet_Policy.Not_Tracked)
      then
         Result.Status := Recovery_Capacity_Exceeded;
         return;
      end if;
      if ACK_Included then
         Item.ACK_Owed := False;
      end if;
   end Emit;

   procedure Build_Crypto_Packet
     (Item   : in out State;
      Offset : Varint_Policy.Value_Type;
      Data   : Ada.Streams.Stream_Element_Array;
      Now    : Timestamp;
      Packet : out Ada.Streams.Stream_Element_Array;
      Result : out Build_Result)
   is
      Frame : constant Crypto_Frame_Policy.Encode_Result :=
        Crypto_Frame_Policy.Encode (Offset, Data);
      Plaintext : Ada.Streams.Stream_Element_Array (1 .. Max_Plaintext);
      Length    : Natural;
      Included  : Boolean;
      Retained  : Crypto_Flight.Retain_Status;
   begin
      Packet := (others => 0);
      Result := (others => <>);
      if Frame.Status /= Crypto_Frame_Policy.Encoded then
         Result.Status := Crypto_Range_Too_Large;
         return;
      elsif not Crypto_Flight.Can_Retain
        (Item.Outgoing, Offset, Data'Length)
      then
         --  Refuse before sending. A packet whose CRYPTO range cannot be
         --  retained could never be retransmitted on a probe timeout.
         Result.Status := Crypto_Retention_Exceeded;
         return;
      end if;
      Compose
        (Item,
         Frame.Data (1 .. Ada.Streams.Stream_Element_Offset (Frame.Length)),
         Plaintext, Length, Included);
      Emit
        (Item, Plaintext (1 .. Ada.Streams.Stream_Element_Offset (Length)),
         Included, ACK_Eliciting => True, Now => Now, Packet => Packet,
         Result => Result);
      if Result.Status /= Built then
         return;
      end if;
      Crypto_Flight.Retain
        (Item.Outgoing, Result.Number, Offset, Data, Retained);
      pragma Assert (Retained = Crypto_Flight.Retained);
   end Build_Crypto_Packet;

   procedure Build_ACK_Packet
     (Item   : in out State;
      Now    : Timestamp;
      Packet : out Ada.Streams.Stream_Element_Array;
      Result : out Build_Result)
   is
      Plaintext : Ada.Streams.Stream_Element_Array (1 .. Max_Plaintext);
      Length    : Natural;
      Included  : Boolean;
   begin
      Packet := (others => 0);
      Result := (others => <>);
      Compose (Item, (1 .. 0 => 0), Plaintext, Length, Included);
      if not Included then
         Result.Status := Nothing_To_ACK;
         return;
      end if;
      Emit
        (Item, Plaintext (1 .. Ada.Streams.Stream_Element_Offset (Length)),
         Included, ACK_Eliciting => False, Now => Now, Packet => Packet,
         Result => Result);
   end Build_ACK_Packet;

   procedure Build_Probe_Packet
     (Item   : in out State;
      Index  : Positive;
      Now    : Timestamp;
      Packet : out Ada.Streams.Stream_Element_Array;
      Result : out Build_Result)
   is
      Chunk     : Crypto_Flight.Chunk_Count :=
        Crypto_Flight.First_Pending (Item.Outgoing);
      Plaintext : Ada.Streams.Stream_Element_Array (1 .. Max_Plaintext);
      Length    : Natural;
      Included  : Boolean;
   begin
      Packet := (others => 0);
      Result := (others => <>);
      for Skipped in 2 .. Index loop
         exit when Chunk = 0;
         Chunk := Crypto_Flight.Next_Pending (Item.Outgoing, Chunk);
      end loop;

      if Chunk = 0 then
         Result.Status := Nothing_To_ACK;
         return;
      end if;

      declare
         Size : constant Ada.Streams.Stream_Element_Offset :=
           Crypto_Flight.Length (Item.Outgoing, Chunk);
         Data : Ada.Streams.Stream_Element_Array (1 .. Size);
         Frame : Crypto_Frame_Policy.Encode_Result;
      begin
         Crypto_Flight.Copy (Item.Outgoing, Chunk, Data);
         Frame := Crypto_Frame_Policy.Encode
           (Crypto_Flight.Offset (Item.Outgoing, Chunk), Data);
         if Frame.Status /= Crypto_Frame_Policy.Encoded then
            Result.Status := Crypto_Range_Too_Large;
            return;
         end if;
         Compose
           (Item,
            Frame.Data (1 .. Ada.Streams.Stream_Element_Offset (Frame.Length)),
            Plaintext, Length, Included);
         Emit
           (Item, Plaintext (1 .. Ada.Streams.Stream_Element_Offset (Length)),
            Included, ACK_Eliciting => True, Now => Now, Packet => Packet,
            Result => Result);
         if Result.Status = Built then
            Crypto_Flight.Rebind (Item.Outgoing, Chunk, Result.Number);
         end if;
      end;
   end Build_Probe_Packet;

   procedure Build_Ping_Packet
     (Item   : in out State;
      Now    : Timestamp;
      Packet : out Ada.Streams.Stream_Element_Array;
      Result : out Build_Result)
   is
      Plaintext : Ada.Streams.Stream_Element_Array (1 .. Max_Plaintext);
      Length    : Natural;
      Included  : Boolean;
   begin
      Packet := (others => 0);
      Result := (others => <>);
      Compose (Item, Ping_Frame, Plaintext, Length, Included);
      Emit
        (Item, Plaintext (1 .. Ada.Streams.Stream_Element_Offset (Length)),
         Included, ACK_Eliciting => True, Now => Now, Packet => Packet,
         Result => Result);
      if Result.Status = Built then
         Item.Ping_Sent := True;
      end if;
   end Build_Ping_Packet;

   procedure Build_Transport_Close_Packet
     (Item       : in out State;
      Error_Code : Varint_Policy.Value_Type;
      Frame_Type : Varint_Policy.Value_Type;
      Packet     : out Ada.Streams.Stream_Element_Array;
      Result     : out Build_Result)
   is
      Frame : constant Initial_Frame_Policy.Transport_Close_Encode_Result :=
        Initial_Frame_Policy.Encode_Transport_Close (Error_Code, Frame_Type);
      Built_Packet  : Initial_Connection.Build_Result;
      Record_Status : Sent_Packet_Policy.Record_Status;
      --  RFC 9000 14.1 has a server discard any client Initial packet whose
      --  datagram payload is under 1,200 bytes, closes included.
      Minimum : constant Natural :=
        (if Item.Role = Initial_Connection.Client
         then 1_200 else 0);
   begin
      Packet := (others => 0);
      Result := (others => <>);
      Initial_Connection.Build_Initial_At_Least
        (Item.Packets, (1 .. 0 => 0),
         Frame.Data (1 .. Ada.Streams.Stream_Element_Offset (Frame.Length)),
         Minimum_Packet_Length => Minimum, Packet => Packet,
         Result => Built_Packet);
      Result.Number := Built_Packet.Number;
      Result.Status := Build_Status_For (Built_Packet.Status);
      if Built_Packet.Status = Initial_Connection.Built then
         Result.Packet_Length := Built_Packet.Packet_Length;
         Sent_Packet_Policy.Record_Sent
           (Item.Sent,
            (Number        => Built_Packet.Number,
             Sent_At       => 0,
             Bytes         => Sent_Packet_Policy.Packet_Byte_Count
               (Built_Packet.Packet_Length),
             ACK_Eliciting => False,
             In_Flight     => False),
            Record_Status);
      end if;
   end Build_Transport_Close_Packet;

   --  Apply one peer ACK frame to the ledger and the retained flight.
   procedure Apply_Peer_ACK
     (Item       : in out State;
      Plaintext  : Ada.Streams.Stream_Element_Array;
      Frame      : Initial_Frame_Policy.Parse_Result;
      Now        : Timestamp;
      Loss_Delay : Timestamp;
      Result     : in out Process_Result;
      Rejected   : out Boolean)
   is
      Ranges  : ACK_Range_Policy.Decode_Result;
      Applied : Sent_Packet_Policy.Apply_Result;
   begin
      Rejected := True;
      Ranges := ACK_Range_Policy.Decode (Plaintext, Frame);
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
        (Item.Sent, Ranges, Now, Loss_Delay, Applied);
      if Applied.Status = Sent_Packet_Policy.Acknowledges_Unsent_Packet then
         Result.Status := Acknowledges_Unsent_Packet;
         return;
      end if;
      Rejected := False;
      Result.Resolved := Applied;
      for Index in 1 .. Applied.Count loop
         if Applied.Events (Index).Kind = Sent_Packet_Policy.Acknowledged then
            Crypto_Flight.Acknowledge
              (Item.Outgoing, Applied.Events (Index).Packet.Number);
            if Applied.Events (Index).Packet.ACK_Eliciting then
               Result.ACKed_Eliciting := True;
               Item.Ping_Sent := False;
               if not Result.Has_Sample
                 and then Applied.Events (Index).Packet.Number =
                   Packet_Number (Frame.Largest_Acknowledged)
                 and then Now >= Applied.Events (Index).Packet.Sent_At
               then
                  Result.Has_Sample := True;
                  Result.Sample :=
                    Now - Applied.Events (Index).Packet.Sent_At;
               end if;
            end if;
         end if;
      end loop;
   end Apply_Peer_ACK;

   procedure Process_Packet
     (Item       : in out State;
      Packet     : Ada.Streams.Stream_Element_Array;
      Now        : Timestamp;
      Loss_Delay : Timestamp;
      Result     : out Process_Result)
   is
      Plaintext : Ada.Streams.Stream_Element_Array (1 .. Max_Datagram_Length);
      Received  : Initial_Connection.Process_Result;
      Length    : Initial_Frame_Policy.Frame_Offset;
      Cursor    : Initial_Frame_Policy.Frame_Offset := 0;
      Frame     : Initial_Frame_Policy.Parse_Result;
      Inserted  : Crypto_Reassembly_Policy.Insert_Status;
      Rejected  : Boolean;
   begin
      Result := (others => <>);
      Initial_Connection.Process_Initial
        (Item.Packets, Packet, Plaintext, Received);
      if Received.Status /= Initial_Connection.Processed then
         Result.Status :=
           (case Received.Status is
               when Initial_Connection.Processed => Processed,
               when Initial_Connection.Duplicate => Duplicate_Packet,
               when Initial_Connection.Too_Old => Packet_Too_Old,
               when Initial_Connection.Envelope_Rejected => Envelope_Rejected,
               when Initial_Connection.Authentication_Failed =>
                 Authentication_Failed,
               when Initial_Connection.Invalid_Reserved_Bits =>
                 Invalid_Reserved_Bits);
         return;
      end if;
      Result.Peer_Source := Received.Packet.Envelope.Header.Source;

      Length := Initial_Frame_Policy.Frame_Offset
        (Received.Packet.Plaintext_Length);
      while Cursor < Length loop
         Frame := Initial_Frame_Policy.Parse_Next
           (Plaintext (1 .. Length), Cursor);
         if Frame.Status /= Initial_Frame_Policy.Parsed then
            Result.Status :=
              (case Frame.Status is
                  when Initial_Frame_Policy.Parsed => Processed,
                  when Initial_Frame_Policy.End_Of_Input
                     | Initial_Frame_Policy.Truncated => Frame_Truncated,
                  when Initial_Frame_Policy.Frame_Type_Not_Allowed =>
                    Frame_Not_Allowed,
                  when Initial_Frame_Policy.Frame_Value_Too_Large =>
                    Frame_Value_Too_Large,
                  when Initial_Frame_Policy.Invalid_ACK_Range =>
                    Invalid_ACK_Range);
            return;
         end if;
         Result.Frame_Count := Result.Frame_Count + 1;
         if Frame.Kind in Initial_Frame_Policy.Ping
           | Initial_Frame_Policy.Crypto
         then
            Result.ACK_Eliciting := True;
         end if;
         if Frame.Kind = Initial_Frame_Policy.Acknowledgment then
            Apply_Peer_ACK
              (Item, Plaintext (1 .. Length), Frame, Now, Loss_Delay, Result,
               Rejected);
            if Rejected then
               return;
            end if;
         elsif Frame.Kind = Initial_Frame_Policy.Crypto then
            if Frame.Crypto_Length = 0 then
               Crypto_Reassembly_Policy.Insert
                 (Item.Crypto, Frame.Crypto_Offset, (1 .. 0 => 0), Inserted);
            else
               Crypto_Reassembly_Policy.Insert
                 (Item.Crypto, Frame.Crypto_Offset,
                  Plaintext
                    (Plaintext'First + Frame.Crypto_Data_Offset
                       .. Plaintext'First + Frame.Crypto_Data_Offset
                            + Frame.Crypto_Length - 1),
                  Inserted);
            end if;
            if Inserted = Crypto_Reassembly_Policy.Conflicting_Overlap then
               Result.Status := Conflicting_Crypto_Data;
               return;
            elsif Inserted = Crypto_Reassembly_Policy.Exceeds_Capacity then
               Result.Status := Crypto_Data_Too_Large;
               return;
            end if;
         elsif Frame.Kind = Initial_Frame_Policy.Transport_Close then
            --  RFC 9000 10.2.2 puts the receiver into the draining state, so
            --  the remaining frames of this packet cannot change the outcome.
            Result.Peer_Closed := True;
            Result.Close_Error := Frame.Close_Error_Code;
            Result.Status := Processed;
            return;
         end if;
         Cursor := Cursor + Frame.Consumed;
      end loop;
      if Result.ACK_Eliciting then
         Item.ACK_Owed := True;
      end if;
      Result.Status := Processed;
   end Process_Packet;
end Flyology.QUIC.Initial_Space;
