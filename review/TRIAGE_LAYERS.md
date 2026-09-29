## Layer 1 - HTTP/1 server, routing and middleware

The surface a plain TCP peer reaches without negotiating anything: the HTTP/1.1
connection engine, request-head and chunk parsing, the router, and the middleware chain
that CORS, rate limits, metrics and the error responder hang from. No P0 sits here; the
three P1 items are an escaping `Program_Error` that drops the connection with no response
({{ISSUE:H1-SERVER-5}}), an over-segmented target that bypasses the middleware chain and
automatic admission ({{ISSUE:ROUTING-MW-1}}), and a rejected `Respond` that makes the
errors middleware close instead of writing its 500 ({{ISSUE:ROUTING-MW-2}}). One ordering
constraint: {{ISSUE:H1-SERVER-5}} and {{ISSUE:H1-SERVER-3}} both change how a parsing or
admission rejection reaches a status in `Connection_Handlers.Serve` and
`Dispatch_Configuration`, so one lane should take both, {{ISSUE:H1-SERVER-5}} first, and
both carry a maintainer decision about the same vocabulary.

- **{{ISSUE:H1-SERVER-5}}** (P1) Raise `Protocol_Error` rather than `Program_Error` for the three peer-chosen refusals, leaving the two application-fault raises alone.
  Depends on: nothing. **DECISION** which status each peer-chosen refusal answers with.
- **{{ISSUE:ROUTING-MW-1}}** (P1) Turn a segmentation failure into the same invalid-path result the decode failure produces, so `Run_Automatic` answers it.
  Depends on: nothing.
- **{{ISSUE:ROUTING-MW-2}}** (P1) Narrow the blanket handler so a rejected `Respond` marks the exchange `Failed` only once the wire response has started.
  Depends on: nothing.
- **{{ISSUE:H1-SERVER-1}}** (P2) Consume one leading `CRLF` before the head is inspected, in one place both the head inspector and the reader see.
  Depends on: nothing.
- **{{ISSUE:H1-SERVER-2}}** (P2) Trim SP and HTAB at both ends of the chunk-size and extension name and value slices, leaving quoted strings intact.
  Depends on: nothing.
- **{{ISSUE:H1-SERVER-3}}** (P2) Distinguish the unknown-transfer-coding rejection from the general malformed-request case so the handler can answer 501.
  Depends on: {{ISSUE:H1-SERVER-5}}. **DECISION** how the rejection vocabulary carries a status out of the parser.
- **{{ISSUE:H1-SERVER-4}}** (P2) Record the deliberate refusal of a mismatched absolute-form authority in the server specification and the matching guide page.
  Depends on: nothing. **DECISION** whether the refusal stands or the `Host` field is ignored as RFC 9112 asks.
- **{{ISSUE:ROUTING-MW-3}}** (P2) Require `:path` to be `*` or to begin with `/` in the HTTP/2 admission check, matching the HTTP/3 policy exactly.
  Depends on: nothing.
- **{{ISSUE:ROUTING-MW-4}}** (P2) Bound the method component of the metrics series key, and give the filled table a replacement rule.
  Depends on: nothing. **DECISION** which methods share a fixed key and whether the table evicts.
- **{{ISSUE:ROUTING-MW-5}}** (P2) Emit `Vary: Origin` for every response on a route with a non-wildcard CORS policy, before the three early returns.
  Depends on: nothing.

## Layer 2 - HTTP/2

The HTTP/2 server engine, the client session, HPACK and the settings, frame and policy
units they consume. Two P0 items: a client that fails the connection on a setting RFC 9113
permits, which breaks every origin built on python-hyper h2 ({{ISSUE:H2-1}}), and a server
that enforces its reduced stream window before the peer can have read the SETTINGS that
announced it ({{ISSUE:H2-2}}); the four P1 items are a discarded response body after
`RST_STREAM(NO_ERROR)` ({{ISSUE:H2-3}}), a cancel mid field section that freezes the client
pump ({{ISSUE:H2-4}}), a route body limit that can never answer 413 ({{ISSUE:H2-5}}), and a
missing HPACK dynamic table size update ({{ISSUE:H2-6}}). Two ordering constraints:
{{ISSUE:H2-3}} must land before {{ISSUE:H2-10}}, or the server change breaks this
repository's own client against itself; and {{ISSUE:H2-1}} and {{ISSUE:H2-7}} both turn on
the two `Settings.Apply` call sites that discard the applied result, so one lane should
take both.

- **{{ISSUE:H2-1}}** (P0) Test the value rather than the peer role in the `ENABLE_PUSH` guard, and remove the workaround from both maintained Python peers.
  Depends on: nothing.
- **{{ISSUE:H2-2}}** (P0) Start each stream at the protocol default window, and answer a stream-window overshoot with `RST_STREAM` instead of a connection error.
  Depends on: nothing. **DECISION** what window is advertised and how the per-stream input buffer is bounded. **MODEL FIRST** HTTP/2 stream state and flow control. **PROOF** `Flyology.HTTP.HTTP_2_Policy`, if the window arithmetic changes there.
- **{{ISSUE:H2-3}}** (P1) Leave a stream whose response already completed alone in `Reset_Stream`, so buffered body bytes still reach the caller.
  Depends on: nothing. **DECISION** whether the test is on stream phase, on the error code, or on both.
- **{{ISSUE:H2-4}}** (P1) Admit the pinned header slot regardless of phase in the client's `Pull_Output`, so the field section finishes and the pin clears.
  Depends on: nothing. **MODEL FIRST** HTTP/2 stream state and flow control.
- **{{ISSUE:H2-5}}** (P1) Exclude `Body_Limit_Failure` from the failure test in `Queue_Response_Head`, so an over-limit stream can still answer 413.
  Depends on: nothing. **DECISION** how the over-limit condition is carried without a new failure variant.
- **{{ISSUE:H2-6}}** (P1) Emit the RFC 7541 dynamic table size update from both `Encode_Head` entry points once a lowered table size is acknowledged.
  Depends on: nothing. **DECISION** what maximum the encoder signals and how the value reaches `Encode_Head`.
- **{{ISSUE:H2-7}}** (P2) Pass `Flow_Control_Error` through at both `Settings.Apply` call sites when `Apply` reports it, instead of defaulting to `Protocol_Error`.
  Depends on: nothing.
- **{{ISSUE:H2-8}}** (P2) Test for an idle stream before a zero-increment `WINDOW_UPDATE` is rejected, and stop `Reject_Stream` advancing `Last_Client_Stream`.
  Depends on: nothing. **DECISION** whether the idle test lives at the call site or in the stream controller. **MODEL FIRST** HTTP/2 stream state and flow control.
- **{{ISSUE:H2-9}}** (P2) Charge closed-stream credit without queueing `RST_STREAM` when the server itself reset the stream, including after the slot is reaped.
  Depends on: nothing. **MODEL FIRST** HTTP/2 stream state and flow control.
- **{{ISSUE:H2-10}}** (P2) Reset an early-answered stream with `NO_ERROR`, or keep it draining, so its input count returns to the connection window.
  Depends on: {{ISSUE:H2-3}}. **DECISION** whether the server aborts or drains a request body it will not read. **MODEL FIRST** HTTP/2 stream state and flow control.
- **{{ISSUE:H2-11}}** (P2) Report an idle-stream `RST_STREAM` or `WINDOW_UPDATE` to the frame handler so it reaches `Protocol_Failure`, and suppress the second reset.
  Depends on: nothing. **DECISION** whether the idle test adds a result parameter or moves to the two call sites. **MODEL FIRST** HTTP/2 stream state and flow control.

## Layer 3 - HTTP/3, QPACK and the QUIC transport

The largest layer: the HTTP/3 server and client, QPACK, and the `flyology_quic` transport
and TLS crate underneath them. Three P0 items, one per crate boundary: a request body over
roughly 15 KiB that never completes because no MAX_STREAM_DATA is sent
({{ISSUE:H3-QPACK-1}}), a frame larger than the reassembly window that can never be
consumed ({{ISSUE:H3-QPACK-2}}), and a server with no anti-amplification limit that also
accepts undersized client Initial packets ({{ISSUE:QUIC-TRANSPORT-1}}). Twelve P1 items
follow, from the field-section limit that closes the connection on a 33-field request
({{ISSUE:H3-QPACK-3}}) to the TLS secrets that outlive the handshake ({{ISSUE:QUIC-TLS-3}}).
Three ordering constraints: {{ISSUE:H3-QPACK-1}} and {{ISSUE:H3-QPACK-2}} both turn on the
same 16,384-byte figure, once as a transport default and once as a compile-time reassembly
bound, so their decisions should be taken together; {{ISSUE:H3-QPACK-9}} shares
`Return_Request_Credit` with {{ISSUE:H3-QPACK-1}}; and {{ISSUE:QUIC-TRANSPORT-8}} must not
land before {{ISSUE:QUIC-TRANSPORT-1}}, because padding the server's Initial is what makes
the missing byte budget reachable. More of this layer sits inside proved units than any
other, so lanes here run `./scripts/prove.sh` with `FLYOLOGY_PROOF_LEVEL=2` routinely.

- **{{ISSUE:H3-QPACK-1}}** (P0) Return request credit from the `Data_Received` branch as well, and answer an oversized request with STOP_SENDING rather than silence.
  Depends on: nothing. **DECISION** at what rate an in-progress body earns credit, and whether the advertised window changes.
- **{{ISSUE:H3-QPACK-2}}** (P0) Consume a DATA frame's payload in pieces so the reassembly base advances, and report an oversized declared length as a resource error.
  Depends on: nothing. **DECISION** where the frame-length ceiling and the reassembly bound live. **PROOF** `Flyology.HTTP.HTTP_3_Frame_Policy`, `Flyology.HTTP.HTTP_3_Stream_Receive_Policy` and `Flyology.QUIC.Stream_Reassembly_Policy`.
- **{{ISSUE:QUIC-TRANSPORT-1}}** (P0) Credit received and sent bytes per connection, gate output at three times received while the address is unvalidated, and refuse short Initial datagrams.
  Depends on: nothing. **MODEL FIRST** QUIC recovery and packet-space transitions.
- **{{ISSUE:H3-QPACK-3}}** (P1) Give the QPACK retention bounds a status the server answers with 431, and advertise a field-section limit in the server's settings.
  Depends on: nothing. **DECISION** where the advertised field-section limit lives, and whether a new public status variant is added. **PROOF** `Flyology.HTTP.QPACK_Field_Section_Policy` and `Flyology.HTTP.HTTP_3_Stream_Receive_Policy`.
- **{{ISSUE:H3-QPACK-4}}** (P1) Drop the client-role guard in `Release_Message` so a cancelled server response releases its send slot.
  Depends on: nothing.
- **{{ISSUE:H3-QPACK-5}}** (P1) Send GOAWAY and a QUIC application close before `Cleanup`, on both the retirement path and the cancellation path.
  Depends on: nothing. **DECISION** how long the server waits between the GOAWAY and the close.
- **{{ISSUE:H3-QPACK-6}}** (P1) Answer the raising statuses with a stream-scoped reset inside the event loop, and close the connection on every remaining path.
  Depends on: {{ISSUE:H3-QPACK-5}}. **DECISION** how the eight request slots relate to the advertised bidirectional stream limit.
- **{{ISSUE:H3-QPACK-7}}** (P1) Raise `Max_Encode_Length` to what the public field bounds imply, and frame a large field section across several QUIC stream writes.
  Depends on: nothing. **DECISION** the value of `Max_Encode_Length` and whether it stays visible. **PROOF** `Flyology.HTTP.QPACK_Field_Section_Policy`.
- **{{ISSUE:H3-QPACK-8}}** (P1) Compute each stream's receive limit from what its own reader has consumed, and skip a stream whose ring is full.
  Depends on: nothing. **DECISION** how per-stream headroom crosses the public QUIC interface. **PROOF** `Flyology.QUIC.Receive_Flow_Control_Policy`.
- **{{ISSUE:H3-QPACK-9}}** (P1) Count retired streams rather than dispatched requests, and return request credit from the `Stream_Reset` branch as well.
  Depends on: {{ISSUE:H3-QPACK-1}}. **DECISION** the rate at which a peer reset refills the advertised stream limit.
- **{{ISSUE:QUIC-TRANSPORT-2}}** (P1) Let `Can_Send` decide first and report a full ledger as blocked rather than as a transport error; reserve one entry for probes.
  Depends on: nothing. **DECISION** the value and visibility of `Max_Sent_Packets`. **MODEL FIRST** QUIC recovery and packet-space transitions. **PROOF** `Flyology.QUIC.Sent_Packet_Policy` and `Flyology.QUIC.Recovery_Policy`.
- **{{ISSUE:QUIC-TRANSPORT-3}}** (P1) Record the Initial key discard in the driver, and drop a long-header Initial packet unparsed once the handshake has moved on.
  Depends on: nothing. **MODEL FIRST** QUIC recovery and packet-space transitions.
- **{{ISSUE:QUIC-TRANSPORT-4}}** (P1) Ignore post-handshake CRYPTO on the client, keeping `Unexpected_TLS_Message` only for the KeyUpdate case at offset 0.
  Depends on: nothing. **DECISION** whether a 1-RTT CRYPTO reassembly buffer is added, and what bounds it.
- **{{ISSUE:QUIC-TRANSPORT-5}}** (P1) Clamp or reject `Transport_Settings` fields that exceed what the reassembly ring and the stream table can honour.
  Depends on: nothing. **DECISION** where the implicit reassembly ceiling lives and what the accepted range is. **PROOF** `Flyology.QUIC.Stream_Reassembly_Policy` and `Flyology.QUIC.Stream_Table_Policy`, if the capacity moves into them.
- **{{ISSUE:QUIC-TLS-3}}** (P1) Clear the handshake, master, exporter and traffic secrets at both success transitions, and wipe the session when the connection is released.
  Depends on: nothing. **DECISION** how the wipe reaches `Session` at finalization.
- **{{ISSUE:H3-QPACK-10}}** (P2) Extend the stream-local `Message_Error` and `Header_Error` branch to the server role, so a malformed request resets one stream.
  Depends on: {{ISSUE:H3-QPACK-3}}. **DECISION** whether the server answers with an HTTP status before resetting the stream.
- **{{ISSUE:H3-QPACK-11}}** (P2) Exempt a zero-length DATA frame from the `Body_Allowed` rejection, and make one layer the authority on content-forbidding statuses.
  Depends on: nothing. **DECISION** which layer wins on 205. **PROOF** `Flyology.HTTP.HTTP_3_Message_Policy`.
- **{{ISSUE:H3-QPACK-12}}** (P2) Accept Set Dynamic Table Capacity 0 and read Delta Base, refusing only the conditions RFC 9204 actually states.
  Depends on: nothing. **PROOF** `Flyology.HTTP.HTTP_3_Stream_Receive_Policy` and `Flyology.HTTP.QPACK_Field_Section_Policy`.
- **{{ISSUE:H3-QPACK-13}}** (P2) Abandon a malformed message unconditionally, by consuming its bytes or aborting the transport read rather than through the tombstone table.
  Depends on: {{ISSUE:H3-QPACK-10}}. **DECISION** the capacity of the tombstone table and where it lives.
- **{{ISSUE:H3-QPACK-14}}** (P2) Drop the interim and 204 clauses from the `content-length` check, leaving the content-forbidding rule to the message policy.
  Depends on: {{ISSUE:H3-QPACK-11}}. **PROOF** `Flyology.HTTP.HTTP_3_Header_Policy`.
- **{{ISSUE:QUIC-TRANSPORT-6}}** (P2) Record a validated STOP_SENDING, move the send side to Reset Sent, schedule RESET_STREAM, and surface the cancellation upward.
  Depends on: nothing. **DECISION** how the stream identifier and error code reach the layer above. **PROOF** `Flyology.QUIC.Application_Frame_Policy` and `Flyology.QUIC.Receive_Flow_Control_Policy`, if the change reaches them.
- **{{ISSUE:QUIC-TRANSPORT-7}}** (P2) Record a received PATH_CHALLENGE and emit PATH_RESPONSE in the next outgoing packet, and accept a PATH_RESPONSE rather than dropping it.
  Depends on: nothing. **DECISION** how many pending challenges an endpoint remembers. **PROOF** `Flyology.QUIC.Application_Frame_Policy`.
- **{{ISSUE:QUIC-TRANSPORT-8}}** (P2) Pad the server's ack-eliciting Initial to 1,200 bytes, or coalesce it with the first Handshake packet.
  Depends on: {{ISSUE:QUIC-TRANSPORT-1}}.
- **{{ISSUE:QUIC-TRANSPORT-9}}** (P2) Consume the whole ACK frame while retaining the newest ranges, and report that outcome as success rather than a transport error.
  Depends on: nothing. **DECISION** the value and visibility of `Max_Ranges`. **PROOF** `Flyology.QUIC.ACK_Range_Policy`.
- **{{ISSUE:QUIC-TRANSPORT-10}}** (P2) Compare the peer's connection-ID transport parameters with the identifiers on the wire in `Initialize_Application`, closing with 0x08 on a mismatch.
  Depends on: nothing.
- **{{ISSUE:QUIC-TRANSPORT-11}}** (P2) Add the null-backend guard the query functions already use to each packet-driven operation, returning `Invalid_State`.
  Depends on: nothing. **DECISION** a body guard or a precondition on the public operations.
- **{{ISSUE:QUIC-TLS-4}}** (P2) Search the recorded ALPN entries for the configured protocol instead of testing only the first one.
  Depends on: nothing. **DECISION** how many entries `Parse_Result` carries and whose preference order wins. **PROOF** `Flyology.QUIC.TLS_Extension_Policy`.
- **{{ISSUE:QUIC-TLS-5}}** (P2) Map certificate, signature and Finished failures to their TLS alert codes at all three sites, through one shared mapping.
  Depends on: nothing. **DECISION** whether a missing required extension gets its own `Parse_Status` literal. **PROOF** `Flyology.QUIC.TLS_Handshake_Policy` and `Flyology.QUIC.TLS_Extension_Policy`.

## Layer 4 - HTTP client, connection pool and client TLS

The outbound side: the HTTP/1 response parser, the exchange engine, the redirect and
expectation paths, and the connection pool with its leases. No finding in this queue lands
in client TLS itself. No P0; the five P1 items are the response `Content-Length` ceiling
and the `Character'Pos` accumulation behind it ({{ISSUE:H1-CLIENT-1}},
{{ISSUE:H1-CLIENT-7}}), a negative expectation wait that sends the body immediately
({{ISSUE:H1-CLIENT-2}}), a same-origin redirect whose query contains `://`
({{ISSUE:CLIENT-POOL-1}}), and the silent second POST after a late 417
({{ISSUE:CLIENT-POOL-2}}). Ordering inside the layer: {{ISSUE:H1-CLIENT-1}},
{{ISSUE:H1-CLIENT-7}} and {{ISSUE:H1-CLIENT-6}} are one widening of the same arithmetic in
the same private record, so one lane takes all three with {{ISSUE:H1-CLIENT-1}} first;
{{ISSUE:CLIENT-POOL-8}} lands before {{ISSUE:CLIENT-POOL-7}}, which otherwise inherits the
same hole; and {{ISSUE:CLIENT-POOL-5}} is settled by whatever {{ISSUE:CLIENT-POOL-2}} and
{{ISSUE:CLIENT-POOL-4}} do with the proved classifiers.

- **{{ISSUE:H1-CLIENT-1}}** (P1) Widen the HTTP/1 response length arithmetic to `Flyology.HTTP.Body_Size` in `Parse_Natural`, `Content_Length` and the private `Response_Data` fields.
  Depends on: nothing.
- **{{ISSUE:H1-CLIENT-2}}** (P1) Select the remaining exchange budget, or clear the deadline, when `Continue_Wait` is negative, in both branches that arm the wait.
  Depends on: nothing.
- **{{ISSUE:H1-CLIENT-7}}** (P1) Accumulate the digit value rather than `Character'Pos` in `Parse_Natural`, binding it once so the guard and the accumulation agree.
  Depends on: {{ISSUE:H1-CLIENT-1}}.
- **{{ISSUE:CLIENT-POOL-1}}** (P1) Select the absolute-URI redirect branch with the anchored `Has_URI_Scheme` test instead of the unanchored `://` scan.
  Depends on: nothing.
- **{{ISSUE:CLIENT-POOL-2}}** (P1) Track whether any content byte left the exchange, feed it into `Classify_Expectation_Response`, and return a late 417 to the caller.
  Depends on: nothing. **DECISION** how the wrapper observes body-sent, and whether the retry requires a rewindable source. **MODEL FIRST** the client pool lease lifecycle. **PROOF** `Flyology.HTTP.Client_Policy`, if its contract changes.
- **{{ISSUE:H1-CLIENT-3}}** (P2) Evaluate the `close` token first and fall back to the version rule when setting `Reusable`.
  Depends on: nothing.
- **{{ISSUE:H1-CLIENT-4}}** (P2) Allow the terminator's width in the incomplete-head bound, at both copies, so the two checks bound the same quantity.
  Depends on: nothing. **DECISION** where the incomplete-head bound sits relative to `Default_Max_Bytes`.
- **{{ISSUE:H1-CLIENT-5}}** (P2) Consult `Pending_Result` in `Receive_Content_Step`, and abandon the transport once the discarded count passes a bound.
  Depends on: nothing. **DECISION** what that drain bound is and where it is visible.
- **{{ISSUE:H1-CLIENT-6}}** (P2) Widen `Chunk_Size` and `Chunk_Remaining` to `Flyology.HTTP.Body_Size`, so the pending-length comparison is evaluated at 64 bits.
  Depends on: {{ISSUE:H1-CLIENT-1}}, {{ISSUE:H1-CLIENT-7}}.
- **{{ISSUE:CLIENT-POOL-4}}** (P2) Give the engine retry and the wrapper retry one shared budget, and bound the pre-handoff branch explicitly.
  Depends on: nothing. **DECISION** what "retried once" counts, and what the documented bound then means. **MODEL FIRST** the client pool lease lifecycle. **PROOF** `Flyology.HTTP.Client_Policy`, if `Classify_Stale_Retry` becomes the single decision point.
- **{{ISSUE:CLIENT-POOL-5}}** (P2) Restore the four classifiers' callers or delete them, and add a caller invariant for that specification to `scripts/test.sh`.
  Depends on: {{ISSUE:CLIENT-POOL-2}}, {{ISSUE:CLIENT-POOL-4}}. **DECISION** restore the callers, or delete the dead functions and correct `proof/proof-status.md`. **PROOF** `Flyology.HTTP.Client_Policy`. **NO REPRO** dead code, documentation.
- **{{ISSUE:CLIENT-POOL-6}}** (P2) Classify a stopping pool as `Client_Unavailable` on the HTTP/3 path, covering the `Pool.Install` and `Publish_Connecting` routes too.
  Depends on: nothing. **NO REPRO** race not spikeable.
- **{{ISSUE:CLIENT-POOL-7}}** (P2) Retire a non-null `Reply_Data` through `Abandon_Response` and the retention release, each guarded, before `Exchange_Operation.Finalize` frees it.
  Depends on: {{ISSUE:CLIENT-POOL-8}}. **DECISION** whether a new barrier point is added so the fix can be tested. **NO REPRO** no barrier point.
- **{{ISSUE:CLIENT-POOL-8}}** (P2) Wrap the three calls in `Abandon_Response`'s HTTP/2 branch in their own handlers, and retry the lease return in `Response.Finalize`.
  Depends on: nothing. **DECISION** whether a test-only fault-injection seam is added to the HTTP/2 session. **MODEL FIRST** the client pool lease lifecycle. **NO REPRO** needs injection seam.

## Layer 5 - WebSocket and SSE

The two long-lived streaming surfaces: the WebSocket client and the server upgrade path,
and the SSE serialisers on all three HTTP versions with the reconnecting SSE client. No P0;
the five P1 items are a control-frame bound that ends a healthy keepalive session
({{ISSUE:WEBSOCKET-1}}), a `Close` drain that raises an exception its contract omits
({{ISSUE:WEBSOCKET-2}}), a dropped trailing line terminator on HTTP/2 and HTTP/3
({{ISSUE:SSE-1}}), two sink failures that reach the caller as the wrong exception
({{ISSUE:SSE-2}}), and a cancellation token that does not interrupt the reconnect wait
({{ISSUE:SSE-3}}). {{ISSUE:SSE-3}} touches the wait state the existing `formal/sse_client/`
model describes, so its lane runs `./scripts/check-sse-client-formal.sh` and reports whether
that gate is green before changing anything; the model and its trace are extended with the
Ada. {{ISSUE:SSE-1}} touches all three backends at once, so it should not run beside another
SSE change.

- **{{ISSUE:WEBSOCKET-1}}** (P1) Clear `Control_Count` in `Receive` whenever a complete message is returned and whenever the loop is idle with nothing buffered.
  Depends on: nothing.
- **{{ISSUE:WEBSOCKET-2}}** (P1) Give the close drain the bound the last `Receive` used, and name the two reachable exceptions in `Close`'s documentation.
  Depends on: nothing. **DECISION** whether the bound is a `Close` parameter or a value retained on `Client`.
- **{{ISSUE:SSE-1}}** (P1) Append the missing trailing-terminator branch to the HTTP/2 and HTTP/3 data loops, or share one serialiser across the three backends.
  Depends on: nothing.
- **{{ISSUE:SSE-2}}** (P1) Re-raise the identity preserved in `Failure_Cause` for a `Response_Sink_Failed` result, in the engine or in the SSE layer.
  Depends on: nothing.
- **{{ISSUE:SSE-3}}** (P1) Cancel the reconnect wait's `Read_Operation` when the token is requested, so the armed timer child is cancelled.
  Depends on: nothing.
- **{{ISSUE:WEBSOCKET-3}}** (P2) Send the RFC 6455 Close frame before dropping the transport on a detected protocol failure, guarded and written under a deadline.
  Depends on: nothing. **DECISION** what deadline that failure Close is written under.
- **{{ISSUE:WEBSOCKET-4}}** (P2) Skip an empty candidate in `Header_Has_Exact_Token` instead of passing it to `Validate_Token`.
  Depends on: nothing.

## Layer 6 - IRI, lifetime and repository gates

The `flyology_iri` crate and the repository's own integrity gates: the check that no client
unit declares a helper task, and the specification sentences that claim Ada enforces a token
borrow. No P0; the three P1 items are a relative reference that can set the host
({{ISSUE:IRI-4}}), a check that fails open and passes five kinds of violating source
({{ISSUE:LIFETIME-2}}), and two `.ads` sentences that are false as written
({{ISSUE:LIFETIME-3}}). The layer is independent of every other one and can run in parallel
with them, with one exception: {{ISSUE:LIFETIME-2}} changes `scripts/test.sh`, which every
other lane runs as its gate, so it should land between merges rather than beside them.
{{ISSUE:LIFETIME-1}} is the HTTP/3 sibling of a layer 4 finding and follows it.

- **{{ISSUE:IRI-4}}** (P1) Build the resolved reference from components, or emit the `/.` guard, so a dot-reduced path beginning with `//` cannot become an authority.
  Depends on: nothing. **DECISION** whether a URI-mode serialization may carry the `/.` guard.
- **{{ISSUE:LIFETIME-2}}** (P1) Drop the undeclared `rg` dependency for `grep -REi`, widen the file set to the client closure, and reject `Task_Scopes` instantiations.
  Depends on: nothing. **DECISION** whether a declaration split across lines is covered or declared out of scope.
- **{{ISSUE:LIFETIME-3}}** (P1) Correct the two sentences, check the token in `Configure`, or stop returning `'Unchecked_Access`; the body proposes no single direction.
  Depends on: nothing. **DECISION** which of the three, since each promises something different in the specification.
- **{{ISSUE:IRI-1}}** (P2) Reject code points above 16#10FFFF# and overlong forms in `To_ASCII`, or substitute U+FFFD as the WHATWG algorithm says.
  Depends on: nothing.
- **{{ISSUE:IRI-2}}** (P2) Fail an IPv4-in-IPv6 part that has a leading zero or a fourth digit, as the WHATWG IPv6 parser does.
  Depends on: nothing.
- **{{ISSUE:IRI-3}}** (P2) Reject a label beginning with a combining mark, and settle NFC separately; document whichever gap remains.
  Depends on: nothing. **DECISION** whether NFC is implemented, restricted away, or documented as absent.
- **{{ISSUE:LIFETIME-1}}** (P2) Give the HTTP/3 branch of `Abandon_Response` the guarded `Release_Pump`, `Cancel_Stream` and `Release_Stream` sequence.
  Depends on: {{ISSUE:CLIENT-POOL-8}}. **NO REPRO** no observable difference.

## Explicitly out of scope

Issue #11, "flyology_iri: Slice copies the whole reference on every component access,
making Resolve allocation-heavy", is the repository's only open issue and carries the
`enhancement` label. It reports that the private `Slice` helper materializes the whole
serialized reference for every component access, so each public component getter is
O(reference length) and `Resolve` pays that cost repeatedly; the author states it is not
benchmarked. It is a performance report, not a correctness finding, and nothing in the
queue above fixes it. {{ISSUE:IRI-4}} changes `Resolve` and one of its options removes the
recomposition round trip entirely, so the lane that takes it should read #11 first and
still leave the performance work out of its branch.

There are no open pull requests on the repository.
