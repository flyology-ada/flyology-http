procedure Flyology.QUIC.Application_Space.Batch_Smoke is
   use type Ada.Streams.Stream_Element;
   use type Stream_ID_Policy.Open_Status;
   use type Timestamp;

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

   Client_Parameters : Transport_Parameter_Policy.Transport_Parameters;
   Server_Parameters : Transport_Parameter_Policy.Transport_Parameters;
   Client : State;
   Server : State;
   Packet : Ada.Streams.Stream_Element_Array (1 .. Max_Datagram_Length);
   Sent : Send_Result;
   Received : Process_Result;
   Opened_ID : Varint_Policy.Value_Type;
   Opened : Open_Status;
   Fragments : constant Stream_Fragment_Array :=
     (1 => (ID => 0, Offset => 0, Length => 1, Fin => True),
      2 => (ID => 4, Offset => 0, Length => 1, Fin => True));
   Over_Credit : constant Stream_Fragment_Array :=
     (1 => (ID => 0, Offset => 0, Length => 2, Fin => True),
      2 => (ID => 4, Offset => 0, Length => 1, Fin => True));

   procedure Open_And_Deliver_Request
     (Expected_ID : Varint_Policy.Value_Type;
      Value       : Ada.Streams.Stream_Element;
      Now         : Timestamp)
   is
   begin
      Open_Stream
        (Client, Stream_ID_Policy.Bidirectional, Opened_ID, Opened);
      pragma Assert
        (Opened = Stream_ID_Policy.Opened and then Opened_ID = Expected_ID);
      Build_Stream_Packet
        (Client, Opened_ID, Offset => 0, Fin => True,
         Data => (1 => Value), Now => Now, Packet => Packet, Result => Sent);
      pragma Assert (Sent.Status = Application_Space.Sent);
      Process_Packet
        (Server,
         Packet
           (1 .. Ada.Streams.Stream_Element_Offset (Sent.Packet_Length)),
         Now => Now + 1, ACK_Delay_Exponent => 3,
         Maximum_ACK_Delay => 25_000, Handshake_Confirmed => True,
         Result => Received);
      pragma Assert (Received.Status = Processed);
   end Open_And_Deliver_Request;
begin
   Client_Parameters.Initial_Max_Data := (Present => True, Value => 2);
   Client_Parameters.Initial_Max_Stream_Data_Bidi_Local :=
     (Present => True, Value => 2);
   Client_Parameters.Initial_Max_Stream_Data_Bidi_Remote :=
     (Present => True, Value => 2);
   Client_Parameters.Initial_Max_Stream_Data_Uni :=
     (Present => True, Value => 2);
   Client_Parameters.Initial_Max_Streams_Bidi :=
     (Present => True, Value => 2);
   Client_Parameters.Initial_Max_Streams_Uni :=
     (Present => True, Value => 1);

   Server_Parameters.Initial_Max_Data := (Present => True, Value => 100);
   Server_Parameters.Initial_Max_Stream_Data_Bidi_Local :=
     (Present => True, Value => 100);
   Server_Parameters.Initial_Max_Stream_Data_Bidi_Remote :=
     (Present => True, Value => 100);
   Server_Parameters.Initial_Max_Stream_Data_Uni :=
     (Present => True, Value => 100);
   Server_Parameters.Initial_Max_Streams_Bidi :=
     (Present => True, Value => 4);
   Server_Parameters.Initial_Max_Streams_Uni :=
     (Present => True, Value => 4);

   Initialize
     (Client, Client_Keys, Server_Keys, Server_ID, Client_ID,
      Stream_ID_Policy.Client, Client_Parameters, Server_Parameters);
   Initialize
     (Server, Server_Keys, Client_Keys, Client_ID, Server_ID,
      Stream_ID_Policy.Server, Server_Parameters, Client_Parameters);
   Open_And_Deliver_Request (0, 16#A0#, 700);
   Open_And_Deliver_Request (4, 16#A4#, 702);

   Build_Stream_Batch_Packet
     (Server, Over_Credit, (16#B0#, 16#B1#, 16#B4#),
      Now => 704, Packet => Packet, Result => Sent);
   pragma Assert
     (Sent.Status = Connection_Flow_Blocked
      and then Committed_Data (Server) = 0);

   Build_Stream_Batch_Packet
     (Server, Fragments, (16#C0#, 16#C4#),
      Now => 705, Packet => Packet, Result => Sent);
   pragma Assert
     (Sent.Status = Application_Space.Sent
      and then Committed_Data (Server) = 2);
   Process_Packet
     (Client,
      Packet (1 .. Ada.Streams.Stream_Element_Offset (Sent.Packet_Length)),
      Now => 706, ACK_Delay_Exponent => 3,
      Maximum_ACK_Delay => 25_000, Handshake_Confirmed => True,
      Result => Received);
   pragma Assert
     (Received.Status = Processed
      and then Has_Stream (Client, 0)
      and then Has_Stream (Client, 4)
      and then Available_Length (Client, 0) = 1
      and then Available_Length (Client, 4) = 1
      and then Stream_Element (Client, 0, 0) = 16#C0#
      and then Stream_Element (Client, 4, 0) = 16#C4#);
end Flyology.QUIC.Application_Space.Batch_Smoke;
