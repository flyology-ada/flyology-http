# Filed issues

Repository: https://github.com/flyology-ada/flyology-http. Filed from review commit f078732.

| Finding | Severity | Issue | Title |
| --- | --- | --- | --- |
| H1-SERVER-5 | P1 | [#57](https://github.com/flyology-ada/flyology-http/issues/57) | HEAD or HTTP/1.0 on an SSE route drops the connection with no response, via an escaping Program_Error |
| H1-SERVER-1 | P2 | [#58](https://github.com/flyology-ada/flyology-http/issues/58) | A stray CRLF before a request-line is rejected as malformed, and at EOF becomes a spurious 400 |
| H1-SERVER-2 | P2 | [#59](https://github.com/flyology-ada/flyology-http/issues/59) | Chunk-extension bad whitespace is rejected although the chunk-ext grammar admits it in all four positions |
| H1-SERVER-3 | P2 | [#60](https://github.com/flyology-ada/flyology-http/issues/60) | A request with an unknown transfer coding is answered 400 where RFC 9112 asks for 501 |
| H1-SERVER-4 | P2 | [#61](https://github.com/flyology-ada/flyology-http/issues/61) | Absolute-form request-target with a differing Host is refused instead of the Host field being ignored |
| ROUTING-MW-1 | P1 | [#62](https://github.com/flyology-ada/flyology-http/issues/62) | The 400 for a path with more than 64 segments bypasses the middleware chain and automatic admission |
| ROUTING-MW-2 | P1 | [#63](https://github.com/flyology-ada/flyology-http/issues/63) | A rejected Respond marks the exchange Failed, so the errors middleware closes instead of writing its 500 |
| ROUTING-MW-3 | P2 | [#64](https://github.com/flyology-ada/flyology-http/issues/64) | HTTP/2 :path beginning with http:// is routed as an absolute-form target, unlike HTTP/3 and HTTP/1 |
| ROUTING-MW-4 | P2 | [#65](https://github.com/flyology-ada/flyology-http/issues/65) | The metrics series key includes the client-chosen request method and nothing evicts a filled table |
| ROUTING-MW-5 | P2 | [#66](https://github.com/flyology-ada/flyology-http/issues/66) | CORS middleware omits Vary: Origin on responses whose header set depends on Origin |
| H2-1 | P0 | [#67](https://github.com/flyology-ada/flyology-http/issues/67) | Client fails the connection when a server sends `SETTINGS_ENABLE_PUSH = 0` |
| H2-2 | P0 | [#68](https://github.com/flyology-ada/flyology-http/issues/68) | Server enforces its reduced 16 KiB stream window before the peer can have processed the SETTINGS that announced it |
| H2-3 | P1 | [#69](https://github.com/flyology-ada/flyology-http/issues/69) | Client discards the buffered response body when the server follows END_STREAM with RST_STREAM(NO_ERROR) |
| H2-4 | P1 | [#70](https://github.com/flyology-ada/flyology-http/issues/70) | Cancelling a client stream mid field section abandons the CONTINUATION and freezes the connection pump |
| H2-5 | P1 | [#71](https://github.com/flyology-ada/flyology-http/issues/71) | A route body limit crossed mid-stream can never answer 413 over HTTP/2; the stream is reset with INTERNAL_ERROR |
| H2-6 | P1 | [#72](https://github.com/flyology-ada/flyology-http/issues/72) | HPACK encoder never emits the dynamic table size update required after a peer lowers SETTINGS_HEADER_TABLE_SIZE |
| H2-7 | P2 | [#73](https://github.com/flyology-ada/flyology-http/issues/73) | `SETTINGS_INITIAL_WINDOW_SIZE` above 2^31-1 is answered with PROTOCOL_ERROR instead of FLOW_CONTROL_ERROR |
| H2-8 | P2 | [#74](https://github.com/flyology-ada/flyology-http/issues/74) | Zero-increment WINDOW_UPDATE on an idle stream draws RST_STREAM and advances the server's last client stream |
| H2-9 | P2 | [#75](https://github.com/flyology-ada/flyology-http/issues/75) | Server sends RST_STREAM(STREAM_CLOSED) for every DATA frame on a stream it has already reset |
| H2-10 | P2 | [#76](https://github.com/flyology-ada/flyology-http/issues/76) | Server never resets a stream answered early while its request half is open, pinning the connection receive window |
| H2-11 | P2 | [#77](https://github.com/flyology-ada/flyology-http/issues/77) | Client ignores RST_STREAM and WINDOW_UPDATE on idle streams instead of failing the connection |
| H3-QPACK-1 | P0 | [#78](https://github.com/flyology-ada/flyology-http/issues/78) | HTTP/3 server sends no MAX_STREAM_DATA while a request body arrives, so an upload over 15 KiB never completes |
| H3-QPACK-2 | P0 | [#79](https://github.com/flyology-ada/flyology-http/issues/79) | An HTTP/3 frame larger than the 16,384-byte QUIC reassembly window can never be consumed |
| H3-QPACK-3 | P1 | [#80](https://github.com/flyology-ada/flyology-http/issues/80) | A well-formed 33-field request section closes the whole QUIC connection with QPACK_DECOMPRESSION_FAILED |
| H3-QPACK-4 | P1 | [#81](https://github.com/flyology-ada/flyology-http/issues/81) | Cancelling an HTTP/3 response leaks its send slot, so the 33rd cancellation silences the connection |
| H3-QPACK-5 | P1 | [#82](https://github.com/flyology-ada/flyology-http/issues/82) | HTTP/3 server abandons a connection at its request limit without sending GOAWAY or CONNECTION_CLOSE |
| H3-QPACK-6 | P1 | [#83](https://github.com/flyology-ada/flyology-http/issues/83) | Resource_Exhausted on the ninth concurrent request abandons the QUIC connection with no close frame |
| H3-QPACK-7 | P1 | [#84](https://github.com/flyology-ada/flyology-http/issues/84) | QPACK Encode refuses field sections over 1,109 bytes, so the documented 16 KiB field value cannot be sent |
| H3-QPACK-8 | P1 | [#85](https://github.com/flyology-ada/flyology-http/issues/85) | HTTP/3 client credit raises every stream's limit, so an unread sibling response fails instead of blocking |
| H3-QPACK-9 | P1 | [#86](https://github.com/flyology-ada/flyology-http/issues/86) | Peer-reset request streams never refill MAX_STREAMS, so 29 cancelled requests exhaust an HTTP/3 connection |
| H3-QPACK-10 | P2 | [#87](https://github.com/flyology-ada/flyology-http/issues/87) | A malformed HTTP/3 request closes the whole QUIC connection instead of resetting the one request stream |
| H3-QPACK-11 | P2 | [#88](https://github.com/flyology-ada/flyology-http/issues/88) | A zero-length DATA frame on a HEAD, 204 or 304 response is rejected as a malformed message |
| H3-QPACK-12 | P2 | [#89](https://github.com/flyology-ada/flyology-http/issues/89) | Set Dynamic Table Capacity 0 and a nonzero Delta Base are rejected although RFC 9204 permits both |
| H3-QPACK-13 | P2 | [#90](https://github.com/flyology-ada/flyology-http/issues/90) | A malformed HTTP/3 response on a stream identifier above 4092 is reported once per poll without end |
| H3-QPACK-14 | P2 | [#91](https://github.com/flyology-ada/flyology-http/issues/91) | A 204 or 1xx response carrying content-length is treated as malformed by the HTTP/3 recipient |
| QUIC-TRANSPORT-1 | P0 | [#92](https://github.com/flyology-ada/flyology-http/issues/92) | A QUIC server applies no anti-amplification limit and accepts undersized client Initial packets |
| QUIC-TRANSPORT-2 | P1 | [#93](https://github.com/flyology-ada/flyology-http/issues/93) | A large transfer fails the connection once 64 packets are unacknowledged, instead of applying backpressure |
| QUIC-TRANSPORT-3 | P1 | [#94](https://github.com/flyology-ada/flyology-http/issues/94) | Initial keys are never discarded, so a forged Initial packet closes an established connection in both roles |
| QUIC-TRANSPORT-4 | P1 | [#95](https://github.com/flyology-ada/flyology-http/issues/95) | QUIC client closes a live connection on post-handshake CRYPTO that is not one whole NewSessionTicket at offset 0 |
| QUIC-TRANSPORT-5 | P1 | [#96](https://github.com/flyology-ada/flyology-http/issues/96) | A server that raises Max_Stream_Data_Bidi_Remote advertises credit it cannot honour and closes a compliant peer |
| QUIC-TRANSPORT-6 | P2 | [#97](https://github.com/flyology-ada/flyology-http/issues/97) | STOP_SENDING is validated and dropped, so no RESET_STREAM is sent and no layer sees the cancellation |
| QUIC-TRANSPORT-7 | P2 | [#98](https://github.com/flyology-ada/flyology-http/issues/98) | PATH_CHALLENGE is parsed and ignored, so no PATH_RESPONSE is ever sent |
| QUIC-TRANSPORT-8 | P2 | [#99](https://github.com/flyology-ada/flyology-http/issues/99) | The server's ack-eliciting Initial datagram is not expanded to 1200 bytes |
| QUIC-TRANSPORT-9 | P2 | [#100](https://github.com/flyology-ada/flyology-http/issues/100) | An ACK frame with 64 or more ACK ranges is answered with CONNECTION_CLOSE PROTOCOL_VIOLATION |
| QUIC-TRANSPORT-10 | P2 | [#101](https://github.com/flyology-ada/flyology-http/issues/101) | The connection-ID transport parameters are decoded but never compared with the connection IDs on the wire |
| QUIC-TRANSPORT-11 | P2 | [#102](https://github.com/flyology-ada/flyology-http/issues/102) | Packet-driven Connections operations raise Constraint_Error instead of returning Invalid_State |
| QUIC-TLS-3 | P1 | [#103](https://github.com/flyology-ada/flyology-http/issues/103) | Handshake, master, exporter and traffic secrets survive a successful QUIC handshake and the release of the connection |
| QUIC-TLS-4 | P2 | [#104](https://github.com/flyology-ada/flyology-http/issues/104) | QUIC server matches only the first ALPN entry of the ClientHello instead of selecting from the list |
| QUIC-TLS-5 | P2 | [#105](https://github.com/flyology-ada/flyology-http/issues/105) | TLS certificate, signature and Finished failures close the QUIC connection with internal_error instead of the required alerts |
| H1-CLIENT-1 | P1 | [#106](https://github.com/flyology-ada/flyology-http/issues/106) | HTTP/1 client rejects every response Content-Length above 2147483599 as an overflowing decimal value |
| H1-CLIENT-2 | P1 | [#107](https://github.com/flyology-ada/flyology-http/issues/107) | A negative Set_Expect_Continue wait sends the request body immediately instead of waiting to the deadline |
| H1-CLIENT-7 | P1 | [#108](https://github.com/flyology-ada/flyology-http/issues/108) | Parse_Natural accumulates Character'Pos, so 48 Content-Length values raise Constraint_Error |
| H1-CLIENT-3 | P2 | [#109](https://github.com/flyology-ada/flyology-http/issues/109) | An HTTP/1.0 response carrying both keep-alive and close is left in the pool as reusable |
| H1-CLIENT-4 | P2 | [#110](https://github.com/flyology-ada/flyology-http/issues/110) | Response heads of 16383 and 16384 bytes pass the parser oracle and fail on the live transport |
| H1-CLIENT-5 | P2 | [#111](https://github.com/flyology-ada/flyology-http/issues/111) | A composable buffer exchange drains an over-capacity response body with no byte bound |
| H1-CLIENT-6 | P2 | [#112](https://github.com/flyology-ada/flyology-http/issues/112) | Validate_Response raises Constraint_Error for chunk sizes 7FFFFFFE and 7FFFFFFF |
| CLIENT-POOL-1 | P1 | [#113](https://github.com/flyology-ada/flyology-http/issues/113) | Same-origin relative redirect whose query contains `://` raises `Redirect_Error` |
| CLIENT-POOL-2 | P1 | [#114](https://github.com/flyology-ada/flyology-http/issues/114) | Synchronous 417 fallback retries after body transmission with a consumed, un-rewound source |
| CLIENT-POOL-4 | P2 | [#115](https://github.com/flyology-ada/flyology-http/issues/115) | Synchronous safe-method exchanges can replay twice, one engine retry plus one wrapper retry |
| CLIENT-POOL-5 | P2 | [#116](https://github.com/flyology-ada/flyology-http/issues/116) | Four proved `Client_Policy` classifiers have no caller under `src/`, and `proof-status.md` still says they are consumed |
| CLIENT-POOL-6 | P2 | [#117](https://github.com/flyology-ada/flyology-http/issues/117) | Shutdown racing HTTP/3 establishment reports `Transport_Failed` instead of `Client_Unavailable` |
| CLIENT-POOL-7 | P2 | [#118](https://github.com/flyology-ada/flyology-http/issues/118) | `Exchange_Operation.Finalize` frees a response-head `Reply_Data` without returning its lease or lifetime retention |
| CLIENT-POOL-8 | P2 | [#119](https://github.com/flyology-ada/flyology-http/issues/119) | `Response.Finalize` frees a lease record without returning the pool slot when `Abandon_Response` raises |
| WEBSOCKET-1 | P1 | [#120](https://github.com/flyology-ada/flyology-http/issues/120) | The client control-frame bound is scoped to one Receive call, so keepalive pings end a healthy session |
| WEBSOCKET-2 | P1 | [#121](https://github.com/flyology-ada/flyology-http/issues/121) | Close drains the peer close under the default 1 MiB bound and raises an exception its contract omits |
| WEBSOCKET-3 | P2 | [#122](https://github.com/flyology-ada/flyology-http/issues/122) | The client closes the TCP connection with no Close frame on every protocol failure it detects |
| WEBSOCKET-4 | P2 | [#123](https://github.com/flyology-ada/flyology-http/issues/123) | Accept_WebSocket refuses an upgrade whose Sec-WebSocket-Protocol list has a leading or interior empty element |
| SSE-1 | P1 | [#124](https://github.com/flyology-ada/flyology-http/issues/124) | HTTP/2 and HTTP/3 SSE serialisers drop a trailing line terminator that the HTTP/1.1 serialiser preserves |
| SSE-2 | P1 | [#125](https://github.com/flyology-ada/flyology-http/issues/125) | Event_Too_Large and Reconnect_Delay_Too_Large raised while the body streams surface as Invalid_Event_Stream |
| SSE-3 | P1 | [#126](https://github.com/flyology-ada/flyology-http/issues/126) | A cancellation token does not interrupt the reconnect wait of the blocking SSE Read |
| IRI-4 | P1 | [#127](https://github.com/flyology-ada/flyology-http/issues/127) | Resolve turns a path beginning with two slashes into an authority, so a relative reference can set the host |
| IRI-1 | P2 | [#128](https://github.com/flyology-ada/flyology-http/issues/128) | Overlong and out-of-range UTF-8 in a percent-decoded host decodes to a different host instead of failing |
| IRI-2 | P2 | [#129](https://github.com/flyology-ada/flyology-http/issues/129) | Web URL IPv6 parsing accepts leading zeros in the IPv4-in-IPv6 tail that the WHATWG parser rejects |
| IRI-3 | P2 | [#130](https://github.com/flyology-ada/flyology-http/issues/130) | IDNA host conversion applies no NFC normalization and no leading-combining-mark check |
| LIFETIME-2 | P1 | [#131](https://github.com/flyology-ada/flyology-http/issues/131) | The "no helper task in client units" check fails open and passes five kinds of violating source |
| LIFETIME-3 | P1 | [#132](https://github.com/flyology-ada/flyology-http/issues/132) | `Request_Tasks` and `Applications` claim Ada enforces a token borrow that `'Unchecked_Access` suppresses |
| LIFETIME-1 | P2 | [#133](https://github.com/flyology-ada/flyology-http/issues/133) | Finalizing an unread HTTP/3 `Response` never releases its stream, so its transport is drained rather than closed |
