procedure Flyology.QUIC.Handshake_Connection.Smoke is
   use type Ada.Streams.Stream_Element_Offset;
   use type Connection_State_Policy.Packet_Number;

   function ID
     (Data : Ada.Streams.Stream_Element_Array)
      return Long_Header_Policy.Connection_ID
   is
      Result : Long_Header_Policy.Connection_ID;
   begin
      Result.Length := Natural (Data'Length);
      if Data'Length > 0 then
         Result.Data (1 .. Data'Length) := Data;
      end if;
      return Result;
   end ID;

   Client_Keys : constant TLS_Key_Schedule.QUIC_Traffic_Keys :=
     (Traffic => (others => 0),
      Key => (others => 16#11#),
      IV  => (others => 16#22#),
      HP  => (others => 16#33#));
   Server_Keys : constant TLS_Key_Schedule.QUIC_Traffic_Keys :=
     (Traffic => (others => 0),
      Key => (others => 16#44#),
      IV  => (others => 16#55#),
      HP  => (others => 16#66#));
   Client_ID : constant Long_Header_Policy.Connection_ID :=
     ID ((16#AA#, 16#BB#, 16#CC#, 16#DD#));
   Server_ID : constant Long_Header_Policy.Connection_ID :=
     ID ((16#10#, 16#20#, 16#30#, 16#40#));
   Client : Connection;
   Server : Connection;
begin
   Initialize (Client, Client_Keys, Server_Keys, Server_ID, Client_ID);
   Initialize (Server, Server_Keys, Client_Keys, Client_ID, Server_ID);

   declare
      Plaintext : constant Ada.Streams.Stream_Element_Array :=
        (1 => 16#06#, 2 => 0, 3 => 20, 4 .. 23 => 16#A5#);
      Packet : Ada.Streams.Stream_Element_Array (1 .. 96);
      Decoded : Ada.Streams.Stream_Element_Array (Packet'Range);
      Built_Packet : Build_Result;
      Processed_Packet : Process_Result;
   begin
      declare
         Too_Small : Ada.Streams.Stream_Element_Array (1 .. 1);
         Failed : Build_Result;
      begin
         Build_Handshake (Client, Plaintext, Too_Small, Failed);
         pragma Assert
           (Failed.Status = Output_Too_Small
            and then Failed.Number = 0
            and then Too_Small = (Too_Small'Range => 0));
      end;

      Build_Handshake (Client, Plaintext, Packet, Built_Packet);
      pragma Assert
        (Built_Packet.Status = Built
         and then Built_Packet.Number = 0
         and then Built_Packet.Number_Length = 1);
      Process_Handshake
        (Server,
         Packet
           (Packet'First
              .. Packet'First
                   + Ada.Streams.Stream_Element_Offset
                       (Built_Packet.Packet_Length - 1)),
         Decoded, Processed_Packet);
      pragma Assert
        (Processed_Packet.Status = Processed
         and then Processed_Packet.Packet.Number = 0
         and then Processed_Packet.Packet.Plaintext_Length = Plaintext'Length
         and then Decoded (1 .. Plaintext'Length) = Plaintext);

      Process_Handshake
        (Server,
         Packet
           (Packet'First
              .. Packet'First
                   + Ada.Streams.Stream_Element_Offset
                       (Built_Packet.Packet_Length - 1)),
         Decoded, Processed_Packet);
      pragma Assert
        (Processed_Packet.Status = Duplicate
         and then Decoded = (Decoded'Range => 0));

      declare
         Reply : constant Ada.Streams.Stream_Element_Array :=
           (16#01#, 0, 0, 0);
         Reply_Packet : Ada.Streams.Stream_Element_Array (1 .. 64);
         Reply_Build : Build_Result;
      begin
         Build_Handshake (Server, Reply, Reply_Packet, Reply_Build);
         pragma Assert
           (Reply_Build.Status = Built and then Reply_Build.Number = 0);
         Process_Handshake
           (Client,
            Reply_Packet
              (Reply_Packet'First
                 .. Reply_Packet'First
                      + Ada.Streams.Stream_Element_Offset
                          (Reply_Build.Packet_Length - 1)),
            Decoded, Processed_Packet);
         pragma Assert
           (Processed_Packet.Status = Processed
            and then Processed_Packet.Packet.Number = 0
            and then Decoded (1 .. Reply'Length) = Reply);
      end;
   end;
end Flyology.QUIC.Handshake_Connection.Smoke;
