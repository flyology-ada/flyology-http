with Ada.Streams;
with Repro_Support;

procedure Flyology.QUIC.Application_Space.Repro_Quic_Transport_4 is
   --  QUIC-TRANSPORT-4: the 1-RTT CRYPTO stream is judged one frame at a
   --  time, so anything but exactly one complete NewSessionTicket at
   --  CRYPTO offset 0 fails the connection after the handshake succeeded.
   --
   --  RFC 8446 s4.6.1: "Servers MAY send multiple tickets on a single
   --  connection, either immediately after each other or after specific
   --  events".
   --  RFC 9001 s4: "QUIC carries TLS handshake data in CRYPTO frames, each
   --  of which consists of a contiguous block of handshake data identified
   --  by an offset and length."

   use Repro_Support;
   use type Application_Connection.Build_Status;

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

   Client_Peer, Server_Peer :
     Transport_Parameter_Policy.Transport_Parameters;
   Sender : Application_Connection.Connection;
   Client : State;
   Packet : Ada.Streams.Stream_Element_Array (1 .. Max_Datagram_Length);
   Built  : Application_Connection.Build_Result;
   Received : Process_Result;
   Clock  : Timestamp := 600;

   procedure Feed
     (Label     : String;
      Plaintext : Ada.Streams.Stream_Element_Array;
      Status    : out Process_Status) is
   begin
      Application_Connection.Build_One_RTT (Sender, Plaintext, Packet, Built);
      pragma Assert (Built.Status = Application_Connection.Built);
      Clock := Clock + 1;
      Process_Packet
        (Client,
         Packet (1 .. Ada.Streams.Stream_Element_Offset
                        (Built.Packet_Length)),
         Now => Clock, ACK_Delay_Exponent => 3,
         Maximum_ACK_Delay => 25_000, Handshake_Confirmed => True,
         Result => Received);
      Status := Received.Status;
      Note (Label & ": " & Process_Status'Image (Status));
   end Feed;

   Status : Process_Status;

begin
   Client_Peer.Initial_Max_Data := (Present => True, Value => 100);
   Client_Peer.Initial_Max_Stream_Data_Bidi_Local :=
     (Present => True, Value => 100);
   Client_Peer.Initial_Max_Stream_Data_Bidi_Remote :=
     (Present => True, Value => 100);
   Client_Peer.Initial_Max_Stream_Data_Uni := (Present => True, Value => 100);
   Client_Peer.Initial_Max_Streams_Bidi := (Present => True, Value => 4);
   Client_Peer.Initial_Max_Streams_Uni := (Present => True, Value => 4);
   Server_Peer := Client_Peer;

   Application_Connection.Initialize
     (Sender, Server_Keys, Client_Keys, Client_ID, Server_ID);
   Initialize
     (Client, Client_Keys, Server_Keys, Server_ID, Client_ID,
      Stream_ID_Policy.Client, Server_Peer, Client_Peer);

   --  Precondition: one complete NewSessionTicket at offset 0 is accepted.
   --  CRYPTO(type 06, offset 0, length 4) carrying handshake message
   --  type 4 (NewSessionTicket) with a zero-length body.
   Feed ("first ticket at CRYPTO offset 0",
         (16#06#, 0, 4, 4, 0, 0, 0), Status);
   Check (Status = Processed,
          "precondition: one complete ticket at offset 0 is accepted");

   --  A second NewSessionTicket follows at CRYPTO offset 4, which is where
   --  the continuous CRYPTO offset space puts it.
   Feed ("second ticket at CRYPTO offset 4",
         (16#06#, 4, 4, 4, 0, 0, 0), Status);
   Check (Status = Processed,
          "a client accepts a second NewSessionTicket at the next CRYPTO"
          & " offset (RFC 8446 s4.6.1)");

   --  Two tickets carried in one CRYPTO frame.
   declare
      Fresh_Sender : Application_Connection.Connection;
      Fresh_Client : State;
   begin
      Application_Connection.Initialize
        (Fresh_Sender, Server_Keys, Client_Keys, Client_ID, Server_ID);
      Initialize
        (Fresh_Client, Client_Keys, Server_Keys, Server_ID, Client_ID,
         Stream_ID_Policy.Client, Server_Peer, Client_Peer);
      Application_Connection.Build_One_RTT
        (Fresh_Sender, (16#06#, 0, 8, 4, 0, 0, 0, 4, 0, 0, 0),
         Packet, Built);
      pragma Assert (Built.Status = Application_Connection.Built);
      Process_Packet
        (Fresh_Client,
         Packet (1 .. Ada.Streams.Stream_Element_Offset
                        (Built.Packet_Length)),
         Now => 700, ACK_Delay_Exponent => 3,
         Maximum_ACK_Delay => 25_000, Handshake_Confirmed => True,
         Result => Received);
      Note ("two tickets in one CRYPTO frame: "
            & Process_Status'Image (Received.Status));
      Check (Received.Status = Processed,
             "a client accepts two complete NewSessionTickets carried in"
             & " one CRYPTO frame");
   end;

   --  One ticket longer than a single frame, split across two frames: the
   --  first frame's handshake body length exceeds the frame payload.
   declare
      Fresh_Sender : Application_Connection.Connection;
      Fresh_Client : State;
   begin
      Application_Connection.Initialize
        (Fresh_Sender, Server_Keys, Client_Keys, Client_ID, Server_ID);
      Initialize
        (Fresh_Client, Client_Keys, Server_Keys, Server_ID, Client_ID,
         Stream_ID_Policy.Client, Server_Peer, Client_Peer);
      --  CRYPTO(offset 0, length 6) holding the first 6 bytes of a ticket
      --  whose declared body length is 8.
      Application_Connection.Build_One_RTT
        (Fresh_Sender, (16#06#, 0, 6, 4, 0, 0, 8, 16#AA#, 16#BB#),
         Packet, Built);
      pragma Assert (Built.Status = Application_Connection.Built);
      Process_Packet
        (Fresh_Client,
         Packet (1 .. Ada.Streams.Stream_Element_Offset
                        (Built.Packet_Length)),
         Now => 800, ACK_Delay_Exponent => 3,
         Maximum_ACK_Delay => 25_000, Handshake_Confirmed => True,
         Result => Received);
      Note ("first half of a split ticket: "
            & Process_Status'Image (Received.Status));
      Check (Received.Status = Processed,
             "a client buffers the first CRYPTO frame of a ticket that"
             & " spans two frames (RFC 9001 s4)");
   end;

   Finish;
end Flyology.QUIC.Application_Space.Repro_Quic_Transport_4;
