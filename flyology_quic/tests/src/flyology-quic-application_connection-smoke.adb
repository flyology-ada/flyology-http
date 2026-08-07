with Flyology.QUIC.One_RTT_Sender;

procedure Flyology.QUIC.Application_Connection.Smoke is
   use type Ada.Streams.Stream_Element_Offset;
   use type Connection_State_Policy.Packet_Number;

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
   Wrong_ID : constant Long_Header_Policy.Connection_ID :=
     ID ((16#99#, 16#20#, 16#30#, 16#40#));
   Client : Connection;
   Server : Connection;
begin
   Initialize (Client, Client_Keys, Server_Keys, Server_ID, Client_ID);
   Initialize (Server, Server_Keys, Client_Keys, Client_ID, Server_ID);
   declare
      Plaintext : constant Ada.Streams.Stream_Element_Array :=
        (16#01#, 0, 0, 0);
      Packet : Ada.Streams.Stream_Element_Array (1 .. 64);
      Decoded : Ada.Streams.Stream_Element_Array (Packet'Range);
      Built_Packet : Build_Result;
      Processed_Packet : Process_Result;
   begin
      declare
         Too_Small : Ada.Streams.Stream_Element_Array (1 .. 1);
         Failed : Build_Result;
      begin
         Build_One_RTT (Client, Plaintext, Too_Small, Failed);
         pragma Assert
           (Failed.Status = Output_Too_Small
            and then Failed.Number = 0
            and then Too_Small = (Too_Small'Range => 0));
      end;
      Build_One_RTT (Client, Plaintext, Packet, Built_Packet);
      pragma Assert
        (Built_Packet.Status = Built and then Built_Packet.Number = 0);
      Process_One_RTT
        (Server,
         Packet
           (1 .. Ada.Streams.Stream_Element_Offset
                   (Built_Packet.Packet_Length)),
         Decoded, Processed_Packet);
      pragma Assert
        (Processed_Packet.Status = Processed
         and then Processed_Packet.Packet.Number = 0
         and then Decoded (1 .. Plaintext'Length) = Plaintext);
      Process_One_RTT
        (Server,
         Packet
           (1 .. Ada.Streams.Stream_Element_Offset
                   (Built_Packet.Packet_Length)),
         Decoded, Processed_Packet);
      pragma Assert
        (Processed_Packet.Status = Duplicate
         and then Decoded = (Decoded'Range => 0));

      declare
         Backend : Crypto_OpenSSL.Provider;
         Wrong_Packet : Ada.Streams.Stream_Element_Array (1 .. 64);
         Wrong_Result : One_RTT_Sender.Send_Result;
      begin
         Crypto_OpenSSL.Initialize_Provider (Backend);
         One_RTT_Sender.Send
           (Backend, Client_Keys.Key, Client_Keys.IV, Client_Keys.HP,
            Wrong_ID, 1, 1, False, False, Plaintext, Wrong_Packet,
            Wrong_Result);
         Process_One_RTT
           (Server,
            Wrong_Packet
              (1 .. Ada.Streams.Stream_Element_Offset
                      (Wrong_Result.Packet_Length)),
            Decoded, Processed_Packet);
         pragma Assert
           (Processed_Packet.Status = Unexpected_Destination
            and then Decoded = (Decoded'Range => 0));
      end;
   end;
end Flyology.QUIC.Application_Connection.Smoke;
