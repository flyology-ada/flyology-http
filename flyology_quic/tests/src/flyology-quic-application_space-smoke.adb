procedure Flyology.QUIC.Application_Space.Smoke is
   use type Ada.Streams.Stream_Element;
   use type Application_Connection.Build_Status;
   use type Recovery_Policy.Byte_Count;
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
     (Key => (others => 16#11#), IV => (others => 16#22#),
      HP => (others => 16#33#));
   Server_Keys : constant TLS_Key_Schedule.QUIC_Traffic_Keys :=
     (Key => (others => 16#44#), IV => (others => 16#55#),
      HP => (others => 16#66#));
   Client_ID : constant Long_Header_Policy.Connection_ID :=
     ID ((16#AA#, 16#BB#, 16#CC#, 16#DD#));
   Server_ID : constant Long_Header_Policy.Connection_ID :=
     ID ((16#10#, 16#20#, 16#30#, 16#40#));
   Client_Peer : Transport_Parameter_Policy.Transport_Parameters;
   Server_Peer : Transport_Parameter_Policy.Transport_Parameters;
   Client     : State;
   Server     : State;
   Packet     : Ada.Streams.Stream_Element_Array (1 .. Max_Datagram_Length);
   Sent_Data  : Send_Result;
   Received   : Process_Result;
   Opened_ID  : Varint_Policy.Value_Type;
   Opened     : Open_Status;
   Control    : constant Ada.Streams.Stream_Element_Array :=
     (16#10#, 10, 16#11#, 0, 10, 16#12#, 2);
   Built      : Application_Connection.Build_Result;
begin
   Client_Peer.Initial_Max_Data := (Present => True, Value => 2);
   Client_Peer.Initial_Max_Stream_Data_Bidi_Local :=
     (Present => True, Value => 2);
   Client_Peer.Initial_Max_Stream_Data_Bidi_Remote :=
     (Present => True, Value => 2);
   Client_Peer.Initial_Max_Stream_Data_Uni :=
     (Present => True, Value => 2);
   Client_Peer.Initial_Max_Streams_Bidi := (Present => True, Value => 1);
   Client_Peer.Initial_Max_Streams_Uni := (Present => True, Value => 1);
   Server_Peer.Initial_Max_Data := (Present => True, Value => 100);
   Server_Peer.Initial_Max_Stream_Data_Bidi_Local :=
     (Present => True, Value => 100);
   Server_Peer.Initial_Max_Stream_Data_Bidi_Remote :=
     (Present => True, Value => 100);
   Server_Peer.Initial_Max_Stream_Data_Uni :=
     (Present => True, Value => 100);
   Server_Peer.Initial_Max_Streams_Bidi := (Present => True, Value => 4);
   Server_Peer.Initial_Max_Streams_Uni := (Present => True, Value => 4);

   Initialize
     (Client, Client_Keys, Server_Keys, Server_ID, Client_ID,
      Stream_ID_Policy.Client, Server_Peer, Client_Peer);
   Initialize
     (Server, Server_Keys, Client_Keys, Client_ID, Server_ID,
      Stream_ID_Policy.Server, Client_Peer, Server_Peer);

   Open_Stream (Client, Stream_ID_Policy.Bidirectional, Opened_ID, Opened);
   pragma Assert
     (Opened = Stream_ID_Policy.Opened and then Opened_ID = 0);
   Open_Stream (Client, Stream_ID_Policy.Bidirectional, Opened_ID, Opened);
   pragma Assert (Opened = Stream_ID_Policy.Stream_Limit_Reached);
   Build_Stream_Packet
     (Client, Stream_ID => 4, Offset => 0, Fin => False,
      Data => (1 => 16#00#), Now => 0, Packet => Packet,
      Result => Sent_Data);
   pragma Assert (Sent_Data.Status = Stream_Not_Sendable);

   Build_ACK_Packet (Client, 0, 0, Packet, Sent_Data);
   pragma Assert (Sent_Data.Status = Nothing_To_ACK);

   Build_Stream_Packet
     (Client, Stream_ID => 0, Offset => 0, Fin => True,
      Data => (16#48#, 16#33#), Now => 100, Packet => Packet,
      Result => Sent_Data);
   pragma Assert
     (Sent_Data.Status = Sent
      and then Sent_Data.Number = 0
      and then Retained_Packets (Client) = 1
      and then Committed_Data (Client) = 2
      and then Bytes_In_Flight (Client) =
        Recovery_Policy.Byte_Count (Sent_Data.Packet_Length));
   pragma Assert (Probe_Timeout (Client, 25_000) = 1_024_000);
   pragma Assert
     (Has_Recovery_Timeout (Client)
      and then Recovery_Deadline (Client, 25_000) = 1_024_100);
   On_Probe_Timeout (Client);
   pragma Assert
     (PTO_Count (Client) = 1
      and then Probe_Timeout (Client, 25_000) = 2_048_000
      and then Recovery_Deadline (Client, 25_000) = 2_048_100);
   Process_Packet
     (Server,
      Packet
        (1 .. Ada.Streams.Stream_Element_Offset (Sent_Data.Packet_Length)),
      Now => 150,
      ACK_Delay_Exponent => 3, Maximum_ACK_Delay => 25_000,
      Handshake_Confirmed => True, Result => Received);
   pragma Assert
     (Received.Status = Processed
      and then Received.Number = 0
      and then Received.ACK_Eliciting
      and then Has_Stream (Server, 0)
      and then Available_Length (Server, 0) = 2
      and then Stream_Element (Server, 0, 0) = 16#48#
      and then Stream_Element (Server, 0, 1) = 16#33#);

   Build_ACK_Packet (Server, ACK_Delay => 1, Now => 160,
                     Packet => Packet, Result => Sent_Data);
   pragma Assert
     (Sent_Data.Status = Sent
      and then Sent_Data.Number = 0
      and then Retained_Packets (Server) = 0
      and then Bytes_In_Flight (Server) = 0);
   Process_Packet
     (Client,
      Packet
        (1 .. Ada.Streams.Stream_Element_Offset (Sent_Data.Packet_Length)),
      Now => 200,
      ACK_Delay_Exponent => 3, Maximum_ACK_Delay => 25_000,
      Handshake_Confirmed => True, Result => Received);
   pragma Assert
     (Received.Status = Processed
      and then not Received.ACK_Eliciting
      and then Received.Resolved_Count = 1
      and then Retained_Packets (Client) = 0
      and then not Has_Recovery_Timeout (Client)
      and then Bytes_In_Flight (Client) = 0
      and then PTO_Count (Client) = 0
      and then Has_RTT_Sample (Client)
      and then Smoothed_RTT (Client) = 100);

   Process_Packet
     (Client,
      Packet
        (1 .. Ada.Streams.Stream_Element_Offset (Sent_Data.Packet_Length)),
      Now => 201,
      ACK_Delay_Exponent => 3, Maximum_ACK_Delay => 25_000,
      Handshake_Confirmed => True, Result => Received);
   pragma Assert (Received.Status = Duplicate);

   Build_Stream_Packet
     (Client, Stream_ID => 0, Offset => 2, Fin => True,
      Data => (1 => 16#21#), Now => 202, Packet => Packet,
      Result => Sent_Data);
   pragma Assert
     (Sent_Data.Status = Stream_Final_Size_Mismatch
      and then Committed_Data (Client) = 2);

   Build_Handshake_Done_Packet
     (Server, Now => 203, Packet => Packet, Result => Sent_Data);
   pragma Assert (Sent_Data.Status = Sent);
   --  Drop the original HANDSHAKE_DONE and recover it from a PTO probe.
   Build_Probe_Packet
     (Server, Now => 204, Packet => Packet, Result => Sent_Data);
   pragma Assert (Sent_Data.Status = Sent);
   Process_Packet
     (Client,
      Packet
        (1 .. Ada.Streams.Stream_Element_Offset (Sent_Data.Packet_Length)),
      Now => 205, ACK_Delay_Exponent => 3, Maximum_ACK_Delay => 25_000,
      Handshake_Confirmed => False, Result => Received);
   pragma Assert
     (Received.Status = Processed
      and then Received.ACK_Eliciting
      and then Received.Handshake_Done);

   Build_Handshake_Done_Packet
     (Client, Now => 206, Packet => Packet, Result => Sent_Data);
   pragma Assert (Sent_Data.Status = Sent);
   Process_Packet
     (Server,
      Packet
        (1 .. Ada.Streams.Stream_Element_Offset (Sent_Data.Packet_Length)),
      Now => 207, ACK_Delay_Exponent => 3, Maximum_ACK_Delay => 25_000,
      Handshake_Confirmed => True, Result => Received);
   pragma Assert (Received.Status = Unexpected_Handshake_Done);

   Application_Connection.Build_One_RTT
     (Server.Packets, Control, Packet, Built);
   pragma Assert (Built.Status = Application_Connection.Built);
   Process_Packet
     (Client,
      Packet (1 .. Ada.Streams.Stream_Element_Offset (Built.Packet_Length)),
      Now => 208, ACK_Delay_Exponent => 3, Maximum_ACK_Delay => 25_000,
      Handshake_Confirmed => True, Result => Received);
   pragma Assert (Received.Status = Processed);

   Open_Stream (Client, Stream_ID_Policy.Bidirectional, Opened_ID, Opened);
   pragma Assert
     (Opened = Stream_ID_Policy.Opened and then Opened_ID = 4);
   Build_Stream_Packet
     (Client, Stream_ID => 0, Offset => 2, Fin => True,
      Data => (1 => 16#21#), Now => 208, Packet => Packet,
      Result => Sent_Data);
   pragma Assert
     (Sent_Data.Status = Stream_Final_Size_Mismatch
      and then Committed_Data (Client) = 2);

   --  Time-threshold loss may empty the sent-packet ledger. Retained frames
   --  must keep recovery armed until a retransmitted copy is acknowledged.
   declare
      Loss_Client, Loss_Server : State;
      Loss_Packet : Ada.Streams.Stream_Element_Array
        (1 .. Max_Datagram_Length);
      Loss_Sent     : Send_Result;
      Loss_Received : Process_Result;
      Loss_ID       : Varint_Policy.Value_Type;
      Loss_Opened   : Open_Status;
   begin
      Initialize
        (Loss_Client, Client_Keys, Server_Keys, Server_ID, Client_ID,
         Stream_ID_Policy.Client, Server_Peer, Client_Peer);
      Initialize
        (Loss_Server, Server_Keys, Client_Keys, Client_ID, Server_ID,
         Stream_ID_Policy.Server, Client_Peer, Server_Peer);
      Open_Stream
        (Loss_Client, Stream_ID_Policy.Bidirectional, Loss_ID, Loss_Opened);
      pragma Assert
        (Loss_Opened = Stream_ID_Policy.Opened and then Loss_ID = 0);

      for Attempt in Natural range 0 .. 3 loop
         Build_Stream_Packet
           (Loss_Client, Stream_ID => Loss_ID, Offset => 0, Fin => True,
            Data => (16#48#, 16#33#), Now => Timestamp (100 + Attempt),
            Packet => Loss_Packet, Result => Loss_Sent);
         pragma Assert (Loss_Sent.Status = Sent);
      end loop;
      Process_Packet
        (Loss_Server,
         Loss_Packet
           (1 .. Ada.Streams.Stream_Element_Offset
                   (Loss_Sent.Packet_Length)),
         Now => 200, ACK_Delay_Exponent => 3,
         Maximum_ACK_Delay => 25_000, Handshake_Confirmed => True,
         Result => Loss_Received);
      pragma Assert (Loss_Received.Status = Processed);
      Build_ACK_Packet
        (Loss_Server, ACK_Delay => 0, Now => 201,
         Packet => Loss_Packet, Result => Loss_Sent);
      pragma Assert (Loss_Sent.Status = Sent);
      Process_Packet
        (Loss_Client,
         Loss_Packet
           (1 .. Ada.Streams.Stream_Element_Offset
                   (Loss_Sent.Packet_Length)),
         Now => 2_000_000, ACK_Delay_Exponent => 3,
         Maximum_ACK_Delay => 25_000, Handshake_Confirmed => True,
         Result => Loss_Received);
      pragma Assert
        (Loss_Received.Status = Processed
         and then Loss_Received.Resolved_Count = 4
         and then Retained_Packets (Loss_Client) = 0
         and then Has_Recovery_Timeout (Loss_Client));
      Build_Probe_Packet
        (Loss_Client, Now => 2_000_001,
         Packet => Loss_Packet, Result => Loss_Sent);
      pragma Assert (Loss_Sent.Status = Sent);
   end;

   declare
      Abort_Client, Abort_Server : State;
      Abort_Packet : Ada.Streams.Stream_Element_Array
        (1 .. Max_Datagram_Length);
      Abort_Sent     : Send_Result;
      Abort_Received : Process_Result;
      Abort_ID       : Varint_Policy.Value_Type;
      Abort_Opened   : Open_Status;
   begin
      Initialize
        (Abort_Client, Client_Keys, Server_Keys, Server_ID, Client_ID,
         Stream_ID_Policy.Client, Server_Peer, Server_Peer);
      Initialize
        (Abort_Server, Server_Keys, Client_Keys, Client_ID, Server_ID,
         Stream_ID_Policy.Server, Server_Peer, Server_Peer);
      Open_Stream
        (Abort_Client, Stream_ID_Policy.Bidirectional,
         Abort_ID, Abort_Opened);
      pragma Assert
        (Abort_Opened = Stream_ID_Policy.Opened and then Abort_ID = 0);
      Build_Stream_Packet
        (Abort_Client, Abort_ID, Offset => 0, Fin => False,
         Data => (16#68#, 16#33#), Now => 300,
         Packet => Abort_Packet, Result => Abort_Sent);
      pragma Assert (Abort_Sent.Status = Sent);
      Process_Packet
        (Abort_Server,
         Abort_Packet
           (1 .. Ada.Streams.Stream_Element_Offset
                   (Abort_Sent.Packet_Length)),
         Now => 301, ACK_Delay_Exponent => 3,
         Maximum_ACK_Delay => 25_000, Handshake_Confirmed => True,
         Result => Abort_Received);
      pragma Assert (Abort_Received.Status = Processed);

      Build_Stream_Abort_Packet
        (Abort_Client, Abort_ID, Application_Error => 16#10C#,
         Final_Size => 1, Now => 302,
         Packet => Abort_Packet, Result => Abort_Sent);
      pragma Assert (Abort_Sent.Status = Stream_Final_Size_Mismatch);
      Build_Stream_Abort_Packet
        (Abort_Client, Abort_ID, Application_Error => 16#10C#,
         Final_Size => 2, Now => 303,
         Packet => Abort_Packet, Result => Abort_Sent);
      pragma Assert (Abort_Sent.Status = Sent);
      Process_Packet
        (Abort_Server,
         Abort_Packet
           (1 .. Ada.Streams.Stream_Element_Offset
                   (Abort_Sent.Packet_Length)),
         Now => 304, ACK_Delay_Exponent => 3,
         Maximum_ACK_Delay => 25_000, Handshake_Confirmed => True,
         Result => Abort_Received);
      pragma Assert
        (Abort_Received.Status = Processed
         and then Was_Reset (Abort_Server, Abort_ID)
         and then Reset_Error (Abort_Server, Abort_ID) = 16#10C#);
   end;

   --  Stream admission and all other packet effects are transactional. A
   --  rejected packet must not expose an otherwise valid leading STREAM.
   declare
      Attack_Sender : Application_Connection.Connection;
      Attack_Server : State;
      Attack_Packet : Ada.Streams.Stream_Element_Array
        (1 .. Max_Datagram_Length);
      Attack_Built    : Application_Connection.Build_Result;
      Attack_Received : Process_Result;

      procedure Check_Rejected
        (Plaintext : Ada.Streams.Stream_Element_Array;
         Expected  : Process_Status)
      is
      begin
         Application_Connection.Build_One_RTT
           (Attack_Sender, Plaintext, Attack_Packet, Attack_Built);
         pragma Assert
           (Attack_Built.Status = Application_Connection.Built);
         Process_Packet
           (Attack_Server,
            Attack_Packet
              (1 .. Ada.Streams.Stream_Element_Offset
                      (Attack_Built.Packet_Length)),
            Now => Timestamp (Attack_Built.Number + 400),
            ACK_Delay_Exponent => 3, Maximum_ACK_Delay => 25_000,
            Handshake_Confirmed => True, Result => Attack_Received);
         pragma Assert
           (Attack_Received.Status = Expected
            and then not Has_Stream (Attack_Server, 0));
      end Check_Rejected;
   begin
      Application_Connection.Initialize
        (Attack_Sender, Client_Keys, Server_Keys, Server_ID, Client_ID);
      Initialize
        (Attack_Server, Server_Keys, Client_Keys, Client_ID, Server_ID,
         Stream_ID_Policy.Server, Client_Peer, Server_Peer);

      --  A server cannot receive its own unopened bidi or uni stream.
      Check_Rejected ((16#0A#, 1, 1, 16#A1#), Invalid_Stream_State);
      Check_Rejected ((16#0A#, 3, 1, 16#A3#), Invalid_Stream_State);
      --  The server advertised only one client-initiated bidi stream.
      Check_Rejected ((16#0A#, 4, 1, 16#A4#), Invalid_Stream_Limit);
      --  STREAM and RESET_STREAM final sizes both consume receive credit.
      Check_Rejected
        ((16#0A#, 0, 3, 16#A0#, 16#A1#, 16#A2#),
         Flow_Control_Error);
      Check_Rejected ((16#04#, 0, 0, 3), Flow_Control_Error);
      --  The valid leading byte is rolled back when HANDSHAKE_DONE is illegal.
      Check_Rejected
        ((16#0A#, 0, 1, 16#AA#, 16#1E#), Unexpected_Handshake_Done);

      Application_Connection.Build_One_RTT
        (Attack_Sender, (16#1C#, 10, 0, 0),
         Attack_Packet, Attack_Built);
      Process_Packet
        (Attack_Server,
         Attack_Packet
           (1 .. Ada.Streams.Stream_Element_Offset
                   (Attack_Built.Packet_Length)),
         Now => 500, ACK_Delay_Exponent => 3,
         Maximum_ACK_Delay => 25_000, Handshake_Confirmed => True,
         Result => Attack_Received);
      pragma Assert
        (Attack_Received.Status = Processed
         and then Attack_Received.Peer_Closed
         and then not Attack_Received.Application_Close
         and then Attack_Received.Close_Error = 10);

      Application_Connection.Build_One_RTT
        (Attack_Sender, (16#1D#, 11, 0),
         Attack_Packet, Attack_Built);
      Process_Packet
        (Attack_Server,
         Attack_Packet
           (1 .. Ada.Streams.Stream_Element_Offset
                   (Attack_Built.Packet_Length)),
         Now => 501, ACK_Delay_Exponent => 3,
         Maximum_ACK_Delay => 25_000, Handshake_Confirmed => True,
         Result => Attack_Received);
      pragma Assert
        (Attack_Received.Status = Processed
         and then Attack_Received.Peer_Closed
         and then Attack_Received.Application_Close
         and then Attack_Received.Close_Error = 11);
   end;

   --  Clients may ignore a complete post-handshake NewSessionTicket, while
   --  QUIC still rejects a TLS KeyUpdate carried in 1-RTT CRYPTO.
   declare
      Ticket_Sender : Application_Connection.Connection;
      Ticket_Client : State;
      Ticket_Packet : Ada.Streams.Stream_Element_Array
        (1 .. Max_Datagram_Length);
      Ticket_Built : Application_Connection.Build_Result;
      Ticket_Received : Process_Result;
   begin
      Application_Connection.Initialize
        (Ticket_Sender, Server_Keys, Client_Keys, Client_ID, Server_ID);
      Initialize
        (Ticket_Client, Client_Keys, Server_Keys, Server_ID, Client_ID,
         Stream_ID_Policy.Client, Server_Peer, Client_Peer);

      Application_Connection.Build_One_RTT
        (Ticket_Sender, (16#06#, 0, 4, 4, 0, 0, 0),
         Ticket_Packet, Ticket_Built);
      Process_Packet
        (Ticket_Client,
         Ticket_Packet
           (1 .. Ada.Streams.Stream_Element_Offset
                   (Ticket_Built.Packet_Length)),
         Now => 600, ACK_Delay_Exponent => 3,
         Maximum_ACK_Delay => 25_000, Handshake_Confirmed => True,
         Result => Ticket_Received);
      pragma Assert (Ticket_Received.Status = Processed);

      Application_Connection.Build_One_RTT
        (Ticket_Sender, (16#06#, 0, 5, 16#18#, 0, 0, 1, 0),
         Ticket_Packet, Ticket_Built);
      Process_Packet
        (Ticket_Client,
         Ticket_Packet
           (1 .. Ada.Streams.Stream_Element_Offset
                   (Ticket_Built.Packet_Length)),
         Now => 601, ACK_Delay_Exponent => 3,
         Maximum_ACK_Delay => 25_000, Handshake_Confirmed => True,
         Result => Ticket_Received);
      pragma Assert (Ticket_Received.Status = Unexpected_TLS_Message);
   end;
end Flyology.QUIC.Application_Space.Smoke;
