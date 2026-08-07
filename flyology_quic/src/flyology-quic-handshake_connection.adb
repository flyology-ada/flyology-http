with Flyology.QUIC.Packet_Number_Policy;

package body Flyology.QUIC.Handshake_Connection is
   use type Connection_State_Policy.Receive_Disposition;
   use type Handshake_Receiver.Receive_Status;
   use type Handshake_Sender.Send_Status;

   function Is_Initialized (Item : Connection) return Boolean is
     (Item.Initialized);

   procedure Initialize
     (Item        : in out Connection;
      Sending     : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Receiving   : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Destination : Long_Header_Policy.Connection_ID;
      Source      : Long_Header_Policy.Connection_ID) is
   begin
      Crypto_OpenSSL.Initialize_Provider (Item.Backend);
      Item.Sending := Sending;
      Item.Receiving := Receiving;
      Item.Destination := Destination;
      Item.Source := Source;
      Connection_State_Policy.Reset (Item.Send_State);
      Connection_State_Policy.Reset (Item.Receive_State);
      Item.Initialized := True;
   end Initialize;

   procedure Build_Handshake
     (Item      : in out Connection;
      Plaintext : Ada.Streams.Stream_Element_Array;
      Packet    : out Ada.Streams.Stream_Element_Array;
      Result    : out Build_Result)
   is
      Number : Connection_State_Policy.Packet_Number;
      Number_Length : Long_Header_Policy.Packet_Number_Length;
      Sent : Handshake_Sender.Send_Result;
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

      Handshake_Sender.Send
        (Item.Backend, Item.Sending.Key, Item.Sending.IV, Item.Sending.HP,
         Item.Destination, Item.Source, Number, Number_Length, Plaintext,
         Packet, Sent);

      Result.Packet_Length := Sent.Packet_Length;
      Result.Header_Length := Sent.Header_Length;
      Result.Status :=
        (case Sent.Status is
            when Handshake_Sender.Sent => Built,
            when Handshake_Sender.Insufficient_Protected_Payload =>
              Insufficient_Protected_Payload,
            when Handshake_Sender.Packet_Too_Large => Packet_Too_Large,
            when Handshake_Sender.Output_Too_Small => Output_Too_Small);
      if Sent.Status = Handshake_Sender.Sent then
         Connection_State_Policy.Commit_Sent (Item.Send_State);
      end if;
   end Build_Handshake;

   procedure Process_Handshake
     (Item      : in out Connection;
      Packet    : Ada.Streams.Stream_Element_Array;
      Plaintext : out Ada.Streams.Stream_Element_Array;
      Result    : out Process_Result)
   is
      Received    : Handshake_Receiver.Receive_Result;
      Disposition : Connection_State_Policy.Receive_Disposition;
      Expected    : constant Connection_State_Policy.Packet_Number :=
        Connection_State_Policy.Expected_Number (Item.Receive_State);
   begin
      Plaintext := (others => 0);
      Result := (others => <>);
      Handshake_Receiver.Receive
        (Item.Backend, Item.Receiving.Key, Item.Receiving.IV,
         Item.Receiving.HP, Expected, Packet, Plaintext, Received);
      Result.Packet := Received;

      case Received.Status is
         when Handshake_Receiver.Envelope_Rejected =>
            Result.Status := Envelope_Rejected;
         when Handshake_Receiver.Authentication_Failed =>
            Result.Status := Authentication_Failed;
         when Handshake_Receiver.Invalid_Reserved_Bits =>
            Result.Status := Invalid_Reserved_Bits;
         when Handshake_Receiver.Received =>
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
   end Process_Handshake;
end Flyology.QUIC.Handshake_Connection;
