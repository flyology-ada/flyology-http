with Flyology.QUIC.One_RTT_Sender;

procedure Flyology.QUIC.Application_Connection.Smoke is
   use type Ada.Streams.Stream_Element_Offset;
   use type Connection_State_Policy.Packet_Number;
   use type One_RTT_Sender.Send_Status;

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
     (Traffic => (others => 16#01#),
      Key => (others => 16#11#), IV => (others => 16#22#),
      HP => (others => 16#33#));
   Server_Keys : constant TLS_Key_Schedule.QUIC_Traffic_Keys :=
     (Traffic => (others => 16#02#),
      Key => (others => 16#44#), IV => (others => 16#55#),
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
         Next_Keys, Next_Next_Keys : TLS_Key_Schedule.QUIC_Traffic_Keys;
         Old_Packet, Updated_Packet :
           Ada.Streams.Stream_Element_Array (1 .. 64);
         Old_Built : Build_Result;
         Updated : One_RTT_Sender.Send_Result;
      begin
         Crypto_OpenSSL.Initialize_Provider (Backend);
         Build_One_RTT (Client, Plaintext, Old_Packet, Old_Built);
         pragma Assert
           (Old_Built.Status = Built and then Old_Built.Number = 1);
         TLS_Key_Schedule.Update_QUIC_Keys
           (Backend, Client_Keys, Next_Keys);
         pragma Assert (Next_Keys.HP = Client_Keys.HP);
         One_RTT_Sender.Send
           (Backend, Next_Keys.Key, Next_Keys.IV, Next_Keys.HP,
            Server_ID, 2, 1, Key_Phase => True, Spin => False,
            Plaintext => Plaintext, Packet => Updated_Packet,
            Result => Updated);
         pragma Assert (Updated.Status = One_RTT_Sender.Sent);
         Process_One_RTT
           (Server,
            Updated_Packet
              (1 .. Ada.Streams.Stream_Element_Offset
                      (Updated.Packet_Length)),
            Decoded, Processed_Packet);
         pragma Assert
           (Processed_Packet.Status = Processed
            and then Processed_Packet.Packet.Key_Phase);
         Process_One_RTT
           (Server,
            Old_Packet
              (1 .. Ada.Streams.Stream_Element_Offset
                      (Old_Built.Packet_Length)),
            Decoded, Processed_Packet);
         pragma Assert
           (Processed_Packet.Status = Processed
            and then not Processed_Packet.Packet.Key_Phase);

         TLS_Key_Schedule.Update_QUIC_Keys
           (Backend, Next_Keys, Next_Next_Keys);
         pragma Assert (Next_Next_Keys.HP = Client_Keys.HP);
         One_RTT_Sender.Send
           (Backend, Next_Next_Keys.Key, Next_Next_Keys.IV,
            Next_Next_Keys.HP, Server_ID, 3, 1,
            Key_Phase => False, Spin => False,
            Plaintext => Plaintext, Packet => Updated_Packet,
            Result => Updated);
         pragma Assert (Updated.Status = One_RTT_Sender.Sent);
         Process_One_RTT
           (Server,
            Updated_Packet
              (1 .. Ada.Streams.Stream_Element_Offset
                      (Updated.Packet_Length)),
            Decoded, Processed_Packet);
         pragma Assert
           (Processed_Packet.Status = Processed
            and then not Processed_Packet.Packet.Key_Phase);
      end;

      declare
         Backend : Crypto_OpenSSL.Provider;
         Intermediate, Current_Keys : TLS_Key_Schedule.QUIC_Traffic_Keys;
         Wrong_Packet : Ada.Streams.Stream_Element_Array (1 .. 64);
         Wrong_Result : One_RTT_Sender.Send_Result;
      begin
         Crypto_OpenSSL.Initialize_Provider (Backend);
         TLS_Key_Schedule.Update_QUIC_Keys
           (Backend, Client_Keys, Intermediate);
         TLS_Key_Schedule.Update_QUIC_Keys
           (Backend, Intermediate, Current_Keys);
         One_RTT_Sender.Send
           (Backend, Current_Keys.Key, Current_Keys.IV, Current_Keys.HP,
            Wrong_ID, 4, 1, False, False, Plaintext, Wrong_Packet,
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
