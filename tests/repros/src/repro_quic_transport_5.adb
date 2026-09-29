with Ada.Streams;
with Flyology.QUIC.Connections;
with Flyology.QUIC.Test_Connections;
with Repro_Support;

procedure Repro_Quic_Transport_5 is
   --  QUIC-TRANSPORT-5: Transport_Settings are advertised to the peer with
   --  no clamp against the fixed 16,384-byte reassembly ring
   --  (Stream_Reassembly_Policy.Max_Stream_Data) or the 32 stream slots
   --  (Stream_Table_Policy.Max_Streams), so a peer that stays inside the
   --  advertised credit is closed on.
   --
   --  RFC 9000 s4.1: a receiver advertises credit it is prepared to accept.
   --  The .ads contract (flyology-quic-connections.ads:93-109) documents the
   --  fields as "Receive credit on peer bidi streams" and states no ceiling.

   package QUIC renames Flyology.QUIC.Connections;
   package Peer renames Flyology.QUIC.Test_Connections;

   use Repro_Support;
   use type Ada.Streams.Stream_Element_Offset;
   use type QUIC.Operation_Status;
   use type QUIC.Server_Initialize_Status;
   use type QUIC.Connection_State;
   use type QUIC.Open_Status;
   use type QUIC.Send_Status;
   use type QUIC.Stream_Offset;

   subtype Bytes is Ada.Streams.Stream_Element_Array;

   ALPN : constant Bytes := (1 => 16#68#, 2 => 16#33#);
   Original_ID : constant Bytes :=
     (16#83#, 16#94#, 16#C8#, 16#F0#, 16#3E#, 16#51#, 16#57#, 16#08#);

   function ID (Data : Bytes) return QUIC.Connection_ID is
      Result : QUIC.Connection_ID;
   begin
      Result.Length := Natural (Data'Length);
      Result.Data (1 .. Data'Length) := Data;
      return Result;
   end ID;

   Client_ID : constant QUIC.Connection_ID :=
     ID ((16#AA#, 16#BB#, 16#CC#, 16#DD#, 1, 2, 3, 4));

   --  A deployment that wants larger request bodies raises the documented
   --  per-stream receive credit.  Nothing in the contract forbids it.
   Server_Settings : constant QUIC.Transport_Settings :=
     (QUIC.Transport_Settings'(others => <>) with delta
        Max_Stream_Data_Bidi_Remote => 32_768);
   Client_Settings : constant QUIC.Transport_Settings :=
     (others => <>);

   Client, Server : QUIC.Connection;
   Client_Output, Server_Output, Reply : QUIC.Datagram_Batch;
   Client_Status, Server_Status : QUIC.Operation_Status;
   Init_Status : QUIC.Server_Initialize_Status;

   procedure Give
     (Packet : QUIC.Datagram;
      Target : in out QUIC.Connection;
      Out_Of : out QUIC.Datagram_Batch;
      Status : out QUIC.Operation_Status) is
   begin
      QUIC.Process_Datagram
        (Target,
         Packet.Data (1 .. Ada.Streams.Stream_Element_Offset (Packet.Length)),
         Out_Of, Status);
   end Give;

   Stream : QUIC.Stream_ID;
   Opened : QUIC.Open_Status;
   Sent   : QUIC.Send_Status;
   Packet : QUIC.Datagram;
   Chunk  : constant Bytes (1 .. 1_100) := (others => 16#41#);
   Offset : QUIC.Stream_Offset := 0;
   Ignored : QUIC.Datagram_Batch;
   Sent_Bytes : Natural := 0;

begin
   QUIC.Initialize_Client
     (Client, ALPN, Client_Settings, Peer.Server_Certificate,
      Original_ID, ID (Original_ID), Client_ID);
   QUIC.Start_Client (Client, Client_Output, Client_Status);
   pragma Assert (Client_Status = QUIC.Succeeded
                  and then Client_Output.Count = 1);

   declare
      First : constant Bytes :=
        Client_Output.Items (1).Data
          (1 .. Ada.Streams.Stream_Element_Offset
                  (Client_Output.Items (1).Length));
   begin
      QUIC.Initialize_Server_From_Initial
        (Server, ALPN, Server_Settings, Peer.Server_Certificate,
         Peer.Server_Private_Key, Peer.Server_Connection_ID, First,
         Init_Status);
      pragma Assert (Init_Status = QUIC.Initialized);
      QUIC.Process_Datagram (Server, First, Server_Output, Server_Status);
      pragma Assert (Server_Status = QUIC.Succeeded);
   end;

   Reply := (others => <>);
   for Index in 1 .. Server_Output.Count loop
      Give (Server_Output.Items (Index), Client, Client_Output, Client_Status);
      if Client_Output.Count > 0 then
         Reply := Client_Output;
      end if;
   end loop;
   pragma Assert (QUIC.Is_Connected (Client) and then Reply.Count = 1);
   Give (Reply.Items (1), Server, Server_Output, Server_Status);
   pragma Assert (QUIC.Is_Connected (Server));
   Reply := (others => <>);
   for Index in 1 .. Server_Output.Count loop
      Give (Server_Output.Items (Index), Client, Client_Output, Client_Status);
      if Client_Output.Count > 0 then
         Reply := Client_Output;
      end if;
   end loop;
   if Reply.Count = 1 then
      Give (Reply.Items (1), Server, Ignored, Server_Status);
   end if;

   Check (QUIC.Is_Connected (Server) and then QUIC.Is_Connected (Client),
          "precondition: the handshake completed");
   Note ("server advertised Max_Stream_Data_Bidi_Remote = 32768");

   QUIC.Open_Stream (Client, QUIC.Bidirectional, Stream, Opened);
   pragma Assert (Opened = QUIC.Opened);

   --  Send a 19,800-byte request body on one stream without the server
   --  consuming it: inside the 32,768 bytes the server advertised, outside
   --  the 16,384-byte ring it actually has.
   for Index in 1 .. 18 loop
      QUIC.Build_Stream_Datagram
        (Client, Stream, Offset, Fin => False, Data => Chunk,
         Now => QUIC.Timestamp (1_000 + Index),
         Packet => Packet, Status => Sent);
      exit when Sent /= QUIC.Sent;
      Offset := Offset + Chunk'Length;
      Give (Packet, Server, Server_Output, Server_Status);
      Sent_Bytes := Sent_Bytes + Chunk'Length;
      exit when Server_Status /= QUIC.Succeeded
        or else QUIC.State (Server) /= QUIC.Connected;
      --  Return the server's acknowledgments so the sender is never the
      --  binding constraint.  The server never consumes the stream, which
      --  is exactly what an application that has not yet read the body
      --  does.
      for Reply_Index in 1 .. Server_Output.Count loop
         Give (Server_Output.Items (Reply_Index), Client, Ignored,
               Client_Status);
      end loop;
   end loop;

   Note ("client sent" & Sent_Bytes'Image
         & " bytes within the advertised 32768; last client status "
         & QUIC.Send_Status'Image (Sent)
         & "; server status " & QUIC.Operation_Status'Image (Server_Status)
         & "; server state " & QUIC.Connection_State'Image
             (QUIC.State (Server)));

   Check (QUIC.State (Server) = QUIC.Connected,
          "a server accepts stream data inside the per-stream credit it"
          & " advertised (RFC 9000 s4.1)");
   Expect_Equal (Sent_Bytes, 19_800,
                 "all 18 chunks are delivered within the advertised credit");

   Finish;
end Repro_Quic_Transport_5;
