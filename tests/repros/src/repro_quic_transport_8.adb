with Ada.Streams;
with Flyology.QUIC.Connections;
with Flyology.QUIC.Test_Connections;
with Repro_Support;

procedure Repro_Quic_Transport_8 is
   --  QUIC-TRANSPORT-8: the server's first flight carries an ack-eliciting
   --  Initial packet (the ServerHello CRYPTO) in its own datagram, which is
   --  not expanded to 1,200 bytes.
   --
   --  RFC 9000 s14.1: "Similarly, a server MUST expand the payload of all UDP
   --  datagrams carrying ack-eliciting Initial packets to at least the
   --  smallest allowed maximum datagram size of 1200 bytes."

   package QUIC renames Flyology.QUIC.Connections;
   package Peer renames Flyology.QUIC.Test_Connections;

   use Repro_Support;
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type QUIC.Operation_Status;
   use type QUIC.Server_Initialize_Status;

   Client, Server : QUIC.Connection;
   Client_Output, Server_Output : QUIC.Datagram_Batch;
   Client_Status, Server_Status : QUIC.Operation_Status;
   Init_Status : QUIC.Server_Initialize_Status;

begin
   Peer.Initialize_Client (Client);
   QUIC.Start_Client (Client, Client_Output, Client_Status);
   pragma Assert (Client_Status = QUIC.Succeeded
                  and then Client_Output.Count = 1);
   Expect_Equal (Client_Output.Items (1).Length, 1_200,
                 "the client Initial datagram is padded to 1200 bytes");

   declare
      First : constant Ada.Streams.Stream_Element_Array :=
        Client_Output.Items (1).Data
          (1 .. Ada.Streams.Stream_Element_Offset
                  (Client_Output.Items (1).Length));
   begin
      Peer.Initialize_Server_From_Initial (Server, First, Init_Status);
      pragma Assert (Init_Status = QUIC.Initialized);
      QUIC.Process_Datagram (Server, First, Server_Output, Server_Status);
      pragma Assert (Server_Status = QUIC.Succeeded
                     and then Server_Output.Count >= 2);
   end;

   for Index in 1 .. Server_Output.Count loop
      Note ("server datagram" & Index'Image & ": first byte "
            & Hex (Server_Output.Items (Index).Data (1 .. 1))
            & ", length" & Server_Output.Items (Index).Length'Image);
   end loop;

   --  Long header with type bits 00 is an Initial packet (RFC 9000 s17.2.2).
   Check ((Server_Output.Items (1).Data (1) and 16#F0#) = 16#C0#,
          "precondition: the server's first datagram is a long-header"
          & " Initial packet");
   Check (Server_Output.Items (1).Length >= 1_200,
          "a UDP datagram carrying an ack-eliciting server Initial packet is"
          & " expanded to at least 1200 bytes (RFC 9000 s14.1)");

   Finish;
end Repro_Quic_Transport_8;
