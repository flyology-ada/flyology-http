with Ada.Streams;
with Flyology.QUIC.ACK_Frame_Policy;
with Repro_Support;

procedure Flyology.QUIC.Application_Space.Repro_Quic_Transport_9 is
   --  QUIC-TRANSPORT-9: a well-formed ACK frame with 64 or more ACK ranges
   --  is rejected with ACK_Range_Capacity_Exceeded, which the driver maps to
   --  CONNECTION_CLOSE PROTOCOL_VIOLATION (0x0A).
   --
   --  RFC 9000 s19.3: "ACK Range Count: A variable-length integer specifying
   --  the number of ACK Range fields in the frame."  No maximum is stated,
   --  and s13.2.3 constrains only what an endpoint chooses to send.

   use Repro_Support;
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Array;
   use type Application_Connection.Build_Status;
   use type Application_Connection.Process_Status;
   use type Stream_ID_Policy.Open_Status;

   function ID
     (Data : Ada.Streams.Stream_Element_Array)
      return Long_Header_Policy.Connection_ID
   is
      Result : Long_Header_Policy.Connection_ID;
   begin
      Result.Length := Natural (Data'Length);
      Result.Data (1 .. Data'Length) := Data;
      return Result;
   end ID;

   Client_Keys : constant TLS_Key_Schedule.QUIC_Traffic_Keys :=
     (Traffic => (others => 16#01#), Key => (others => 16#11#),
      IV => (others => 16#22#), HP => (others => 16#33#));
   Server_Keys : constant TLS_Key_Schedule.QUIC_Traffic_Keys :=
     (Traffic => (others => 16#02#), Key => (others => 16#44#),
      IV => (others => 16#55#), HP => (others => 16#66#));
   Client_ID : constant Long_Header_Policy.Connection_ID :=
     ID ((16#AA#, 16#BB#, 16#CC#, 16#DD#));
   Server_ID : constant Long_Header_Policy.Connection_ID :=
     ID ((16#10#, 16#20#, 16#30#, 16#40#));

   Client_Peer, Server_Peer :
     Transport_Parameter_Policy.Transport_Parameters;
   Remote : Application_Connection.Connection;
   Client : State;
   Packet : Ada.Streams.Stream_Element_Array (1 .. Max_Datagram_Length);
   Plain  : Ada.Streams.Stream_Element_Array (1 .. Max_Datagram_Length);
   Built  : Application_Connection.Build_Result;
   Decode : Application_Connection.Process_Result;
   Received : Process_Result;
   Sent_Data : Send_Result;
   Opened_ID : Varint_Policy.Value_Type;
   Opened : Open_Status;
   Highest : Natural := 0;

   --  Two-byte QUIC varint (RFC 9000 s16), valid for 0 .. 16383.
   function Varint2 (Value : Natural)
      return Ada.Streams.Stream_Element_Array is
     ((16#40# or Ada.Streams.Stream_Element (Value / 256),
       Ada.Streams.Stream_Element (Value mod 256)));

   --  ACK frame: type 0x02, Largest Acknowledged, ACK Delay, ACK Range
   --  Count, First ACK Range, then Count (Gap, Length) pairs of zeroes.
   --  Each zero pair steps the next range down by two packet numbers.
   function ACK_Frame (Largest, Count : Natural)
      return Ada.Streams.Stream_Element_Array
   is
      Head : constant Ada.Streams.Stream_Element_Array :=
        (1 => 16#02#) & Varint2 (Largest) & (1 => 16#00#)
        & Varint2 (Count) & (1 => 16#00#);
      Pairs : constant Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (2 * Count)) :=
          (others => 0);
   begin
      return Head & Pairs;
   end ACK_Frame;

   procedure Try (Count : Natural) is
      Frame : constant Ada.Streams.Stream_Element_Array :=
        ACK_Frame (Highest, Count);
   begin
      Application_Connection.Build_One_RTT (Remote, Frame, Packet, Built);
      pragma Assert (Built.Status = Application_Connection.Built);
      Process_Packet
        (Client,
         Packet (1 .. Ada.Streams.Stream_Element_Offset
                        (Built.Packet_Length)),
         Now => 900_000, ACK_Delay_Exponent => 3,
         Maximum_ACK_Delay => 25_000,
         Handshake_Confirmed => True, Result => Received);
      Note ("ACK largest" & Highest'Image & " with" & Count'Image
            & " ranges (smallest"
            & Natural'Image (Highest - 2 * Count) & "): "
            & Process_Status'Image (Received.Status));
   end Try;

begin
   Client_Peer.Initial_Max_Data := (Present => True, Value => 10_000);
   Client_Peer.Initial_Max_Stream_Data_Bidi_Local :=
     (Present => True, Value => 10_000);
   Client_Peer.Initial_Max_Stream_Data_Bidi_Remote :=
     (Present => True, Value => 10_000);
   Client_Peer.Initial_Max_Stream_Data_Uni :=
     (Present => True, Value => 10_000);
   Client_Peer.Initial_Max_Streams_Bidi := (Present => True, Value => 4);
   Client_Peer.Initial_Max_Streams_Uni := (Present => True, Value => 4);
   Server_Peer := Client_Peer;

   Application_Connection.Initialize
     (Remote, Server_Keys, Client_Keys, Client_ID, Server_ID);
   Initialize
     (Client, Client_Keys, Server_Keys, Server_ID, Client_ID,
      Stream_ID_Policy.Client, Server_Peer, Client_Peer);
   Open_Stream (Client, Stream_ID_Policy.Bidirectional, Opened_ID, Opened);
   pragma Assert (Opened = Stream_ID_Policy.Opened);

   --  Put 200 packets behind the sender so a 64-range ACK covers only
   --  packets it really sent.  The peer acknowledges every eighth one so
   --  the congestion window and the 64-entry ledger are never the limit.
   for Index in 1 .. 200 loop
      Build_Stream_Packet
        (Client, Stream_ID => 0,
         Offset => Varint_Policy.Value_Type (Index - 1),
         Fin => False, Data => (1 => 16#61#),
         Now => Timestamp (1_000 * Index), Packet => Packet,
         Result => Sent_Data);
      exit when Sent_Data.Status /= Sent;
      Highest := Index - 1;
      Application_Connection.Process_One_RTT
        (Remote,
         Packet (1 .. Ada.Streams.Stream_Element_Offset
                        (Sent_Data.Packet_Length)),
         Plain, Decode);
      pragma Assert (Decode.Status = Application_Connection.Processed);
      if Index mod 8 = 0 then
         declare
            Peer_ACK : constant ACK_Frame_Policy.Encode_Result :=
              Application_Connection.Encode_ACK (Remote, 0);
         begin
            Application_Connection.Build_One_RTT
              (Remote,
               Peer_ACK.Data
                 (1 .. Ada.Streams.Stream_Element_Offset (Peer_ACK.Length)),
               Packet, Built);
            Process_Packet
              (Client,
               Packet (1 .. Ada.Streams.Stream_Element_Offset
                              (Built.Packet_Length)),
               Now => Timestamp (1_000 * Index + 500),
               ACK_Delay_Exponent => 3, Maximum_ACK_Delay => 25_000,
               Handshake_Confirmed => True, Result => Received);
         end;
      end if;
   end loop;
   Note ("highest packet number the sender reached:" & Highest'Image);
   Check (Highest >= 130,
          "precondition: enough packets were sent for a 64-range ACK");

   Try (62);
   Check (Received.Status = Processed,
          "precondition: an ACK with 62 ranges is accepted");

   Try (63);
   Check (Received.Status = Processed,
          "an ACK with 63 ranges is accepted");

   Try (64);
   Check (Received.Status = Processed,
          "an ACK with 64 ranges is accepted (RFC 9000 s19.3 sets no"
          & " maximum on ACK Range Count)");

   Finish;
end Flyology.QUIC.Application_Space.Repro_Quic_Transport_9;
