# Verification: QUIC-TRANSPORT

Commit: f078732

Findings examined: 11 (the ten in `review/discovery-QUIC-TRANSPORT.md` plus one
raised here). Confirmed: 11. Refuted: 0. Partial: 0. Other: 0.

| ID | Discovery severity | Verdict | Final severity | Repro |
|----|--------------------|---------|----------------|-------|
| QUIC-TRANSPORT-1 | P0 | CONFIRMED (ratios corrected) | P0 | `flyology-quic-connection_driver-repro_quic_transport_1` |
| QUIC-TRANSPORT-2 | P1 | CONFIRMED | P1 | `flyology-quic-connection_driver-repro_quic_transport_2` |
| QUIC-TRANSPORT-3 | P1 | CONFIRMED | P1 | `flyology-quic-connection_driver-repro_quic_transport_3` |
| QUIC-TRANSPORT-4 | P1 | CONFIRMED | P1 | `flyology-quic-application_space-repro_quic_transport_4` |
| QUIC-TRANSPORT-5 | P2 | CONFIRMED | **P1** (raised) | `repro_quic_transport_5` |
| QUIC-TRANSPORT-6 | P2 | CONFIRMED | P2 | `flyology-quic-application_space-repro_quic_transport_6` |
| QUIC-TRANSPORT-7 | P2 | CONFIRMED | P2 | `flyology-quic-application_space-repro_quic_transport_7` |
| QUIC-TRANSPORT-8 | P2 | CONFIRMED | P2 | `repro_quic_transport_8` |
| QUIC-TRANSPORT-9 | P2 | CONFIRMED | P2 | `flyology-quic-application_space-repro_quic_transport_9` |
| QUIC-TRANSPORT-10 | P2 | CONFIRMED | P2 | `flyology-quic-connection_driver-repro_quic_transport_10` |
| QUIC-TRANSPORT-11 | new | CONFIRMED | P2 | `repro_quic_transport_11` |

Nothing was refuted at the level of "this defect does not exist". One numeric
claim was refuted: the amplification ratio QUIC-TRANSPORT-1 estimates for a
compliant 1,200-byte client Initial against the pinned test certificate. The
measured value is 1.73x, inside RFC 9000's three-times limit; the limit is
exceeded through the missing section 14.1 minimum (measured 9.64x) or through a
certificate larger than about 825 bytes (measured 3.61x at 1,024 bytes and
11.52x at 4,096). Details under that finding.

Every spike is under `tests/repros/src/` and is run with
`./tests/repros/run.sh <name>`. Six of the eleven are child units of a
`private package`, as `tests/repros/README.md` prescribes; their program name
is the full unit name. The harness self-tests `repro_smoke` and `seam_check`
still PASS after these files were added.

## QUIC-TRANSPORT-1: No anti-amplification limit before address validation

- **Verdict:** CONFIRMED (the ratios in the discovery entry are corrected below;
  the one the entry gives for the default configuration is REFUTED)
- **Severity:** P0 (discovery said P0; kept). The rubric's P0 covers "a single
  hostile packet or frame that stalls or amplifies". One spoofed 216-byte
  datagram draws 2,084 bytes at the spoofed address with the repository's own
  pinned certificate, measured below.
- **Repro:** `tests/repros/src/flyology-quic-connection_driver-repro_quic_transport_1.adb`,
  run with
  `./tests/repros/run.sh flyology-quic-connection_driver-repro_quic_transport_1`
  (a child unit of the private package `Flyology.QUIC.Connection_Driver`, per
  `tests/repros/README.md`)
- **Output:**

```
  note padded client Initial: 1200 bytes
  note minimal client Initial: 216 bytes
  note    flight 1 at 0 us: 2 datagrams, 698 bytes
  note    flight 2 at 999000 us: 2 datagrams, 693 bytes
  note    flight 3 at 2997000 us: 2 datagrams, 693 bytes
  note A 1200-byte Initial, 320-byte certificate: status SUCCEEDED, flights 3, sent 2084 bytes, received 1200 bytes
  note    amplification 1.73x
  ok   A: at most 3x the bytes received (RFC 9000 s8.1)
  note    flight 1 at 0 us: 5 datagrams, 4615 bytes
  note    flight 2 at 999000 us: 5 datagrams, 4610 bytes
  note    flight 3 at 2997000 us: 5 datagrams, 4610 bytes
  note B 1200-byte Initial, 4096-byte certificate: status SUCCEEDED, flights 3, sent 13835 bytes, received 1200 bytes
  note    amplification 11.52x
  FAIL B: at most 3x the bytes received (RFC 9000 s8.1)
  note    flight 1 at 0 us: 3 datagrams, 1449 bytes
  note    flight 2 at 999000 us: 3 datagrams, 1444 bytes
  note    flight 3 at 2997000 us: 3 datagrams, 1444 bytes
  note E 1200-byte Initial, 1024-byte certificate: status SUCCEEDED, flights 3, sent 4337 bytes, received 1200 bytes
  note    amplification 3.61x
  FAIL E: at most 3x the bytes received (RFC 9000 s8.1)
  note    flight 1 at 0 us: 2 datagrams, 698 bytes
  note    flight 2 at 999000 us: 2 datagrams, 693 bytes
  note    flight 3 at 2997000 us: 2 datagrams, 693 bytes
  note C minimal Initial, 320-byte certificate: status SUCCEEDED, flights 3, sent 2084 bytes, received 216 bytes
  FAIL C: a server discards a client Initial in a datagram under 1200 bytes (RFC 9000 s14.1)
  note    amplification 9.64x
  FAIL C: at most 3x the bytes received (RFC 9000 s8.1)
  note    flight 1 at 0 us: 5 datagrams, 4615 bytes
  note    flight 2 at 999000 us: 5 datagrams, 4610 bytes
  note    flight 3 at 2997000 us: 5 datagrams, 4610 bytes
  note D minimal Initial, 4096-byte certificate: status SUCCEEDED, flights 3, sent 13835 bytes, received 216 bytes
  note    amplification 64.05x
  FAIL D: at most 3x the bytes received (RFC 9000 s8.1)
checks: 6  failures: 5
BUG REPRODUCED
EXIT=1
```

### The absence, proved by exhaustive search

The discovery entry claims no byte accounting tied to address validation exists
anywhere in the crate. Four searches over all 102 files of `flyology_quic/src`
settle it.

1. Vocabulary sweep.
   `rg -in 'amplif|address.?valid|validated|anti.?amp|three.?times|bytes_received|bytes_sent|received_bytes|sent_bytes|byte_budget|budget' flyology_quic/src/`
   returns exactly five lines, all one flag:

   ```
   flyology-quic-connection_driver.ads:333:  --  RFC 9002 PeerCompletedAddressValidation: a client that has processed
   flyology-quic-connection_driver.ads:335:      Peer_Validated        : Boolean := False;
   flyology-quic-connection_driver.adb:62:      or else (Item.Is_Client and then not Item.Peer_Validated)
   flyology-quic-connection_driver.adb:1086:      Item.Peer_Validated := True;
   flyology-quic-application_space.adb:1516:  --  already been validated and staged by their owning policies.
   ```

   `Peer_Validated` is the *client's* RFC 9002 `PeerCompletedAddressValidation`
   predicate, read only by `Has_Handshake_Timeout` to keep the anti-deadlock
   PING armed. It is never read on the server side and counts nothing.

2. State sweep. The complete connection state is
   `Connection_Driver.Connection` (`flyology-quic-connection_driver.ads:314-341`),
   which holds the three per-space states. All four record declarations were
   read in full: `Connection_Driver.Connection`, `Initial_Space.State`,
   `Handshake_Space.State`, `Application_Space.State`. None contains a field
   counting bytes received from, or sent to, the peer address. The public
   `Connections.Connection` is a single `System.Address` to a
   `Connection_Impl` whose only component is that driver `Connection`
   (`flyology-quic-connections.adb`), so there is no second place to hide one.

3. The 1,200-byte minimum. Every occurrence of `1_200` / `1200` in the crate
   (11 sites) is a send-side padding target, a `Max_UDP_Payload_Size`
   transport-parameter floor, or a ServerHello buffer bound. The only citation
   of RFC 9000 14.1 in the crate is `flyology-quic-initial_space.adb:336-338`,
   and it is about what this endpoint *emits*. `Initialize_Server_From_Initial`
   (`flyology-quic-connections.adb:309-349`) gates only on
   `Initial_Packet_Policy.Parse` succeeding; `First_Datagram'Length` is never
   compared with anything. `Serve_Listener`
   (`src/flyology-http-server-http_3.adb:2086-2102`) admits any datagram with
   `Last >= Message.Data'First and then not Truncated` and allocates a slot for
   any Initial.

4. Retry and tokens. `rg -in 'Retry|New_Token|Token' flyology_quic/src` shows
   the Retry packet type and address-validation tokens are not implemented at
   all, which `flyology_quic/tests/qualification.md` also states. There is
   therefore no alternative address-validation mechanism.

### The measurement

The discovery entry estimated "about 3.3-4.7x" against a 1,200-byte Initial with
the pinned test certificate. **That estimate is wrong and is not carried
forward.** The measured value is **1.73x**, inside the three-times limit.

Two things the estimate got wrong. The server flight is 2 datagrams totalling
698 bytes, not the "up to 18,000 octets across up to 20 datagrams" the entry
assumed (that is the size of the `Authentication` buffer, not of the flight the
320-byte Ed25519 test certificate produces). And only **three** flights fit in
the listener's 3.0 s no-progress budget, not four: the measured probe deadlines
are 999,000 us and 2,997,000 us (`Initial_RTT` 333 ms, PTO = 3 x 333 ms, then
one doubling), and the next would fall at 6,993,000 us.

What the spike measures instead:

| case | client Initial | server certificate | server bytes | ratio |
|------|---------------|--------------------|--------------|-------|
| A | 1,200 B (compliant) | 320 B, the pinned test cert | 2,084 | **1.73x** |
| E | 1,200 B (compliant) | 1,024 B | 4,337 | **3.61x** |
| B | 1,200 B (compliant) | 4,096 B (the HTTP/3 maximum) | 13,835 | **11.52x** |
| C | **216 B** (undersized) | 320 B, the pinned test cert | 2,084 | **9.64x** |
| D | **216 B** (undersized) | 4,096 B | 13,835 | **64.05x** |

Two independent multipliers, either of which alone breaks the limit:

- **The section 14.1 minimum is not enforced on receipt.** A client Initial
  carrying this crate's ClientHello needs only **216 bytes** — smaller than the
  300-350 the entry guessed. The server initialises from it, authenticates it,
  and returns the full flight. Nothing rejects it.
- **Certificate size.** `TLS_Session` copies `Certificate_DER` into the
  Certificate message without parsing it
  (`flyology-quic-tls_session.adb:155-156`), and each of the three flights
  carries it, so the flight grows by 3 bytes per certificate byte. The
  break-even is about 825 bytes: any certificate larger than that exceeds
  three times a *fully compliant, fully padded* 1,200-byte client Initial.
  `src/flyology-http-server-http_3.ads:75` accepts `Certificate_DER'Length in
  1 .. 4_096`, so a 1-2 KB CA-issued leaf — ordinary for a publicly trusted
  certificate even with an Ed25519 key — is inside the documented contract and
  over the limit. Case B and case E use opaque arrays of the right length, which
  is a faithful measurement precisely because the DER is never parsed.

### Reachability and what a peer observes

`src/flyology-http-server-http_3.adb:112-140` allocates a listener slot for any
Initial from any source address, and `:516-517` drives `QUIC.Process_Timeout`
from the worker whenever `Recovery_Deadline` is due, so the retransmissions the
spike counts are what reaches the wire. A host that spoofs the victim's source
address in one 216-byte UDP datagram causes 2,084 bytes to be delivered to the
victim over 3 seconds with this repository's own default certificate.

### Standard

- RFC 9000 section 8.1: "Prior to validating the client address, servers MUST
  NOT send more than three times as many bytes as the number of bytes they have
  received." And: "servers MUST count all of the payload bytes received in
  datagrams that are uniquely attributed to a single connection."
- RFC 9000 section 14.1: "A server MUST discard an Initial packet that is
  carried in a UDP datagram with a payload that is smaller than the smallest
  allowed maximum datagram size of 1200 bytes."

### Coverage

`flyology_quic/tests/qualification.md` lists anti-amplification accounting and
1,200-byte Initial datagrams as not yet covered, and
`flyology_quic/tests/src/flyology-quic-connections-recovery_smoke.adb:150-171`
pins the current retransmission behaviour with no byte budget. No green
baseline covers this: `review/baselines/10-http3-interop.log` exercises
well-behaved aioquic and quic-go clients, which always pad their Initial to
1,200 bytes and never spoof a source address.

### Observation not counted as a separate finding

Without address validation there is also no Retry, so each spoofed Initial holds
one of `Maximum_Connection_Capacity` = 256 listener slots for
`Default_Handshake_Idle_Timeout` = 3.0 s. 256 spoofed datagrams occupy the whole
listener. This is the same missing mechanism as the finding above and is noted
here rather than filed twice.

## QUIC-TRANSPORT-2: The 64-entry ledger fails large transfers and refuses probes

- **Verdict:** CONFIRMED
- **Severity:** P1 (discovery said P1; kept)
- **Repro:** `tests/repros/src/flyology-quic-connection_driver-repro_quic_transport_2.adb`,
  run with
  `./tests/repros/run.sh flyology-quic-connection_driver-repro_quic_transport_2`
- **Output:**

```
  note round trip 1: sent 10 packets, then CONGESTION_BLOCKED
  note round trip 2: sent 20 packets, then CONGESTION_BLOCKED
  note round trip 3: sent 40 packets, then CONGESTION_BLOCKED
  note round trip 4: sent 64 packets, then RECOVERY_CAPACITY_EXCEEDED
  note round trip 5: sent 64 packets, then RECOVERY_CAPACITY_EXCEEDED
  note round trip 6: sent 64 packets, then RECOVERY_CAPACITY_EXCEEDED
  note round trip 7: sent 64 packets, then RECOVERY_CAPACITY_EXCEEDED
  note round trip 8: sent 64 packets, then RECOVERY_CAPACITY_EXCEEDED
  note with nothing acknowledged: sent 64 further packets, then RECOVERY_CAPACITY_EXCEEDED
  FAIL a sender that runs out of room reports backpressure (Congestion_Blocked or a flow-control status), not Recovery_Capacity_Exceeded, which Flyology.HTTP.HTTP_3_Connection.Send_Status_For maps to Transport_Error
  note PTO with a full ledger: TIMEOUT_PACKET_ERROR, 0 datagrams
  FAIL a probe timeout with a full ledger still sends at least one ack-eliciting packet (RFC 9002 s6.2.4)
checks: 2  failures: 2
BUG REPRODUCED
EXIT=1
```

- **Description:** `Application_Space.Build_Tracked_Frame_Packet` and its stream
  siblings test `Sent_Packet_Policy.Retained (Item.Sent) = Max_Sent_Packets`
  (64) *before* `Recovery_Policy.Can_Send`
  (`flyology-quic-application_space.adb:417-436`, `:553-566`, `:695-705`,
  `:1088-1095`). NewReno slow start has no ceiling
  (`recovery_policy.adb:240-241` adds the acknowledged bytes while
  `Slow_Start_Limit = Byte_Count'Last`, set at `:116`), so the window passes
  64 x 1,350 bytes after three round trips and the local ledger becomes the
  binding limit. The spike measures exactly that transition: rounds 1-3 stop
  at 10, 20 and 40 packets with `CONGESTION_BLOCKED`, which is correct
  backpressure; from round 4 on the sender stops at 64 with
  `RECOVERY_CAPACITY_EXCEEDED`, having moved about 77 KB.
  `Flyology.HTTP.HTTP_3_Connection.Send_Status_For`
  (`src/flyology-http-http_3_connection.adb:39-48`) maps that to
  `Transport_Error` through its `when others` arm;
  `Server.HTTP_3.Send_Data` (`src/flyology-http-server-http_3.adb:836-843`)
  retries only on `Transport_Blocked` and otherwise raises
  `Flyology.IO.Device_Error`, and `Flush_Pending_Responses.Commit` (`:388-400`)
  does the same, so the owner closes the connection with H3_INTERNAL_ERROR
  (0x102 via `Application_Error_For`, `:298`).
  The probe path is worse than the entry states: `Process_Timeout` returns
  `Timeout_Packet_Error`, and `Server.HTTP_3.Process_Recovery`
  (`src/flyology-http-server-http_3.adb:330-345`) raises
  `Flyology.IO.Device_Error` on any status other than `Probes_Ready`,
  `Not_Due` or `No_Pending_Recovery`. RFC 9002 section 6.2.4: "When a PTO timer
  expires, a sender MUST send at least one ack-eliciting packet in the packet
  number space as a probe."
- **Reachability against a stock peer:** the spike's only non-default input is
  the peer's advertised credit, 2,000,000 bytes of stream data, which is
  smaller than quic-go's 512 KiB-per-stream default scaled by its connection
  window. Nothing else is unusual and no loss is injected.
- **Why the green suites do not catch it, checked:** the Ada-versus-Ada lanes
  use `QUIC.Transport_Settings'(others => <>)`
  (`tests/flyology-quic-test_connections.adb:91,102`,
  `tests/http3_public_smoke.adb:24`,
  `src/flyology-http-server-http_3.adb:1477`), whose
  `Max_Stream_Data_Bidi_Remote` is 16,384, so a sender is stream-flow-blocked
  at about 15 packets. `review/baselines/10-http3-interop.log` runs
  `tests/http3_interop_server.adb`, whose only routes are `/hello` and a
  `/echo` with `Max_Body => 64` (`:44-54`), and its recorded exchanges are
  three to five datagrams per connection. No maintained lane moves enough
  bytes to reach the ledger.
- **Relationship to H3-QPACK-2** (16 KiB reassembly ceiling, `review/discovery-H3-QPACK.md`):
  the two findings do **not** gate each other in this direction, and the
  hypothesis that the reassembly ceiling makes QUIC-TRANSPORT-2 unreachable is
  wrong. H3-QPACK-2 is a **receive-side** limit on the Ada endpoint: one HTTP/3
  frame larger than the 16,384-byte ring can never become contiguous.
  QUIC-TRANSPORT-2 is a **send-side** limit. The Ada server frames response
  bodies in `Response_Chunk_Size = 1_024`-byte DATA frames
  (`src/flyology-http-server-http_3.adb:46`), so a several-hundred-kilobyte
  response is hundreds of small frames, each of which a stock peer reassembles
  without difficulty; the sender's constraint is the peer's advertised credit
  and its own congestion window, neither of which the 16 KiB ring touches.
  The ring does explain why the *Ada-versus-Ada* lanes never reach the ledger:
  there the receiver's ring and the 16,384-byte default credit coincide, and
  the sender is stream-flow-blocked long before 64 packets. So the two
  findings share a cause of the coverage gap without one masking the other,
  and both should be filed.

## QUIC-TRANSPORT-3: Initial keys are never discarded; a forged Initial ends an established connection

- **Verdict:** CONFIRMED
- **Severity:** P1 (discovery said P1; kept). P0 was considered and rejected:
  the rubric's "single hostile packet that stalls" clause fits the effect, but
  the attacker must first have observed the client's original Destination
  Connection ID, so this is not a blind off-path reset.
- **Duplicate:** this is the SAME defect as **QUIC-TLS-1** in
  `review/discovery-QUIC-TLS.md`, found independently by the two discovery
  reviewers. It is verified once, here. QUIC-TRANSPORT-3 is the primary number;
  QUIC-TLS-1 is a cross-reference and must not be filed a second time. The same
  statement appears in the QUIC-TLS section of this report.
- **Repro:** `tests/repros/src/flyology-quic-connection_driver-repro_quic_transport_3.adb`,
  run with
  `./tests/repros/run.sh flyology-quic-connection_driver-repro_quic_transport_3`
- **Output:**

```
  ok   precondition: the server handshake completed
  ok   precondition: the client handshake completed
  note forged Initial for the server: 1200 bytes
  note server reports CONNECTION_CLOSED, state PEER_CLOSED
  FAIL an established server discards an Initial packet protected with the publicly derivable Initial keys (RFC 9001 s4.9.1)
  note forged Initial for the client: 1200 bytes
  note client reports CONNECTION_CLOSED, state PEER_CLOSED
  FAIL an established client discards an Initial packet protected with the publicly derivable Initial keys (RFC 9001 s4.9.1)
checks: 4  failures: 2
BUG REPRODUCED
EXIT=1
```

- **Description:** the spike completes a real handshake between two drivers,
  then builds a fresh `Initial_Connection` from nothing but values that travel
  in plaintext — the original Destination Connection ID and the two endpoints'
  connection IDs — advances its packet number past the replay window, and
  protects a transport CONNECTION_CLOSE (0x1c) with the RFC 9001 section 5.2
  Initial keys. Both an established server and an established client accept it:
  `Operation_Status` is `Connection_Closed` and `State` becomes `Peer_Closed`.
  `Scan_Datagram` dispatches Initial packets in every state
  (`connection_driver.adb:1382-1409`); `Process_Initial_Packet` honours
  `Processed.Peer_Closed` at `:906-911`, before the state check at `:1029-1033`
  ever runs; and neither `Initial_Space.State` nor
  `Connection_Driver.Connection` has any "keys discarded" flag. RFC 9001
  section 4.9.1: "a client MUST discard Initial keys when it first sends a
  Handshake packet and a server MUST discard Initial keys when it first
  successfully processes a Handshake packet. Endpoints MUST NOT send Initial
  packets after this point." (Note for the consolidation: QUIC-TLS-1 quotes a
  paraphrase, "packets protected with Initial keys received after this point
  are discarded", which is not in the RFC; the sentence above is the real
  text, and the discard obligation follows from the key-discard requirement
  rather than from a separate sentence.) The section opens with the rationale:
  "Packets protected with Initial secrets ... are not authenticated, meaning
  that an attacker could spoof packets with the intent to disrupt a
  connection."
- **Reachability:** on the server side `Registry.Resolve`
  (`src/flyology-http-server-http_3.adb:112-123`) matches the live slot on peer
  address plus either the server's source CID or the original DCID, so a
  datagram with a spoofed source address reaches the worker. On the client side
  no registry is involved. No baseline covers it: the aioquic and quic-go peers
  in `review/baselines/10-http3-interop.log` never send an Initial packet after
  the handshake.

## QUIC-TRANSPORT-4: A client fails on any post-handshake CRYPTO except one complete ticket at offset 0

- **Verdict:** CONFIRMED
- **Severity:** P1 (discovery said P1; kept)
- **Repro:** `tests/repros/src/flyology-quic-application_space-repro_quic_transport_4.adb`,
  run with
  `./tests/repros/run.sh flyology-quic-application_space-repro_quic_transport_4`
- **Output:**

```
  note first ticket at CRYPTO offset 0: PROCESSED
  ok   precondition: one complete ticket at offset 0 is accepted
  note second ticket at CRYPTO offset 4: UNEXPECTED_TLS_MESSAGE
  FAIL a client accepts a second NewSessionTicket at the next CRYPTO offset (RFC 8446 s4.6.1)
  note two tickets in one CRYPTO frame: UNEXPECTED_TLS_MESSAGE
  FAIL a client accepts two complete NewSessionTickets carried in one CRYPTO frame
  note first half of a split ticket: UNEXPECTED_TLS_MESSAGE
  FAIL a client buffers the first CRYPTO frame of a ticket that spans two frames (RFC 9001 s4)
checks: 4  failures: 3
BUG REPRODUCED
EXIT=1
```

- **Description:** `Application_Space.Process_Packet`
  (`flyology-quic-application_space.adb:1307-1349`) judges each 1-RTT CRYPTO
  frame in isolation. It accepts the frame only when the local role is client,
  `Crypto_Offset = 0`, the first handshake byte is 4 (NewSessionTicket), and
  the declared handshake body length exactly equals the frame payload minus
  the 4-byte header. All three shapes a compliant server may produce fail that
  test: a second ticket, which lands at the next offset in the continuous
  CRYPTO offset space; two tickets sharing one frame; and one ticket split
  across two frames. Each becomes `Unexpected_TLS_Message`, which
  `Transport_Error_For` maps to CRYPTO_ERROR 0x10A
  (`connection_driver.adb:580`) and `Fail_Application_With_Close`
  (`connection_driver.adb:1316-1330`) turns into a CONNECTION_CLOSE, so an
  HTTP/3 client connection that finished its handshake fails afterwards.
  RFC 8446 section 4.6.1: "Servers MAY send multiple tickets on a single
  connection, either immediately after each other or after specific events".
  RFC 9001 section 4: "QUIC carries TLS handshake data in CRYPTO frames, each
  of which consists of a contiguous block of handshake data identified by an
  offset and length", and "QUIC is responsible for buffering handshake bytes
  that arrive out of order"; the application space does no such buffering.
- **Peer behaviour:** which stock servers send more than one ticket, or split
  one across frames, is **not verified against a peer** in this harness. The
  interop baseline passes because neither oracle sends a post-handshake ticket
  in the qualified configuration (`review/baselines/10-http3-interop.log` shows
  three to five datagrams per connection and no post-handshake CRYPTO).
  `flyology_quic/tests/src/flyology-quic-application_space-smoke.adb:418-458`
  pins the current behaviour for one ticket at offset 0 and for a KeyUpdate,
  so a fix must change that test.

## QUIC-TRANSPORT-5: `Transport_Settings` are advertised unclamped against fixed reassembly bounds

- **Verdict:** CONFIRMED
- **Severity:** P1 (discovery said P2; raised). The rubric's P1 covers a
  documented contract being violated. `Transport_Settings` is a public
  parameter of `Server.HTTP_3.Serve*` (`src/flyology-http-server-http_3.ads:66,
  103, 142`) and of `Routing.Serve_HTTP_3`
  (`src/flyology-http-server-routing.ads:998, 1060, 1131, 1202`); its field is
  documented as "Receive credit on peer bidi streams"
  (`flyology-quic-connections.ads:97`), typed over the whole varint range, and
  no `.ads` text says the defaults are ceilings. Raising it — the obvious way
  to accept larger request bodies — makes the server close a compliant peer's
  connection with transport error 0x01.
- **Repro:** `tests/repros/src/repro_quic_transport_5.adb`, run with
  `./tests/repros/run.sh repro_quic_transport_5`
- **Output:**

```
  ok   precondition: the handshake completed
  note server advertised Max_Stream_Data_Bidi_Remote = 32768
  note client sent 16500 bytes within the advertised 32768; last client status SENT; server status SUCCEEDED; server state FAILED
  FAIL a server accepts stream data inside the per-stream credit it advertised (RFC 9000 s4.1)
  FAIL all 18 chunks are delivered within the advertised credit
         expected: 19800   actual: 16500
checks: 3  failures: 2
BUG REPRODUCED
EXIT=1
```

- **Description:** `Encode_Parameters` (`flyology-quic-connections.adb:176-201`)
  copies each `Transport_Settings` field straight into the encoded transport
  parameters with no comparison against
  `Stream_Reassembly_Policy.Max_Stream_Data` (16,384,
  `flyology-quic-stream_reassembly_policy.ads:18`) or
  `Stream_Table_Policy.Max_Streams` (32, `:17`). The spike configures a server
  with `Max_Stream_Data_Bidi_Remote => 32_768`, completes a handshake, and has
  the client send 1,100-byte chunks on one stream while the server's
  application never consumes. The server accepts 16,500 bytes and then
  transitions to `Failed`: `Stream_Reassembly_Policy.Insert` returns
  `Exceeds_Capacity` once `Ending - Base` passes 16,384
  (`stream_reassembly_policy.adb:72-76`), which becomes
  `Stream_Table_Policy.Stream_Data_Too_Large`, then
  `Application_Space.Stream_Data_Too_Large`, then transport error 0x01
  (INTERNAL_ERROR) at `connection_driver.adb:581-582`. RFC 9000 section 4.1:
  "QUIC employs a limit-based flow control scheme where a receiver advertises
  the limit of total bytes it is prepared to receive on a given stream or for
  the entire connection"; the peer stayed inside that limit.
- **Coverage:** none; every maintained lane uses
  `Transport_Settings'(others => <>)`, whose 16,384 default happens to equal
  the ring exactly.

## QUIC-TRANSPORT-6: STOP_SENDING is validated and dropped

- **Verdict:** CONFIRMED
- **Severity:** P2 (discovery said P2; kept). P1 was considered because the
  reachability is much higher than the discovery entry states (below), but
  nothing fails: the peer discards the data it asked to stop, and the
  connection survives. Wasted work, not a wrong result.
- **Repro:** `tests/repros/src/flyology-quic-application_space-repro_quic_transport_6.adb`,
  run with
  `./tests/repros/run.sh flyology-quic-application_space-repro_quic_transport_6`
- **Output:**

```
  ok   precondition: stream 0 is in the Send state
  note STOP_SENDING processed as PROCESSED; frames seen 1
  note next outgoing packet: reply frames 02 00 00 00 00
  FAIL an endpoint that receives STOP_SENDING for a stream in the Send state sends a RESET_STREAM (RFC 9000 s3.5)
  note sending more data on the cancelled stream: SENT
  FAIL a stream that the peer asked to stop is no longer sendable (RFC 9000 s3.5 moves it to Reset Sent)
checks: 3  failures: 2
BUG REPRODUCED
```

- **Standard, quoted exactly:** RFC 9000 section 3.5: "A STOP_SENDING frame
  requests that the receiving endpoint send a RESET_STREAM frame. **An endpoint
  that receives a STOP_SENDING frame MUST send a RESET_STREAM frame if the
  stream is in the "Ready" or "Send" state.**" The spike's stream is in the
  Send state (its precondition sends data on it first).
- **Description:** `Application_Space.Process_Packet`
  (`flyology-quic-application_space.adb:1392-1402`) runs
  `Receive_Flow_Control_Policy.Check_Stop_Sending` purely as an admission
  check and then falls through; `Stop_Sending` appears nowhere else in the
  body. `Process_Result` (`application_space.ads:241-253`) has no field for
  it, so no higher layer can act on it either. After the frame is processed
  the spike decrypts the endpoint's next outgoing packet and finds only an
  ACK (`02 00 00 00 00`), and the local sender can still put more data on the
  cancelled stream.
- **Do stock peers send it? Checked against the pinned oracles' source.**
  - **quic-go 0.54.1 does, in ordinary use.** `http3/body.go:70-72`:
    `func (r *body) Close() error { r.str.CancelRead(...ErrCodeRequestCanceled); return nil }`,
    and `http3/server.go:674` calls `str.CancelRead(...ErrCodeNoError)` on the
    request stream after a handler returns. `CancelRead` queues a
    STOP_SENDING unless the stream already reached EOF or was cancelled
    (`receive_stream.go:379-392`: `if s.errorRead || s.cancelledRemotely { return false }`).
    So any Go client that closes a response body without reading it to EOF, and
    any Go handler that does not drain the request body, sends STOP_SENDING to
    the Ada endpoint.
  - **aioquic 1.3.0 sends it** only when the application aborts a read
    (`quic/connection.py:3128-3129`, gated on `stream.receiver.stop_pending`).
  - **The interop lane passing does not mean they do not send it.** The
    oracles read the whole body first — `tests/oracle/quic-go/main.go:131`
    calls `io.ReadAll(response.Body)` before `Close()`, which makes
    `CancelRead` a no-op through the `s.errorRead` branch above, and the
    aioquic scripts never cancel. The lane is silent on this frame, not
    evidence about it.
  - Possible further consequence, **not verified against a peer**: quic-go
    stops issuing MAX_STREAM_DATA for an abandoned stream, so an Ada server
    streaming a response larger than the peer's per-stream window onto a
    cancelled stream would become stream-flow-blocked and sit in
    `Send_Data`'s `Wait_For_Transport` loop until the request deadline.
- **Coverage:** `flyology_quic/tests/qualification.md:143` lists "reset/stop
  semantics" among the areas still required before claiming the complete QUIC
  v1 feature set, so this is a known gap rather than a surprise.

## QUIC-TRANSPORT-7: PATH_CHALLENGE is parsed and ignored

- **Verdict:** CONFIRMED
- **Severity:** P2 (discovery said P2; kept). It is an unambiguous MUST
  violation, but it needs a path change to be reached, and
  `flyology_quic/tests/qualification.md:144` already lists "NAT rebinding, and
  path validation" as not yet qualified.
- **Repro:** `tests/repros/src/flyology-quic-application_space-repro_quic_transport_7.adb`,
  run with
  `./tests/repros/run.sh flyology-quic-application_space-repro_quic_transport_7`
- **Output:**

```
  note PATH_CHALLENGE processed as PROCESSED; frames seen 1; ack-eliciting TRUE
  ok   precondition: the PATH_CHALLENGE frame is accepted
  note next outgoing packet: reply frames 02 00 00 00 00
  FAIL an endpoint that receives PATH_CHALLENGE echoes the data in a PATH_RESPONSE (RFC 9000 s8.2.2)
checks: 2  failures: 1
BUG REPRODUCED
```

- **Standard, quoted exactly:** RFC 9000 section 8.2.2: "**On receiving a
  PATH_CHALLENGE frame, an endpoint MUST respond by echoing the data contained
  in the PATH_CHALLENGE frame in a PATH_RESPONSE frame.** An endpoint MUST NOT
  delay transmission of a packet containing a PATH_RESPONSE frame unless
  constrained by congestion control."
- **Description:** `Application_Frame_Policy` decodes 0x1A and 0x1B into
  `Path_Challenge` and `Path_Response` kinds, but the `Frame.Kind` chain in
  `flyology-quic-application_space.adb:1283-1512` has no branch for either;
  `rg 'Path_Challenge|Path_Response' flyology_quic/src/flyology-quic-application_space.adb`
  returns nothing. The frame is counted as ack-eliciting and discarded. The
  spike decrypts the endpoint's next outgoing packet and finds only an ACK.
- **Do stock peers send it? Checked against the pinned oracles' source.**
  Not on a stable path, which is why the interop lane passes.
  - aioquic 1.3.0 writes a PATH_CHALLENGE for any path that is neither
    validated nor already challenged, right after the handshake
    (`quic/connection.py:3022-3033`). A client's own path is created
    pre-validated by `connect()` (`:516`,
    `QuicNetworkPath(addr, is_validated=True)`), and a server's path is
    validated when a Handshake-epoch packet arrives (`:1060-1064`). So neither
    role challenges on the original path; both would challenge a new one.
  - quic-go 0.54.1 enqueues a PATH_CHALLENGE only when its path manager sees a
    new remote address (`path_manager.go:122-137`) or probes an alternative
    path (`path_manager_outgoing.go:267`).
  So the lane passing is consistent with neither peer challenging the original
  path, and says nothing about a rebound one. After a NAT rebinding a stock
  peer challenges the new address, never receives a PATH_RESPONSE, and by
  RFC 9000 section 9 cannot use the unvalidated path beyond the
  anti-amplification limit, so the connection blackholes until its idle
  timeout.
- **Side note for the consolidation:** aioquic's `QuicNetworkPath.can_send`
  (`quic/connection.py:209`) is exactly the accounting QUIC-TRANSPORT-1 finds
  missing: `return self.is_validated or (self.bytes_sent + size) <= 3 * self.bytes_received`.

## QUIC-TRANSPORT-8: The server's ack-eliciting Initial datagram is not expanded to 1,200 bytes

- **Verdict:** CONFIRMED
- **Severity:** P2 (discovery said P2; kept)
- **Repro:** `tests/repros/src/repro_quic_transport_8.adb`, run with
  `./tests/repros/run.sh repro_quic_transport_8`
- **Output:**

```
  ok   the client Initial datagram is padded to 1200 bytes
  note server datagram 1: first byte c1, length 142
  note server datagram 2: first byte eb, length 560
  ok   precondition: the server's first datagram is a long-header Initial packet
  FAIL a UDP datagram carrying an ack-eliciting server Initial packet is expanded to at least 1200 bytes (RFC 9000 s14.1)
checks: 3  failures: 1
BUG REPRODUCED
EXIT=1
```

- **Standard, quoted exactly:** RFC 9000 section 14.1: "Similarly, a server
  MUST expand the payload of all UDP datagrams carrying ack-eliciting Initial
  packets to at least the smallest allowed maximum datagram size of 1200
  bytes."
- **Description:** `Initial_Space.Emit` and `Build_Transport_Close_Packet`
  compute `Minimum := (if Item.Role = Client then 1_200 else 0)`
  (`flyology-quic-initial_space.adb:141-142`, `:339-340`), and
  `Process_Initial_Packet` appends the ServerHello Initial as its own datagram
  rather than coalescing it with the Handshake packets
  (`connection_driver.adb:956-969`). The measured server Initial datagram is
  142 bytes and carries CRYPTO, so it is ack-eliciting. Stock clients do not
  discard it, so this is not interop-breaking on its own; it is also the
  reason the server's flight is cheap enough that case A of
  QUIC-TRANSPORT-1 stays under 3x.

## QUIC-TRANSPORT-9: An ACK frame with 64 or more ranges closes the connection

- **Verdict:** CONFIRMED
- **Severity:** P2 (discovery said P2; kept). Reachability depends on the
  peer's own ACK-range cap, which is not verified against a peer here.
- **Repro:** `tests/repros/src/flyology-quic-application_space-repro_quic_transport_9.adb`,
  run with
  `./tests/repros/run.sh flyology-quic-application_space-repro_quic_transport_9`
- **Output:**

```
  note highest packet number the sender reached: 199
  ok   precondition: enough packets were sent for a 64-range ACK
  note ACK largest 199 with 62 ranges (smallest 75): PROCESSED
  ok   precondition: an ACK with 62 ranges is accepted
  note ACK largest 199 with 63 ranges (smallest 73): PROCESSED
  ok   an ACK with 63 ranges is accepted
  note ACK largest 199 with 64 ranges (smallest 71): ACK_RANGE_CAPACITY_EXCEEDED
  FAIL an ACK with 64 ranges is accepted (RFC 9000 s19.3 sets no maximum on ACK Range Count)
checks: 4  failures: 1
BUG REPRODUCED
EXIT=1
```

- **Description:** the spike puts 200 real packets behind the sender (the peer
  acknowledges every eighth so neither the congestion window nor the 64-entry
  ledger of QUIC-TRANSPORT-2 interferes), then delivers ACK frames whose every
  range names packets the sender really sent. 62 and 63 ranges are processed;
  64 is rejected. `ACK_Range_Policy.Decode` tests
  `Frame.ACK_Range_Count >= Max_Ranges` (64) before any other validity check
  (`flyology-quic-ack_range_policy.adb:64-66`), so the frame is refused purely
  on its range count. `Application_Space` maps `Too_Many_Ranges` to
  `ACK_Range_Capacity_Exceeded` (`application_space.adb:1452-1461`) and
  `Transport_Error_For` maps that to PROTOCOL_VIOLATION 0x0A
  (`connection_driver.adb:575-578`), so the driver answers a well-formed frame
  with a CONNECTION_CLOSE. RFC 9000 section 19.3 defines "ACK Range Count: A
  variable-length integer specifying the number of ACK Range fields in the
  frame" and states no maximum; section 13.2.3 says "A receiver limits the
  number of ACK Ranges (Section 19.3.1) it remembers and sends in ACK frames",
  which constrains what an endpoint emits, not what it must accept.

## QUIC-TRANSPORT-10: Connection-ID transport parameters are never compared with the wire CIDs

- **Verdict:** CONFIRMED
- **Severity:** P2 (discovery said P2; kept)
- **Repro:** `tests/repros/src/flyology-quic-connection_driver-repro_quic_transport_10.adb`,
  run with
  `./tests/repros/run.sh flyology-quic-connection_driver-repro_quic_transport_10`
- **Output:**

```
  note honest parameters: client state CONNECTED
  ok   precondition: matching parameters complete a handshake
  note original_destination_connection_id does not match the client's DCID: client state CONNECTED
  FAIL a client rejects a server whose original_destination_connection_id does not match the Destination Connection ID it sent (RFC 9000 s7.3)
  note initial_source_connection_id does not match the server's wire SCID: client state CONNECTED
  FAIL a client rejects a server whose initial_source_connection_id does not match the Source Connection ID it received (RFC 9000 s7.3)
checks: 3  failures: 2
BUG REPRODUCED
EXIT=1
```

- **Description:** the spike runs three handshakes that differ only in the
  server's authenticated transport parameters, leaving the wire connection IDs
  correct. A server that claims an `original_destination_connection_id` of
  `deadbeefdeadbeef` — which is not the Destination Connection ID the client
  put in its Initial — and a server that claims an
  `initial_source_connection_id` that is not the Source Connection ID it used
  on the wire both complete the handshake. `Transport_Parameter_Policy.Decode`
  checks presence and role only, and
  `rg 'Original_Destination_Connection_ID|Initial_Source_Connection_ID|Retry_Source_Connection_ID' flyology_quic/src/ --glob '!*transport_parameter_policy*'`
  finds only the two encode sites in `connections.adb:185-187`, so the decoded
  values are never compared with `Item.Peer_ID`, `Item.Local_ID` or the
  original DCID. RFC 9000 section 7.3: "The values provided by a peer for
  these transport parameters MUST match the values that an endpoint used in
  the Destination and Source Connection ID fields of Initial packets that it
  sent (and received, for servers). Endpoints MUST validate that received
  transport parameters match received connection ID values." The section then
  requires "a mismatch between values received from a peer in these transport
  parameters and the value sent in the corresponding Destination or Source
  Connection ID fields of Initial packets" to be "a connection error of type
  TRANSPORT_PARAMETER_ERROR or PROTOCOL_VIOLATION". The practical effect is
  that on-path tampering with an Initial packet's connection IDs is not
  diagnosed; the handshake either succeeds or later fails with an unrelated
  status. Stays P2 for that reason.

## QUIC-TRANSPORT-11 (new): packet-driven operations dereference an uninitialized connection

- **Verdict:** CONFIRMED
- **Severity:** P2. The discovery entry records this under "Observations not
  counted"; it is numbered here because it is a reproducible contract
  violation, and because it was worth settling whether it is a memory-safety
  problem. It is not: the access check is present and raises.
- **Repro:** `tests/repros/src/repro_quic_transport_11.adb`, run with
  `./tests/repros/run.sh repro_quic_transport_11`
- **Output:**

```
  ok   a fresh Connection reports Uninitialized
  ok   Is_Connected guards the null backend
  ok   Has_Recovery_Timeout guards the null backend
  note Process_Datagram raised CONSTRAINT_ERROR: flyology-quic-connections.adb:417 access check failed
  FAIL Process_Datagram on an uninitialized connection reports Invalid_State instead of raising
checks: 4  failures: 1
BUG REPRODUCED
EXIT=1
```

- **Description:** `Flyology.QUIC.Connections` guards the null backend in
  `State`, `Is_Connected`, `Received_Data`, `Handshake_Confirmed` and
  `Has_Recovery_Timeout`, but every packet-driven operation —
  `Start_Client`, both `Process_Datagram` overloads, `Process_Timeout`,
  `Open_Stream` and all the `Build_*_Datagram` procedures — writes
  `Impl (Item).Driver` with no guard. `Operation_Status` documents
  "@enum Invalid_State The operation is not valid in the current phase"
  (`flyology-quic-connections.ads:323`) and `State` returns `Uninitialized`
  for a fresh object, so a caller reasonably expects that status. The result
  is `Constraint_Error` from the access check at `connections.adb:417`.
  This is not a memory-safety issue: `flyology_quic/config/flyology_quic_config.gpr`
  builds with `-O3 -gnatn` and no `-gnatp`, so the check is present in the
  release profile as well as in this harness.
- **Reachability:** not reachable through the maintained HTTP/3 server.
  `Serve_Connection` (`src/flyology-http-server-http_3.adb:1860-1868`) raises
  `Protocol_Error` when `Initialize_Server_From_Initial` does not return
  `Initialized`, before any `Process_Datagram` call, and the worker task
  catches it (`:2027-2031`). This is a public-API hygiene defect, which is why
  it stays P2.

## Notes for the consolidation

- **QUIC-TRANSPORT-3 and QUIC-TLS-1 are one defect**, found independently by
  two discovery reviewers. Verified once, under QUIC-TRANSPORT-3. File it once,
  with QUIC-TLS-1 as a cross-reference. QUIC-TLS-1's quotation of RFC 9001
  section 4.9.1 ("packets protected with Initial keys received after this point
  are discarded") is a paraphrase that is not in the RFC; use the sentence
  quoted under QUIC-TRANSPORT-3.
- **QUIC-TRANSPORT-2 and H3-QPACK-2 do not mask each other.** The 16 KiB
  reassembly ceiling is a receive-side limit on the Ada endpoint; the 64-entry
  ledger is a send-side limit. A large Ada response is many 1,024-byte DATA
  frames, so the ceiling never gates the sender. The ring does explain why the
  Ada-versus-Ada lanes never reach the ledger, so the two share a cause of the
  coverage gap. Both should be filed.
- **What `qualification.md` already says.** Four of these findings sit in areas
  the crate itself lists as not yet qualified: "key discard" (line 138) covers
  QUIC-TRANSPORT-3, "reset/stop semantics" (143) covers QUIC-TRANSPORT-6,
  "NAT rebinding, and path validation" (144) covers QUIC-TRANSPORT-7, and
  "Anti-amplification accounting, 1200-byte Initial datagrams" (145) covers
  QUIC-TRANSPORT-1 and QUIC-TRANSPORT-8. That is a statement about test
  coverage, not about the behaviour being intended; the defects are real and
  reproduced. It does mean none of them should be reported as a surprise
  regression.
- **Peer evidence gathered here** (from the pinned oracles' own source, not
  from a new peer run): quic-go 0.54.1's `http3` package sends STOP_SENDING on
  every early response-body close and on every handler that does not drain the
  request body; aioquic 1.3.0 and quic-go both send PATH_CHALLENGE only for a
  path they have not validated, which on a stable path is neither of them; and
  aioquic implements the RFC 9000 section 8.1 accounting this crate lacks, in
  one line (`quic/connection.py:209`).
- **Not verified against a peer, stated as such in the entries:** which TLS
  servers emit more than one NewSessionTicket or split one across CRYPTO frames
  (QUIC-TRANSPORT-4); whether any stock peer emits 64 or more ACK ranges
  (QUIC-TRANSPORT-9); and the downstream flow-control stall sketched under
  QUIC-TRANSPORT-6.
- **Areas the discovery reviewer cleared, spot-checked here and not disputed:**
  the `Recovery_Policy` slow-start and `Can_Send` arithmetic (read in full
  while building the QUIC-TRANSPORT-2 spike), `Sent_Packet_Policy`'s
  `Acknowledges_Unsent_Packet` rule and `ACK_Range_Policy`'s ordering of checks
  (read in full while building the QUIC-TRANSPORT-9 spike), and
  `Stream_Reassembly_Policy`'s capacity test (QUIC-TRANSPORT-5). Nothing in
  them contradicted the discovery's "no findings" list.
