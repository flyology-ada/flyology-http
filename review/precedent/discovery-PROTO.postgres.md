# PROTO discovery report: framing, encoding, decoding

Scope: `src/flyology-postgres-protocol.ads/.adb`, `src/flyology-postgres-wire.ads/.adb`,
`src/flyology-postgres-framing.ads/.adb`; consumers skimmed in
`src/flyology-postgres-client.adb`, `src/flyology-postgres-server_sessions.adb`,
`src/flyology-postgres-server.adb`, the three transport bodies, and the
`Flyology.Bytes` dependency. Reference: PostgreSQL protocol 3.x message formats
and `postmaster.c`/`libpq` behaviour. Read-only review; nothing was built or run.

Severity rubric (as given): P0 memory/aliasing, security, hang, or interop-breaking
protocol violation; P1 wrong result or unexpected exception on valid input via a
reachable path, or a documented contract violated; P2 edge-case incorrectness,
wrong diagnostics, or contract drift needing unusual input.

Summary: no P0. One P1 (documented single-deadline contract of `Framing.Read_Message`
/ `Read_Initial` is not implemented). Six P2 items, mostly contract drift between
`.ads` documentation and behaviour, plus two spec deviations in startup-packet
decoding. All wire encoders and strict decoders were checked field-by-field
against the protocol and found correct in shape, signedness, count widths, NUL
handling, and trailing-data strictness.

---

### PROTO-1: `Framing.Read_Message`/`Read_Initial` re-arm `Timeout` for every transport read instead of one deadline per message
- Location: src/flyology-postgres-framing.adb:62-81 (also :48-60 for `Read_Initial`, :12-22, :24-46); contract at src/flyology-postgres-framing.ads:10-19
- Severity: P1
- Confidence: high (mechanism); medium (real-world impact)
- Evidence:
  - Contract, framing.ads:15-17:
    ```
    15   --  Read one typed message under a single deadline.
    17   --  @param Timeout Maximum time allowed for the whole message.
    ```
  - Body, framing.adb:70-80, issues three independent `Receive_Exactly` calls, each with the full `Timeout`:
    ```
    70      Channel.Receive_Exactly (Tag, Timeout, On_Wait);
    71      Length := Read_Length (Channel, Timeout, On_Wait);        -- :20 Receive_Exactly (Header, Timeout, On_Wait)
    76      return Protocol.Make_Message
    78         Read_Contents (Channel, ..., Timeout, On_Wait));         -- :34 Receive_Exactly (Buffer.all, Timeout, On_Wait)
    ```
  - Every concrete transport treats `Timeout` as per-call: `transports-sockets.adb` `Receive_Exactly` forwards `Timeout` straight to `Flyology.IO.Sockets.Receive_Exactly`; `transports-connections.adb:44-45` forwards it to `Item.Channel.Receive_Exactly (Data, Timeout => Timeout, ...)`; `transports-tls_sockets.adb:32-35` computes `Deadline := Clock + Timeout` inside each call. Nothing in Framing subtracts elapsed time between the three reads.
- Failure scenario: peer sends the 1-byte tag, stalls for `Timeout - epsilon`, sends the 4-byte length, stalls again, then sends the body. `Read_Message` returns after roughly `3 * Timeout` without raising `Timeout_Error`; `Read_Initial` (tag-less) can take `2 * Timeout`. Callers that size `Timeout` as a liveness bound (e.g. `Client.Receive_Copy_Event` at client.adb:2266-2292, which is the path replication feedback rides on, and `Server.Run_Session`'s `Startup_Timeout` at server.adb:372/403) get a bound three times looser than documented. Not an unbounded hang, but the documented contract is not met.
- Reproduction test sketch: write a `Transports.Transport` implementation whose `Receive_Exactly` records `Timeout` and a simulated clock (advance the clock by `Timeout - 0.001` on each call before returning the requested bytes for a queued `Make_Empty_Message ('S')` frame). Call `Framing.Read_Message (T, Timeout => 1.0)`. Expected per contract: `Flyology.IO.Timeout_Error` once cumulative simulated time exceeds 1.0. Actual: the message is returned after three calls, cumulative simulated time about 3.0 and no exception. A wall-clock variant using `delay` inside `Receive_Exactly` works the same way.
- Existing coverage: none. `Memory_Transport.Receive_Exactly` in tests/src/tests.adb:121-126 declares `pragma Unreferenced (Timeout)` and never waits, so no unit test observes deadline accounting.

### PROTO-2: `Startup_Data`, `Process_Id`, and `Secret_Key` document `Protocol_Error` on the wrong variant but never raise
- Location: src/flyology-postgres-protocol.adb:1217-1225; contract at src/flyology-postgres-protocol.ads:597-612
- Severity: P2 (contract drift; requires calling the accessor on the wrong variant, which no in-repo caller does)
- Confidence: high
- Evidence:
  - Contract, protocol.ads:602, :607, :612:
    ```
    602   --  @exception Protocol_Error Item is not Startup.
    607   --  @exception Protocol_Error Item is not Cancel_Request.
    612   --  @exception Protocol_Error Item is not Cancel_Request.
    ```
  - Bodies are plain component reads with no variant check, protocol.adb:1217-1225:
    ```
    1217   function Startup_Data (Item : Initial_Request) return Startup_Information is (Item.Startup);
    1221   function Process_Id (Item : Initial_Request) return UInt32 is (Item.Backend_Pid);
    1224   function Secret_Key (Item : Initial_Request) return Byte_Array is (Flyology.Bytes.To_Array (Item.Secret));
    ```
    `Initial_Request` (protocol.ads:819-824) is a plain record, not a discriminated one, so the defaults (`User` empty, `Backend_Pid = 0`, `Secret` empty) are silently returned. Compare the sibling accessors on `Backend_Message` (protocol.adb:1051-1141), which do `Require (Item.Response = ...)`.
- Failure scenario: a consumer that follows the documented contract and uses the exception as its variant check receives `Process_Id = 0` and a zero-length `Secret_Key` for a startup packet, or a `Startup_Information` with an empty `User` for a `Cancel_Request`, with no error. Inside this repository `Server.Run_Session` guards with `Protocol.Kind` first (server.adb:416, :420), so the drift is not exercised.
- Reproduction test sketch: `I := Protocol.Decode_Initial (Encode_SSL_Request (5 .. 8))` (contents after the length; see PROTO-3); then `Protocol.Startup_Data (I)`, `Protocol.Process_Id (I)`, `Protocol.Secret_Key (I)`. Expected per `.ads`: `Protocol_Error` from each. Actual: default record, `0`, and a `1 .. 0` array.
- Existing coverage: none; `Test_Startup`, `Test_SSL_Request`, `Test_Variable_Cancellation_Key` only call the accessor matching the decoded kind.

### PROTO-3: `Protocol.Decode_Initial` is documented as taking the complete packet "including its length field" but decodes the post-length contents
- Location: src/flyology-postgres-protocol.ads:588-592 (contract); src/flyology-postgres-protocol.adb:1146-1156 and src/flyology-postgres-wire.adb:218-268 (behaviour); the in-repo callers strip the length first: src/flyology-postgres-framing.adb:57-59, tests/src/tests.adb:271-275
- Severity: P2 (contract drift; silent misclassification for a caller that trusts the doc)
- Confidence: high
- Evidence:
  - Contract, protocol.ads:589-590:
    ```
    589   --  Strictly decode an untagged initial packet including its length field.
    590   --  @param Contents Complete packet bytes.
    ```
  - `Wire.Decode_Initial` reads the first four bytes as the request code (wire.adb:233) and branches on `SSL_Request_Code` / `Cancel_Request_Code` / major version 3 (wire.adb:239-270). `Framing.Read_Initial` deliberately passes only `Read_Contents (Channel, Content_Length (Length), ...)` (framing.adb:57-59), i.e. the bytes after the length.
- Failure scenario: a caller passes the full 8-byte `Encode_SSL_Request` output. The first word decodes as `8` (the length), `Shift_Right (8, 16) = 0 /= 3`, so wire.adb:264-267 returns `Unknown_Request` with `Initial_Ok`; `Protocol.Decode_Initial` maps that to `Unknown_Initial`. No exception, wrong classification. Same for a full startup packet: the length word is neither a special code nor major 3, so it is reported as `Unknown_Initial` rather than `Startup`.
- Reproduction test sketch: `Protocol.Kind (Protocol.Decode_Initial (Protocol.Encode_SSL_Request))`. Expected per doc: `SSL_Request`. Actual: `Unknown_Initial`. (The existing tests avoid this by slicing `Packet (Cursor .. Packet'Last)` after `Read_U32`.)
- Existing coverage: `Test_SSL_Request` and `Test_Startup` (tests.adb:265-305) both slice off the length, so they document the real contract rather than the written one.

### PROTO-4: startup `replication` value parsing is case-sensitive and rejects boolean spellings PostgreSQL accepts
- Location: src/flyology-postgres-protocol.adb:1190-1202
- Severity: P2 (server-side interop edge; standard PostgreSQL tooling sends exactly `true`/`database`)
- Confidence: medium
- Evidence:
  - protocol.adb:1190-1202:
    ```
    1190   if Name = "replication" then
    1191      if Value = "database" then
    1194      elsif Value in "true" | "on" | "yes" | "1" then
    1197      elsif Value not in "false" | "off" | "no" | "0" then
    1200         raise Protocol_Error with "invalid startup replication mode";
    ```
  - PostgreSQL `ProcessStartupPacket` handles `replication` with `strcmp (valptr, "database")` and otherwise `parse_bool (valptr, &am_walsender)`; `parse_bool_with_len` is case-insensitive and accepts unique prefixes (`t`, `tr`, `tru`, `f`, `y`, `ye`, `n`, `on`, `of`, `off`, `1`, `0`). So `replication=TRUE`, `replication=t`, `replication=On`, `replication=Yes` are valid physical-replication requests to a real server but are rejected here.
- Failure scenario: a third-party client connects to a `Flyology.Postgres.Server` with `replication=TRUE`. `Framing.Read_Initial` -> `Protocol.Decode_Initial` raises `Protocol_Error` inside `Run_Session`'s declarative part (server.adb:371-372), so the server drops the connection without even sending a FATAL `ErrorResponse`; a real PostgreSQL would start a walsender.
- Reproduction test sketch: build contents by hand (Encode_Startup only emits `true`/`database`): `Append_U32 (C, 3 * 2**16); Append_C_String (C, "user"); Append_C_String (C, "a"); Append_C_String (C, "replication"); Append_C_String (C, "True"); Append_Byte (C, 0);` then `Protocol.Decode_Initial (To_Array (C))`. Expected (PostgreSQL semantics): `Startup` with `Replication_Mode = Physical_Replication_Connection`. Actual: `Protocol_Error "invalid startup replication mode"`.
- Existing coverage: none. `Test_Startup`/`Test_Malformed_Startup` do not set `replication`; replication tests use `Encode_Startup`'s own spellings.

### PROTO-5: `_pq_.*` protocol options are discarded by `Decode_Initial`, so the server cannot send the NegotiateProtocolVersion the spec requires for unrecognised options
- Location: src/flyology-postgres-protocol.adb:1180-1206 (only `replication` is retained; every other parameter is dropped), src/flyology-postgres-protocol.ads:569-583 (`Startup_Information` has no field for them); consumer side src/flyology-postgres-server_sessions.adb:150-159 (`Send_Negotiate_Protocol` always encodes `0` unrecognised options) and src/flyology-postgres-server.adb:444-447 (only sent when `Protocol_Minor > 2`)
- Severity: P2 (spec deviation on the server role; libpq does not send `_pq_.` options by default, so mainstream interop is unaffected)
- Confidence: medium
- Evidence:
  - protocol.adb:1183-1205 loops over every name/value pair but only inspects `Name = "replication"`; `_pq_.`-prefixed names fall through and are lost.
  - server_sessions.adb:156-157:
    ```
    156      Protocol.Append_U32 (Contents, Latest_Minor);
    157      Protocol.Append_U32 (Contents, 0);
    ```
  - Protocol spec (message flow, start-up): the server must reply with `NegotiateProtocolVersion` "if the client requests any protocol options that the server does not support", listing each unrecognised `_pq_.` option name; only if the version and all options are supported may it proceed straight to authentication.
- Failure scenario: a 3.2 client sends `_pq_.some_option=1`. `Startup.Protocol_Minor = 2` so server.adb:444 skips `NegotiateProtocolVersion`; the server proceeds to authentication. Per spec the client is entitled to conclude the option was accepted, and there is no API through which an application could even learn the option was requested.
- Reproduction test sketch: contents as in PROTO-4 but with an extra pair `("_pq_.foo", "1")`; `Protocol.Decode_Initial` succeeds and `Startup_Data` exposes nothing about `_pq_.foo`. Expected: either a field enumerating unrecognised `_pq_.` options (so the server can list them in `NegotiateProtocolVersion`) or, at minimum, a way for the server layer to detect their presence. Actual: silently dropped.
- Existing coverage: none; `_pq_` does not occur anywhere under `src/` or `tests/`.

### PROTO-6: `Read_C_String` reports "exceeds the configured limit" when the cursor is already past the end of the buffer
- Location: src/flyology-postgres-protocol.adb:157-161
- Severity: P2 (wrong diagnostic)
- Confidence: high
- Evidence:
  - protocol.adb:157-161 bundles three unrelated conditions under one message:
    ```
    157      Require
    158        (Source'Length <= Maximum_Message_Size
    159         and then Cursor >= Source'First
    160         and then Cursor <= Source'Last,
    161         "Postgres string exceeds the configured limit");
    ```
    Contract, protocol.ads:690: `@exception Protocol_Error No terminator remains in Source.` The "unterminated Postgres string" message at :164 is only reached when at least one byte remains.
- Failure scenario: a client sends a `Q` message with an empty payload. `Server_Sessions.Query_Text` (server_sessions.adb:479) calls `Read_C_String` with `Cursor = 1` on a `1 .. 0` array; the raised `Protocol_Error` says the string "exceeds the configured limit" when the payload is in fact zero bytes and simply unterminated. The same message appears for `Password_Text`, `SASL_Initial_Response`, and the client's SASL mechanism loop (client.adb:263) when the buffer is exhausted.
- Reproduction test sketch: `Empty : Byte_Array (1 .. 0); Cursor : Byte_Offset := 1; Read_C_String (Empty, Cursor)`. Expected: `Protocol_Error` mentioning an unterminated string. Actual: `Protocol_Error "Postgres string exceeds the configured limit"`.
- Existing coverage: `Test_Malformed_String` (tests.adb:404-422) uses a one-byte unterminated buffer and only checks that some `Protocol_Error` is raised; it does not distinguish the message, and no test uses an empty buffer.

### PROTO-7: `Maximum_Message_Size` is documented as including the type byte, but `Make_Message` and `Valid_Typed_Length` admit a frame of `Maximum_Message_Size + 1` bytes
- Location: src/flyology-postgres-protocol.adb:179-181 and src/flyology-postgres-wire.ads:319-320; contract at src/flyology-postgres.ads:6-8 and src/flyology-postgres-protocol.ads:33-34
- Severity: P2 (off-by-one in a documented bound; no interop or memory-safety effect because encoder and decoder agree with each other)
- Confidence: high
- Evidence:
  - Contract, flyology-postgres.ads:6-8:
    ```
    6   Maximum_Message_Size : constant := 16 * 1_024 * 1_024;
    7   --  Largest complete PostgreSQL wire message accepted by the library,
    8   --  including its type byte and encoded length.
    ```
  - protocol.adb:179-181 allows `Payload'Length <= Maximum_Message_Size - 4`; `Encode` (protocol.adb:222-229) then emits `1 + 4 + Payload'Length`, i.e. up to `Maximum_Message_Size + 1` bytes.
  - wire.ads:319-320 `Valid_Typed_Length` accepts `Length <= Maximum_Frame_Size`, and `Framing.Read_Message` then reads `1 + Length` bytes, again up to `Maximum_Message_Size + 1`.
  - Untagged initial packets (`Valid_Initial_Length`, `Encode_Startup` at protocol.adb:1261-1263) do honour the bound exactly, so the drift is specific to typed messages.
- Failure scenario: `Make_Message ('d', Payload (1 .. 16#100_0000# - 4))` succeeds and `Encode` returns a 16 MiB + 1 byte frame, contradicting the documented "including its type byte" limit; symmetrically `Read_Message` accepts a frame one byte larger than documented.
- Reproduction test sketch: `Protocol.Encode (Protocol.Make_Message ('d', (1 .. Byte_Offset (Protocol.Maximum_Message_Size - 4) => 0)))'Length`. Expected per doc: `Protocol_Error` from `Make_Message` (or a length of at most `Maximum_Message_Size`). Actual: `Maximum_Message_Size + 1`.
- Existing coverage: none exercises the bound.

---

## Areas reviewed with no findings

- Wire primitives (`Element_At`, `Decode_U16/U32/U64`, `Encode_U16/U32/U64`, `Try_Read_*`, `Try_Read_Bytes`, `Find_Nul`, `Try_Read_C_String`, `View_Equals`, `Content_Length`): big-endian order, zero-based logical positions independent of array bounds, cursor left unchanged on failure, null-range loop in `View_Equals` is legal Ada.
- `Wire.Decode_Initial`: SSLRequest/GSSENCRequest require exactly 4 content bytes; CancelRequest accepts contents 12..264 (secret 4..256, covering 3.0's fixed 4-byte key and 3.2's variable key); non-3 major -> `Unknown_Request`; startup requires a final NUL, rejects trailing bytes, unterminated names/values, and a missing or empty `user`; empty/absent `database` defaults to `user` as `postmaster.c` does; last duplicate parameter wins as in PostgreSQL.
- `Protocol.Encode_Startup`, `Encode_SSL_Request`, `Encode_Cancel_Request`: lengths include the length word (8 / 12+key), codes 80877103 / 80877102 correct, NUL-terminated pairs plus terminator, secret length checked 4..256.
- Frontend constructors `Make_Parse_Message`, `Make_Bind_Message`, `Make_Describe_Message`, `Make_Execute_Message`, `Make_Close_Message`, `Make_Flush/Sync/Copy_Data/Copy_Done/Copy_Fail_Message`: field order, `Int16` counts, `Int32` parameter lengths with `-1` for NULL and `0` for empty, `S`/`P` selector bytes, `Int32` max-rows with 0 = unlimited, format-code arrays in the 0 / 1 / N shapes (`Parameter_Format_Count`, `Result_Format_Count` collapse only when semantically equivalent), all-text and all-binary single-code forms verified by `Test_Extended_Frontend_Messages`.
- `Append_C_String` and `Make_Field_Description` reject embedded NUL; length-prefixed fields (`Text_Parameter`, `Text_Column`, SASL bodies) correctly allow NUL.
- Backend strict decoders `Decode_Row_Description` (name, table OID, attr number Int16, type OID, type size Int16, typmod Int32, format Int16 restricted to 0/1; per-field minimum 19 bytes via `Count_Fits`), `Decode_Data_Row` (Int16 count, `-1` NULL, any other negative length rejected, empty value distinct from NULL), `Decode_Diagnostic` (code byte + string, terminator required, trailing data rejected, repeated codes retained with first-match lookup), `Decode_Parameter_Status`, `Decode_Parameter_Description`, `Decode_Copy_Format_Description` (Int8 overall + Int16 count + exactly 2*count bytes), `ReadyForQuery` (exactly one of `I`/`T`/`E`), empty-payload markers `1 2 3 n s c I`. Trailing-payload checks are present in every decoder. Unknown tags (`K`, `R`, `v`, `A`, `V`) stay `Unknown_Response` per the documented contract.
- `Decode_Frontend_Copy`: CopyData raw, CopyDone must be empty, CopyFail one string with no trailing bytes.
- Signed conversions `Signed_16`/`Signed_32` (protocol.adb:594-602) and `Unsigned_16`/`Unsigned_32` (server_sessions.adb:28-36), `To_Int32_Bits`/`To_UInt32_Bits` and 64-bit variants: correct two's-complement mapping at both boundaries.
- Public cursor readers `Read_U16`/`Read_U32`: bounds and `Byte_Offset'Last` overflow guards correct; `Read_C_String` advances exactly past the terminator.
- Ownership/aliasing: `Message`, `Backend_Message`, `Frontend_Copy_Message`, `Bind_Parameter`, `Column_Value` hold `Flyology.Bytes.Unbounded_Bytes` (vector-backed, value semantics); `Payload`, `Copy_Bytes`, `Copy_Data`, `Secret_Key`, `Parameter_Bytes`, `Column_Bytes` return fresh copies; `Framing.Read_Contents` copies out of its heap buffer before freeing and frees on exception. No view escapes into freed storage.
- `Framing.Read_Length`/`Read_Message`/`Read_Initial` length validation: minimum 4 (typed) / 8 (initial), lengths >= 2**31 rejected as too large, zero-length body skips the transport read. `Write_Message`, `Write_Packet`, `Write_Byte` are straightforward.
- Server encoders in `Server_Sessions` (Authentication 0/3/10/11/12, BackendKeyData 4..256-byte key, NegotiateProtocolVersion shape, ParameterStatus, ErrorResponse/NoticeResponse with `S V C M` and terminator, CommandComplete, RowDescription, DataRow, Copy*Response, ReadyForQuery) match the protocol byte layouts; SQLSTATE length enforced.
- Client consumption: BackendKeyData accepted at 8..260 bytes (3.0 fixed key through 3.2 256-byte key); SASL mechanism list parsed to its terminator with trailing-data check; SASLInitialResponse encodes mechanism, Int32 length, body.

## Observations recorded but not counted as findings (deliberate policy, out of PROTO scope, or lenient-by-design)

- `Maximum_Message_Size` = 16 MiB is far below PostgreSQL's ~1 GB `PQ_LARGE_MESSAGE_LIMIT`; a real backend can legitimately send a larger DataRow/CopyData, which this client rejects with `Protocol_Error` and a desynchronised stream. This is a documented library policy value, not a codec bug; flagged for the decision-authority rules rather than as a defect.
- The client always requests protocol 3.2 (client.adb:219) and ignores the resulting `NegotiateProtocolVersion` (`when others => null` at client.adb:369-370). Correct for servers >= 9.3 since it sends no `_pq_.` options and handles both key sizes; servers older than that would reject the version with a FATAL error. Policy choice, out of PROTO scope.
- `Decode_Copy_Format_Description` does not enforce "all column codes must be 0 when the overall format is text"; libpq does not either.
- Client `Result_Formats`/`Parameters` format-code collapsing can turn a would-be server error (`N` codes for an `M`-column query) into a valid single-code message; behaviour is lenient, never wrong.
- AuthenticationMD5Password and other auth methods raise `Unsupported_Authentication` by design.
