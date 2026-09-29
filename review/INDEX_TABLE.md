| ID | Severity | Title | Location | Repro |
| --- | --- | --- | --- | --- |
| H2-1 | P0 | Client fails the connection when a server sends `SETTINGS_ENABLE_PUSH = 0` | `src/flyology-http-http_2_settings.adb:45-51` | `flyology-http-http_2_settings-repro_h2_1` |
| H2-2 | P0 | Server enforces its reduced 16 KiB stream window before the peer can have processed the SETTINGS that announced it | `src/flyology-http-server-http_2.adb:100-101` | `repro_h2_2` |
| H3-QPACK-1 | P0 | Server returns no per-stream receive credit while a request body is arriving | `src/flyology-http-server-http_3.adb:1637-1671` | `repro_h3_qpack_1` |
| H3-QPACK-2 | P0 | Whole-frame buffering against a 16 KiB reassembly window | `src/flyology-http-http_3_frame_policy.adb:72-81` | `flyology-http-http_3_stream_receive_policy-repro_h3_qpack_2` |
| QUIC-TRANSPORT-1 | P0 | No anti-amplification limit before address validation | `flyology-quic-connection_driver.adb:956-995` | `flyology-quic-connection_driver-repro_quic_transport_1` |
| CLIENT-POOL-1 | P1 | Same-origin relative redirect whose query contains `://` raises `Redirect_Error` | `src/flyology-http-client.adb:6301-6315` | `repro_client_pool_1` |
| CLIENT-POOL-2 | P1 | Synchronous 417 fallback retries after body transmission with a consumed, un-rewound source | `src/flyology-http-client.adb:6636-6647` | `repro_client_pool_2` |
| H1-CLIENT-1 | P1 | HTTP/1 response `Content-Length` of 2^31 or more is rejected as malformed | `src/flyology-http-client-http_1_internals.adb:151-168` | `flyology-http-http_3_header_policy-repro_h1_client_1` |
| H1-CLIENT-2 | P1 | A negative `Set_Expect_Continue` wait sends the body immediately | `src/flyology-http-client.adb:3767-3792` | `repro_h1_client_2` |
| H1-CLIENT-7 | P1 | a `Content-Length` of 2 147 483 600 .. 2 147 483 647 raises `Constraint_Error` out of the HTTP/1 response parser | see the area section | `repro_h1_client_7` |
| H1-SERVER-5 | P1 | Peer-chosen request shapes surface as `Program_Error`, escaping the documented `Protocol_Error` rejection channel | `src/flyology-http-server.adb:3933-3937` | `repro_h1_server_5` |
| H2-3 | P1 | Client discards a complete response when the server follows END_STREAM with `RST_STREAM(NO_ERROR)` | `src/flyology-http-http_2_client_connection.adb:1370-1387` | `repro_h2_3` |
| H2-4 | P1 | Client `Cancel_Stream` during a fragmented request field section pins the pump, then a non-CONTINUATION frame follows an unterminated HEADERS | `src/flyology-http-http_2_client_connection.adb:1625-1649` | `repro_h2_4` |
| H2-5 | P1 | A request body exceeding a route limit mid-stream can never receive the 413 over HTTP/2; the stream is reset with INTERNAL_ERROR | `src/flyology-http-server-http_2.adb:644-651` | `repro_h2_5` |
| H2-6 | P1 | HPACK encoder never emits the dynamic-table size update required after a peer lowers `SETTINGS_HEADER_TABLE_SIZE` | `src/flyology-http-http_2_settings.adb:43-44` | `flyology-http-http_2_requests-repro_h2_6` |
| H3-QPACK-3 | P1 | Receive-side field-section limits close the connection and are never advertised | `src/flyology-http-qpack_field_section_policy.adb:127-136` | `repro_h3_qpack_3` |
| H3-QPACK-4 | P1 | Server leaks one send slot per cancelled response | `src/flyology-http-http_3_connection.adb:624-677` | `repro_h3_qpack_4` |
| H3-QPACK-5 | P1 | Server never sends GOAWAY or CONNECTION_CLOSE at end of life | `src/flyology-http-server-http_3.adb:1897-1927` | `repro_h3_qpack_5` |
| H3-QPACK-6 | P1 | Exceptions other than Timeout_Error abandon the connection without a close | `src/flyology-http-server-http_3.adb:1901-1918` | `repro_h3_qpack_6` |
| H3-QPACK-7 | P1 | Send-side field sections are capped at 1,109 encoded bytes | `src/flyology-http-qpack_field_section_policy.ads:21` | `flyology-http-qpack_field_section_policy-repro_h3_qpack_7` |
| H3-QPACK-8 | P1 | Client raises MAX_STREAM_DATA for every stream from transport-level consumption | `src/flyology-http-client.adb:2517-2552` | `flyology-http-http_3_client_connection-repro_h3_qpack_8` |
| H3-QPACK-9 | P1 | Peer-reset request streams never refill MAX_STREAMS credit | `src/flyology-http-server-http_3.adb:1637-1663` | `repro_h3_qpack_9` |
| IRI-4 | P1 | `Resolve` recomposes a `//`-prefixed path without authority into an authority, and rewrites WHATWG opaque paths under a web base | `flyology_iri/src/flyology_iri.adb:1462-1469` | `repro_iri_4` |
| LIFETIME-2 | P1 | The "no helper task in client units" invariant check fails open and is evadable | `scripts/test.sh:75-84` | `repro_lifetime_2.sh` |
| LIFETIME-3 | P1 | Two `.ads` contracts claim Ada-enforced lifetime with no `compile_fail` case pinning them; `Request_Tasks` cancellation inheritance is untested | `src/flyology-http-server-request_tasks.ads:25-31` | `repro_lifetime_3, with controls repro_lifetime_3b/3c/3d` |
| QUIC-TLS-3 | P1 | Handshake, master, exporter and traffic secrets are never wiped after a successful handshake or on finalization | `flyology_quic/src/flyology-quic-tls_session.adb:790-791` | `flyology-quic-tls_session-repro_quic_tls_3` |
| QUIC-TRANSPORT-2 | P1 | The 64-entry ledger fails large transfers and refuses probes | `flyology-quic-application_space.adb:417-436` | `flyology-quic-connection_driver-repro_quic_transport_2` |
| QUIC-TRANSPORT-3 | P1 | Initial keys are never discarded; a forged Initial ends an established connection | `flyology-quic-connection_driver.adb:1382-1409` | `flyology-quic-connection_driver-repro_quic_transport_3` |
| QUIC-TRANSPORT-4 | P1 | A client fails on any post-handshake CRYPTO except one complete ticket at offset 0 | `flyology-quic-application_space.adb:1307-1349` | `flyology-quic-application_space-repro_quic_transport_4` |
| QUIC-TRANSPORT-5 | P1 | `Transport_Settings` are advertised unclamped against fixed reassembly bounds | `flyology-quic-connections.adb:176-201` | `repro_quic_transport_5` |
| ROUTING-MW-1 | P1 | A malformed-path 400 for more than 64 segments bypasses the global middleware chain and automatic admission | `src/flyology-http-server-routing.adb:1895` | `repro_routing_mw_1` |
| ROUTING-MW-2 | P1 | `Applications.Respond` marks the exchange `Failed` before any byte is written, so every Exchange-based 500 recovery path closes or resets instead of answering | `src/flyology-http-server-applications.adb:465-468` | `repro_routing_mw_2` |
| SSE-1 | P1 | HTTP/2 and HTTP/3 SSE serialisers drop a trailing line terminator from event data that the HTTP/1.1 serialiser preserves | `src/flyology-http-server-http_2.adb:1966-1996` | `repro_sse_1` |
| SSE-2 | P1 | `Event_Too_Large` and `Reconnect_Delay_Too_Large` raised while the exchange streams into the sink are re-raised as `Invalid_Event_Stream` | `src/flyology-http-client.adb:3884-3891` | `repro_sse_2` |
| SSE-3 | P1 | A cancellation token does not interrupt the reconnect wait of the blocking `Read`, contrary to the `.ads` contract | `src/flyology-http-client-sse.adb:648-661` | `repro_sse_3` |
| WEBSOCKET-1 | P1 | Client `Receive` fails a healthy session after 32 control frames in one call | `src/flyology-http-websocket_client.adb:32` | `repro_websocket_1` |
| WEBSOCKET-2 | P1 | Client `Close` drains the peer close under the 1 MiB default bound, not the application's | `src/flyology-http-websocket_client.adb:1372-1374` | `repro_websocket_2` |
| CLIENT-POOL-4 | P2 | Synchronous safe-method exchanges can replay twice (engine retry plus wrapper retry) | `src/flyology-http-client.adb:925-957` | `repro_client_pool_4` |
| CLIENT-POOL-5 | P2 | Four proved `Client_Policy` classifiers have no production caller; `proof-status.md` still says they are consumed | `src/flyology-http-client_policy.ads:15-40,52-77,86-127,171-188`; | none (see entry) |
| CLIENT-POOL-6 | P2 | Shutdown racing HTTP/3 establishment reports `Transport_Failed`/`Device_Error` instead of `Client_Unavailable`/`Client_Closed` | `src/flyology-http-client.adb:4963-4969` | none (see entry) |
| CLIENT-POOL-7 | P2 | `Exchange_Operation.Finalize` frees a response-head `Reply_Data` without returning its lease or lifetime retention | `src/flyology-http-client.adb:1906-1940` | none (see entry) |
| CLIENT-POOL-8 | P2 | `Response.Finalize` exception path frees the lease record without returning the pool slot | `src/flyology-http-client.adb:7369-7404` | none (see entry) |
| H1-CLIENT-3 | P2 | An HTTP/1.0 response carrying both `close` and `keep-alive` is pooled | `src/flyology-http-client-http_1_internals.adb:410-418` | `repro_h1_client_3` |
| H1-CLIENT-4 | P2 | Heads of 16383-16384 bytes are accepted by the oracle but rejected on the live path | `src/flyology-http-client-http_1_internals.adb:363-381` | `repro_h1_client_4` |
| H1-CLIENT-5 | P2 | A composable buffer exchange drains an over-capacity body with no byte bound | `src/flyology-http-client.adb:3864-3908` | `repro_h1_client_5` |
| H1-CLIENT-6 | P2 | `Validate_Response` overflows on chunk sizes `7FFFFFFE`/`7FFFFFFF` (test oracle only) | `src/flyology-http-client-http_1_internals.adb:585-587` | `repro_h1_client_6` |
| H1-SERVER-1 | P2 | A stray CRLF before a request-line is rejected as malformed, and at EOF becomes a spurious 400 | `src/flyology-http-server.adb:1141-1162` | `repro_h1_server_1` |
| H1-SERVER-2 | P2 | Chunk-extension BWS is rejected although the chunk-ext grammar admits it | `src/flyology-http-server.adb:874-895` | `repro_h1_server_2` |
| H1-SERVER-3 | P2 | Oversized head, unknown transfer coding, CONNECT, and unsupported versions all collapse to 400 | `src/flyology-http-server.adb:1060` | `repro_h1_server_3` |
| H1-SERVER-4 | P2 | Absolute-form target with a differing Host is refused instead of Host being ignored | `src/flyology-http-server.adb:843-848` | `repro_h1_server_4` |
| H2-7 | P2 | `SETTINGS_INITIAL_WINDOW_SIZE` above 2^31-1 is reported as PROTOCOL_ERROR instead of FLOW_CONTROL_ERROR | `src/flyology-http-server-http_2.adb:2422-2427` | `repro_h2_7` |
| H2-8 | P2 | Server answers `WINDOW_UPDATE(0)` on an idle stream with RST_STREAM on that idle stream and advances `Last_Client_Stream` | `src/flyology-http-server-http_2.adb:1217-1221` | `repro_h2_8` |
| H2-9 | P2 | Server sends RST_STREAM(STREAM_CLOSED) for every DATA frame on a closed stream, including streams it has already reset | `src/flyology-http-server-http_2.adb:618-631` | `repro_h2_9` |
| H2-10 | P2 | Server never resets a stream whose response completed while the request half is still open; its buffered input pins the connection window | `src/flyology-http-server-http_2.adb:419-428` | `repro_h2_10` |
| H2-11 | P2 | Client ignores RST_STREAM and WINDOW_UPDATE on idle streams and answers post-cancel in-flight frames with RST_STREAM(PROTOCOL_ERROR) | `src/flyology-http-http_2_client_connection.adb:1374-1378` | `repro_h2_11` |
| H3-QPACK-10 | P2 | Server treats malformed requests and empty request streams as connection errors | `src/flyology-http-http_3_connection.adb:426-440` | `repro_h3_qpack_10` |
| H3-QPACK-11 | P2 | Empty DATA frame on a HEAD, 204, 205 or 304 response is rejected | `src/flyology-http-http_3_message_policy.adb:113-117` | `flyology-http-http_3_message_policy-repro_h3_qpack_11` |
| H3-QPACK-12 | P2 | Legal QPACK inputs rejected | `src/flyology-http-http_3_stream_receive_policy.adb:169-174` | `flyology-http-http_3_stream_receive_policy-repro_h3_qpack_12` |
| H3-QPACK-13 | P2 | Stale Stream_Reset re-emission for malformed responses on stream IDs above 4092 | `src/flyology-http-http_3_connection.adb:426-440` | `repro_h3_qpack_13` |
| H3-QPACK-14 | P2 | 204 or 1xx with Content-Length is treated as malformed | `src/flyology-http-http_3_header_policy.adb:414-418` | `flyology-http-http_3_header_policy-repro_h3_qpack_14` |
| IRI-1 | P2 | Overlong and out-of-range UTF-8 in a percent-decoded special host decodes to a different host instead of failing | `flyology_iri/src/flyology_iri-web.adb:597` | `repro_iri_1` |
| IRI-2 | P2 | IPv4-in-IPv6 tail accepts leading zeros the WHATWG IPv6 parser rejects | `flyology_iri/src/flyology_iri-web.adb:477-518` | `repro_iri_2` |
| IRI-3 | P2 | IDNA applies no NFC normalization and no leading-combining-mark check, and the disclosure does not name either | `flyology_iri/src/flyology_iri-idna.adb:174-211` | `repro_iri_3` |
| LIFETIME-1 | P2 | Finalizing an unread HTTP/3 `Response` never cancels or releases its stream, unlike HTTP/2 and unlike the composable path | `src/flyology-http-client.adb:2151-2170` | none (see entry) |
| QUIC-TLS-4 | P2 | Server matches only the first ALPN entry of the ClientHello instead of selecting from the list | `flyology_quic/src/flyology-quic-tls_extension_policy.adb:220-224` | `flyology-quic-tls_session-repro_quic_tls_4` |
| QUIC-TLS-5 | P2 | TLS failures close with `internal_error` (0x150) and missing ALPN with `missing_extension` (0x16D) instead of the alerts the RFCs require | `flyology_quic/src/flyology-quic-connection_driver.adb:945-951` | `flyology-quic-connection_driver-repro_quic_tls_5` |
| QUIC-TRANSPORT-6 | P2 | STOP_SENDING is validated and dropped | `flyology-quic-application_space.adb:1392-1402` | `flyology-quic-application_space-repro_quic_transport_6` |
| QUIC-TRANSPORT-7 | P2 | PATH_CHALLENGE is parsed and ignored | `flyology-quic-application_frame_policy.adb:386-395` | `flyology-quic-application_space-repro_quic_transport_7` |
| QUIC-TRANSPORT-8 | P2 | The server's ack-eliciting Initial datagram is not expanded to 1,200 bytes | `flyology-quic-initial_space.adb:141-142` | `repro_quic_transport_8` |
| QUIC-TRANSPORT-9 | P2 | An ACK frame with 64 or more ranges closes the connection | `flyology-quic-ack_range_policy.adb:64-66` | `flyology-quic-application_space-repro_quic_transport_9` |
| QUIC-TRANSPORT-10 | P2 | Connection-ID transport parameters are never compared with the wire CIDs | the only uses of `Original_Destination_Connection_ID` and | `flyology-quic-connection_driver-repro_quic_transport_10` |
| QUIC-TRANSPORT-11 | P2 | packet-driven operations dereference an uninitialized connection | see the area section | `repro_quic_transport_11` |
| ROUTING-MW-3 | P2 | HTTP/2 `:path` beginning with `http://` or `https://` is routed as an absolute-form target; HTTP/3 and HTTP/1 reject or validate it | `src/flyology-http-server-routing.adb:283-314` | `repro_routing_mw_3` |
| ROUTING-MW-4 | P2 | Metrics series are keyed by the client-controlled request method with no eviction, so distinct method tokens pin the bounded series table | `src/flyology-http-server-metrics.adb:47-83` | `repro_routing_mw_4` |
| ROUTING-MW-5 | P2 | CORS middleware omits `Vary: Origin` on responses whose CORS headers depend on `Origin` but where none were added | `src/flyology-http-server-middleware_cors.adb:40-43` | `repro_routing_mw_5` |
| WEBSOCKET-3 | P2 | Client fails the connection with no Close frame on every protocol failure | `src/flyology-http-websocket_client.adb:1310-1321` | `repro_websocket_3` |
| WEBSOCKET-4 | P2 | Server refuses an upgrade whose `Sec-WebSocket-Protocol` list contains an empty element | `src/flyology-http-server.adb:3961-3973` | `repro_websocket_4` |
