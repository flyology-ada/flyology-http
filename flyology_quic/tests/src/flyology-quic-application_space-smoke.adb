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
      Stream_ID_Policy.Client, Client_Peer);
   Initialize
     (Server, Server_Keys, Client_Keys, Client_ID, Server_ID,
      Stream_ID_Policy.Server, Server_Peer);

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
         Stream_ID_Policy.Client, Client_Peer);
      Initialize
        (Loss_Server, Server_Keys, Client_Keys, Client_ID, Server_ID,
         Stream_ID_Policy.Server, Server_Peer);
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
         Stream_ID_Policy.Client, Server_Peer);
      Initialize
        (Abort_Server, Server_Keys, Client_Keys, Client_ID, Server_ID,
         Stream_ID_Policy.Server, Server_Peer);
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
end Flyology.QUIC.Application_Space.Smoke;
