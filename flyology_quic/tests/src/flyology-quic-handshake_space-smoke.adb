procedure Flyology.QUIC.Handshake_Space.Smoke is
   use type Ada.Streams.Stream_Element;

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
   Client : State;
   Server : State;
   Flight : Ada.Streams.Stream_Element_Array (1 .. 2_500);
   Packet_1, Packet_2, Packet_3 :
     Ada.Streams.Stream_Element_Array (1 .. Max_Datagram_Length);
   Built_1, Built_2, Built_3 : Build_Result;
   Received : Process_Result;
begin
   for Index in Flight'Range loop
      Flight (Index) := Ada.Streams.Stream_Element (Index mod 251);
   end loop;
   Initialize (Client, Client_Keys, Server_Keys, Server_ID, Client_ID);
   Initialize (Server, Server_Keys, Client_Keys, Client_ID, Server_ID);

   Build_Crypto_Packet
     (Client, 0, Flight (1 .. 1_000), Packet_1, Built_1);
   Build_Crypto_Packet
     (Client, 1_000, Flight (1_001 .. 2_000), Packet_2, Built_2);
   Build_Crypto_Packet
     (Client, 2_000, Flight (2_001 .. 2_500), Packet_3, Built_3);
   pragma Assert
     (Built_1.Status = Built and then Built_2.Status = Built
      and then Built_3.Status = Built
      and then Built_1.Packet_Length <= Max_Datagram_Length
      and then Built_2.Packet_Length <= Max_Datagram_Length
      and then Built_3.Packet_Length <= Max_Datagram_Length);

   Process_Packet
     (Server,
      Packet_2
        (1 .. Ada.Streams.Stream_Element_Offset (Built_2.Packet_Length)),
      Received);
   pragma Assert
     (Received.Status = Processed and then Contiguous_Length (Server) = 0);
   Process_Packet
     (Server,
      Packet_1
        (1 .. Ada.Streams.Stream_Element_Offset (Built_1.Packet_Length)),
      Received);
   pragma Assert (Contiguous_Length (Server) = 2_000);
   Process_Packet
     (Server,
      Packet_3
        (1 .. Ada.Streams.Stream_Element_Offset (Built_3.Packet_Length)),
      Received);
   pragma Assert
     (Received.Status = Processed
      and then Contiguous_Length (Server) = Flight'Length);
   for Index in Crypto_Reassembly_Policy.Stream_Index
     range 0 .. Flight'Length - 1
   loop
      pragma Assert
        (Crypto_Element (Server, Index) = Flight (Flight'First + Index));
   end loop;
end Flyology.QUIC.Handshake_Space.Smoke;
