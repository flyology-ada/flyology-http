with Ada.Streams;
use type Ada.Streams.Stream_Element_Array;

--  RFC 9002 section 6.2 handshake-space loss recovery.
--
--  Every step drives the connection with an explicit monotonic timestamp, so
--  the probe deadlines below are exact rather than wall-clock dependent.
procedure Flyology.QUIC.Connections.Recovery_Smoke is
   use type Ada.Streams.Stream_Element_Offset;

   function Nibble (Value : Character) return Natural is
     (case Value is
         when '0' .. '9' => Character'Pos (Value) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (Value) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (Value) - Character'Pos ('A') + 10,
         when others => raise Constraint_Error);

   function Hex (Value : String) return Ada.Streams.Stream_Element_Array is
      Result : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Value'Length / 2));
      Source : Positive := Value'First;
   begin
      for Element of Result loop
         Element := Ada.Streams.Stream_Element
           (16 * Nibble (Value (Source)) + Nibble (Value (Source + 1)));
         Source := Source + 2;
      end loop;
      return Result;
   end Hex;

   function ID (Data : Ada.Streams.Stream_Element_Array) return Connection_ID
   is
      Result : Connection_ID;
   begin
      Result.Length := Natural (Data'Length);
      Result.Data (1 .. Data'Length) := Data;
      return Result;
   end ID;

   function Payload
     (Item : Datagram) return Ada.Streams.Stream_Element_Array is
     (Item.Data (1 .. Ada.Streams.Stream_Element_Offset (Item.Length)));

   Certificate : constant Ada.Streams.Stream_Element_Array :=
     Hex
       ("3082013c3081efa0030201020214434e3e3873a520217edf913fba03f4" &
        "ea17411e64300506032b657030143112301006035504030c096c6f6361" &
        "6c686f7374301e170d3236303830373230323830385a170d3336303830" &
        "343230323830385a30143112301006035504030c096c6f63616c686f73" &
        "74302a300506032b65700321006380a1de85cdd187a3134d096ff12e8b" &
        "1e47aa4c94cff3c4144bad3ee5f81eaea3533051301d0603551d0e0416" &
        "0414d3dd952a2ff44a35af38d9249d71a454ced348ce301f0603551d23" &
        "041830168014d3dd952a2ff44a35af38d9249d71a454ced348ce300f060" &
        "3551d130101ff040530030101ff300506032b657003410024075a33b818" &
        "be62a4f328b79bd8f79febe7d3710fb44ba7a7b2d8e12bc3d1e4056d5" &
        "c20fba04e183430175b62ed1a107eb518dfaacf11045fa0e5a6feba2c0f");
   Private_Key : constant Ed25519_Private_Key :=
     Ed25519_Private_Key'
       (Hex ("f491306c81165ffd97822f3ef58de891" &
             "8779314457f5501e42d3f68504cd3aa8"));
   ALPN : constant Ada.Streams.Stream_Element_Array := Hex ("6833");
   Original_ID : constant Ada.Streams.Stream_Element_Array :=
     Hex ("8394c8f03e515708");
   Client_ID : constant Connection_ID := ID (Hex ("aabbccdd01020304"));
   Server_ID : constant Connection_ID := ID (Hex ("1020304050607080"));

   --  RFC 9002 section 6.2.1 with no RTT sample: 333ms smoothed plus four
   --  times the 166.5ms variance. Handshake spaces add no max_ack_delay.
   First_PTO : constant Timestamp := 999_000;

   procedure Start (Client : in out Connection; Now : Timestamp;
                    Flight : out Datagram_Batch)
   is
      Status : Operation_Status;
   begin
      Initialize_Client
        (Client, ALPN, Transport_Settings'(others => <>), Certificate,
         Original_ID, ID (Original_ID), Client_ID);
      Start_Client (Client, Flight, Status, Now);
      pragma Assert (Status = Succeeded and then Flight.Count = 1);
      --  A client Initial is always padded to QUIC's 1,200-octet minimum.
      pragma Assert (Flight.Items (1).Length = 1_200);
   end Start;

   procedure Accept_Initial
     (Server : in out Connection;
      Packet : Datagram;
      Now    : Timestamp;
      Flight : out Datagram_Batch)
   is
      Setup  : Server_Initialize_Status;
      Status : Operation_Status;
   begin
      Initialize_Server_From_Initial
        (Server, ALPN, Transport_Settings'(others => <>), Certificate,
         Private_Key, Server_ID, Payload (Packet), Setup);
      pragma Assert (Setup = Initialized);
      Process_Datagram (Server, Payload (Packet), Flight, Status, Now);
      pragma Assert (Status = Succeeded);
   end Accept_Initial;

   procedure Deliver
     (Target : in out Connection;
      Packet : Datagram;
      Now    : Timestamp;
      Output : out Datagram_Batch)
   is
      Status : Operation_Status;
   begin
      Process_Datagram (Target, Payload (Packet), Output, Status, Now);
      pragma Assert (Status in Succeeded | Waiting_For_More);
   end Deliver;

   --  Hand every datagram of Flight to Target and return the last non-empty
   --  response, which is how a peer observes one arriving flight.
   procedure Deliver_All
     (Target : in out Connection;
      Flight : Datagram_Batch;
      Now    : Timestamp;
      Reply  : out Datagram_Batch)
   is
      Output : Datagram_Batch;
   begin
      Reply := (others => <>);
      for Index in 1 .. Flight.Count loop
         Deliver (Target, Flight.Items (Index), Now, Output);
         if Output.Count > 0 then
            Reply := Output;
         end if;
      end loop;
   end Deliver_All;
begin
   --  A dropped client Initial is retransmitted by the probe timeout, and the
   --  probe carries the ClientHello rather than only proving reachability.
   declare
      Client, Server : Connection;
      Flight, Probes, Server_Flight, Reply, Trailing : Datagram_Batch;
      Deadline : Timestamp;
   begin
      Start (Client, 0, Flight);
      pragma Assert (Has_Recovery_Timeout (Client));
      Deadline := Recovery_Deadline (Client);
      pragma Assert (Deadline = First_PTO);

      declare
         Status : Timeout_Status;
      begin
         Process_Timeout (Client, Deadline - 1, Probes, Status);
         pragma Assert (Status = Not_Due and then Probes.Count = 0);
         Process_Timeout (Client, Deadline, Probes, Status);
         pragma Assert (Status = Probes_Ready and then Probes.Count = 1);
         --  The retransmission is a fresh packet number in a full-size
         --  client Initial, not a copy of the dropped datagram.
         pragma Assert (Probes.Items (1).Length = 1_200);
         pragma Assert
           (Probes.Items (1).Data /= Flight.Items (1).Data);
         --  Exponential backoff doubles the next deadline.
         pragma Assert
           (Has_Recovery_Timeout (Client)
            and then Recovery_Deadline (Client) = Deadline + 2 * First_PTO);
      end;

      --  Only the probe reaches the server, and it carries enough of the
      --  handshake for the server to answer with its own flight.
      Accept_Initial (Server, Probes.Items (1), 1_000_000, Server_Flight);
      pragma Assert
        (Server_Flight.Count >= 2 and then State (Server) = Server_Handshake);

      Deliver_All (Client, Server_Flight, 1_100_000, Reply);
      pragma Assert (Is_Connected (Client) and then Reply.Count = 1);
      Deliver_All (Server, Reply, 1_200_000, Trailing);
      pragma Assert
        (Is_Connected (Server) and then Handshake_Confirmed (Server));
      Deliver_All (Client, Trailing, 1_300_000, Reply);
      --  A confirmed client owes nothing in either handshake space, so its
      --  probe timer is disarmed and the connection stops retransmitting.
      pragma Assert
        (Handshake_Confirmed (Client)
         and then not Has_Recovery_Timeout (Client));
   end;

   --  A dropped server handshake flight is retransmitted by the server's own
   --  probe timeout while the client waits in Client_Handshake.
   declare
      Client, Server : Connection;
      Flight, Server_Flight, Client_Reply, Probes, Reply, Trailing :
        Datagram_Batch;
      Handshake_Packets : Natural;
      Deadline : Timestamp;
   begin
      Start (Client, 0, Flight);
      Accept_Initial (Server, Flight.Items (1), 10_000, Server_Flight);
      pragma Assert (Server_Flight.Count >= 2);
      Handshake_Packets := Server_Flight.Count - 1;

      --  Deliver only the server Initial; every Handshake packet is lost.
      Deliver (Client, Server_Flight.Items (1), 20_000, Client_Reply);
      pragma Assert
        (not Is_Connected (Client) and then State (Client) = Client_Handshake);
      --  With nothing to send in the Initial space the client still owes an
      --  immediate acknowledgment, which is what retires the server Initial.
      pragma Assert (Client_Reply.Count = 1);
      Deliver_All (Server, Client_Reply, 30_000, Reply);
      pragma Assert (Reply.Count = 0);

      pragma Assert (Has_Recovery_Timeout (Server));
      Deadline := Recovery_Deadline (Server);
      declare
         Status : Timeout_Status;
      begin
         Process_Timeout (Server, Deadline - 1, Probes, Status);
         pragma Assert (Status = Not_Due and then Probes.Count = 0);
         Process_Timeout (Server, Deadline, Probes, Status);
         --  Only the unacknowledged Handshake ranges come back; the Initial
         --  flight was acknowledged and is not retransmitted.
         pragma Assert
           (Status = Probes_Ready
            and then Probes.Count = Handshake_Packets);
      end;

      Deliver_All (Client, Probes, Deadline + 10_000, Reply);
      pragma Assert (Is_Connected (Client) and then Reply.Count = 1);
      Deliver_All (Server, Reply, Deadline + 20_000, Trailing);
      pragma Assert
        (Is_Connected (Server) and then Handshake_Confirmed (Server));
      Deliver_All (Client, Trailing, Deadline + 30_000, Reply);
      pragma Assert (Handshake_Confirmed (Client));
   end;

   --  With its Initial flight acknowledged and no Handshake packet received,
   --  a client still probes so the peer cannot be left waiting. RFC 9002
   --  section 6.2.2.1 calls this the anti-deadlock probe.
   declare
      Client, Server : Connection;
      Flight, Server_Flight, Client_Reply, Probes, Reply : Datagram_Batch;
      Deadline : Timestamp;
   begin
      Start (Client, 0, Flight);
      Accept_Initial (Server, Flight.Items (1), 10_000, Server_Flight);
      Deliver (Client, Server_Flight.Items (1), 20_000, Client_Reply);
      pragma Assert (State (Client) = Client_Handshake);

      pragma Assert (Has_Recovery_Timeout (Client));
      Deadline := Recovery_Deadline (Client);
      declare
         Status : Timeout_Status;
      begin
         Process_Timeout (Client, Deadline, Probes, Status);
         pragma Assert (Status = Probes_Ready and then Probes.Count = 1);
      end;

      --  The probe is a Handshake packet, so the server accepts it and the
      --  connection is still able to complete afterwards.
      Deliver_All (Server, Probes, Deadline + 1_000, Reply);
      Deliver_All (Client, Server_Flight, Deadline + 2_000, Reply);
      pragma Assert (Is_Connected (Client) and then Reply.Count = 1);
      Deliver_All (Server, Reply, Deadline + 3_000, Client_Reply);
      pragma Assert
        (Is_Connected (Server) and then Handshake_Confirmed (Server));
   end;
end Flyology.QUIC.Connections.Recovery_Smoke;
