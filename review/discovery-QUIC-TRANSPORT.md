# Discovery: QUIC-TRANSPORT

Scope (all under `flyology_quic/src/` unless noted; line counts are the file
sizes read in full, "region" means only the cited lines were read):

- Drivers and levels: `flyology-quic-connection_driver.adb` (1647),
  `.ads` (342); `flyology-quic-application_space.adb` (1577), `.ads` (383);
  `flyology-quic-initial_space.adb` (519), `.ads` (206);
  `flyology-quic-handshake_space.adb` (519, read as a diff against the
  Initial space), `.ads` (204); `flyology-quic-connections.adb` (777),
  `.ads` (760); `flyology-quic-application_connection.adb` (234), `.ads`
  (116); `flyology-quic-initial_connection.adb` (225), `.ads` (134);
  `flyology-quic-handshake_connection.ads` (112) and body (region);
  `flyology-quic-connection_io.adb` (60); `flyology-quic-one_rtt_receiver.adb`
  (108); `flyology-quic-one_rtt_sender.adb` (115);
  `flyology-quic-initial_receiver.adb` and `-handshake_receiver.adb` (regions).
- Proved policy units, spec and body: varint (84+124), packet_number (62+70),
  ack_range (63+134), ack_frame (36+139), recovery (140+255), sent_packet
  (123+170), flow_control (145+319), receive_flow_control (164+398),
  stream_frame (78+171), stream_id (82+73), stream_reassembly (119+208),
  stream_table (210+419), transport_parameter (112+548), application_frame
  (161+417), initial_frame (100+296), connection_state (106+99), long_header
  (99+155), one_rtt_packet (spec+50), handshake_packet (63+89),
  initial_packet (71+123), protection (spec 64).
- Consumers in the HTTP crate (regions only, to trace reachability):
  `src/flyology-http-http_3_connection.adb:25-70`,
  `src/flyology-http-server-http_3.adb:110-140, 280-450, 805-850,
  1495-1540, 1636-1660, 2085-2115`,
  `src/flyology-http-client-http_3_internals.adb:130-205`,
  `src/flyology-http-client.adb:5845-5900`.
- Tests and gates: `flyology_quic/tests/qualification.md`,
  `flyology_quic/src/proof-status.md`, `proof/proof-status.md`,
  `flyology_quic/tests/src/*` (grepped; `application_space-smoke.adb:405-460`,
  `ack_range_policy-smoke.adb:25-48` read), `scripts/test-http3-interop.sh`,
  `tests/oracle/*`, `tests/http3_interop_server.adb`, `tests/corpus/*`.
- Prior audit: `review/prior-audit.md` contains no QUIC transport entry; the
  whole crate is outside its stated coverage, so nothing below is a repeat.

Commit: f078732
Rubric: P0/P1/P2 as defined in review/DISCOVERY_BRIEF.md

Proved boundary: the 27 `SPARK_Mode => On` policy units are proved at level 1
(`proof-status.md`). Every finding below is located in an unproved driver
(`connection_driver`, `application_space`, `initial_space`, `connections`) or
in an HTTP-crate consumer, except QUIC-TRANSPORT-9 which is a proved unit's
contract choice consumed fatally by the driver. No runtime check is
suppressed anywhere in the crate (`-gnatp` absent; release profile is
`-O3 -gnatn`), so every arithmetic overflow candidate I checked would have
been a `Constraint_Error`, and none survived refutation.

## Summary

| ID | Title | Severity | Confidence |
|----|-------|----------|------------|
| QUIC-TRANSPORT-1 | No anti-amplification limit: a spoofed client Initial draws the full server flight plus three PTO retransmissions, and undersized client Initials are not discarded | P0 | high (absence), medium (ratio) |
| QUIC-TRANSPORT-2 | The 64-entry sent-packet ledger is checked before the congestion window and refuses PTO probes when full, so large transfers fail with H3_INTERNAL_ERROR and a lost ACK burst tears the connection down | P1 | high |
| QUIC-TRANSPORT-3 | Initial keys are never discarded: a forged Initial built from on-wire data closes or fails an established connection in both roles | P1 | high (path), medium (threat model) |
| QUIC-TRANSPORT-4 | A client fails the connection on any post-handshake CRYPTO other than one complete NewSessionTicket at offset 0 | P1 | medium |
| QUIC-TRANSPORT-5 | `Transport_Settings` are advertised unclamped against the fixed 16 KiB reassembly ring and 32 stream slots, so a larger setting makes a compliant peer's traffic fatal | P2 | high |
| QUIC-TRANSPORT-6 | STOP_SENDING is validated and dropped; RESET_STREAM is never sent and the frame is not surfaced to any layer | P2 | high |
| QUIC-TRANSPORT-7 | PATH_CHALLENGE is parsed and ignored; no PATH_RESPONSE is ever sent | P2 | high |
| QUIC-TRANSPORT-8 | The server's ack-eliciting Initial datagram is not expanded to 1,200 bytes | P2 | high |
| QUIC-TRANSPORT-9 | An ACK frame with 64 or more ranges closes the connection with PROTOCOL_VIOLATION | P2 | high |
| QUIC-TRANSPORT-10 | The connection-ID transport parameters are never compared with the wire connection IDs | P2 | high |

## Findings

### QUIC-TRANSPORT-1: No anti-amplification limit before address validation

- **Location:** `flyology-quic-connection_driver.adb:956-995` (first flight),
  `:1524-1554` (every PTO retransmits every unacknowledged CRYPTO range),
  `:46-62` (server timer armed while CRYPTO is unacknowledged);
  `flyology-quic-connections.adb:309-349` and
  `src/flyology-http-server-http_3.adb:2090-2102` (no 1,200-byte minimum on a
  received client Initial); `src/flyology-http-server-http_3.ads:32`
  (`Default_Handshake_Idle_Timeout` 3.0 s bounds the repetitions).
- **Severity:** P0
- **Confidence:** high that no accounting exists (a crate-wide grep for
  amplification, address validation and the 1,200-byte minimum finds only the
  client-side `Peer_Validated` flag); medium on the exact ratios below.
- **Evidence:**

```ada
--  connection_driver.adb:976-995 (server, still Server_Initial)
            while Offset < TLS_Result.Authentication_Length loop
               Chunk := Natural'Min
                 (Handshake_Space.Max_Crypto_Payload,
                  TLS_Result.Authentication_Length - Offset);
               Handshake_Space.Build_Crypto_Packet
                 (Item.Handshake, Varint_Policy.Value_Type (Offset),
                  ...
               if Handshake_Built.Status /= Handshake_Space.Built
                 or else not Append
                   (Output, Packet_Out, Handshake_Built.Packet_Length)
```

```ada
--  connection_driver.adb:1508-1510, 1538-1553 (each PTO, no byte budget)
   --  RFC 9002 section 6.2.4 probes the handshake spaces by retransmitting
   --  every CRYPTO range that is still unacknowledged. ...
      if Item.Handshake_Initialized then
         for Index in 1 .. Max_Output_Datagrams loop
            Handshake_Space.Build_Probe_Packet
              (Item.Handshake, Index, Now, Packet, Handshake_Built);
```

```ada
--  connections.adb:319-326 (server accepts any parsed Initial; the envelope
--  policy only requires Protected_Length >= 20)
      Envelope : constant Initial_Packet_Policy.Parse_Result :=
        Initial_Packet_Policy.Parse (First_Datagram);
      ...
      if Envelope.Status /= Initial_Packet_Policy.Parsed then
         Status := Invalid_Initial;
```

- **Failure scenario:**
  1. An attacker sends one client Initial datagram whose UDP source address is
     the victim's. Because no receiver enforces RFC 9000 s14.1's 1,200-byte
     minimum, the datagram can be as small as the ClientHello needs (about
     300-350 bytes); a padded 1,200-byte one also works.
  2. The listener allocates a slot, `Initialize_Server_From_Initial` succeeds,
     `Process_Datagram` runs `Accept_Client_Hello` and appends the ServerHello
     Initial plus the whole EncryptedExtensions..Finished flight (up to 18,000
     octets of CRYPTO across up to 20 datagrams) to `Output`, all sent to the
     victim.
  3. Nothing arrives from the victim. `Has_Handshake_Timeout` is true because
     both spaces hold unacknowledged CRYPTO, so the PTO fires at 333 ms
     (`Initial_RTT`), then 666 ms and 1,332 ms later with backoff, and each
     time `Process_Handshake_Timeout` retransmits the entire flight.
  4. The listener's 3.0 s no-progress budget reclaims the slot, so four copies
     of the flight reach the victim per spoofed datagram. With the pinned
     Ed25519 test certificate the flight is roughly 1.0-1.4 KB, so 4 flights
     against a 1,200-byte Initial is about 3.3-4.7x, and against a 350-byte
     Initial about 11-16x. With a 4,096-byte DER (the maximum
     `Certificate_DER` accepts) the flight is about 4.5 KB: 15x and 51x.
  Every one of those exceeds the three-times limit that RFC 9000 s8.1 makes a
  MUST, and RFC 9002 s6.2.2.1 says the server timer is not armed at all while
  amplification-limited.
- **Reproduction test sketch:** no network needed. Build a server
  `Connection` with `Initialize_Server_From_Initial` from a valid client
  Initial of length L (the `connection_driver-smoke` harness already
  produces one). Call `Process_Datagram`, sum `Output` byte lengths; then call
  `Process_Timeout` at `Now = 333_001`, `999_002`, `2_331_003` microseconds
  and add each `Output`. Expected per s8.1: the running total never exceeds
  3*L until a Handshake packet from the client has been processed. Actual:
  about four flights, each larger than L/3. A second case feeds a 400-byte
  client Initial: expected `Invalid_Initial` or a silent discard per s14.1,
  actual `Initialized` and a full flight.
- **Existing coverage:**
  `flyology_quic/tests/src/flyology-quic-connections-recovery_smoke.adb:150-171`
  asserts that the server *does* retransmit its flight on PTO with nothing
  from the client, so it pins the current behaviour; it applies no byte
  budget. No test presents an undersized client Initial to a server.
  `qualification.md` lists "anti-amplification accounting, 1200-byte Initial
  datagrams" as not yet covered.
- **Standard:** RFC 9000 s8.1 (three-times limit, MUST), s14.1 (server MUST
  discard a client Initial in a datagram under 1,200 bytes), s21.1.1.1
  (amplification attack); RFC 9002 s6.2.2.1.

### QUIC-TRANSPORT-2: The 64-entry ledger fails large transfers and refuses probes

- **Location:** `flyology-quic-application_space.adb:417-436` (ledger checked
  before `Can_Send`), `:553-566` (batch path, same order), `:695-705` and
  `:1088-1095` (probe refused when the ledger is full, even with
  `Permit_Probe`); `flyology-quic-connection_driver.adb:1629-1643`
  (`Timeout_Packet_Error` returned and `On_Probe_Timeout` skipped);
  consumed at `src/flyology-http-http_3_connection.adb:39-48`
  (`when others => Transport_Error`), `src/flyology-http-server-http_3.adb:
  299, 341-345, 396-400, 841-844`, `src/flyology-http-client-http_3_internals.adb:171-173`,
  `src/flyology-http-client.adb:5869-5873`.
- **Severity:** P1
- **Confidence:** high on the code path; medium on the exact byte threshold,
  which depends on the peer's advertised stream credit and on how many
  packets the sender emits between ACK reads.
- **Evidence:**

```ada
--  application_space.adb:417-436
      if not Stream_Was_Opened (Item, Stream_ID) then
         Result.Status := Stream_Not_Sendable;
         return;
      elsif Sent_Packet_Policy.Retained (Item.Sent) =
        Sent_Packet_Policy.Max_Sent_Packets
      then
         Result.Status := Recovery_Capacity_Exceeded;
         return;
      elsif Free_Retransmittable_Frame (Item) = 0
        or else Free_Packet_Frame_Mapping (Item) = 0
      then
         Result.Status := Recovery_Capacity_Exceeded;
         return;
      elsif not Recovery_Policy.Can_Send
        (Item.Recovery,
         Sent_Packet_Policy.Packet_Byte_Count (Max_Datagram_Length))
      then
         Result.Status := Congestion_Blocked;
```

```ada
--  application_space.adb:1088-1095 (probe path; the PING fallback at :1084
--  goes through Build_Tracked_Frame_Packet, which refuses at :695-705)
      elsif Sent_Packet_Policy.Retained (Item.Sent) =
        Sent_Packet_Policy.Max_Sent_Packets
        or else Free_Packet_Frame_Mapping (Item) = 0
      then
         ...
         Result.Status := Recovery_Capacity_Exceeded;
```

```ada
--  http_3_connection.adb:39-48
   function Send_Status_For
     (Value : QUIC.Send_Status) return Operation_Status
   is
     (case Value is
         when QUIC.Sent => Succeeded,
         when QUIC.Congestion_Blocked => Transport_Blocked,
         when QUIC.Stream_Capacity_Exceeded => Stream_Capacity_Exceeded,
         when QUIC.Stream_Flow_Blocked | QUIC.Connection_Flow_Blocked =>
           Transport_Blocked,
         when others => Transport_Error);
```

```ada
--  connection_driver.adb:1629-1643
      for Probe in 1 .. 2 loop
         Application_Space.Build_Probe_Packet
           (Item.Application, Now, Packet, Built);
         if Built.Status = Application_Space.Sent then
            ...
         elsif Output.Count = 0 then
            Status := Timeout_Packet_Error;
            return;
```

- **Failure scenario (send path):**
  1. The server streams a response of a few hundred kilobytes to a client
     whose `initial_max_stream_data_bidi_remote` is at least about 74 KB
     (quic-go's default is 512 KiB and Chromium's is larger; I could not
     verify curl/ngtcp2's default in this harness). The ledger is checked
     before the congestion window, so the sender is only ever congestion
     blocked while the window is below 64 packets.
  2. NewReno slow start (`Recovery_Policy.On_Packets_Resolved`) doubles the
     window per round trip from 12,000 bytes with no upper bound, so after
     about three round trips the window exceeds 64 x ~1,150 bytes.
  3. The 65th unacknowledged STREAM packet returns
     `Recovery_Capacity_Exceeded`; `Send_Status_For` maps it to
     `Transport_Error`; `Send_Data` raises `Device_Error` ("HTTP/3 response
     data failed"), and the owner closes the connection with H3_INTERNAL_ERROR
     (0x102) via `Close_For_H3_Error`. A streamed upload from the pooled or
     composable client to a peer with a large window fails the same way with
     `Transport_Failed`.
- **Failure scenario (PTO path):** with 64 packets in flight and the peer's
  ACKs for them lost or delayed for one PTO (on a LAN the PTO is about
  smoothed RTT + 25 ms max_ack_delay), `Process_Timeout` cannot build the
  probe RFC 9002 s6.2.4 requires, returns `Timeout_Packet_Error` without
  backing off, and all three HTTP consumers treat that as fatal.
- **Reproduction test sketch:** two `Connection_Driver` instances as in
  `connection_driver-smoke.adb`. (a) Grow the client's window by sending ten
  1,100-byte STREAM datagrams, delivering them, and delivering the server's
  ACKs back, repeated until `Congestion_Window` exceeds 90,000; then call
  `Build_Stream_Datagram` repeatedly without delivering anything. Expected:
  the first non-`Sent` status is `Congestion_Blocked` at the window; actual:
  `Recovery_Capacity_Exceeded` at the 65th packet. (b) With 64 packets in
  flight and nothing delivered, call `Process_Timeout` at
  `Recovery_Deadline`. Expected `Probes_Ready` with one ack-eliciting
  datagram; actual `Timeout_Packet_Error`.
- **Existing coverage:**
  `flyology_quic/tests/src/flyology-quic-sent_packet_policy-smoke.adb:87-112`
  asserts `Table_Full` at the proved policy level only. No driver or HTTP test
  puts more than a handful of packets in flight: the Ada-versus-Ada lanes
  advertise 16,384 bytes of stream credit, capping in-flight at about 15
  packets; the interop server serves `/hello` and a 64-byte `/echo`
  (`tests/http3_interop_server.adb:48-54`); the oracle exchanges use 5-7 byte
  bodies (`tests/oracle/*.py`, `tests/oracle/quic-go/main.go`); every corpus
  fixture is under one kilobyte. `qualification.md` says application-space
  PTO "under sustained network loss is not" covered.
- **Standard:** RFC 9002 s6.2.4 (on PTO a sender MUST send at least one
  ack-eliciting packet), s7.3.1 (slow start); no RFC caps in-flight packet
  count, so the 64-entry bound is a local policy that here becomes a
  connection failure rather than backpressure.

### QUIC-TRANSPORT-3: Initial keys are never discarded; a forged Initial ends an established connection

- **Location:** `flyology-quic-connection_driver.adb:1382-1409` (Initial
  packets scanned in every state), `:1029-1030` (accepted in
  `Client_Handshake | Server_Handshake | Connected`), `:901-911`
  (frame error becomes `Fail_Initial_With_Close`, CONNECTION_CLOSE becomes
  `Peer_Closed`); `flyology-quic-initial_space.adb:392-394, 504-510`;
  routing at `src/flyology-http-server-http_3.adb:112-123`.
- **Severity:** P1
- **Confidence:** high that the path exists; medium on the threat model, which
  needs the original destination CID and the current CIDs, all of which are
  plaintext on the wire.
- **Evidence:**

```ada
--  connection_driver.adb:1029-1033 (no discard after the handshake)
      elsif Item.Current in Client_Handshake | Server_Handshake | Connected then
         Result.Status := Succeeded;
      else
         Result.Status := Invalid_State;
      end if;
```

```ada
--  connection_driver.adb:901-911 (reached before the state check above)
      elsif Processed.Status /= Initial_Space.Processed then
         Fail_Initial_With_Close
           (Item, Transport_Error_For (Processed.Status),
            Frame_Type => 16#06#, Output => Output, Result => Result);
         return;
      elsif Processed.Peer_Closed then
         Item.Close_Is_Application := False;
         Item.Close_Error := Processed.Close_Error;
         Item.Current := Peer_Closed;
         Result.Status := Connection_Closed;
```

```ada
--  server-http_3.adb:112-123 (a datagram from the client's address whose
--  DCID is the server CID or the original DCID reaches the live slot)
         for Slot in Used'Range loop
            if Used (Slot)
              and then Peers (Slot) = Peer
              and then
                (Same_ID (Sources (Slot), Header.Destination)
                 or else Same_ID (Originals (Slot), Header.Destination))
```

- **Failure scenario:**
  1. An observer records the client's first Initial (original DCID D0, client
     SCID C) and the server's reply (server SCID S). Initial keys derive from
     D0 alone (RFC 9001 s5.2), so the observer can protect Initial packets.
  2. After the handshake, the observer sends one 1,200-byte Initial with a
     spoofed client source address, DCID S, any SCID, a fresh 4-byte packet
     number, and a CONNECTION_CLOSE (0x1c) frame. The registry resolves it to
     the live slot, `Process_Initial_Packet` authenticates it, and the
     connection becomes `Peer_Closed`; the HTTP/3 layer reports
     `Connection_Closed` and tears the session down. Against the client, the
     same packet with DCID C needs no registry at all. An ACK frame whose
     largest acknowledged exceeds anything sent, or two conflicting CRYPTO
     bytes, produce `Fail_Initial_With_Close` instead.
  RFC 9001 s4.9.1 requires both endpoints to discard Initial keys (a client
  when it first sends a Handshake packet, a server when it first processes
  one) precisely so that packets protected with publicly derivable keys
  cannot affect the connection afterwards.
- **Reproduction test sketch:** complete a handshake between two drivers as
  in `connection_driver-smoke.adb`. Initialize a third `Initial_Connection`
  in the client role with the same `Original_Destination_ID`, DCID = the
  server's local CID, and call `Build_Initial_At_Least` with plaintext
  `16#1C# 00 00 00` padded to 1,200. Feed it to the server driver's
  `Process_Datagram`. Expected: discarded, `State` still `Connected`. Actual:
  `Connection_Closed` and `State = Peer_Closed`.
- **Existing coverage:** none.
  `flyology_quic/tests/src/flyology-quic-application_space-smoke.adb:395-415`
  tests an application close inside a 1-RTT packet, which needs the real keys.
- **Standard:** RFC 9001 s4.9.1 (Initial key discard, MUST), s5.2 (Initial
  secrets from the original DCID); RFC 9000 s21.1.2 (off-path attackers can
  inject packets).

### QUIC-TRANSPORT-4: A client fails on any post-handshake CRYPTO except one complete ticket at offset 0

- **Location:** `flyology-quic-application_space.adb:1307-1349`; consumed at
  `flyology-quic-connection_driver.adb:1314-1332` (`Unexpected_TLS_Message`
  maps to crypto error 0x10A and closes).
- **Severity:** P1
- **Confidence:** medium. The code path is certain; how many real servers
  send two tickets or a ticket split across CRYPTO frames I could not check in
  this harness. OpenSSL's documented default for TLS 1.3 is two
  NewSessionTicket messages, and Go's `crypto/tls` sends one.
- **Evidence:**

```ada
--  application_space.adb:1333-1349
               if Stream_ID_Policy.Local_Role (Item.Allocator) =
                    Stream_ID_Policy.Client
                 and then Frame.Base.Crypto_Offset = 0
                 and then Data_Length >= 4
                 and then Plaintext
                   (Plaintext'First
                      + Ada.Streams.Stream_Element_Offset (Data_Offset)) = 4
                 and then Body_Length = Natural (Data_Length) - 4
               then
                  --  A client that does not implement resumption may ignore
                  --  a complete post-handshake NewSessionTicket. ...
                  null;
               else
                  Result.Status := Unexpected_TLS_Message;
                  return;
```

- **Failure scenario:** the application space never reassembles the 1-RTT
  CRYPTO stream; it judges each frame alone. A second NewSessionTicket
  arrives at `Crypto_Offset = L` (the first ticket's length), or a single
  ticket longer than one frame arrives as two frames whose first has
  `Body_Length /= Data_Length - 4`, or two tickets share one frame. Each is
  `Unexpected_TLS_Message`, the driver sends CONNECTION_CLOSE 0x10A, and the
  HTTP/3 client connection fails after the handshake had already completed.
- **Reproduction test sketch:** extend
  `application_space-smoke.adb:434-445`: after the accepted offset-0 ticket
  `(06, 00, 04, 04, 00, 00, 00)`, build a 1-RTT packet carrying
  `(06, 04, 04, 04, 00, 00, 00)` (offset 4). Expected `Processed`; actual
  `Unexpected_TLS_Message`.
- **Existing coverage:** `application_space-smoke.adb:418-458` pins one
  complete ticket at offset 0 (accepted) and a KeyUpdate at offset 0
  (rejected). The oracle servers do not send tickets in the qualified
  configuration (aioquic has no ticket handler; the quic-go oracle is a single
  exchange).
- **Standard:** RFC 8446 s4.6.1 (a server MAY send multiple tickets on one
  connection); RFC 9001 s4.1 (post-handshake messages are carried in CRYPTO
  frames with a continuous offset space).

### QUIC-TRANSPORT-5: `Transport_Settings` are advertised unclamped against fixed reassembly bounds

- **Location:** `flyology-quic-connections.adb:176-201` (settings copied
  straight into transport parameters); `flyology-quic-application_space.adb:
  846-867, 878-895` (per-stream credit = consumed + configured window);
  `flyology-quic-stream_reassembly_policy.adb:72-76` (16,384-byte ring from
  the consumed base); `flyology-quic-stream_table_policy.ads:17` (32 slots);
  `src/flyology-http-server-http_3.adb:1640-1644` (cumulative limit =
  `Max_Streams_Bidi + Served`); documented at
  `flyology-quic-connections.ads:93-109` with no bound stated.
- **Severity:** P2 (needs a non-default setting; the `.ads` contract does not
  say the defaults are ceilings)
- **Confidence:** high
- **Evidence:**

```ada
--  connections.ads:101-108 (defaults equal the fixed bounds exactly)
   type Transport_Settings is record
      ...
      Max_Stream_Data_Bidi_Remote : Stream_Offset := 16_384;
      Max_Stream_Data_Uni         : Stream_Offset := 16_384;
      Max_Streams_Bidi            : Stream_Offset := 29;
      Max_Streams_Uni             : Stream_Offset := 3;
```

```ada
--  stream_reassembly_policy.adb:72-76
      if Ending > Item.Base
        and then Ending - Item.Base > Absolute_Offset (Max_Stream_Data)
      then
         return;   --  Status = Exceeds_Capacity -> Stream_Data_Too_Large
```

- **Failure scenario:** a server built with
  `Max_Stream_Data_Bidi_Remote => 65_536` advertises 64 KiB of stream credit;
  a compliant client sends a 20 KB request body in one burst on a new stream;
  receive flow control accepts it, `Stream_Table_Policy.Insert` returns
  `Data_Capacity_Exceeded`, and the driver closes with transport error 0x01.
  With `Max_Streams_Bidi => 64`, a client that opens 33 concurrent requests
  within its granted limit gets `Stream_Capacity_Exceeded` and the same close.
- **Reproduction test sketch:** `Initialize_Server_From_Initial` with
  `Max_Stream_Data_Bidi_Remote => 32_768`; after the handshake feed a STREAM
  frame for stream 0 at offset 16_384 with 1,000 bytes. Expected accepted
  (within advertised credit); actual `Stream_Data_Too_Large` and a close.
- **Existing coverage:** none; every lane uses the defaults.
- **Standard:** RFC 9000 s4.1 (a receiver advertises the credit it will
  accept; a sender within it MUST NOT be penalised).

### QUIC-TRANSPORT-6: STOP_SENDING is validated and dropped

- **Location:** `flyology-quic-application_space.adb:1392-1402`;
  `Process_Result` (`application_space.ads:241-252`) has no field for it.
- **Severity:** P2
- **Confidence:** high
- **Evidence:**

```ada
--  application_space.adb:1392-1402
         elsif Frame.Kind = Application_Frame_Policy.Stop_Sending then
            Receive_Status :=
              Receive_Flow_Control_Policy.Check_Stop_Sending
                (Candidate_Receive, Frame.Stream_ID, Local_Bidi_Opened,
                 Local_Uni_Opened);
            if Receive_Status /= Receive_Flow_Control_Policy.Reserved
              and then Receive_Status /= Receive_Flow_Control_Policy.Retired
            then
               Result.Status := Process_Status_For (Receive_Status);
               return;
            end if;
```

- **Failure scenario:** an HTTP/3 client cancels a request with STOP_SENDING
  (H3_REQUEST_CANCELLED). The server neither sends RESET_STREAM nor learns of
  the cancellation, so it streams the entire response and keeps consuming the
  peer's flow-control credit for data the peer discards.
- **Reproduction test sketch:** after a handshake, deliver a 1-RTT packet
  with `(05, 00, 10)` for stream 0 that has response data pending. Expected: a
  RESET_STREAM for stream 0 in the next flight (or a `Process_Result` field
  the HTTP layer can act on); actual: nothing, and the response continues.
- **Existing coverage:** `receive_flow_control_policy-smoke.adb:51-57` tests
  the admission check only.
- **Standard:** RFC 9000 s3.5 (MUST send RESET_STREAM in Ready or Send state);
  RFC 9114 s4.1.1.

### QUIC-TRANSPORT-7: PATH_CHALLENGE is parsed and ignored

- **Location:** `flyology-quic-application_frame_policy.adb:386-395` parses
  0x1A/0x1B; the frame loop in `flyology-quic-application_space.adb:1283-1512`
  has no branch for `Path_Challenge`, so it is accepted as ack-eliciting and
  discarded.
- **Severity:** P2 (`qualification.md` lists path validation and NAT
  rebinding as not yet covered, so this is a known gap, but the response is a
  MUST and its absence blackholes a connection after a rebinding)
- **Confidence:** high
- **Evidence:** the `Frame.Kind` chain at `application_space.adb:1299-1510`
  handles Handshake_Done, Crypto, New_Token, both closes, Stream,
  Reset_Stream, Stop_Sending, Max_Data, Max_Stream_Data, Max_Streams_*,
  Streams_Blocked_*, Acknowledgment; `Path_Challenge`, `Path_Response`,
  `New_Connection_ID`, `Retire_Connection_ID`, `Data_Blocked`,
  `Stream_Data_Blocked` fall through.
- **Failure scenario:** the client's NAT rebinds; the server (a stock one)
  sends PATH_CHALLENGE to the new address (RFC 9000 s9.3); no PATH_RESPONSE
  ever returns; the server MUST NOT use the unvalidated path, so the
  connection dies at the peer's idle timeout.
- **Reproduction test sketch:** deliver `(1A, 01..08)` in a 1-RTT packet;
  expected a PATH_RESPONSE `(1B, 01..08)` in the next output; actual none.
- **Existing coverage:** `application_frame_policy-smoke.adb:59` parses the
  frame only.
- **Standard:** RFC 9000 s8.2.2 (MUST respond with PATH_RESPONSE echoing the
  data), s19.17.

### QUIC-TRANSPORT-8: The server's ack-eliciting Initial datagram is not expanded to 1,200 bytes

- **Location:** `flyology-quic-initial_space.adb:141-142` (padding only for
  the client role); `flyology-quic-connection_driver.adb:956-969` (the
  ServerHello Initial is emitted as its own datagram, not coalesced).
- **Severity:** P2 (a MUST, but stock clients do not discard small server
  Initials, so not interop-breaking)
- **Confidence:** high
- **Evidence:**

```ada
--  initial_space.adb:141-142
      Minimum : constant Natural :=
        (if Item.Role = Initial_Connection.Client then 1_200 else 0);
```

- **Failure scenario:** the ServerHello Initial carries CRYPTO, is
  ack-eliciting, and leaves in a datagram of roughly 150 bytes, so the path's
  ability to carry 1,200-byte datagrams is never confirmed by the server's
  first flight as s14.1 intends.
- **Reproduction test sketch:** in `connection_driver-smoke.adb`, assert
  `Server_Output.Items (1).Length >= 1_200` after the client Initial is
  processed; currently false.
- **Existing coverage:** `connection_driver-smoke.adb:192` asserts the
  *client* datagram is 1,200 bytes; nothing asserts the server's.
- **Standard:** RFC 9000 s14.1 ("a server MUST expand the payload of all UDP
  datagrams carrying ack-eliciting Initial packets to at least 1200 bytes").

### QUIC-TRANSPORT-9: An ACK frame with 64 or more ranges closes the connection

- **Location:** `flyology-quic-ack_range_policy.adb:64-66` (proved unit,
  contract choice); `flyology-quic-application_space.adb:1452-1461` and
  `flyology-quic-initial_space.adb:380-389` (mapped to
  `ACK_Range_Capacity_Exceeded`); `flyology-quic-connection_driver.adb:576,
  504-505, 524-525` (mapped to PROTOCOL_VIOLATION 0x0A and closed).
- **Severity:** P2
- **Confidence:** high on the path; whether a stock peer ever emits 64
  ranges depends on its own cap (quic-go and Chromium cap what they send; I
  did not verify the exact values), so reachability is medium.
- **Evidence:**

```ada
--  ack_range_policy.adb:64-66
      if Frame.ACK_Range_Count >= Max_Ranges then
         Result.Status := Too_Many_Ranges;
         return Result;
```

- **Failure scenario:** under heavy alternating loss a peer's receive history
  legitimately contains many gaps; an ACK with an `ACK Range Count` of 63 or
  more is well-formed, yet the driver answers with CONNECTION_CLOSE
  PROTOCOL_VIOLATION. Processing only the newest 64 ranges and ignoring the
  rest would be safe: ranges are descending, so the ignored ones are the
  oldest packets, which at worst are retransmitted spuriously.
- **Reproduction test sketch:** build an ACK with largest 200, first range 0,
  and 64 gap/length pairs of (0, 0); deliver it after 200 packets were sent.
  Expected: the newest ranges applied; actual: connection Failed with 0x0A.
- **Existing coverage:** `ack_range_policy-smoke.adb:42-47` asserts
  `Too_Many_Ranges` at the policy level, pinning the choice.
- **Standard:** RFC 9000 s19.3 sets no limit on ACK Range Count; s13.2.3
  permits a *sender* of ACKs to limit ranges, not a receiver to reject them.

### QUIC-TRANSPORT-10: Connection-ID transport parameters are never compared with the wire CIDs

- **Location:** the only uses of `Original_Destination_Connection_ID` and
  `Initial_Source_Connection_ID` outside the codec are the encoders at
  `flyology-quic-connections.adb:185-187`; `Transport_Parameter_Policy.Decode`
  (`:360-367`) checks presence only; `connection_driver.adb:755-777`
  (`Initialize_Application`) reads the peer parameters without comparing them
  to `Item.Peer_ID`, `Item.Local_ID`, or the original DCID it was initialised
  with.
- **Severity:** P2
- **Confidence:** high (crate-wide grep)
- **Evidence:** `rg 'Original_Destination_Connection_ID|Initial_Source_Connection_ID|Retry_Source_Connection_ID' flyology_quic/src/ --glob '!*transport_parameter_policy*'`
  returns only the two encode lines.
- **Failure scenario:** an on-path party rewrites the Source Connection ID of
  the client's Initial (Initial packets have no integrity against on-path
  modification). The server's authenticated `initial_source_connection_id`
  then disagrees with the CID the server is using for the client; RFC 9000
  s7.3 requires a TRANSPORT_PARAMETER_ERROR or PROTOCOL_VIOLATION close, which
  never happens, so the tampering is not detected. The practical effect is a
  handshake that later fails on `Unexpected_Destination` rather than a
  diagnosed error, which is why this stays P2.
- **Reproduction test sketch:** in `tls_transport_smoke`-style setup, encode
  server transport parameters with `Original_Destination_Connection_ID` set
  to a different 8-byte value than the client's original DCID; expected a
  client-side close with 0x08; actual the handshake completes.
- **Existing coverage:** `transport_parameter_policy-smoke.adb` covers
  presence and role rules only.
- **Standard:** RFC 9000 s7.3 ("MUST treat ... a mismatch ... as a connection
  error").

## Areas reviewed with no findings

- **Variable-length integers** (`varint_policy`, proved): all four widths,
  non-minimal encodings accepted as s16 permits, maximum `2**62-1` fits
  `Value_Type`, `Encode` is shortest-form; every consumer that adds two
  varints checks `Value_Type'Last - Left` first (stream frame, CRYPTO frame,
  reassembly, flow control, receive credit).
- **Packet-number reconstruction** (`packet_number_policy`, proved) is a
  faithful RFC 9000 Appendix A.3 transcription including the
  `expected >= half` guard and the `2**62 - window` ceiling; callers use
  `Reconstruct_From_Expected` with `Expected_Number`, which saturates at
  `Packet_Number'Last`, so the `Reconstruct` precondition is never violated.
  Sender-side length selection treats nothing as acknowledged, which is
  over-conservative but safe.
- **RTT and PTO arithmetic** (`recovery_policy`, proved): first-sample,
  min_rtt, the ack_delay clamp after confirmation, and the "subtract only if
  it does not drive below min_rtt" rule match RFC 9002 s5.3; PTO is
  smoothed + max(4*var, granularity) + max_ack_delay with saturating doubling
  and a 16-count cap; `Decoded_ACK_Delay` saturates before multiplying by
  `2**exponent`, and the decoder rejects an exponent above 20 and a
  max_ack_delay of `2**14` or more, so the driver's narrowing and `* 1_000`
  cannot overflow. The RFC 9002 s5.1 sample rules (largest acknowledged must
  be newly acknowledged and ack-eliciting) are enforced at
  `application_space.adb:1485-1500` and `initial_space.adb:405-413`.
- **ACK range decoding** (`ack_range_policy`, `initial_frame_policy`, proved):
  `first_ack_range > largest`, negative gaps, and negative lengths all reject
  with FRAME_ENCODING_ERROR (0x07); ECN counts are consumed so the frame
  boundary is correct; an ACK of an unsent packet is PROTOCOL_VIOLATION.
- **Loss detection** (`sent_packet_policy`, proved): packet threshold 3 and
  the time threshold are RFC 9002 s6.1; both only run on an ACK that newly
  acknowledges something, as the RFC requires.
- **Receive flow control and stream limits** (`receive_flow_control_policy`,
  proved): stream direction and initiator, `Stream_Not_Opened` for a
  locally-initiated stream the peer names first, `Stream_Limit_Exceeded`
  (0x04) beyond the granted count, both flow limits (0x03), implicit opening
  of lower-numbered streams, and every final-size contradiction in RFC 9000
  s4.5 (0x06) including RESET_STREAM's final size; a decreasing MAX_DATA or
  MAX_STREAM_DATA is ignored via `'Max`; MAX_STREAMS above `2**60` is 0x07.
  Released streams become `Retired` by ordinal, and `Process_Packet` filters
  retired streams before reassembly, so a spurious retransmission cannot
  reopen a slot.
- **Stream reassembly** (`stream_reassembly_policy`, proved): the 16 KiB ring
  is addressed modulo from the consumed base, conflicting overlaps are
  detected byte-for-byte before any mutation, and data below the consumed base
  is deduplicated. The per-stream credit the server advertises equals the ring
  exactly for the default settings (see QUIC-TRANSPORT-5 for non-defaults).
- **Transport parameters** (`transport_parameter_policy`, proved): duplicates,
  client-forbidden parameters, `max_udp_payload_size < 1200`,
  `active_connection_id_limit < 2`, preferred-address structure, mandatory
  CIDs, and the RFC 9000 s18.2 integer limits are all enforced.
- **Frame and envelope parsers** (`application_frame_policy`, `long_header`,
  `initial_packet`, `handshake_packet`, `one_rtt_packet`, proved): all v1
  frame types decoded, NEW_CONNECTION_ID with `retire_prior_to > sequence` or
  a bad CID length rejected, unknown types 0x07, fixed bit and 20-byte CID
  limit enforced, 20-byte minimum protected payload for the header-protection
  sample, reserved bits checked only after AEAD authentication.
- **Key update** (`application_connection.adb:96-233`): a packet that fails
  under current keys is retried under next-generation keys, then previous
  keys; a successful opposite-phase trial rotates both directions and retains
  the previous receive epoch. Matches RFC 9001 s6.
- **Handshake recovery (PRs #20-#22, commits a3866c5, 5f23f55, 4e5fc62):** the
  client anti-deadlock PING, the trailing-KeyUpdate rejection before
  `Connected`, and the in-place stream table with a connection-fatal
  reassembly conflict are correct as written; the recovery smoke test covers
  the client and server PTO paths deterministically.
- **Unauthenticated packets** are discarded without closing in all three
  spaces (`connection_driver.adb:881-900, 1052-1068, 1297-1313`), as RFC 9000
  s12.2 and s5.2 require.

## Observations not counted

- `Max_Sent_Packets = 64`, `Max_Ranges = 64`, `Receive_Window = 256`,
  `Max_Stream_Data = 16_384`, 32 reassembly slots, 1,024 lifetime stream
  slots, `Initial_Congestion_Window = 12_000`, `Max_PTO_Count = 16`,
  `Default_Handshake_Idle_Timeout = 3.0` are documented policy values; they
  are cited above only where they turn a protocol rule into a failure.
- No loss timer is armed for the RFC 9002 s6.1.2 time threshold; loss is
  declared only on the next newly-acknowledging ACK or recovered by PTO. The
  RFC makes the timer a SHOULD. Persistent congestion (s7.6) is not
  implemented, and `Application_Limited` is always `False`, so the window
  grows during application-limited periods.
- Connection-level MAX_DATA is always `committed + Max_Data`
  (`application_space.adb:804-809`), so connection-level flow control never
  applies backpressure; the per-stream credit and the 32 slots do.
- Version Negotiation, Retry, stateless reset, NEW_CONNECTION_ID,
  RETIRE_CONNECTION_ID (including the s19.16 MUST for a sequence above any
  issued), and the QUIC idle timeout are absent; `qualification.md` declares
  them pending. A RETIRE_CONNECTION_ID with sequence above 0 is silently
  accepted rather than treated as PROTOCOL_VIOLATION.
- A 1-RTT packet that arrives before `Connected` (0.5-RTT data coalesced with
  a partial Handshake flight) is dropped rather than buffered
  (`connection_driver.adb:1265-1271`); the peer's PTO recovers it.
- `Connections.Process_Datagram` and its siblings dereference `Impl (Item)`
  without the null guard `State` has, so an application calling them before
  `Initialize_*` gets an access-check `Constraint_Error` rather than
  `Invalid_State`.
- The sender sizes packet numbers as if nothing were ever acknowledged
  (`Is_Representable (Number, False, 0)`), which caps a connection at
  `2**31` sent packets per space.
- `Open_Stream` does not consult the 32-slot reassembly table, so a client
  that opens more concurrent request streams than 29 (if the server permits)
  cannot receive all the responses; the HTTP/3 client bounds this itself and
  it is the HTTP-3 reviewer's surface.
- Coverage gap stated plainly: no maintained lane moves a body larger than a
  few hundred bytes over HTTP/3 against a peer with a large stream window, and
  no lane presents a spoofed, undersized, or post-handshake Initial to a
  server. Findings 1, 2 and 3 all live in that gap.
