## ROUTING-MW

Routing, dispatch and the middleware stack: `flyology-http-server-routing.adb/.ads`,
`flyology-http-server-applications.adb/.ads`, the ten `middleware_*` packages,
`flyology-http-server-cors.adb/.ads`, `flyology-http-server-metrics.adb/.ads`,
`flyology-rate_limit_policy`, `flyology-http-decoded_path_policy`,
`flyology-http-route_parameter_policy` and `flyology-http-server-native_routes`, plus the
`:path` and request-target admission sites in `flyology-http-server.adb`,
`flyology-http-server-http_2.adb` and `flyology-http-http_3_header_policy.adb` that feed
them. Tests read: `tests/http_routing_audit.adb`, `tests/http_smoke.adb`, and the three
policy smoke mains. Five findings, all CONFIRMED, all reproduced: two P1 and three P2. The
verification moved ROUTING-MW-2 up from P2 to P1 and corrected the standard citation on
ROUTING-MW-5 and the production name on ROUTING-MW-3. Nothing in this area was refuted, and
the regression check on the previously fixed routing and middleware findings found every fix
still present at `f078732`.

### ROUTING-MW-1: The 400 for a path with more than 64 segments bypasses the middleware chain and automatic admission

- **Severity:** P1 (discovery said P1; unchanged). A named `.ads` contract is violated on an
  input any peer can send on any protocol.
- **Location:** `src/flyology-http-server-routing.adb:1894-1895` (the `Split_Path` call),
  raise at `:399-401`, handler at `:2086-2090`; contract at
  `src/flyology-http-server-routing.ads:806-811`; contrast the handled decode failure at
  `:1828-1835`.
- **Repro:** `./tests/repros/run.sh repro_routing_mw_1` (exit 1, BUG REPRODUCED; re-run for
  the drafting pass, 6 checks, 2 failures).
- **What is wrong:** `Decode_For_Dispatch` converts a `Decode_Path` failure into
  `Invalid_Path := True` so the malformed-path 400 is written through
  `Run_Automatic ("flyology.bad_request")` and runs the whole global chain. `Split_Path` is
  called outside that function and raises its own `Route_Error` at `Max_Segments = 64`,
  which unwinds to the outermost handler and writes `X.Problem (400, ...)` directly with no
  `Configure_Route`, no `Seal_Route` and no pipeline. The spike's control arm, `/%2e%2e/x`,
  carries `X-Content-Type-Options: nosniff` and is answered 429 on the second request under
  `Set_Automatic_Admission (Rate_Per_Second => 1)`; a 130-byte, 65-segment target on the same
  router gets neither, and repeats indefinitely.
- **Notes:** No maintainer decision needed; the fix moves the failure onto the existing
  `Run_Automatic` path and `Max_Segments` does not change. No existing test asserts the wrong
  behaviour. `tests/http_routing_audit.adb:503`
  (`Check_Automatic_Response_Admission`) already builds the router, middleware and admission
  policy the regression test needs but covers only the five automatic responses that do go
  through `Run_Automatic`. Outside every unit `scripts/prove.sh` proves.

### ROUTING-MW-2: A rejected Respond marks the exchange Failed, so the errors middleware closes instead of writing its 500

- **Severity:** P1 (discovery said P2; **raised**). The rubric's P1 clause is a documented
  contract violated, with no qualifier that the trigger be ordinary input, and two `.ads`
  contracts are violated: `middleware_errors.ads:8-9` and `applications.ads:49`. The measured
  result is zero response bytes where a closing 500 is promised, in the one component whose
  documented purpose is to contain application faults. The discovery's reason for P2, that it
  needs an application-side defect, is recorded and outweighed, because containing
  application-side defects is the feature. Not P0: the connection closes cleanly, nothing is
  corrupted and nothing hangs.
- **Location:** `src/flyology-http-server-applications.adb:436-446` and `:465-468`; consumed
  at `src/flyology-http-server-middleware_errors.adb:52-65`; `Mark_Failed` at
  `src/flyology-http-server-applications.adb:1001-1010`; the post-handler close at
  `src/flyology-http-server-routing.adb:2065-2074`; the connection-level path that still
  answers at `src/flyology-http-server-routing.adb:2264-2275`; the connection-layer validation
  at `src/flyology-http-server.adb:2733-2739` with the commit point at `:2770`.
- **Repro:** `./tests/repros/run.sh repro_routing_mw_2` (exit 1, BUG REPRODUCED; re-run,
  4 checks, 4 failures).
- **What is wrong:** `Respond` validates before writing and then catches every exception in a
  blanket handler that sets `Response_Value := Failed`, so an exchange with nothing on the
  wire reports `Failed` instead of `Not_Started`. `Middleware_Errors.Call` tests exactly that
  state, takes the `X.Mark_Failed` branch, and the HTTP/1 client sees an empty reply: the
  spike measures **0 bytes written**. The verifier measured more than the discovery predicted:
  besides the missing 500, a fully written 200 is relabelled `FAILED` when a second `Respond`
  is rejected, and the next pipelined request on the keep-alive connection is never served
  (1 response observed where 2 are due). The sharpest framing, which is in the issue Summary:
  installing the documented safety net is what removes the safety, because HTTP/1 *without*
  the errors middleware still answers 500 through the connection-level `Respond`, which
  consults `Response_Begun` rather than the exchange state.
- **Notes:** No maintainer decision needed; the fix narrows an over-broad handler and adds no
  value or parameter. No existing test asserts the wrong behaviour:
  `tests/http_smoke.adb:2930-2942` covers a handler that raises *before* calling `Respond`
  (`Unexpected` at `:2804-2811`), which is the only shape that still reaches the 500 branch,
  and `:2944-2956` covers a failure after a stream started. Outside every proved unit.

### ROUTING-MW-3: HTTP/2 :path beginning with http:// is routed as an absolute-form target, unlike HTTP/3 and HTTP/1

- **Severity:** P2 (discovery said P2; unchanged). The area brief asked whether the severity
  must drop because RFC 9113 permits the absolute form in `:path`. It does not permit it, so
  nothing drops. It does not rise either: the input is malformed rather than valid, and
  `routing.ads:928-930` is a statement about dispatch, not about pseudo-header admission, so
  there is no clean `.ads` hook. Confidence rises from the discovery's *medium* to *high* for
  the mechanism and the standard.
- **Location:** `src/flyology-http-server-http_2.adb:2341-2349` (the only `:path` checks on
  the h2 admission path); `src/flyology-http-server-routing.adb:283-286` and `:295-309`
  (`Absolute_Form_Authority`, `Raw_Path`); contrast
  `src/flyology-http-http_3_header_policy.adb:299-304` and
  `src/flyology-http-server.adb:838-848`; the query split at
  `src/flyology-http-server-requests.adb:62-63`.
- **Repro:** `./tests/repros/run.sh repro_routing_mw_3` (exit 1, BUG REPRODUCED; re-run,
  5 checks, 2 failures). The only spike in this area that needs a real HTTP/2 connection; it
  binds with `Sockets.Any_Port` and reads the port back with `Sockets.Get_Socket_Name`.
- **What is wrong:** Nothing on the HTTP/2 admission path requires `:path` to be an
  `absolute-path`, so `http://localhost/admin/users` reaches `Raw_Path`, which strips the
  embedded authority, never compares it with `:authority`, and routes `/admin/users`. The
  spike exercises all three lanes: HTTP/2 serves it as `admin.users`; HTTP/1 answers 400 when
  the embedded authority conflicts with `Host` and 200 when it agrees; HTTP/3 rejects it as
  `Invalid_Path`. A second probe is sharper: `:path: http://localhost?x=1/admin` routes `/`
  while the query parameter `x` reads `1/admin`, because `Raw_Path` returns `"/"` on meeting
  `?` before any `/` while `Requests.Find_Query` takes the first `?` of the whole value.
- **Notes:** The discovery report named the wrong production: RFC 9113 section 8.3.1 says
  **`absolute-path`**, not `"path-absolute"`. The issue body quotes all three linked clauses
  that make this a MUST: section 8.3.1 (`absolute-path` plus "exactly one valid value"),
  section 8.3 ("MUST treat ... invalid pseudo-header fields as malformed") and section 8.1.1
  ("MUST be treated as a stream error ... PROTOCOL_ERROR"). The intermediary scenario is
  **not verified against a peer** and the body says so in the same sentence as the claim; the
  severity does not rest on it. The green h2spec 2.6.0 baseline (146 of 146) is silent here:
  its cases under section 8.1.2.3 test only an empty `:path`, an omitted `:method`, `:scheme`
  or `:path`, and duplicated pseudo-header fields, never an invalid *value*. No existing test
  asserts the wrong behaviour; `tests/http_routing_audit.adb:164-240` exercises the absolute
  form over HTTP/1, where it is legal, and
  `tests/flyology-http-http_3_header_policy-smoke.adb:94-95` pins the HTTP/3 rejection.
  Outside every proved unit.

### ROUTING-MW-4: The metrics series key includes the client-chosen request method and nothing evicts a filled table

- **Severity:** P2 (discovery said P2; unchanged). Observability only. Memory stays bounded,
  the loss is counted in `Dropped_Series`, and the aggregate counters keep working. The defect
  is that the peer chooses which series survive, permanently.
- **Location:** `src/flyology-http-server-metrics.adb:54-72`, consumed from
  `src/flyology-http-server-middleware_metrics.adb:23-30` with `X.Request_Method` at `:25`;
  method admission at `src/flyology-http-server.adb:1164-1168` and `src/flyology-http.adb:14`;
  key bounds at `src/flyology-http-server-metrics.ads:119-120`.
- **Repro:** `./tests/repros/run.sh repro_routing_mw_4` (exit 1, BUG REPRODUCED; re-run,
  8 checks, 2 failures).
- **What is wrong:** The series key is the triple route, method and status class. `Route` is
  bounded as `metrics.ads:39` states, but `Method` is the token the peer sent, and nothing in
  `metrics.adb` ever clears a `Used` entry or reduces `Value.Series`, so the table is
  fill-once for the life of the sink. Every unknown method to an existing path is a 405 with
  `Route_Name = "flyology.method_not_allowed"`, so only the method varies. The spike drives a
  `Capacity => 4` sink with four distinct five-byte method tokens; `Series` reaches 4 with
  `Dropped_Series = 0`, and the legitimate `GET /x` 200 that follows is dropped, as is every
  legitimate request after it (15 requests counted in the aggregate, none in any series).
- **Notes:** The capacity **is** a documented policy value:
  `src/flyology-http-server-metrics.ads:80-83` declares
  `type In_Memory (Capacity : Positive := 256)` with the comment naming
  route/method/status-class series, and `website/guide/server/index.html:469` documents the
  cap and the drop counter. The finding is therefore **not** about the number 256. It is about
  the peer choosing one of the three key components and about `metrics.adb` never clearing a
  `Used` entry. The issue body frames it that way and carries a **maintainer decision** with
  both sets of options listed and neither chosen: for the method key, a private implementation
  value, a value derived from the router's registered methods, a generic formal, or a
  deliberately public constant; for eviction, a private implementation value, a discriminant
  on `In_Memory` beside `Capacity`, a generic formal, build-time configuration, a deliberately
  public constant, or leaving the table fill-once and documenting it. The rate limiter's
  bucket table already has the least-recently-seen takeover this would mirror
  (`src/flyology-http-server-middleware_rate_limits.adb:94-95`). This makes the earlier
  audit's "Metrics cardinality" appendix claim that a client cannot inflate cardinality
  incorrect for the method key. Existing coverage pins the bound but never varies the method
  (`tests/http_smoke.adb:3322-3323`, `Series = 1` and `Dropped_Series > 0`); it does not
  assert wrong behaviour and need not change. Outside every proved unit.

### ROUTING-MW-5: CORS middleware omits Vary: Origin on responses whose header set depends on Origin

- **Severity:** P2 (discovery said P2; unchanged). Cache-correctness edge case. No credential
  or origin bypass: `Origin_Allowed` is unchanged and nothing is reflected to a disallowed
  origin.
- **Location:** `src/flyology-http-server-middleware_cors.adb:15-30` (`Add_Origin`, the only
  `Vary: Origin`), with the three early returns at `:40-43`, `:53-61` and `:92-95`.
- **Repro:** `./tests/repros/run.sh repro_routing_mw_5` (exit 1, BUG REPRODUCED; re-run,
  6 checks, 2 failures).
- **What is wrong:** For a non-wildcard policy the representation's header set depends on
  `Origin`, but `Vary: Origin` is emitted only from `Add_Origin`, which runs only after the
  origin was present and allowed. The spike's allowed origin gets
  `Access-Control-Allow-Origin` and `Vary`; a disallowed origin and a request with no `Origin`
  each get a cacheable 200 with neither. A shared cache stores the no-`Origin` copy under a
  key that ignores `Origin` and serves it to a later cross-origin fetch, which the user agent
  then blocks on a resource the server would have allowed.
- **Notes:** **The discovery report's citation was wrong and the verifier corrected it.** The
  sentence attributed to RFC 9110 section 12.5.5 ("An origin server SHOULD send a Vary header
  field when its algorithm for selecting a representation varies ...") is not in RFC 9110 at
  all; it paraphrases the obsoleted RFC 7231 section 7.1.4, and RFC 9110 replaced it with a
  weaker intent-conditioned SHOULD plus an explicit "Vary might be elided" escape. On RFC 9110
  alone the finding would be weak. The behaviour claim survives under the WHATWG Fetch
  Standard's "CORS protocol and HTTP caches", which states the requirement and then describes
  this exact failure; the issue body cites Fetch for the requirement and RFC 9110 section
  12.5.5 only for the cache-key mechanism. Filing it against RFC 9110 would invite a correct
  rejection. Cache behaviour itself is **not checkable from a spike**, since no cache is in
  the loop, so the reproduction establishes only the emitted field set, which is the part the
  server controls; the body says so. The preflight path is already correct and the guide's
  claim at `website/guide/server/index.html:438` holds. Existing coverage asserts `Vary` on
  the allowed path only (`tests/http_routing_audit.adb:1109-1111`,
  `tests/http_smoke.adb:3256-3257`) and does not assert wrong behaviour. Outside every proved
  unit.

### Coverage evidence

Read in full or in the ranges the discovery scope lists: `flyology-http-server-routing`
(.adb 3284 lines, .ads 1471), `flyology-http-server-applications`, the ten `middleware_*`
packages, `flyology-http-server-cors`, `flyology-http-server-metrics`,
`flyology-rate_limit_policy`, `flyology-http-server-compression.ads`,
`flyology-http-server-logging.ads`, `flyology-http-decoded_path_policy`,
`flyology-http-route_parameter_policy`, `flyology-http-server-native_routes`, and the
admission sites in `flyology-http-server.adb`, `flyology-http-server-http_2.adb`,
`flyology-http-http_2_hpack.adb`, `flyology-http-http_3_header_policy.adb` and
`flyology-http-server-requests.adb`. Tests read: `tests/http_routing_audit.adb` (2717 lines,
outline plus the automatic-admission and CORS sections), `tests/http_smoke.adb` (the CORS,
metrics and errors-middleware sections), and the `decoded_path_policy`,
`route_parameter_policy` and `rate_limit_policy` smoke mains. Also `proof/proof-status.md`,
`website/guide/server/index.html` and the routing entries in the earlier audit.

Executed: all five spikes, twice, once during verification and once during drafting; every
run exits 1 with BUG REPRODUCED and the same check and failure counts. `repro_routing_mw_3`
drives a real loopback HTTP/2 connection with a raw-frame peer; the other four drive the
router through an in-memory `Flyology.HTTP.Server.Transport` copied from
`tests/http_routing_audit.adb:103-159`.

Suites and peers that bear on the area: the green `./scripts/test.sh` baseline covers
`tests/http_routing_audit.adb` and `tests/http_smoke.adb`, and each finding's entry records
why the relevant assertion is absent rather than wrong. h2spec 2.6.0 (146 of 146) is the only
pinned peer that touches the HTTP/2 admission path, and its section 8.1.2.3 case list does not
cover ROUTING-MW-3, as quoted above. No other pinned peer is relevant: Autobahn is WebSocket,
the HTTP/3 interop runs are request and response exchanges, and the WPT URL corpus belongs to
the IRI area.

Not exercised: whether a deployed HTTP/2 intermediary forwards a non-`absolute-path` `:path`
unchanged (ROUTING-MW-3), which cannot be settled in process and is marked not verified
against a peer; and the behaviour of a real shared cache in front of the server
(ROUTING-MW-5), for which the spike substitutes the emitted field set. No unit in this area
is proved by `scripts/prove.sh` except `flyology-http-decoded_path_policy.adb`,
`flyology-http-route_parameter_policy.adb` and `flyology-rate_limit_policy.adb`, none of which
is touched by any of the five fixes.

### Refuted and not counted

Refuted or checked and found sound, with no finding raised: percent decoding, dot segments and
the matching order (single-pass decode, encoded-slash rejection, the proved
`Decoded_Path_Policy.Classify`, UTF-8 validation, overlong and surrogate sequences);
parameter capture and its bounds; method dispatch, `Allow` construction, the HEAD fallback and
`OPTIONS *`; registration-time ambiguity, where the runtime `Route_Error` at
`routing.adb:1866` is unreachable; mount composition and effective middleware order; the five
automatic responses that do run the global chain; fail-closed authentication; the CORS core
(exact-token origin comparison, the `Create` rejections, preflight `Vary`); rate limiting
(saturating refill, bounded tokens, digest identity, no shard collision); bulkheads (permit
ownership and release on every unwind); request IDs and security headers; runtime
reconfiguration (`Try_Publish`, generation retention, `Reclaim`, `Finalize`); the middleware
pipeline's single-use continuation and capacity checks; and `compression.ads`, which is an
interface with no encoder in this crate. The regression check on the earlier audit's routing
and middleware findings found every fix present at `f078732`.

Recorded but outside the rubric: a mid-loop mount failure leaves the destination holding the
routes copied so far, which the spec does not promise against; `Strict_Slashes` cannot register
both `/a` and `/a/` because `Patterns_Overlap` ignores `Trailing`; an empty remainder loses the
trailing slash; duplicate `Origin` request fields are comma-joined and the joined value can be
reflected, with no exploit because browsers never send two and a non-browser client is not
subject to CORS; `*` is not a wildcard in `Allowed_Methods` or `Allowed_Headers`; `OPTIONS` on
a resource with no explicit `OPTIONS` route is 405; headers staged before `Run_Automatic` are
inherited by a middleware short-circuit response; a rate-limiter key an application derives
from a spoofable proxy header allows self-eviction within the documented bounded-LRU
trade-off; absurd policy durations near `Duration'Last` overflow the clock addition and surface
as a 500, which is a configuration error not reachable from a peer; parser-level 400, 413, 417
and 500 responses carry no middleware headers by design, since they never construct an
exchange; and metrics `Method` truncation above `Max_Method_Length` is counted in
`Dropped_Series`, noted only because it interacts with ROUTING-MW-4.
