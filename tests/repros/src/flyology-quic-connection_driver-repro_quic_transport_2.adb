with Ada.Streams;
with Repro_Support;

procedure Flyology.QUIC.Connection_Driver.Repro_Quic_Transport_2 is
   --  QUIC-TRANSPORT-2: the 64-entry sent-packet ledger is checked before
   --  the congestion window, so a sender whose window has grown past 64
   --  packets reports Recovery_Capacity_Exceeded instead of backpressure,
   --  and a PTO with a full ledger cannot build the probe RFC 9002 s6.2.4
   --  requires.
   --
   --  RFC 9002 s6.2.4: "When a PTO timer expires, a sender MUST send at
   --  least one ack-eliciting packet in the packet number space as a probe."
   --
   --  The peer here advertises 2,000,000 bytes of stream credit, which is
   --  what a stock peer does (quic-go's default initial_max_stream_data is
   --  512 KiB).  Nothing else is unusual.

   use Repro_Support;
   use type Application_Space.Timestamp;
   use type Application_Space.Open_Status;
   use type Application_Space.Send_Status;
   use type Application_Space.Stream_Offset;
   use type Transport_Parameter_Policy.Encode_Status;

   subtype Bytes is Ada.Streams.Stream_Element_Array;

   function Nibble (Value : Character) return Natural is
     (case Value is
         when '0' .. '9' => Character'Pos (Value) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (Value) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (Value) - Character'Pos ('A') + 10,
         when others => raise Constraint_Error);

   function Hex_Bytes (Value : String) return Bytes is
      Result : Bytes (1 .. Ada.Streams.Stream_Element_Offset
                             (Value'Length / 2));
      Source : Positive := Value'First;
   begin
      for Element of Result loop
         Element := Ada.Streams.Stream_Element
           (16 * Nibble (Value (Source)) + Nibble (Value (Source + 1)));
         Source := Source + 2;
      end loop;
      return Result;
   end Hex_Bytes;

   function ID (Data : Bytes) return Long_Header_Policy.Connection_ID is
      Result : Long_Header_Policy.Connection_ID;
   begin
      Result.Length := Natural (Data'Length);
      Result.Data (1 .. Data'Length) := Data;
      return Result;
   end ID;

   function Parameter
     (Value : Long_Header_Policy.Connection_ID)
      return Transport_Parameter_Policy.Connection_ID_Parameter
   is
      Result : Transport_Parameter_Policy.Connection_ID_Parameter;
   begin
      Result.Present := True;
      Result.Length := Value.Length;
      if Value.Length > 0 then
         Result.Data (1 .. Ada.Streams.Stream_Element_Offset (Value.Length)) :=
           Value.Data (1 .. Ada.Streams.Stream_Element_Offset (Value.Length));
      end if;
      return Result;
   end Parameter;

   Certificate : constant Bytes :=
     Hex_Bytes
       ("3082013c3081efa0030201020214434e3e3873a520217edf913fba03f4" &
        "ea17411e64300506032b657030143112301006035504030c096c6f6361" &
        "6c686f7374301e170d3236303830373230323830385a170d3336303830" &
        "343230323830385a30143112301006035504030c096c6f63616c686f73" &
        "74302a300506032b65700321006380a1de85cdd187a3134d096ff12e8b" &
        "1e47aa4c94cff3c4144bad3ee5f81eaea3533051301d0603551d0e0416" &
        "0414d3dd952a2ff44a35af38d9249d71a454ced348ce301f0603551d23" &
        "041830168014d3dd952a2ff44a35af38d9249d71a454ced348ce300f060" &
        "3551d130101ff040530030101ff300506032b657003410024075a33b818" &
        "be62a4f328b79bd8f79febe7d3710fb44ba7a7b2d8e12bc3d1e4056d5" &
        "c20fba04e183430175b62ed1a107eb518dfaacf11045fa0e5a6feba2c0f");
   Private_Key : constant Crypto_OpenSSL.Ed25519_Private_Key :=
     Crypto_OpenSSL.Ed25519_Private_Key'
       (Hex_Bytes ("f491306c81165ffd97822f3ef58de891" &
                   "8779314457f5501e42d3f68504cd3aa8"));
   ALPN        : constant Bytes := Hex_Bytes ("6833");
   Original_ID : constant Bytes := Hex_Bytes ("8394c8f03e515708");
   Client_ID   : constant Long_Header_Policy.Connection_ID :=
     ID (Hex_Bytes ("aabbccdd01020304"));
   Server_ID   : constant Long_Header_Policy.Connection_ID :=
     ID (Hex_Bytes ("1020304050607080"));

   Client_Parameters, Server_Parameters :
     Transport_Parameter_Policy.Transport_Parameters;
   Client_Encoded, Server_Encoded :
     Transport_Parameter_Policy.Encode_Result;

   Client, Server : Connection;
   Payload : constant Bytes (1 .. 1_100) := (others => 16#5A#);

   Now : Application_Space.Timestamp := 1_000;

   procedure Give
     (Packet : Datagram;
      Target : in out Connection;
      Reply  : out Datagram_Batch)
   is
      Result : Operation_Result;
   begin
      Process_Datagram
        (Target,
         Packet.Data (1 .. Ada.Streams.Stream_Element_Offset (Packet.Length)),
         Reply, Result, Now);
   end Give;

   procedure Handshake is
      Client_Output, Server_Output, Reply, Ignored : Datagram_Batch;
      Client_Result : Operation_Result;
   begin
      Start_Client (Client, Client_Output, Client_Result, Now);
      pragma Assert (Client_Output.Count = 1);
      Give (Client_Output.Items (1), Server, Server_Output);
      pragma Assert (Server_Output.Count >= 2);

      Reply := (others => <>);
      for Index in 1 .. Server_Output.Count loop
         Give (Server_Output.Items (Index), Client, Client_Output);
         if Client_Output.Count > 0 then
            Reply := Client_Output;
         end if;
      end loop;
      pragma Assert (Is_Connected (Client) and then Reply.Count = 1);

      Give (Reply.Items (1), Server, Server_Output);
      pragma Assert (Is_Connected (Server));
      Reply := (others => <>);
      for Index in 1 .. Server_Output.Count loop
         Give (Server_Output.Items (Index), Client, Client_Output);
         if Client_Output.Count > 0 then
            Reply := Client_Output;
         end if;
      end loop;
      if Reply.Count = 1 then
         Give (Reply.Items (1), Server, Ignored);
      end if;
      pragma Assert (Handshake_Confirmed (Client));
   end Handshake;

   Stream : Varint_Policy.Value_Type;
   Opened : Application_Space.Open_Status;
   Offset : Varint_Policy.Value_Type := 0;

   --  One round trip: send packets until the sender says stop, deliver them
   --  to the peer (draining its stream buffer so the peer's own 16 KiB
   --  reassembly ring is never the binding constraint), then deliver the
   --  peer's acknowledgments back.
   procedure Round
     (Limit       : Positive;
      Deliver_ACK : Boolean;
      Sent_Count  : out Natural;
      Last_Status : out Application_Space.Send_Status)
   is
      Packet   : Datagram;
      Status   : Application_Space.Send_Status;
      Outbound : array (1 .. Limit) of Datagram;
      Reply    : Datagram_Batch;
      Ignored  : Datagram_Batch;
      ACKs     : Datagram_Batch;
   begin
      Sent_Count := 0;
      Last_Status := Application_Space.Sent;
      for Index in 1 .. Limit loop
         Build_Stream_Datagram
           (Client, Stream, Offset, False, Payload, Now, Packet, Status);
         Last_Status := Status;
         exit when Status /= Application_Space.Sent;
         Offset := Offset + Payload'Length;
         Sent_Count := Sent_Count + 1;
         Outbound (Sent_Count) := Packet;
      end loop;
      if not Deliver_ACK then
         return;
      end if;
      Now := Now + 5_000;
      ACKs := (others => <>);
      for Index in 1 .. Sent_Count loop
         Give (Outbound (Index), Server, Reply);
         if Has_Stream (Server, Stream)
           and then Available_Length (Server, Stream) > 0
         then
            Consume (Server, Stream, Available_Length (Server, Stream));
         end if;
         if Reply.Count > 0 then
            ACKs := Reply;
         end if;
      end loop;
      Now := Now + 5_000;
      for Index in 1 .. ACKs.Count loop
         Give (ACKs.Items (Index), Client, Ignored);
      end loop;
   end Round;

   Sent_Count  : Natural;
   Last_Status : Application_Space.Send_Status;
   Timeout_Result : Timeout_Status;
   Final_Batch : Datagram_Batch;

begin
   Client_Parameters.Initial_Source_Connection_ID := Parameter (Client_ID);
   Client_Parameters.Initial_Max_Data := (Present => True, Value => 4_000_000);
   Client_Parameters.Initial_Max_Stream_Data_Bidi_Local :=
     (Present => True, Value => 2_000_000);
   Client_Parameters.Initial_Max_Stream_Data_Bidi_Remote :=
     (Present => True, Value => 2_000_000);
   Client_Parameters.Initial_Max_Stream_Data_Uni :=
     (Present => True, Value => 2_000_000);
   Client_Parameters.Initial_Max_Streams_Bidi := (Present => True, Value => 8);
   Client_Parameters.Initial_Max_Streams_Uni := (Present => True, Value => 8);

   Server_Parameters.Original_Destination_Connection_ID :=
     Parameter (ID (Original_ID));
   Server_Parameters.Initial_Source_Connection_ID := Parameter (Server_ID);
   Server_Parameters.Initial_Max_Data := (Present => True, Value => 4_000_000);
   Server_Parameters.Initial_Max_Stream_Data_Bidi_Local :=
     (Present => True, Value => 2_000_000);
   Server_Parameters.Initial_Max_Stream_Data_Bidi_Remote :=
     (Present => True, Value => 2_000_000);
   Server_Parameters.Initial_Max_Stream_Data_Uni :=
     (Present => True, Value => 2_000_000);
   Server_Parameters.Initial_Max_Streams_Bidi := (Present => True, Value => 8);
   Server_Parameters.Initial_Max_Streams_Uni := (Present => True, Value => 8);

   Client_Encoded := Transport_Parameter_Policy.Encode
     (Client_Parameters, Transport_Parameter_Policy.Client);
   Server_Encoded := Transport_Parameter_Policy.Encode
     (Server_Parameters, Transport_Parameter_Policy.Server);
   pragma Assert
     (Client_Encoded.Status = Transport_Parameter_Policy.Encoded
      and then Server_Encoded.Status = Transport_Parameter_Policy.Encoded);

   Initialize_Client
     (Client, ALPN,
      Client_Encoded.Data
        (1 .. Ada.Streams.Stream_Element_Offset (Client_Encoded.Length)),
      Certificate, Original_ID, ID (Original_ID), Client_ID,
      Client_Parameters);
   Initialize_Server
     (Server, ALPN,
      Server_Encoded.Data
        (1 .. Ada.Streams.Stream_Element_Offset (Server_Encoded.Length)),
      Certificate, Private_Key, Original_ID, Client_ID, Server_ID,
      Server_Parameters);

   Handshake;
   Open_Stream (Client, Stream_ID_Policy.Bidirectional, Stream, Opened);
   pragma Assert (Opened = Stream_ID_Policy.Opened);

   --  Grow the congestion window the way NewReno slow start does: each round
   --  acknowledges everything sent in the previous one.
   for Trip in 1 .. 8 loop
      Round (200, True, Sent_Count, Last_Status);
      Note ("round trip" & Trip'Image & ": sent" & Sent_Count'Image
            & " packets, then "
            & Application_Space.Send_Status'Image (Last_Status));
      exit when Sent_Count = 0;
   end loop;

   --  Now stop acknowledging and keep sending.  The first refusal shows
   --  which limit binds.
   Round (200, False, Sent_Count, Last_Status);
   Note ("with nothing acknowledged: sent" & Sent_Count'Image
         & " further packets, then "
         & Application_Space.Send_Status'Image (Last_Status));

   Check (Last_Status /= Application_Space.Recovery_Capacity_Exceeded,
          "a sender that runs out of room reports backpressure"
          & " (Congestion_Blocked or a flow-control status), not"
          & " Recovery_Capacity_Exceeded, which"
          & " Flyology.HTTP.HTTP_3_Connection.Send_Status_For maps to"
          & " Transport_Error");

   --  RFC 9002 s6.2.4: the PTO MUST produce an ack-eliciting probe.
   if Has_Recovery_Timeout (Client) then
      Now := Recovery_Deadline (Client);
      Process_Timeout (Client, Now, Final_Batch, Timeout_Result);
      Note ("PTO with a full ledger: "
            & Timeout_Status'Image (Timeout_Result)
            & "," & Final_Batch.Count'Image & " datagrams");
      Check (Timeout_Result = Probes_Ready,
             "a probe timeout with a full ledger still sends at least one"
             & " ack-eliciting packet (RFC 9002 s6.2.4)");
   else
      Note ("no recovery timeout armed; PTO case not exercised");
      Check (False, "a sender with unacknowledged data arms a probe timeout");
   end if;

   Finish;
end Flyology.QUIC.Connection_Driver.Repro_Quic_Transport_2;
