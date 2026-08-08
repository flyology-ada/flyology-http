with Flyology.QUIC.Packet_Number_Policy;

package body Flyology.QUIC.Initial_Connection is
   use type Ada.Streams.Stream_Element_Offset;
   use type Connection_State_Policy.Receive_Disposition;
   use type Initial_Receiver.Receive_Status;
   use type Initial_Sender.Send_Status;

   function Is_Initialized (Item : Connection) return Boolean is
     (Item.Initialized);

   procedure Initialize
     (Item                    : in out Connection;
      Role                    : Endpoint_Role;
      Original_Destination_ID : Ada.Streams.Stream_Element_Array;
      Destination             : Long_Header_Policy.Connection_ID;
      Source                  : Long_Header_Policy.Connection_ID) is
   begin
      Crypto_OpenSSL.Initialize_Provider (Item.Backend);
      Crypto_OpenSSL.Derive_V1_Initial
        (Item.Backend, Original_Destination_ID, Item.Keys);
      Item.Role := Role;
      Item.Destination := Destination;
      Item.Source := Source;
      Connection_State_Policy.Reset (Item.Send_State);
      Connection_State_Policy.Reset (Item.Receive_State);
      Item.Initialized := True;
   end Initialize;

   procedure Build_Initial
     (Item      : in out Connection;
      Token     : Ada.Streams.Stream_Element_Array;
      Plaintext : Ada.Streams.Stream_Element_Array;
      Packet    : out Ada.Streams.Stream_Element_Array;
      Result    : out Build_Result)
   is
   begin
      Build_Initial_At_Least
        (Item, Token, Plaintext, 0, Packet, Result);
   end Build_Initial;

   procedure Build_Initial_At_Least
     (Item                  : in out Connection;
      Token                 : Ada.Streams.Stream_Element_Array;
      Plaintext             : Ada.Streams.Stream_Element_Array;
      Minimum_Packet_Length : Natural;
      Packet                : out Ada.Streams.Stream_Element_Array;
      Result                : out Build_Result)
   is
      Number : Connection_State_Policy.Packet_Number;
      Number_Length : Long_Header_Policy.Packet_Number_Length;
      Sent : Initial_Sender.Send_Result;

      procedure Send_Once
        (Data : Ada.Streams.Stream_Element_Array;
         Output : out Ada.Streams.Stream_Element_Array;
         Send_Result : out Initial_Sender.Send_Result) is
      begin
         if Item.Role = Client then
            Initial_Sender.Send
              (Item.Backend, Item.Keys.Client_Key, Item.Keys.Client_IV,
               Item.Keys.Client_HP, Item.Destination, Item.Source, Token,
               Number, Number_Length, Data, Output, Send_Result);
         else
            Initial_Sender.Send
              (Item.Backend, Item.Keys.Server_Key, Item.Keys.Server_IV,
               Item.Keys.Server_HP, Item.Destination, Item.Source, Token,
               Number, Number_Length, Data, Output, Send_Result);
         end if;
      end Send_Once;
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

      Send_Once (Plaintext, Packet, Sent);
      if Minimum_Packet_Length > 0
        and then
          (Sent.Status = Initial_Sender.Insufficient_Protected_Payload
           or else
             (Sent.Status = Initial_Sender.Sent
              and then Sent.Packet_Length < Minimum_Packet_Length))
      then
         declare
            Candidate : Ada.Streams.Stream_Element_Array
              (1 .. Initial_Sender.Max_Packet_Length) := (others => 0);
            Probe : Ada.Streams.Stream_Element_Array
              (1 .. Initial_Sender.Max_Packet_Length);
            Candidate_Length : Natural := Natural (Plaintext'Length);
            Attempts : Natural := 0;
         begin
            if Plaintext'Length > 0 then
               Candidate
                 (1 .. Ada.Streams.Stream_Element_Offset (Plaintext'Length)) :=
                   Plaintext;
            end if;
            if Sent.Status = Initial_Sender.Insufficient_Protected_Payload then
               Candidate_Length := Natural'Max (Candidate_Length, 4);
               Send_Once
                 (Candidate
                    (1 .. Ada.Streams.Stream_Element_Offset
                            (Candidate_Length)),
                  Probe, Sent);
            end if;
            while Attempts < 4 loop
               Candidate_Length := Candidate_Length
                 + Minimum_Packet_Length - Sent.Packet_Length;
               Send_Once
                 (Candidate
                    (1 .. Ada.Streams.Stream_Element_Offset
                            (Candidate_Length)),
                  Probe, Sent);
               exit when Sent.Status /= Initial_Sender.Sent
                 or else Sent.Packet_Length = Minimum_Packet_Length;
               if Sent.Packet_Length > Minimum_Packet_Length then
                  Candidate_Length := Candidate_Length
                    - (Sent.Packet_Length - Minimum_Packet_Length);
                  Send_Once
                    (Candidate
                       (1 .. Ada.Streams.Stream_Element_Offset
                               (Candidate_Length)),
                     Probe, Sent);
                  exit;
               end if;
               Attempts := Attempts + 1;
            end loop;
            Packet := (others => 0);
            if Sent.Status = Initial_Sender.Sent
              and then Sent.Packet_Length <= Natural (Packet'Length)
            then
               Packet
                 (Packet'First
                    .. Packet'First
                         + Ada.Streams.Stream_Element_Offset
                             (Sent.Packet_Length - 1)) :=
                 Probe (1 .. Ada.Streams.Stream_Element_Offset
                               (Sent.Packet_Length));
            else
               Sent.Status := Initial_Sender.Output_Too_Small;
            end if;
         end;
      end if;

      Result.Packet_Length := Sent.Packet_Length;
      Result.Header_Length := Sent.Header_Length;
      Result.Status :=
        (case Sent.Status is
            when Initial_Sender.Sent => Built,
            when Initial_Sender.Insufficient_Protected_Payload =>
              Insufficient_Protected_Payload,
            when Initial_Sender.Packet_Too_Large => Packet_Too_Large,
            when Initial_Sender.Output_Too_Small => Output_Too_Small);
      if Sent.Status = Initial_Sender.Sent then
         Connection_State_Policy.Commit_Sent (Item.Send_State);
      end if;
   end Build_Initial_At_Least;

   procedure Process_Initial
     (Item      : in out Connection;
      Packet    : Ada.Streams.Stream_Element_Array;
      Plaintext : out Ada.Streams.Stream_Element_Array;
      Result    : out Process_Result)
   is
      Received    : Initial_Receiver.Receive_Result;
      Disposition : Connection_State_Policy.Receive_Disposition;
      Expected    : constant Connection_State_Policy.Packet_Number :=
        Connection_State_Policy.Expected_Number (Item.Receive_State);
   begin
      Plaintext := (others => 0);
      Result := (others => <>);
      if Item.Role = Client then
         Initial_Receiver.Receive
           (Item.Backend, Item.Keys.Server_Key, Item.Keys.Server_IV,
            Item.Keys.Server_HP, Expected, Packet, Plaintext, Received);
      else
         Initial_Receiver.Receive
           (Item.Backend, Item.Keys.Client_Key, Item.Keys.Client_IV,
            Item.Keys.Client_HP, Expected, Packet, Plaintext, Received);
      end if;
      Result.Packet := Received;

      case Received.Status is
         when Initial_Receiver.Envelope_Rejected =>
            Result.Status := Envelope_Rejected;
         when Initial_Receiver.Authentication_Failed =>
            Result.Status := Authentication_Failed;
         when Initial_Receiver.Invalid_Reserved_Bits =>
            Result.Status := Invalid_Reserved_Bits;
         when Initial_Receiver.Received =>
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
   end Process_Initial;
end Flyology.QUIC.Initial_Connection;
