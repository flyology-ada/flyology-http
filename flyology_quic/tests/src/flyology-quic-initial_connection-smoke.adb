with Flyology.IO.Sockets;
with Flyology.QUIC.Initial_Frame_Policy;

procedure Flyology.QUIC.Initial_Connection.Smoke is
   package Sockets renames Flyology.IO.Sockets;

   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Connection_State_Policy.Packet_Number;
   use type Initial_Frame_Policy.Frame_Kind;
   use type Initial_Frame_Policy.Parse_Status;
   use type Sockets.Endpoint;

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

   procedure Close_Quietly (Socket : in out Sockets.Socket_Type) is
   begin
      if Sockets.Is_Open (Socket) then
         Sockets.Close_Socket (Socket);
      end if;
   exception
      when others => null;
   end Close_Quietly;

   Original_ID : constant Ada.Streams.Stream_Element_Array :=
     (16#83#, 16#94#, 16#C8#, 16#F0#, 16#3E#, 16#51#, 16#57#, 16#08#);
   Client_ID : constant Long_Header_Policy.Connection_ID :=
     ID ((16#AA#, 16#BB#, 16#CC#, 16#DD#, 16#01#, 16#02#, 16#03#, 16#04#));
   Server_ID : constant Long_Header_Policy.Connection_ID :=
     ID ((16#10#, 16#20#, 16#30#, 16#40#, 16#50#, 16#60#, 16#70#, 16#80#));
   Original_Destination : constant Long_Header_Policy.Connection_ID :=
     ID (Original_ID);

   Client_Connection : Connection;
   Server_Connection : Connection;
   Client_Socket     : Sockets.Socket_Type;
   Server_Socket     : Sockets.Socket_Type;
begin
   Initialize
     (Client_Connection, Client, Original_ID, Original_Destination, Client_ID);
   Initialize
     (Server_Connection, Server, Original_ID, Client_ID, Server_ID);

   declare
      Padding_Connection : Connection;
      Tiny_Plaintext     : constant Ada.Streams.Stream_Element_Array :=
        (1 => 16#01#);
      Padded_Packet      : Ada.Streams.Stream_Element_Array (1 .. 1_200);
      Padded_Build       : Build_Result;
   begin
      Initialize
        (Padding_Connection, Client, Original_ID, Original_Destination,
         Client_ID);
      Build_Initial_At_Least
        (Padding_Connection, (1 .. 0 => 0), Tiny_Plaintext, 1_200,
         Padded_Packet, Padded_Build);
      pragma Assert
        (Padded_Build.Status = Built
         and then Padded_Build.Number = 0
         and then Padded_Build.Packet_Length = 1_200);
   end;

   Sockets.Create_Socket
     (Client_Socket, Sockets.IPv4, Sockets.Socket_Datagram);
   Sockets.Bind_Socket
     (Client_Socket,
      Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
   Sockets.Create_Socket
     (Server_Socket, Sockets.IPv4, Sockets.Socket_Datagram);
   Sockets.Bind_Socket
     (Server_Socket,
      Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));

   declare
      Client_Endpoint : constant Sockets.Endpoint :=
        Sockets.Get_Socket_Name (Client_Socket);
      Server_Endpoint : constant Sockets.Endpoint :=
        Sockets.Get_Socket_Name (Server_Socket);
      Client_Plaintext : Ada.Streams.Stream_Element_Array (1 .. 1_157) :=
        (others => 0);
      Client_Packet : Ada.Streams.Stream_Element_Array (1 .. 1_200);
      Incoming      : Ada.Streams.Stream_Element_Array (1 .. 1_200);
      Decoded       : Ada.Streams.Stream_Element_Array (Incoming'Range);
      Build         : Build_Result;
      Processed_Packet : Process_Result;
      Last          : Ada.Streams.Stream_Element_Offset;
      Peer          : Sockets.Endpoint;
   begin
      Client_Plaintext (Client_Plaintext'First) := 1;
      declare
         Too_Small : Ada.Streams.Stream_Element_Array (1 .. 1);
         Failed    : Build_Result;
      begin
         Build_Initial
           (Client_Connection, (1 .. 0 => 0), Client_Plaintext, Too_Small,
            Failed);
         pragma Assert
           (Failed.Status = Output_Too_Small
            and then Failed.Number = 0
            and then Too_Small = (Too_Small'Range => 0));
      end;
      Build_Initial
        (Client_Connection, (1 .. 0 => 0), Client_Plaintext, Client_Packet,
         Build);
      pragma Assert
        (Build.Status = Built
         and then Build.Number = 0
         and then Build.Number_Length = 1
         and then Build.Packet_Length = 1_200);

      declare
         Tampered : Ada.Streams.Stream_Element_Array (Client_Packet'Range) :=
           Client_Packet;
      begin
         Tampered (Tampered'Last) := Tampered (Tampered'Last) xor 1;
         Sockets.Send_Socket
           (Client_Socket, Tampered, Last, Server_Endpoint);
         Sockets.Receive_Socket (Server_Socket, Incoming, Last, Peer);
         Process_Initial
           (Server_Connection, Incoming, Decoded, Processed_Packet);
         pragma Assert
           (Processed_Packet.Status = Authentication_Failed
            and then Decoded = (Decoded'Range => 0));
      end;

      Sockets.Send_Socket
        (Client_Socket, Client_Packet, Last, Server_Endpoint);
      pragma Assert (Last = Client_Packet'Last);
      Sockets.Receive_Socket (Server_Socket, Incoming, Last, Peer);
      pragma Assert (Last = Incoming'Last and then Peer = Client_Endpoint);
      Process_Initial
        (Server_Connection, Incoming, Decoded, Processed_Packet);
      pragma Assert
        (Processed_Packet.Status = Processed
         and then Processed_Packet.Packet.Number = 0
         and then Processed_Packet.Packet.Plaintext_Length =
           Client_Plaintext'Length
         and then Decoded (1 .. Client_Plaintext'Length) = Client_Plaintext);

      declare
         Ping : constant Initial_Frame_Policy.Parse_Result :=
           Initial_Frame_Policy.Parse_Next
             (Decoded (1 .. Client_Plaintext'Length), 0);
         Padding : constant Initial_Frame_Policy.Parse_Result :=
           Initial_Frame_Policy.Parse_Next
             (Decoded (1 .. Client_Plaintext'Length), Ping.Consumed);
      begin
         pragma Assert
           (Ping.Status = Initial_Frame_Policy.Parsed
            and then Ping.Kind = Initial_Frame_Policy.Ping
            and then Padding.Status = Initial_Frame_Policy.Parsed
            and then Padding.Kind = Initial_Frame_Policy.Padding
            and then Padding.Padding_Length = Client_Plaintext'Length - 1);
      end;

      declare
         Server_Plaintext : constant Ada.Streams.Stream_Element_Array :=
           (2, 0, 0, 0, 0);
         Server_Packet : Ada.Streams.Stream_Element_Array (1 .. 128);
         Server_Incoming : Ada.Streams.Stream_Element_Array (1 .. 128);
         Server_Decoded  : Ada.Streams.Stream_Element_Array
           (Server_Incoming'Range);
         Server_Build   : Build_Result;
         Client_Process : Process_Result;
      begin
         Build_Initial
           (Server_Connection, (1 .. 0 => 0), Server_Plaintext,
            Server_Packet, Server_Build);
         pragma Assert
           (Server_Build.Status = Built
            and then Server_Build.Number = 0
            and then Server_Build.Number_Length = 1);
         Sockets.Send_Socket
           (Server_Socket,
            Server_Packet
              (Server_Packet'First
               .. Server_Packet'First
                 + Ada.Streams.Stream_Element_Offset
                     (Server_Build.Packet_Length - 1)),
            Last, Peer);
         Sockets.Receive_Socket
           (Client_Socket, Server_Incoming, Last, Peer);
         pragma Assert (Peer = Server_Endpoint);
         Process_Initial
           (Client_Connection,
            Server_Incoming
              (Server_Incoming'First .. Last),
            Server_Decoded, Client_Process);
         pragma Assert
           (Client_Process.Status = Processed
            and then Client_Process.Packet.Number = 0
            and then Client_Process.Packet.Plaintext_Length =
              Server_Plaintext'Length
            and then
              Server_Decoded (1 .. Server_Plaintext'Length) =
                Server_Plaintext);
         declare
            ACK : constant Initial_Frame_Policy.Parse_Result :=
              Initial_Frame_Policy.Parse_Next
                (Server_Decoded (1 .. Server_Plaintext'Length), 0);
         begin
            pragma Assert
              (ACK.Status = Initial_Frame_Policy.Parsed
               and then ACK.Kind = Initial_Frame_Policy.Acknowledgment
               and then ACK.Largest_Acknowledged = 0);
         end;
      end;

      Sockets.Send_Socket
        (Client_Socket, Client_Packet, Last, Server_Endpoint);
      Sockets.Receive_Socket (Server_Socket, Incoming, Last, Peer);
      Process_Initial
        (Server_Connection, Incoming, Decoded, Processed_Packet);
      pragma Assert
        (Processed_Packet.Status = Duplicate
         and then Decoded = (Decoded'Range => 0));
   end;

   Sockets.Close_Socket (Client_Socket);
   Sockets.Close_Socket (Server_Socket);
exception
   when others =>
      Close_Quietly (Client_Socket);
      Close_Quietly (Server_Socket);
      raise;
end Flyology.QUIC.Initial_Connection.Smoke;
