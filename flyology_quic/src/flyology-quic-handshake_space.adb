with Flyology.QUIC.Crypto_Frame_Policy;
with Flyology.QUIC.Initial_Frame_Policy;

package body Flyology.QUIC.Handshake_Space is
   use type Ada.Streams.Stream_Element_Offset;
   use type Crypto_Frame_Policy.Encode_Status;
   use type Crypto_Reassembly_Policy.Insert_Status;
   use type Handshake_Connection.Build_Status;
   use type Handshake_Connection.Process_Status;
   use type Initial_Frame_Policy.Frame_Kind;
   use type Initial_Frame_Policy.Parse_Status;

   function Is_Initialized (Item : State) return Boolean is
     (Item.Initialized);

   function Contiguous_Length
     (Item : State) return Crypto_Reassembly_Policy.Stream_Offset is
     (Crypto_Reassembly_Policy.Contiguous_Length (Item.Crypto));

   function Crypto_Element
     (Item  : State;
      Index : Crypto_Reassembly_Policy.Stream_Index)
      return Ada.Streams.Stream_Element is
     (Crypto_Reassembly_Policy.Element (Item.Crypto, Index));

   procedure Initialize
     (Item        : in out State;
      Sending     : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Receiving   : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Destination : Long_Header_Policy.Connection_ID;
      Source      : Long_Header_Policy.Connection_ID) is
   begin
      Handshake_Connection.Initialize
        (Item.Packets, Sending, Receiving, Destination, Source);
      Crypto_Reassembly_Policy.Reset (Item.Crypto);
      Item.Initialized := True;
   end Initialize;

   procedure Build_Crypto_Packet
     (Item   : in out State;
      Offset : Varint_Policy.Value_Type;
      Data   : Ada.Streams.Stream_Element_Array;
      Packet : out Ada.Streams.Stream_Element_Array;
      Result : out Build_Result)
   is
      Frame : constant Crypto_Frame_Policy.Encode_Result :=
        Crypto_Frame_Policy.Encode (Offset, Data);
      Built : Handshake_Connection.Build_Result;
   begin
      Packet := (others => 0);
      Result := (others => <>);
      if Frame.Status /= Crypto_Frame_Policy.Encoded then
         Result.Status := Crypto_Range_Too_Large;
         return;
      end if;
      Handshake_Connection.Build_Handshake
        (Item.Packets,
         Frame.Data (1 .. Ada.Streams.Stream_Element_Offset (Frame.Length)),
         Packet, Built);
      if Built.Status = Handshake_Connection.Built
        and then Built.Packet_Length <= Max_Datagram_Length
      then
         Result.Status := Handshake_Space.Built;
         Result.Packet_Length := Built.Packet_Length;
      else
         Result.Status :=
           (case Built.Status is
               when Handshake_Connection.Built => Packet_Too_Large,
               when Handshake_Connection.Packet_Number_Exhausted =>
                 Packet_Number_Exhausted,
               when Handshake_Connection.Packet_Number_Unrepresentable =>
                 Packet_Number_Unrepresentable,
               when Handshake_Connection.Insufficient_Protected_Payload =>
                 Packet_Too_Large,
               when Handshake_Connection.Packet_Too_Large => Packet_Too_Large,
               when Handshake_Connection.Output_Too_Small => Output_Too_Small);
      end if;
   end Build_Crypto_Packet;

   procedure Process_Packet
     (Item   : in out State;
      Packet : Ada.Streams.Stream_Element_Array;
      Result : out Process_Result)
   is
      Plaintext : Ada.Streams.Stream_Element_Array (1 .. Max_Datagram_Length);
      Received  : Handshake_Connection.Process_Result;
      Length    : Initial_Frame_Policy.Frame_Offset;
      Cursor    : Initial_Frame_Policy.Frame_Offset := 0;
      Frame     : Initial_Frame_Policy.Parse_Result;
      Inserted  : Crypto_Reassembly_Policy.Insert_Status;
   begin
      Result := (others => <>);
      Handshake_Connection.Process_Handshake
        (Item.Packets, Packet, Plaintext, Received);
      if Received.Status /= Handshake_Connection.Processed then
         Result.Status :=
           (case Received.Status is
               when Handshake_Connection.Processed => Processed,
               when Handshake_Connection.Duplicate => Duplicate_Packet,
               when Handshake_Connection.Too_Old => Packet_Too_Old,
               when Handshake_Connection.Envelope_Rejected =>
                 Envelope_Rejected,
               when Handshake_Connection.Authentication_Failed =>
                 Authentication_Failed,
               when Handshake_Connection.Invalid_Reserved_Bits =>
                 Invalid_Reserved_Bits);
         return;
      end if;

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
         if Frame.Kind = Initial_Frame_Policy.Crypto then
            if Frame.Crypto_Length = 0 then
               Crypto_Reassembly_Policy.Insert
                 (Item.Crypto, Frame.Crypto_Offset,
                  (1 .. 0 => 0), Inserted);
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
         end if;
         Cursor := Cursor + Frame.Consumed;
      end loop;
      Result.Status := Processed;
   end Process_Packet;
end Flyology.QUIC.Handshake_Space;
