procedure Flyology.QUIC.Initial_Space.Smoke is
   use type Ada.Streams.Stream_Element;
   use type Long_Header_Policy.Connection_ID;

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

   Original_ID : constant Ada.Streams.Stream_Element_Array :=
     (16#83#, 16#94#, 16#C8#, 16#F0#, 16#3E#, 16#51#, 16#57#, 16#08#);
   Client_ID : constant Long_Header_Policy.Connection_ID :=
     ID ((16#AA#, 16#BB#, 16#CC#, 16#DD#));
   Server_ID : constant Long_Header_Policy.Connection_ID :=
     ID ((16#10#, 16#20#, 16#30#, 16#40#));
   Original_Destination : constant Long_Header_Policy.Connection_ID :=
     ID (Original_ID);
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
   Initialize
     (Client, Initial_Connection.Client, Original_ID, Original_Destination,
      Client_ID);
   Initialize
     (Server, Initial_Connection.Server, Original_ID, Client_ID, Server_ID);

   Build_Crypto_Packet
     (Client, 0, Flight (1 .. 1_000), 100, Packet_1, Built_1);
   Build_Crypto_Packet
     (Client, 1_000, Flight (1_001 .. 2_000), 100, Packet_2, Built_2);
   Build_Crypto_Packet
     (Client, 2_000, Flight (2_001 .. 2_500), 100, Packet_3, Built_3);
   pragma Assert
     (Built_1.Status = Built and then Built_2.Status = Built
      and then Built_3.Status = Built
      and then Built_1.Packet_Length = 1_200
      and then Built_2.Packet_Length = 1_200
      and then Built_3.Packet_Length = 1_200);

   Process_Packet
     (Server,
      Packet_2
        (1 .. Ada.Streams.Stream_Element_Offset (Built_2.Packet_Length)),
      200, 1_000, Received);
   pragma Assert
     (Received.Status = Processed
      and then Received.Peer_Source = Client_ID
      and then Contiguous_Length (Server) = 0);
   Process_Packet
     (Server,
      Packet_1
        (1 .. Ada.Streams.Stream_Element_Offset (Built_1.Packet_Length)),
      200, 1_000, Received);
   pragma Assert (Contiguous_Length (Server) = 2_000);
   Process_Packet
     (Server,
      Packet_3
        (1 .. Ada.Streams.Stream_Element_Offset (Built_3.Packet_Length)),
      200, 1_000, Received);
   pragma Assert (Contiguous_Length (Server) = Flight'Length);
   for Index in Crypto_Reassembly_Policy.Stream_Index
     range 0 .. Flight'Length - 1
   loop
      pragma Assert
        (Crypto_Element (Server, Index) = Flight (Flight'First + Index));
   end loop;

   Build_Crypto_Packet
     (Server, 0, Flight (1 .. 32), 300, Packet_1, Built_1);
   pragma Assert
     (Built_1.Status = Built
      and then Built_1.Packet_Length < Max_Datagram_Length);
end Flyology.QUIC.Initial_Space.Smoke;
