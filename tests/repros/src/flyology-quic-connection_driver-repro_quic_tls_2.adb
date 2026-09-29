--  QUIC-TLS-2: the client kills an established connection when the server
--  sends post-handshake CRYPTO that is not exactly one complete
--  NewSessionTicket at CRYPTO offset 0.
--
--  The handshake is driven entirely in process: two Connection_Driver
--  objects exchange datagrams directly, with no socket.  Once both sides are
--  connected and the handshake is confirmed, the server's application keys
--  are used to build a 1-RTT packet carrying a crafted CRYPTO frame, which
--  is delivered to the client.
--
--  Correct behaviour (asserted here): the client stays Connected and emits
--  no CONNECTION_CLOSE.  RFC 8446 4.6.1 lets a server send several tickets,
--  and RFC 9000 7.5 makes the CRYPTO stream an ordered byte stream, so
--  message boundaries are not frame boundaries.

with Ada.Streams;
with Flyology.QUIC.Application_Connection;
with Flyology.QUIC.TLS_Key_Schedule;
with Flyology.QUIC.Transport_Parameter_Policy;
with Repro_Support;

procedure Flyology.QUIC.Connection_Driver.Repro_Quic_Tls_2 is
   use type Ada.Streams.Stream_Element_Offset;
   use type Application_Connection.Build_Status;
   use type Transport_Parameter_Policy.Encode_Status;

   subtype Bytes is Ada.Streams.Stream_Element_Array;

   function Nibble (Value : Character) return Natural is
     (case Value is
         when '0' .. '9' => Character'Pos (Value) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (Value) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (Value) - Character'Pos ('A') + 10,
         when others => raise Constraint_Error);

   function Hex (Value : String) return Bytes is
      Result : Bytes (1 .. Ada.Streams.Stream_Element_Offset
                             (Value'Length / 2));
      Source : Positive := Value'First;
   begin
      pragma Assert (Value'Length mod 2 = 0);
      for Element of Result loop
         Element := Ada.Streams.Stream_Element
           (16 * Nibble (Value (Source)) + Nibble (Value (Source + 1)));
         Source := Source + 2;
      end loop;
      return Result;
   end Hex;

   function ID (Data : Bytes) return Long_Header_Policy.Connection_ID is
      Result : Long_Header_Policy.Connection_ID;
   begin
      Result.Length := Natural (Data'Length);
      Result.Data (1 .. Data'Length) := Data;
      return Result;
   end ID;

   function Parameter
     (Value : Long_Header_Policy.Connection_ID)
      return Transport_Parameter_Policy.Connection_ID_Parameter
   is
      Result : Transport_Parameter_Policy.Connection_ID_Parameter;
   begin
      Result.Present := True;
      Result.Length := Value.Length;
      if Value.Length > 0 then
         Result.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Value.Length)) :=
           Value.Data (1 .. Ada.Streams.Stream_Element_Offset (Value.Length));
      end if;
      return Result;
   end Parameter;

   --  The qualification identity shared with tests/oracle and the maintained
   --  driver smoke test.
   Certificate : constant Bytes :=
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
   Private_Key : constant Crypto_OpenSSL.Ed25519_Private_Key :=
     Crypto_OpenSSL.Ed25519_Private_Key'
       (Hex ("f491306c81165ffd97822f3ef58de891" &
             "8779314457f5501e42d3f68504cd3aa8"));
   ALPN : constant Bytes := Hex ("6833");
   Original_ID : constant Bytes := Hex ("8394c8f03e515708");
   Original_Destination : constant Long_Header_Policy.Connection_ID :=
     ID (Original_ID);
   Client_ID : constant Long_Header_Policy.Connection_ID :=
     ID (Hex ("aabbccdd01020304"));
   Server_ID : constant Long_Header_Policy.Connection_ID :=
     ID (Hex ("1020304050607080"));

   Empty : constant Bytes (1 .. 0) := (others => 0);

   procedure Deliver
     (From   : Datagram_Batch;
      Target : in out Connection;
      Reply  : out Datagram_Batch;
      Now    : Application_Space.Timestamp)
   is
      Produced : Datagram_Batch;
      Outcome  : Operation_Result;
   begin
      Reply := (others => <>);
      for Index in 1 .. From.Count loop
         Process_Datagram
           (Target,
            From.Items (Index).Data
              (1 .. Ada.Streams.Stream_Element_Offset
                      (From.Items (Index).Length)),
            Produced, Outcome, Now);
         if Produced.Count > 0 then
            Reply := Produced;
         end if;
      end loop;
   end Deliver;

   --  Run one case end to end on a fresh connection pair.  Preface, when not
   --  empty, is delivered first as a 1-RTT plaintext; Payload is the frame
   --  under test.
   procedure Run_Case
     (Label   : String;
      Preface : Bytes;
      Payload : Bytes)
   is
      Client_Parameters, Server_Parameters :
        Transport_Parameter_Policy.Transport_Parameters;
      Client_Encoded, Server_Encoded :
        Transport_Parameter_Policy.Encode_Result;
      Client, Server : Connection;
      Flight, Reply  : Datagram_Batch;
      Result         : Operation_Result;
      Sending, Receiving : TLS_Key_Schedule.QUIC_Traffic_Keys;
      Sender         : Application_Connection.Connection;
      Packet         : Bytes (1 .. Max_Datagram_Length);
      Built          : Application_Connection.Build_Result;
      Attack         : Datagram_Batch;
   begin
      Client_Parameters.Initial_Source_Connection_ID := Parameter (Client_ID);
      Client_Parameters.Initial_Max_Data := (Present => True, Value => 65_536);
      Client_Parameters.Initial_Max_Stream_Data_Bidi_Local :=
        (Present => True, Value => 16_384);
      Client_Parameters.Initial_Max_Stream_Data_Bidi_Remote :=
        (Present => True, Value => 16_384);
      Client_Parameters.Initial_Max_Stream_Data_Uni :=
        (Present => True, Value => 16_384);
      Client_Parameters.Initial_Max_Streams_Bidi :=
        (Present => True, Value => 8);
      Client_Parameters.Initial_Max_Streams_Uni :=
        (Present => True, Value => 8);

      Server_Parameters.Original_Destination_Connection_ID :=
        Parameter (Original_Destination);
      Server_Parameters.Initial_Source_Connection_ID := Parameter (Server_ID);
      Server_Parameters.Initial_Max_Data := (Present => True, Value => 65_536);
      Server_Parameters.Initial_Max_Stream_Data_Bidi_Local :=
        (Present => True, Value => 16_384);
      Server_Parameters.Initial_Max_Stream_Data_Bidi_Remote :=
        (Present => True, Value => 16_384);
      Server_Parameters.Initial_Max_Stream_Data_Uni :=
        (Present => True, Value => 16_384);
      Server_Parameters.Initial_Max_Streams_Bidi :=
        (Present => True, Value => 8);
      Server_Parameters.Initial_Max_Streams_Uni :=
        (Present => True, Value => 8);

      Client_Encoded := Transport_Parameter_Policy.Encode
        (Client_Parameters, Transport_Parameter_Policy.Client);
      Server_Encoded := Transport_Parameter_Policy.Encode
        (Server_Parameters, Transport_Parameter_Policy.Server);
      pragma Assert
        (Client_Encoded.Status = Transport_Parameter_Policy.Encoded
         and then Server_Encoded.Status = Transport_Parameter_Policy.Encoded);

      Initialize_Client
        (Client, ALPN,
         Client_Encoded.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Client_Encoded.Length)),
         Certificate, Original_ID, Original_Destination, Client_ID,
         Client_Parameters);
      Initialize_Server
        (Server, ALPN,
         Server_Encoded.Data
           (1 .. Ada.Streams.Stream_Element_Offset (Server_Encoded.Length)),
         Certificate, Private_Key, Original_ID, Client_ID, Server_ID,
         Server_Parameters);

      Start_Client (Client, Flight, Result, Now => 0);
      pragma Assert (Result.Status = Succeeded and then Flight.Count = 1);

      Deliver (Flight, Server, Reply, Now => 10);
      pragma Assert (State (Server) = Server_Handshake);
      Deliver (Reply, Client, Flight, Now => 20);
      pragma Assert (Is_Connected (Client));
      Deliver (Flight, Server, Reply, Now => 30);
      pragma Assert
        (Is_Connected (Server) and then Handshake_Confirmed (Server));
      Deliver (Reply, Client, Flight, Now => 40);
      pragma Assert (Handshake_Confirmed (Client));
      Deliver (Flight, Server, Reply, Now => 50);

      Repro_Support.Note
        (Label & ": handshake complete, client state = "
         & Connection_State'Image (State (Client)));

      --  A peer sender holding the server's real application keys.
      TLS_Session.Get_Application_Keys (Server.TLS, Sending, Receiving);
      Application_Connection.Initialize
        (Sender, Sending, Receiving, Server.Peer_ID, Server.Local_ID);

      --  Skip past the packet numbers the real server already used so the
      --  client's packet-number window accepts what follows.
      for Skip in 1 .. 8 loop
         Application_Connection.Build_One_RTT
           (Sender, (16#01#, 0, 0, 0, 0, 0, 0, 0), Packet, Built);
         pragma Assert (Built.Status = Application_Connection.Built);
      end loop;

      if Preface'Length > 0 then
         Application_Connection.Build_One_RTT (Sender, Preface, Packet, Built);
         pragma Assert (Built.Status = Application_Connection.Built);
         Attack := (others => <>);
         Attack.Count := 1;
         Attack.Items (1).Length := Built.Packet_Length;
         Attack.Items (1).Data
           (1 .. Ada.Streams.Stream_Element_Offset (Built.Packet_Length)) :=
           Packet (1 .. Ada.Streams.Stream_Element_Offset
                          (Built.Packet_Length));
         Deliver (Attack, Client, Reply, Now => 100);
         Repro_Support.Check
           (State (Client) = Connected,
            Label & ": client still Connected after the first ticket");
      end if;

      Application_Connection.Build_One_RTT (Sender, Payload, Packet, Built);
      pragma Assert (Built.Status = Application_Connection.Built);
      Attack := (others => <>);
      Attack.Count := 1;
      Attack.Items (1).Length := Built.Packet_Length;
      Attack.Items (1).Data
        (1 .. Ada.Streams.Stream_Element_Offset (Built.Packet_Length)) :=
        Packet (1 .. Ada.Streams.Stream_Element_Offset
                       (Built.Packet_Length));
      Deliver (Attack, Client, Reply, Now => 110);

      Repro_Support.Note
        (Label & ": client state after the crafted CRYPTO frame = "
         & Connection_State'Image (State (Client))
         & ", datagrams emitted =" & Natural'Image (Reply.Count));
      Repro_Support.Check
        (State (Client) = Connected,
         Label & ": connection survives the post-handshake CRYPTO frame");
      Repro_Support.Check
        (Reply.Count = 0,
         Label & ": no CONNECTION_CLOSE is emitted");
   end Run_Case;

begin
   Repro_Support.Note
     ("QUIC-TLS-2: post-handshake CRYPTO handling in the QUIC client");

   --  Case A: two complete NewSessionTicket messages in one CRYPTO frame at
   --  offset 0.  This is the shape an OpenSSL-based server produces with its
   --  documented default of two tickets when both fit one frame.
   --  CRYPTO(type 06, offset 00, length 08) carrying 04 00 00 00 twice.
   Run_Case
     ("two tickets in one frame", Empty,
      (16#06#, 16#00#, 16#08#, 4, 0, 0, 0, 4, 0, 0, 0));

   --  Case B: an accepted ticket at offset 0, then a second ticket at the
   --  next CRYPTO stream offset.
   Run_Case
     ("second ticket at offset 4",
      (16#06#, 16#00#, 16#04#, 4, 0, 0, 0),
      (16#06#, 16#04#, 16#04#, 4, 0, 0, 0));

   --  Case C: one ticket split across two CRYPTO frames; only the first
   --  frame is delivered here, so the client must buffer and wait.
   --  CRYPTO(offset 00, length 06) carrying 04 00 00 08 AA BB, the head of a
   --  NewSessionTicket whose body is eight bytes.
   Run_Case
     ("ticket split across frames", Empty,
      (16#06#, 16#00#, 16#06#, 4, 0, 0, 8, 16#AA#, 16#BB#));

   Repro_Support.Finish;
end Flyology.QUIC.Connection_Driver.Repro_Quic_Tls_2;
