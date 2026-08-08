procedure Flyology.QUIC.Application_Space.Smoke is
   use type Ada.Streams.Stream_Element;
   use type Recovery_Policy.Byte_Count;

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
   Client     : State;
   Server     : State;
   Packet     : Ada.Streams.Stream_Element_Array (1 .. Max_Datagram_Length);
   Sent_Data  : Send_Result;
   Received   : Process_Result;
begin
   Initialize (Client, Client_Keys, Server_Keys, Server_ID, Client_ID);
   Initialize (Server, Server_Keys, Client_Keys, Client_ID, Server_ID);

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
      and then Bytes_In_Flight (Client) =
        Recovery_Policy.Byte_Count (Sent_Data.Packet_Length));
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
      and then Bytes_In_Flight (Client) = 0
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
end Flyology.QUIC.Application_Space.Smoke;
