with Flyology.QUIC.Crypto_Frame_Policy;
with Flyology.QUIC.Initial_Frame_Policy;

package body Flyology.QUIC.Initial_Space is
   use type Ada.Streams.Stream_Element_Offset;
   use type Crypto_Frame_Policy.Encode_Status;
   use type Crypto_Reassembly_Policy.Insert_Status;
   use type Initial_Connection.Build_Status;
   use type Initial_Connection.Endpoint_Role;
   use type Initial_Connection.Process_Status;
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
     (Item                    : in out State;
      Role                    : Initial_Connection.Endpoint_Role;
      Original_Destination_ID : Ada.Streams.Stream_Element_Array;
      Destination             : Long_Header_Policy.Connection_ID;
      Source                  : Long_Header_Policy.Connection_ID) is
   begin
      Initial_Connection.Initialize
        (Item.Packets, Role, Original_Destination_ID, Destination, Source);
      Crypto_Reassembly_Policy.Reset (Item.Crypto);
      Item.Role := Role;
      Item.Initialized := True;
   end Initialize;

   procedure Build_Crypto_Packet
     (Item   : in out State;
      Token  : Ada.Streams.Stream_Element_Array;
      Offset : Varint_Policy.Value_Type;
      Data   : Ada.Streams.Stream_Element_Array;
      Packet : out Ada.Streams.Stream_Element_Array;
      Result : out Build_Result)
   is
      Frame : constant Crypto_Frame_Policy.Encode_Result :=
        Crypto_Frame_Policy.Encode (Offset, Data);
      Built_Packet : Initial_Connection.Build_Result;
      Minimum : constant Natural :=
        (if Item.Role = Initial_Connection.Client
         then 1_200 else 0);
   begin
      Packet := (others => 0);
      Result := (others => <>);
      if Frame.Status /= Crypto_Frame_Policy.Encoded then
         Result.Status := Crypto_Range_Too_Large;
         return;
      end if;
      Initial_Connection.Build_Initial_At_Least
        (Item.Packets, Token,
         Frame.Data (1 .. Ada.Streams.Stream_Element_Offset (Frame.Length)),
         Minimum, Packet, Built_Packet);
      Result.Status :=
        (case Built_Packet.Status is
            when Initial_Connection.Built => Built,
            when Initial_Connection.Packet_Number_Exhausted =>
              Packet_Number_Exhausted,
            when Initial_Connection.Packet_Number_Unrepresentable =>
              Packet_Number_Unrepresentable,
            when Initial_Connection.Insufficient_Protected_Payload
               | Initial_Connection.Packet_Too_Large => Packet_Too_Large,
            when Initial_Connection.Output_Too_Small => Output_Too_Small);
      if Built_Packet.Status = Initial_Connection.Built then
         Result.Packet_Length := Built_Packet.Packet_Length;
      end if;
   end Build_Crypto_Packet;

   procedure Build_Transport_Close_Packet
     (Item       : in out State;
      Error_Code : Varint_Policy.Value_Type;
      Frame_Type : Varint_Policy.Value_Type;
      Packet     : out Ada.Streams.Stream_Element_Array;
      Result     : out Build_Result)
   is
      Frame : constant Initial_Frame_Policy.Transport_Close_Encode_Result :=
        Initial_Frame_Policy.Encode_Transport_Close (Error_Code, Frame_Type);
      Built : Initial_Connection.Build_Result;
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
         Minimum_Packet_Length => Minimum, Packet => Packet, Result => Built);
      Result.Status :=
        (case Built.Status is
            when Initial_Connection.Built => Initial_Space.Built,
            when Initial_Connection.Packet_Number_Exhausted =>
              Packet_Number_Exhausted,
            when Initial_Connection.Packet_Number_Unrepresentable =>
              Packet_Number_Unrepresentable,
            when Initial_Connection.Insufficient_Protected_Payload
               | Initial_Connection.Packet_Too_Large => Packet_Too_Large,
            when Initial_Connection.Output_Too_Small => Output_Too_Small);
      if Built.Status = Initial_Connection.Built then
         Result.Packet_Length := Built.Packet_Length;
      end if;
   end Build_Transport_Close_Packet;

   procedure Process_Packet
     (Item   : in out State;
      Packet : Ada.Streams.Stream_Element_Array;
      Result : out Process_Result)
   is
      Plaintext : Ada.Streams.Stream_Element_Array (1 .. Max_Datagram_Length);
      Received  : Initial_Connection.Process_Result;
      Length    : Initial_Frame_Policy.Frame_Offset;
      Cursor    : Initial_Frame_Policy.Frame_Offset := 0;
      Frame     : Initial_Frame_Policy.Parse_Result;
      Inserted  : Crypto_Reassembly_Policy.Insert_Status;
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
         if Frame.Kind = Initial_Frame_Policy.Crypto then
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
      Result.Status := Processed;
   end Process_Packet;
end Flyology.QUIC.Initial_Space;
