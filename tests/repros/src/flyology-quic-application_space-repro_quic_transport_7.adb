with Ada.Streams;
with Flyology.QUIC.Application_Frame_Policy;
with Repro_Support;

procedure Flyology.QUIC.Application_Space.Repro_Quic_Transport_7 is
   --  QUIC-TRANSPORT-7: PATH_CHALLENGE is parsed by the frame codec but the
   --  1-RTT frame loop has no branch for it, so it is counted as
   --  ack-eliciting and discarded.  No PATH_RESPONSE is ever built.
   --
   --  RFC 9000 s8.2.2: "On receiving a PATH_CHALLENGE frame, an endpoint
   --  MUST respond by echoing the data contained in the PATH_CHALLENGE frame
   --  in a PATH_RESPONSE frame.  An endpoint MUST NOT delay transmission of
   --  a packet containing a PATH_RESPONSE frame unless constrained by
   --  congestion control."

   use Repro_Support;

   use type Application_Connection.Build_Status;
   use type Application_Connection.Process_Status;
   use type Application_Frame_Policy.Frame_Kind;
   use type Application_Frame_Policy.Parse_Status;
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
     (Traffic => (others => 16#01#), Key => (others => 16#11#),
      IV => (others => 16#22#), HP => (others => 16#33#));
   Server_Keys : constant TLS_Key_Schedule.QUIC_Traffic_Keys :=
     (Traffic => (others => 16#02#), Key => (others => 16#44#),
      IV => (others => 16#55#), HP => (others => 16#66#));
   Client_ID : constant Long_Header_Policy.Connection_ID :=
     ID ((16#AA#, 16#BB#, 16#CC#, 16#DD#));
   Server_ID : constant Long_Header_Policy.Connection_ID :=
     ID ((16#10#, 16#20#, 16#30#, 16#40#));

   Client_Peer, Server_Peer :
     Transport_Parameter_Policy.Transport_Parameters;
   Remote : Application_Connection.Connection;
   Client : State;
   Packet : Ada.Streams.Stream_Element_Array (1 .. Max_Datagram_Length);
   Built  : Application_Connection.Build_Result;
   Received : Process_Result;
   Sent_Data : Send_Result;
   Opened_ID : Varint_Policy.Value_Type;
   Opened : Open_Status;
   Saw_Response : Boolean := False;

   procedure Scan_Reply (Label : String) is
      Plain : Ada.Streams.Stream_Element_Array (1 .. Max_Datagram_Length) :=
        (others => 0);
      Decode : Application_Connection.Process_Result;
      Cursor : Application_Frame_Policy.Frame_Offset := 0;
      Frame  : Application_Frame_Policy.Parse_Result;
      Length : Ada.Streams.Stream_Element_Offset;
   begin
      Build_ACK_Packet (Client, 0, 900, Packet, Sent_Data);
      if Sent_Data.Status /= Sent then
         Note (Label & ": no packet built ("
               & Send_Status'Image (Sent_Data.Status) & ")");
         return;
      end if;
      Length := Ada.Streams.Stream_Element_Offset (Sent_Data.Packet_Length);
      Application_Connection.Process_One_RTT
        (Remote, Packet (1 .. Length), Plain, Decode);
      if Decode.Status /= Application_Connection.Processed then
         Note (Label & ": reply did not decrypt");
         return;
      end if;
      declare
         Body_Length : constant Ada.Streams.Stream_Element_Offset :=
           Ada.Streams.Stream_Element_Offset (Decode.Packet.Plaintext_Length);
         Frames : constant Ada.Streams.Stream_Element_Array :=
           Plain (Plain'First .. Plain'First + Body_Length - 1);
      begin
         Note (Label & ": reply frames " & Hex (Frames));
         loop
            Frame := Application_Frame_Policy.Parse_Next (Frames, Cursor);
            exit when Frame.Status /= Application_Frame_Policy.Parsed;
            if Frame.Kind = Application_Frame_Policy.Path_Response then
               Saw_Response := True;
            end if;
            Cursor := Cursor + Frame.Consumed;
         end loop;
      end;
   end Scan_Reply;

begin
   Client_Peer.Initial_Max_Data := (Present => True, Value => 10_000);
   Client_Peer.Initial_Max_Stream_Data_Bidi_Local :=
     (Present => True, Value => 10_000);
   Client_Peer.Initial_Max_Stream_Data_Bidi_Remote :=
     (Present => True, Value => 10_000);
   Client_Peer.Initial_Max_Stream_Data_Uni :=
     (Present => True, Value => 10_000);
   Client_Peer.Initial_Max_Streams_Bidi := (Present => True, Value => 4);
   Client_Peer.Initial_Max_Streams_Uni := (Present => True, Value => 4);
   Server_Peer := Client_Peer;

   Application_Connection.Initialize
     (Remote, Server_Keys, Client_Keys, Client_ID, Server_ID);
   Initialize
     (Client, Client_Keys, Server_Keys, Server_ID, Client_ID,
      Stream_ID_Policy.Client, Server_Peer, Client_Peer);

   Open_Stream (Client, Stream_ID_Policy.Bidirectional, Opened_ID, Opened);
   pragma Assert (Opened = Stream_ID_Policy.Opened and then Opened_ID = 0);

   --  PATH_CHALLENGE (type 0x1A) with eight octets of data.
   Application_Connection.Build_One_RTT
     (Remote,
      (16#1A#, 16#01#, 16#02#, 16#03#, 16#04#,
       16#05#, 16#06#, 16#07#, 16#08#),
      Packet, Built);
   pragma Assert (Built.Status = Application_Connection.Built);
   Process_Packet
     (Client,
      Packet (1 .. Ada.Streams.Stream_Element_Offset (Built.Packet_Length)),
      Now => 200, ACK_Delay_Exponent => 3, Maximum_ACK_Delay => 25_000,
      Handshake_Confirmed => True, Result => Received);
   Note ("PATH_CHALLENGE processed as "
         & Process_Status'Image (Received.Status)
         & "; frames seen" & Received.Frame_Count'Image
         & "; ack-eliciting " & Received.ACK_Eliciting'Image);
   Check (Received.Status = Processed,
          "precondition: the PATH_CHALLENGE frame is accepted");

   Scan_Reply ("next outgoing packet");
   Check (Saw_Response,
          "an endpoint that receives PATH_CHALLENGE echoes the data in a"
          & " PATH_RESPONSE (RFC 9000 s8.2.2)");

   Finish;
end Flyology.QUIC.Application_Space.Repro_Quic_Transport_7;
