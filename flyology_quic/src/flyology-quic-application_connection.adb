with Flyology.QUIC.Packet_Number_Policy;
with Flyology.QUIC.Debug;

package body Flyology.QUIC.Application_Connection is
   package Debug renames Flyology.QUIC.Debug;
   use type Connection_State_Policy.Receive_Disposition;
   use type Long_Header_Policy.Connection_ID;
   use type One_RTT_Receiver.Receive_Status;
   use type One_RTT_Sender.Send_Status;

   function Is_Initialized (Item : Connection) return Boolean is
     (Item.Initialized);

   function Encode_ACK
     (Item      : Connection;
      ACK_Delay : Varint_Policy.Value_Type)
      return ACK_Frame_Policy.Encode_Result
   is
     (ACK_Frame_Policy.Encode (Item.Receive_State, ACK_Delay));

   procedure Initialize
     (Item        : in out Connection;
      Sending     : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Receiving   : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Destination : Long_Header_Policy.Connection_ID;
      Local_ID    : Long_Header_Policy.Connection_ID) is
   begin
      Crypto_OpenSSL.Initialize_Provider (Item.Backend);
      Item.Sending := Sending;
      Item.Receiving := Receiving;
      TLS_Key_Schedule.Update_QUIC_Keys
        (Item.Backend, Item.Receiving, Item.Next_Receiving);
      TLS_Key_Schedule.Clear (Item.Previous_Receiving);
      Item.Destination := Destination;
      Item.Local_ID := Local_ID;
      Connection_State_Policy.Reset (Item.Send_State);
      Connection_State_Policy.Reset (Item.Receive_State);
      Item.Sending_Key_Phase := False;
      Item.Receiving_Key_Phase := False;
      Item.Has_Previous_Receiving := False;
      Item.Initialized := True;
   end Initialize;

   procedure Build_One_RTT
     (Item      : in out Connection;
      Plaintext : Ada.Streams.Stream_Element_Array;
      Packet    : out Ada.Streams.Stream_Element_Array;
      Result    : out Build_Result)
   is
      Number : Connection_State_Policy.Packet_Number;
      Number_Length : Long_Header_Policy.Packet_Number_Length;
      Sent : One_RTT_Sender.Send_Result;
   begin
      Packet := (others => 0);
      Result := (others => <>);
      if not Connection_State_Policy.Can_Send (Item.Send_State) then
         Result.Status := Packet_Number_Exhausted;
         return;
      end if;
      Number := Connection_State_Policy.Next_To_Send (Item.Send_State);
      Result.Number := Number;
      if not Packet_Number_Policy.Is_Representable (Number, False, 0) then
         Result.Status := Packet_Number_Unrepresentable;
         return;
      end if;
      Number_Length :=
        Long_Header_Policy.Packet_Number_Length
          (Packet_Number_Policy.Select_Length (Number, False, 0));
      Result.Number_Length := Number_Length;
      One_RTT_Sender.Send
         (Item.Backend, Item.Sending.Key, Item.Sending.IV, Item.Sending.HP,
         Item.Destination, Number, Number_Length, Item.Sending_Key_Phase,
         Spin => False, Plaintext => Plaintext, Packet => Packet,
         Result => Sent);
      Result.Packet_Length := Sent.Packet_Length;
      Result.Header_Length := Sent.Header_Length;
      Result.Status :=
        (case Sent.Status is
            when One_RTT_Sender.Sent => Built,
            when One_RTT_Sender.Insufficient_Protected_Payload =>
              Insufficient_Protected_Payload,
            when One_RTT_Sender.Packet_Too_Large => Packet_Too_Large,
            when One_RTT_Sender.Output_Too_Small => Output_Too_Small);
      if Sent.Status = One_RTT_Sender.Sent then
         Connection_State_Policy.Commit_Sent (Item.Send_State);
      end if;
   end Build_One_RTT;

   procedure Process_One_RTT
     (Item      : in out Connection;
      Packet    : Ada.Streams.Stream_Element_Array;
      Plaintext : out Ada.Streams.Stream_Element_Array;
      Result    : out Process_Result)
   is
      Received    : One_RTT_Receiver.Receive_Result;
      Disposition : Connection_State_Policy.Receive_Disposition;
      Expected    : constant Connection_State_Policy.Packet_Number :=
        Connection_State_Policy.Expected_Number (Item.Receive_State);
      Used_Previous : Boolean := False;

      procedure Receive_With
        (Keys    : TLS_Key_Schedule.QUIC_Traffic_Keys;
         Decoded : out Ada.Streams.Stream_Element_Array;
         Packet_Result : out One_RTT_Receiver.Receive_Result) is
      begin
         One_RTT_Receiver.Receive
           (Item.Backend, Keys.Key, Keys.IV, Keys.HP,
            Long_Header_Policy.V1_Connection_ID_Length
              (Item.Local_ID.Length),
            Expected, Packet, Decoded, Packet_Result);
      end Receive_With;
   begin
      Plaintext := (others => 0);
      Result := (others => <>);
      Receive_With (Item.Receiving, Plaintext, Received);
      if Received.Status = One_RTT_Receiver.Authentication_Failed then
         declare
            Candidate : One_RTT_Receiver.Receive_Result;
            Candidate_Plaintext : Ada.Streams.Stream_Element_Array
              (Plaintext'Range);
         begin
            Receive_With
              (Item.Next_Receiving, Candidate_Plaintext, Candidate);
            if Debug.Enabled then
               Debug.Log
                 ("quic", "receive-key-trial",
                  "current-number=" &
                    Connection_State_Policy.Packet_Number'Image
                      (Received.Number) &
                  " current-phase=" & Boolean'Image (Received.Key_Phase) &
                  " next-status=" & One_RTT_Receiver.Receive_Status'Image
                    (Candidate.Status) &
                  " next-number=" &
                    Connection_State_Policy.Packet_Number'Image
                      (Candidate.Number) &
                  " next-phase=" & Boolean'Image (Candidate.Key_Phase));
            end if;
            if Candidate.Status in
              One_RTT_Receiver.Received
                | One_RTT_Receiver.Invalid_Reserved_Bits
              and then
                Candidate.Key_Phase /= Item.Receiving_Key_Phase
            then
               if Candidate.Status = One_RTT_Receiver.Received then
                  Item.Previous_Receiving := Item.Receiving;
                  Item.Has_Previous_Receiving := True;
                  Item.Receiving := Item.Next_Receiving;
                  Item.Receiving_Key_Phase := Candidate.Key_Phase;
                  TLS_Key_Schedule.Update_QUIC_Keys
                    (Item.Backend, Item.Receiving, Item.Next_Receiving);
                  if Debug.Enabled then
                     Debug.Log
                       ("quic", "receive-key-update",
                        "phase=" & Boolean'Image
                          (Item.Receiving_Key_Phase) &
                        " packet=" &
                          Connection_State_Policy.Packet_Number'Image
                            (Candidate.Number));
                  end if;
               end if;
               Plaintext := Candidate_Plaintext;
               Received := Candidate;
            elsif Item.Has_Previous_Receiving then
               Receive_With
                 (Item.Previous_Receiving, Candidate_Plaintext, Candidate);
               if Candidate.Status in
                 One_RTT_Receiver.Received
                   | One_RTT_Receiver.Invalid_Reserved_Bits
                 and then
                   Candidate.Key_Phase /= Item.Receiving_Key_Phase
               then
                  Plaintext := Candidate_Plaintext;
                  Received := Candidate;
                  Used_Previous := True;
               end if;
            end if;
         end;
      end if;
      Result.Packet := Received;
      case Received.Status is
         when One_RTT_Receiver.Envelope_Rejected =>
            Result.Status := Envelope_Rejected;
         when One_RTT_Receiver.Authentication_Failed =>
            Result.Status := Authentication_Failed;
         when One_RTT_Receiver.Invalid_Reserved_Bits =>
            Result.Status := Invalid_Reserved_Bits;
         when One_RTT_Receiver.Received =>
            if Received.Envelope.Destination /= Item.Local_ID then
               Plaintext := (others => 0);
               Result.Status := Unexpected_Destination;
               return;
            elsif Received.Key_Phase /= Item.Receiving_Key_Phase
              and then not Used_Previous
            then
               Plaintext := (others => 0);
               Result.Status := Unsupported_Key_Phase;
               return;
            end if;
            Connection_State_Policy.Record_Received
              (Item.Receive_State, Received.Number, Disposition);
            case Disposition is
               when Connection_State_Policy.New_Packet =>
                  Result.Status := Processed;
               when Connection_State_Policy.Duplicate_Packet =>
                  Plaintext := (others => 0);
                  Result.Status := Duplicate;
               when Connection_State_Policy.Packet_Too_Old =>
                  Plaintext := (others => 0);
                  Result.Status := Too_Old;
            end case;
      end case;
   end Process_One_RTT;
end Flyology.QUIC.Application_Connection;
