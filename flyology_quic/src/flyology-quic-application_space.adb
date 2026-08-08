with Flyology.QUIC.ACK_Frame_Policy;
with Flyology.QUIC.ACK_Range_Policy;
with Flyology.QUIC.Application_Frame_Policy;
with Flyology.QUIC.Stream_Frame_Policy;
with Interfaces;

package body Flyology.QUIC.Application_Space is
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.Unsigned_64;
   use type ACK_Frame_Policy.Encode_Status;
   use type ACK_Range_Policy.Decode_Status;
   use type Application_Connection.Build_Status;
   use type Application_Connection.Process_Status;
   use type Application_Frame_Policy.Frame_Kind;
   use type Application_Frame_Policy.Parse_Status;
   use type Recovery_Policy.Send_Status;
   use type Sent_Packet_Policy.Apply_Status;
   use type Sent_Packet_Policy.Event_Kind;
   use type Sent_Packet_Policy.Record_Status;
   use type Stream_Frame_Policy.Encode_Status;
   use type Stream_Table_Policy.Process_Status;

   function Is_Initialized (Item : State) return Boolean is
     (Item.Initialized);

   function Has_Stream
     (Item      : State;
      Stream_ID : Varint_Policy.Value_Type) return Boolean
   is
     (Stream_Table_Policy.Has_Stream (Item.Streams, Stream_ID));

   function Available_Length
     (Item      : State;
      Stream_ID : Varint_Policy.Value_Type) return Stream_Offset
   is
     (Stream_Table_Policy.Available_Length (Item.Streams, Stream_ID));

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

   function Retained_Packets
     (Item : State) return Sent_Packet_Policy.Sent_Count
   is
     (Sent_Packet_Policy.Retained (Item.Sent));

   function Bytes_In_Flight (Item : State) return Recovery_Policy.Byte_Count is
     (Recovery_Policy.Bytes_In_Flight (Item.Recovery));

   function Congestion_Window (Item : State) return Recovery_Policy.Byte_Count is
     (Recovery_Policy.Congestion_Window (Item.Recovery));

   function Has_RTT_Sample (Item : State) return Boolean is
     (Recovery_Policy.Has_RTT_Sample (Item.Recovery));

   function Smoothed_RTT (Item : State) return Recovery_Policy.Duration is
     (Recovery_Policy.Smoothed_RTT (Item.Recovery));

   procedure Initialize
     (Item        : in out State;
      Sending     : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Receiving   : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Destination : Long_Header_Policy.Connection_ID;
      Local_ID    : Long_Header_Policy.Connection_ID) is
   begin
      Application_Connection.Initialize
        (Item.Packets, Sending, Receiving, Destination, Local_ID);
      Stream_Table_Policy.Reset (Item.Streams);
      Sent_Packet_Policy.Reset (Item.Sent);
      Recovery_Policy.Reset (Item.Recovery);
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
      Sent_Packet    : Sent_Packet_Policy.Sent_Packet;
   begin
      Packet := (others => 0);
      Result := (others => <>);
      if Sent_Packet_Policy.Retained (Item.Sent) =
        Sent_Packet_Policy.Max_Sent_Packets
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
      Result.Status := Sent;
   end Build_Stream_Packet;

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
      Received  : Application_Connection.Process_Result;
      Streams   : Stream_Table_Policy.Process_Result;
      Length    : Application_Frame_Policy.Frame_Offset;
      Cursor    : Application_Frame_Policy.Frame_Offset := 0;
      Frame     : Application_Frame_Policy.Parse_Result;
      Ranges    : ACK_Range_Policy.Decode_Result;
      Applied   : Sent_Packet_Policy.Apply_Result;
      Sampled   : Boolean;
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
      Stream_Table_Policy.Process_Plaintext
        (Item.Streams, Plaintext (1 .. Length), Streams);
      Result.Frame_Count := Natural (Streams.Frame_Count);
      if Streams.Status /= Stream_Table_Policy.Processed then
         Result.Status := Process_Status_For (Streams.Status);
         return;
      end if;

      while Cursor < Length loop
         Frame := Application_Frame_Policy.Parse_Next
           (Plaintext (1 .. Length), Cursor);
         if Frame.Status /= Application_Frame_Policy.Parsed then
            Result.Status := Unknown_Frame_Type;
            return;
         end if;
         if Frame.Kind not in Application_Frame_Policy.Padding
           | Application_Frame_Policy.Acknowledgment
           | Application_Frame_Policy.Transport_Close
           | Application_Frame_Policy.Application_Close
         then
            Result.ACK_Eliciting := True;
         end if;
         if Frame.Kind = Application_Frame_Policy.Acknowledgment then
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
              (Item.Sent, Ranges, Now,
               Recovery_Policy.Loss_Delay (Item.Recovery), Applied);
            if Applied.Status = Sent_Packet_Policy.Acknowledges_Unsent_Packet
            then
               Result.Status := Acknowledges_Unsent_Packet;
               return;
            end if;
            Sampled := False;
            for Index in 1 .. Applied.Count loop
               if not Sampled
                 and then Applied.Events (Index).Kind =
                   Sent_Packet_Policy.Acknowledged
                 and then Applied.Events (Index).Packet.ACK_Eliciting
                 and then Applied.Events (Index).Packet.Number =
                   Packet_Number (Frame.Base.Largest_Acknowledged)
                 and then Now >= Applied.Events (Index).Packet.Sent_At
               then
                  Recovery_Policy.Update_RTT
                    (Item.Recovery,
                     Now - Applied.Events (Index).Packet.Sent_At,
                     Decoded_ACK_Delay
                       (Frame.Base.ACK_Delay, ACK_Delay_Exponent),
                     Maximum_ACK_Delay, Handshake_Confirmed);
                  Sampled := True;
               end if;
            end loop;
            Recovery_Policy.On_Packets_Resolved
              (Item.Recovery, Applied.Events, Applied.Count, Now,
               Application_Limited => False);
            Result.Resolved_Count :=
              Result.Resolved_Count + Natural (Applied.Count);
         end if;
         Cursor := Cursor + Frame.Consumed;
      end loop;
      Result.Status := Processed;
   end Process_Packet;
end Flyology.QUIC.Application_Space;
