# Verification: ROUTING-MW

Commit: f078732
Findings examined: 5. Confirmed: 5. Refuted: 0. Partial: 0. Other: 0.

| ID | Discovery severity | Verdict | Final severity | Repro |
|----|--------------------|---------|----------------|-------|
| ROUTING-MW-1 | P1 | CONFIRMED | P1 | `repro_routing_mw_1` |
| ROUTING-MW-2 | P2 | CONFIRMED | P1 (raised) | `repro_routing_mw_2` |
| ROUTING-MW-3 | P2 | CONFIRMED | P2 | `repro_routing_mw_3` |
| ROUTING-MW-4 | P2 | CONFIRMED | P2 | `repro_routing_mw_4` |
| ROUTING-MW-5 | P2 | CONFIRMED (citation corrected) | P2 | `repro_routing_mw_5` |

One correction to the discovery report is material and is recorded under
ROUTING-MW-5: the sentence it attributes to RFC 9110 Section 12.5.5 is not in
RFC 9110. It is a paraphrase of the obsoleted RFC 7231 Section 7.1.4. The
behaviour claim survives under the correct normative source (the WHATWG Fetch
Standard) and under RFC 9110's own statement of what `Vary` does; the
attribution does not.

A second, smaller correction is recorded under ROUTING-MW-3: the discovery
quotes RFC 9113 Section 8.3.1 as naming the `"path-absolute"` production. The
RFC names the **`absolute-path`** production. The requirement is the one the
finding relies on, so the substance is unaffected.

---

## ROUTING-MW-1: A malformed-path 400 for more than 64 segments bypasses the global middleware chain and automatic admission

- **Verdict:** CONFIRMED
- **Severity:** P1 (discovery said P1; unchanged). `routing.ads:806-811` is an
  `.ads` contract that names this exact response, and it is violated on a path
  reachable from any peer on any protocol. The rubric's P1 clause "a documented
  contract violated (`.ads` comment ...)" applies directly. It is not P0: the
  response is still a correct 400, no bytes are corrupted, and nothing stalls.
- **Repro:** `tests/repros/src/repro_routing_mw_1.adb`, run with
  `./tests/repros/run.sh repro_routing_mw_1`
- **Output:**

```
  note target length 130 bytes, 65 segments
  note control first status 400
  ok   control: decode-failure answers 400
  ok   control: decode-failure 400 runs security-headers middleware
  note control second status 429
  ok   control: second decode-failure 400 is rate limited
  note over-segment first status 400
  ok   65-segment target answers 400
  FAIL 65-segment 400 runs the global security-headers middleware
  note over-segment second status 400
  FAIL second 65-segment 400 is metered by automatic admission
checks: 6  failures: 2
BUG REPRODUCED
... exited with code 1
```

- **Description:** `Dispatch_Configuration` decodes the target inside
  `Decode_For_Dispatch` (`routing.adb:1828-1835`), which converts a
  `Decode_Path` failure into `Invalid_Path := True` so the 400 is issued through
  `Run_Automatic ("flyology.bad_request")` and runs the global chain. The call
  to `Split_Path` sits outside that function, at `routing.adb:1895`, and
  `Split_Path` raises its own `Route_Error` at `routing.adb:399-401` when the
  decoded path reaches `Max_Segments` (`routing.ads:1350`, value 64). That raise
  unwinds past `Run_Automatic` to the outermost handler at
  `routing.adb:2086-2090`, which writes `X.Problem (400, "invalid-path", ...)`
  directly with no `Configure_Route`, no `Seal_Route` and no pipeline. The
  spike's control arm is the decode-failure 400 for `/%2e%2e/x`: it carries
  `X-Content-Type-Options: nosniff` and the second request is answered 429 by
  `Set_Automatic_Admission (Rate_Per_Second => 1)`, exactly as
  `routing.ads:806-818` promises. The same router answers a 130-byte,
  65-segment target `/a/a/.../a` with a 400 that carries neither the header nor
  the rate limit, and repeats that 400 indefinitely. The peer therefore has one
  unmetered, unlogged, header-less error surface on every router that relies on
  `Set_Automatic_Admission` to bound its unmatched-path traffic. No maintained
  test sends more than 64 segments; `tests/http_routing_audit.adb:503-594`
  covers only the five automatic responses that do go through `Run_Automatic`.
  Standard: not applicable, the contract is internal.

---

## ROUTING-MW-2: `Applications.Respond` marks the exchange `Failed` before any byte is written

- **Verdict:** CONFIRMED (all four aspects, including two the discovery only
  sketched)
- **Severity:** P1 (discovery said P2; **raised**). The rubric's P1 clause is "a
  documented contract violated (`.ads` comment ...)", with no qualifier that the
  trigger be ordinary input, and two `.ads` contracts are violated here:
  `middleware_errors.ads:8-9` ("Unexpected exceptions become a generic closing
  500 before response start") and `applications.ads:51`, which defines
  `Not_Started` as "No response bytes have been written". The measured result is
  **zero response bytes** where a 500 is promised, in the one component whose
  documented purpose is to contain application faults. I record the discovery's
  reason for P2 - it needs an application-side defect to trigger - and consider
  it outweighed, because containing application-side defects is the feature.
  It is not P0: the connection is closed cleanly, no bytes are corrupted, and
  nothing hangs.
- **Repro:** `tests/repros/src/repro_routing_mw_2.adb`, run with
  `./tests/repros/run.sh repro_routing_mw_2`
- **Output:**

```
  note errors-middleware output []
  note bytes written 0
  FAIL errors middleware writes the promised 500 for a pre-write Respond failure
  note state after pre-write raise: FAILED
  FAIL exchange stays Not_Started when Respond raised before writing
  note state after rejected second Respond: FAILED
  FAIL a fully written response stays Completed when a second Respond is rejected
  note responses on the pipelined connection 1
  FAIL the pipelined request after a rejected second Respond is still served
checks: 4  failures: 4
BUG REPRODUCED
... exited with code 1
```

- **Description:** `Applications.Respond` performs its own pre-write validation
  at `applications.adb:436-446` and then calls through to
  `Flyology.HTTP.Server.Respond`, which validates again at `server.adb:2732-2739`
  and only sets `Item.Response_Begun := True` at `server.adb:2770`, after every
  raise. So `X.Respond (99, ...)` raises `Constraint_Error` with nothing written
  and `Wire_Response_Started` still `False`. The blanket handler at
  `applications.adb:465-468` nevertheless sets `Item.Response_Value := Failed`.
  `Middleware_Errors.Call` then reaches its `when Error : others` arm, finds
  `X.Response /= App.Not_Started` at `middleware_errors.adb:53` and takes the
  `X.Mark_Failed` branch instead of writing the 500. `Mark_Failed`
  (`applications.adb:1001-1010`) sets `Connection_Handle.Request_Close := True`,
  so `Serve` leaves its loop and the HTTP/1 client sees an empty reply: the
  spike measures 0 bytes on the wire. The second half is the mislabelling: a
  handler that writes one complete 200 and then makes a rejected second
  `Respond` call leaves the exchange reporting `FAILED` for a response that was
  fully and correctly written, and the following pipelined request on the same
  keep-alive connection is never served (1 response observed where 2 are due).
  Only HTTP/1 *without* the errors middleware still answers 500, because
  `routing.adb:2262-2275` uses the connection-level `Respond`, which consults
  `Response_Begun` rather than the exchange state - which is why installing the
  documented safety net is what removes the safety. Standard: not applicable,
  the contracts are internal (`middleware_errors.ads:5-9`,
  `applications.ads:48-57`).

---

## ROUTING-MW-3: HTTP/2 `:path` beginning with `http://` or `https://` is routed as an absolute-form target

- **Verdict:** CONFIRMED. The two open questions in the discovery entry are both
  settled below, in the finding's favour.
- **Severity:** P2 (discovery said P2; unchanged). The area brief asked whether
  the severity must drop because RFC 9113 permits the absolute form in `:path`.
  It does not permit it - see the quotes below - so nothing drops. It does not
  rise to P1 either: the input is malformed rather than valid, and
  `routing.ads:928-930` promises that "Route registration, middleware, body
  policy, and endpoint handlers are identical for both protocols", which is a
  statement about dispatch and not about pseudo-header admission, so there is no
  clean `.ads` contract hook. The rubric's P2 - "edge-case incorrectness ...
  needing unusual input" - is the right fit. Confidence rises from the
  discovery's *medium* to *high* for the mechanism and the standard; the
  intermediary scenario remains **not verified against a peer**.
- **Repro:** `tests/repros/src/repro_routing_mw_3.adb`, run with
  `./tests/repros/run.sh repro_routing_mw_3`
- **Output:**

```
  note control :path=/admin/users -> route=admin.users path=/admin/users x=
  ok   control: origin-form :path reaches its route
  note :path=http://localhost/admin/users -> route=admin.users path=/admin/users x=
  FAIL absolute-form :path is treated as malformed (RFC 9113 Sections 8.3, 8.3.1, 8.1.1)
  note :path=http://localhost?x=1/admin -> route=root path=/ x=1/admin
  FAIL absolute-form :path with a query is treated as malformed
  note HTTP/1 absolute form agreeing with Host -> 200
  note HTTP/1 absolute form disagreeing with Host -> 400
  ok   HTTP/1 absolute form with a matching Host is served
  ok   HTTP/1 rejects an absolute form whose authority conflicts with Host
checks: 5  failures: 2
BUG REPRODUCED
... exited with code 1
```

### Question 1: do the three protocols really disagree?

Yes. All three sites, quoted at f078732:

HTTP/2, `src/flyology-http-server-http_2.adb:2341-2349` - the only `:path`
checks on the admission path; none requires a leading `/`:

```ada
               if Method_Text = "CONNECT" or else
                 Scheme_Text not in "http" | "https"
                 or else Path_Text = ""
                 or else Ada.Strings.Fixed.Index (Path_Text, "#") /= 0
                 or else (Path_Text = "*"
                   and then Method_Text /= "OPTIONS")
               then
                  raise Request_Message_Error with
                    "unsupported HTTP/2 request target";
```

HTTP/3, `src/flyology-http-http_3_header_policy.adb:299-304` - requires it:

```ada
         elsif (Scheme = "http" or else Scheme = "https")
           and then Path /= "*"
           and then Path (Path'First) /= '/'
         then
            Result.Status := Invalid_Path;
            return Result;
```

HTTP/1, `src/flyology-http-server.adb:826-848` - accepts the absolute form
(which RFC 9112 Section 3.2.2 makes legal there) but validates the embedded
authority and requires it to agree with `Host`:

```ada
            if Authority_Last < Authority_First
              or else not Valid_Authority
                (Request_Target (Authority_First .. Authority_Last))
            then
               raise Protocol_Error with "invalid absolute request authority";
            elsif Host'Length > 0
              and then Lower (Host) /= Lower
                (Request_Target (Authority_First .. Authority_Last))
            then
               raise Protocol_Error with "Host conflicts with request target";
            end if;
```

The spike exercises all three lanes. HTTP/2 serves
`:path: http://localhost/admin/users` as `/admin/users` with
`Route_Name = "admin.users"`; the embedded authority is discarded by
`Raw_Path` (`routing.adb:283-309`) and never compared with `:authority`.
HTTP/1 answers 400 for the corresponding `GET http://evil.example/admin/users`
with `Host: localhost`, and 200 only when the two agree. HTTP/3 rejects
`Path (Path'First) /= '/'` as `Invalid_Path`, pinned by
`tests/flyology-http-http_3_header_policy-smoke.adb:94-95`.

The second probe shows a sharper consequence:
`:path: http://localhost?x=1/admin` routes `/` while
`Flyology.HTTP.Server.Requests.Query (X, "x")` returns `1/admin`, because
`Raw_Path` returns `"/"` when it meets `?` before any `/`
(`routing.adb:301-302`) but `Requests.Find_Query` (`requests.adb:62-63`) takes
the first `?` of the whole target. The handler's view of the path and of the
query come from different parses of the same value.

### Question 2: does RFC 9113 permit the absolute form in `:path`?

No. It forbids it, at MUST level, through three linked clauses.

RFC 9113 Section 8.3.1:

> "The ':path' pseudo-header field includes the path and query parts of the
> target URI (the absolute-path production and, optionally, a '?' character
> followed by the query production; see Section 4.1 of [HTTP])."

> "All HTTP/2 requests MUST include exactly one valid value for the ':method',
> ':scheme', and ':path' pseudo-header fields, unless they are CONNECT requests
> (Section 8.5)."

RFC 9110 Section 4.1 defines `absolute-path = 1*( "/" segment )`, so
`http://localhost/admin/users` is not one, and is therefore not a valid value.

RFC 9113 Section 8.3:

> "Endpoints MUST treat a request or response that contains undefined or
> invalid pseudo-header fields as malformed (Section 8.1.1)."

RFC 9113 Section 8.1.1:

> "Malformed requests or responses that are detected MUST be treated as a
> stream error (Section 5.4.2) of type PROTOCOL_ERROR."

So the RFC-required outcome is a stream error, which is what the spike asserts
and what HTTP/3 already does here. The discovery's own summary of the RFC is
correct; only the production name is off (`absolute-path`, not
`path-absolute`).

### Why the green h2spec baseline does not cover this

`review/baselines/13-http2-h2spec-docker.log:258-265` lists every h2spec case
under 8.1.2.3 "Request Pseudo-Header Fields": empty `:path`, omitted `:method`,
omitted `:scheme`, omitted `:path`, and duplicated `:method`, `:scheme`,
`:path`. All seven pass. None sends a `:path` whose *value* is syntactically not
an `absolute-path`, so the 146/146 result is silent on this input.

### What a peer would have to do for this to matter

An h2 intermediary would have to apply a path policy to the raw `:path` and
forward the request unchanged. RFC 9113 Section 8.1.1 says "Intermediaries that
process HTTP requests or responses ... MUST NOT forward a malformed request",
so a conforming intermediary would not. Whether any deployed intermediary does
is **not verified against a peer** and cannot be settled in-process. A directly
connected peer gains nothing: it can simply send `:path: /admin/users`.

---

## ROUTING-MW-4: Metrics series are keyed by the client-controlled request method with no eviction

- **Verdict:** CONFIRMED
- **Severity:** P2 (discovery said P2; unchanged). Observability only. Memory
  stays bounded, the loss is counted in `Dropped_Series`, and the aggregate
  counters keep working. The defect is that the peer chooses which series
  survive, permanently.
- **Repro:** `tests/repros/src/repro_routing_mw_4.adb`, run with
  `./tests/repros/run.sh repro_routing_mw_4`
- **Output:**

```
  note series before flood 0, dropped 0
  note flood M0000 /x -> 405
  ok   an unknown method to an existing path answers 405
  note flood M0001 /x -> 405
  ok   an unknown method to an existing path answers 405
  note flood M0002 /x -> 405
  ok   an unknown method to an existing path answers 405
  note flood M0003 /x -> 405
  ok   an unknown method to an existing path answers 405
  note series after flood 4, dropped 0
  ok   the flood filled the series table (evidence the method is the varying key)
  note legitimate GET /x -> 200
  ok   the real route still answers 200
  note series after the real request 4, dropped 1
  FAIL a legitimate route/method/class series first seen after a method flood is not dropped
  note final requests 15, series 4, dropped 11
  FAIL the sink recovers: repeated legitimate traffic is counted per series again
checks: 8  failures: 2
BUG REPRODUCED
... exited with code 1
```

- **Is the capacity a documented policy value?** Yes, and that part of the
  design is sound. `metrics.ads:82` declares
  `type In_Memory (Capacity : Positive := 256)` with the comment "Capacity is
  the maximum route/method/status-class series", and
  `website/guide/server/index.html:469` states "The default in-memory metrics
  sink caps route/method/status-class series and reports dropped series rather
  than growing without bound." The finding is therefore **not** about the number
  256. It is about two things the documentation does not cover: that one of the
  three key components is chosen by the peer, and that a filled table is never
  evicted.
- **Description:** `Metric_State.End_Request` (`metrics.adb:54-83`) linearly
  scans `Values (1 .. Value.Series)` for a matching
  `(Route, Method, Status_Class)` triple, appends a new entry while
  `Value.Series < Capacity`, and otherwise increments `Dropped_Series` and
  returns. Nothing in `metrics.adb` ever clears a `Used` entry or reduces
  `Value.Series`, so the table is fill-once for the lifetime of the sink.
  `Route` is bounded, as `metrics.ads:39` states ("Stable route name, never an
  arbitrary raw path"), but `Method` is passed straight from
  `X.Request_Method` at `middleware_metrics.adb:25` and is the token the peer
  sent: HTTP/1 accepts a token of any length (`server.adb:1164-1168`), h2 and h3
  up to 64 bytes (`flyology-http.adb:14`, `To_Method`), and anything at or under
  `Max_Method_Length = 16` becomes a stored key. Every unknown method to an
  existing path is answered 405 through `Run_Automatic`, which runs the metrics
  middleware with `Route_Name = "flyology.method_not_allowed"`, so only the
  method varies. The spike drives a `Capacity => 4` sink through the router with
  four distinct 5-byte method tokens against `/x`; each is a 405 and each
  creates a series. `Series` reaches 4 with `Dropped_Series = 0`. The very next
  request, a legitimate `GET /x` answered 200, is dropped, and so is every
  legitimate request after it: eleven requests counted in `Requests` and none in
  any series. This makes the prior audit's "Metrics cardinality" appendix
  (`review/prior-audit.md:1591-1594`, "a client cannot inflate cardinality") and
  its refutation at `:1626-1628` incorrect for the method key. The existing
  coverage at `tests/http_smoke.adb:3312-3323` asserts `Series = 1` and
  `Dropped_Series > 0`, which pins the bound but never varies the method.
  Standard: not applicable.

---

## ROUTING-MW-5: CORS middleware omits `Vary: Origin` on responses whose CORS headers depend on `Origin` but where none were added

- **Verdict:** CONFIRMED as to behaviour; **the cited standard clause is wrong
  and is corrected below.**
- **Severity:** P2 (discovery said P2; unchanged). Cache-correctness edge case.
  No credential or origin bypass: `Origin_Allowed` is unchanged and nothing is
  reflected to a disallowed origin.
- **Repro:** `tests/repros/src/repro_routing_mw_5.adb`, run with
  `./tests/repros/run.sh repro_routing_mw_5`
- **Output:**

```
  note allowed  ACAO=[https://app.example] Vary=[Origin]
  ok   control: an allowed origin is reflected
  ok   control: the allowed-origin response carries Vary: Origin
  note denied   ACAO=[] Vary=[]
  ok   a disallowed origin is not reflected
  FAIL the disallowed-origin response carries Vary: Origin
  note no-Origin ACAO=[] Vary=[]
  ok   a non-CORS request gets no Access-Control-Allow-Origin
  FAIL the non-CORS response carries Vary: Origin, so a cache cannot reuse it for a later CORS request
checks: 6  failures: 2
BUG REPRODUCED
... exited with code 1
```

### Correction to the cited standard

The discovery entry cites:

> RFC 9110 Section 12.5.5 ("An origin server SHOULD send a Vary header field
> when its algorithm for selecting a representation varies based on aspects of
> the request message other than the method and target URI")

That sentence is **not in RFC 9110**. `grep -c "algorithm for selecting a
representation" rfc9110.txt` returns 0. It is a near-quote of **RFC 7231
Section 7.1.4**, which RFC 9110 obsoletes, and even there the wording is
"method and request target", not "method and target URI":

> "An origin server SHOULD send a Vary header field when its algorithm for
> selecting a representation varies based on aspects of the request message
> other than the method and request target, unless the variance cannot be
> crossed or the origin server has been deliberately configured to prevent
> cache transparency." (RFC 7231 Section 7.1.4)

RFC 9110 Section 12.5.5 replaced it with a weaker, intent-conditioned SHOULD,
and added an explicit escape:

> "An origin server SHOULD generate a Vary header field on a cacheable response
> when it wishes that response to be selectively reused for subsequent
> requests."

> "Vary might be elided when an origin server considers variance in content
> selection to be less significant than Vary's performance impact on caching,
> particularly when reuse is already limited by cache response directives
> (Section 5.2 of [CACHING])."

On RFC 9110 alone the finding would be weak. What RFC 9110 Section 12.5.5 does
establish is the mechanism the finding depends on:

> "To inform cache recipients that they MUST NOT use this response to satisfy a
> later request unless the later request has the same values for the listed
> header fields as the original request (Section 4.1 of [CACHING]) or reuse of
> the response has been validated by the origin server. In other words, Vary
> expands the cache key required to match a new request to the stored cache
> entry."

### The correct normative source

CORS is specified by the WHATWG Fetch Standard, not by RFC 9110. Its section
"CORS protocol and HTTP caches" states the requirement and then describes this
exact failure:

> "If CORS protocol requirements are more complicated than setting
> `Access-Control-Allow-Origin` to * or a static origin, `Vary` is to be used."

> "In particular, consider what happens if `Vary` is not used and a server is
> configured to send `Access-Control-Allow-Origin` for a certain resource only
> in response to a CORS request. When a user agent receives a response to a
> non-CORS request for that resource (for example, as the result of a
> navigation request), the response will lack `Access-Control-Allow-Origin` and
> the user agent will cache that response. Then, if the user agent subsequently
> encounters a CORS request for the resource, it will use that cached response
> from the previous non-CORS request, without `Access-Control-Allow-Origin`."

> "However, if `Access-Control-Allow-Origin` is set to * or a static origin for
> a particular resource, then configure the server to always send
> `Access-Control-Allow-Origin` in responses for the resource - for non-CORS
> requests as well as CORS requests - and do not use `Vary`."

Fetch offers exactly two conforming configurations. Flyology's non-preflight
CORS path matches neither: for a non-wildcard policy it emits `Vary: Origin`
when the origin is allowed, and emits neither `Access-Control-Allow-Origin` nor
`Vary` when the request has no `Origin` or an origin that is not allowed. That
is the un-`Vary`-ed, conditionally-ACAO'd shape the second quote above warns
against, and `Allowed_Origins` accepts a list, which puts the policy in the
first quote's "more complicated than ... a static origin" case.

- **Description:** `Middleware_CORS.Add_Origin` (`middleware_cors.adb:16-29`) is
  the only place that emits `Vary: Origin`, and it emits it only for a
  non-wildcard policy. `Call` returns before reaching it on three paths: no CORS
  slot or no `Origin` field (`:40-43`), a non-preflight request whose origin is
  not allowed (`:53-61`), and a non-preflight request whose method the policy
  does not allow (`:92-95`). The spike registers `GET /data` with a two-origin,
  non-wildcard policy and issues three requests. `Origin: https://app.example`
  produces `Access-Control-Allow-Origin: https://app.example` and
  `Vary: Origin`. `Origin: https://evil.example` and a request with no `Origin`
  at all each produce a cacheable 200 with neither field. A shared cache stores
  the no-`Origin` copy under a key that ignores `Origin`, and a later
  `fetch()` from `https://app.example` is served that copy; the browser then
  fails the CORS check on a response the server would have allowed. **Cache
  behaviour itself is not checkable from a spike** - no cache is in the loop -
  so the reproduction establishes only the emitted field set, which is the part
  the server controls. The preflight path is already correct and the guide's
  claim at `website/guide/server/index.html:438` that preflights "emit the
  required Vary fields" holds; this is the non-preflight path. Existing coverage
  (`tests/http_routing_audit.adb:1109-1111`, `tests/http_smoke.adb:3256-3257`)
  asserts `Vary: Origin` on the allowed path only.

---

## Notes on method

- Every spike drives the server through an in-memory
  `Flyology.HTTP.Server.Transport` copied from
  `tests/http_routing_audit.adb:103-159`, except `repro_routing_mw_3`, which
  needs a real HTTP/2 connection and uses the raw-frame peer pattern from
  `tests/http2_server_audit.adb`.
- `repro_routing_mw_3` binds its loopback listener with
  `Sockets.Any_Port` and reads the assigned port back with
  `Sockets.Get_Socket_Name`, as `tests/http2_server_audit.adb:465-469` does,
  rather than through `Repro_Support.Ephemeral_Port`. This is a deliberate
  deviation from the brief's wording: it serves the same purpose (no fixed port,
  so no collision with the maintained suites) and additionally closes the
  bind/connect race that `Ephemeral_Port` leaves open.
- `repro_smoke` and `seam_check` were re-run after the last spike build and
  both still PASS (exit 0).
- The green baselines were checked before confirming: h2spec's 8.1.2.3 case list
  is quoted above and does not cover ROUTING-MW-3. ROUTING-MW-1, -2, -4 and -5
  are all behaviours no maintained suite exercises, as each entry's "existing
  coverage" note records.
