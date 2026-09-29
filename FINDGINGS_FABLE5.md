# Flyology HTTP Audit — Findings

Date: 2026-08-07. Multi-agent audit of ~28k lines of Ada across `src/` plus the ~3.7k-line
`flyology_iri` URI/IRI/URL crate, partitioned into six subsystem reviews (HTTP/1.x message
parsing and framing, HTTP/2 frames/HPACK/Huffman/connection state, server routing and
middleware, HTTP client and connection pool, WebSocket and SSE, URL/IRI parsing). Candidate
findings were checked against the source before being recorded, and the most severe were
independently re-verified line by line. The `flyology_iri` crate was built and driven with
purpose-written differential and stress harnesses, so its findings rest on program output rather
than reading — which mattered: finding 1 and finding 20 were both located only after a binary
contradicted the traced control flow. Refuted candidates are listed in the appendix with the
reason they were rejected.

**Confirmed: 43** (1 critical, 9 high, 12 medium, 21 low).

Severity reflects impact if triggered, weighted by reachability. "Critical" extends the parent
repository's high/medium/low scale for one finding that silently redirects traffic to an
attacker-registrable host.

Each finding records how it was checked. **Verified** means I confirmed it directly against the
source, and where stated by executing it. **Reviewed** means it rests on a subsystem reviewer's
reading of cited code that I did not independently re-derive; those are listed in the coverage
gaps and should be reproduced before remediation.

## Contents

1. **[CRITICAL]** RFC 3986 path merge drops the base's root slash, so resolving a relative reference yields a different host — `flyology_iri/src/flyology_iri.adb:1325`
2. **[HIGH]** `Raw_Path` scans for `://` across the whole request target, so a query parameter overrides the routed path — `src/flyology-http-server-routing.adb:90`
3. **[HIGH]** HTTP/2 `:authority` is spliced unvalidated into the request header block, injecting arbitrary headers — `src/flyology-http-server-http_2.adb:1833`
4. **[HIGH]** SSE event name, id, and comment are injectable on the HTTP/2 backend, which drops the HTTP/1.1 validation — `src/flyology-http-server-http_2.adb:1636`
5. **[HIGH]** `Diagnose` is a third, non-WHATWG validator that disagrees with `Parse` on ~30% of inputs — `flyology_iri/src/flyology_iri.adb:735`
6. **[HIGH]** `Expect: 100-continue` with a suppressed body returns an incomplete HTTP/1.1 message's connection to the pool — `src/flyology-http-client.adb:994`
7. **[HIGH]** DATA on a closed or half-closed-remote stream is never charged to the connection flow-control window — `src/flyology-http-server-http_2.adb:562`
8. **[HIGH]** `Release_Stream` never resets `Receive_Window`, so a reused stream slot inherits a window deficit — `src/flyology-http-server-http_2.adb:1246`
9. **[HIGH]** HPACK dynamic table desynchronizes after a stream-level field-section error — `src/flyology-http-http_2_hpack.adb:494`
10. **[HIGH]** Pool `Wait_Source` availability predicate diverges from `Try_Checkout`, spinning past the deadline and cancellation token — `src/flyology-http-client-pool_controller.adb:470`
11. **[MEDIUM]** The `Authenticate` hook returns its decision through an `out Boolean`, which fails open on an unassigned path — `src/flyology-http-server-middleware_authentication.ads:18`
12. **[MEDIUM]** Buffered-body ingress is reserved at the declared or maximum size and held for the whole slow read — `src/flyology-http-server.adb:1449`
13. **[MEDIUM]** IDNA performs no validity, bidi, joiner, or Punycode-decode checking; `xn--` labels pass through unvalidated — `flyology_iri/src/flyology_iri-idna.adb:219`
14. **[MEDIUM]** `Release_Stream` never clears `Continuation_Slot`, permanently freezing all connection output — `src/flyology-http-server-http_2.adb:1246`
15. **[MEDIUM]** CONTINUATION is accepted outside an open field section and its residue prepends the next header block — `src/flyology-http-server-http_2.adb:2108`
16. **[MEDIUM]** HTTP/2 `:path` is never validated for control bytes, unlike the HTTP/1 target — `src/flyology-http-server-http_2.adb:1973`
17. **[MEDIUM]** Rate-limit and bulkhead middleware silently deny every request for route names longer than 128 characters — `src/flyology-http-server-middleware_rate_limits.adb:46`
18. **[MEDIUM]** Bodyless-by-status responses are pooled without confirming the transport is quiescent — `src/flyology-http-client-http_1_internals.adb:657`
19. **[MEDIUM]** A `Text_Frame` payload is admitted without UTF-8 validation, then destroys the connection when sent — `src/flyology-http-server-websocket_handlers.adb:180`
20. **[MEDIUM]** URL host validity depends on letter case: a fast path bypasses the DNS-length checks the slow path enforces — `flyology_iri/src/flyology_iri.adb:980`
21. **[MEDIUM]** `Can_Parse` returns True for input `Parse` rejects as `Too_Long` — `flyology_iri/src/flyology_iri.adb:864`
22. **[MEDIUM]** The WPT URL conformance suite never runs in CI — `flyology_iri/scripts/test.sh:9`
23. **[LOW]** `Current_Is_Head` is not reset per request, so a rejected request on a reused connection gets a `Content-Length` with no body — `src/flyology-http-server.adb:1157`
24. **[LOW]** Repeated `Cookie` request headers are comma-joined, corrupting every cookie value — `src/flyology-http-server.adb:359`
25. **[LOW]** Percent-decoded query values may contain NUL and control bytes, unlike decoded paths — `src/flyology-http-server-requests.adb:18`
26. **[LOW]** `Access-Control-Allow-Origin: *` with `Allow-Credentials: true` is reachable when `*` is a member of the origin list — `src/flyology-http-server-cors.adb:24`
27. **[LOW]** 404/405/OPTIONS/redirect responses bypass per-route rate limiting and concurrency — `src/flyology-http-server-routing.adb:830`
28. **[LOW]** `Add_Header` is append-only, so a handler cannot override middleware security headers — `src/flyology-http-server-applications.adb:296`
29. **[LOW]** Default request IDs are a single global monotonic counter, echoed to the client — `src/flyology-http-server-middleware_request_ids.adb:6`
30. **[LOW]** Middleware added to a subrouter after `Mount` silently does not protect the mounted routes — `src/flyology-http-server-routing.adb:627`
31. **[LOW]** HTTP/2 `:path: *` with a non-OPTIONS method reaches a parameterized route — `src/flyology-http-server-http_2.adb:1973`
32. **[LOW]** The router's fallback 401 hardcodes `WWW-Authenticate: Bearer`, ignoring the configured challenge — `src/flyology-http-server-routing.adb:742`
33. **[LOW]** DATA and WINDOW_UPDATE on an idle stream report FLOW_CONTROL_ERROR instead of PROTOCOL_ERROR — `src/flyology-http-server-http_2.adb:2136`
34. **[LOW]** `Close_WebSocket` silently drops back to the 1 MiB default message limit during the close handshake — `src/flyology-http-server.adb:3605`
35. **[LOW]** `WebSocket_Reserved` is write-only dead connection state — `src/flyology-http-server.ads:679`
36. **[LOW]** Intermediate redirect bodies are drained with no byte bound — `src/flyology-http-client.adb:1410`
37. **[LOW]** The global pool lock is held across each HTTP/2 session lock — `src/flyology-http-client-pool_controller.adb:36`
38. **[LOW]** No policy hook to reject loopback, link-local, or private connect targets — `src/flyology-http-client-exchange_internals.adb:120`
39. **[LOW]** `Valid_IPv4`'s `WHATWG` parameter is dead, so RFC 3986 `dec-octet` leading zeros are accepted — `flyology_iri/src/flyology_iri.adb:460`
40. **[LOW]** `IRI_Syntax` accepts any well-formed UTF-8, not RFC 3987 `ucschar`/`iprivate` — `flyology_iri/src/flyology_iri.adb:388`
41. **[LOW]** Web-mode parse failures collapse to `Invalid_Character` at offset 0, discarding the documented error categories — `flyology_iri/src/flyology_iri.adb:1011`
42. **[LOW]** A failed `Try_Parse` is indistinguishable from a successful parse of `""` and reports the wrong `Syntax` — `flyology_iri/src/flyology_iri.adb:1010`
43. **[LOW]** The `flyology_iri` release profile suppresses runtime checks with no proof discharging them — `flyology_iri/flyology_iri.gpr:21`

---

## 1. RFC 3986 path merge drops the base's root slash, so resolving a relative reference yields a different host

- **Severity:** critical
- **Category:** host-confusion / ssrf
- **Subsystem:** `flyology_iri` reference resolution
- **Location:** `flyology_iri/src/flyology_iri.adb:1325` (helper at `:1203`)
- **Verification:** verified by execution

`Resolve`'s implementation of the RFC 3986 §5.2.3 *merge* step removes the base's last segment
with `Remove_Last_Segment`, which strips the separator along with the segment, and then
re-appends `'/'` only when the remainder is non-empty. When the base path's only slash is its
leading one — `"/"` or `"/x"`, i.e. any site-root or single-segment base — the prefix becomes
`""`, the guard suppresses the slash, and the relative path is concatenated directly onto the
authority. RFC 3986 requires excluding the characters *after* the right-most `/` while retaining
the `/` itself.

```ada
Unbounded.Set_Unbounded_String (Prefix, Path (Base));
Remove_Last_Segment (Prefix);
if Unbounded.Length (Prefix) > 0 then     --  suppresses the required '/'
   Unbounded.Append (Prefix, '/');
end if;
```

Measured against a program linked directly to the built library:

```
base=http://good.com/   rel=index.html  -> http://good.comindex.html   host=[good.comindex.html]
base=http://good.com/x  rel=evil.com/   -> http://good.comevil.com/    host=[good.comevil.com]
base=http://good.com/x  rel=../up       -> http://good.comup           host=[good.comup]
base=http://good.com/x  rel=./same      -> http://good.comsame         host=[good.comsame]
base=http://good.com/a/b rel=c.html     -> http://good.com/a/c.html    host=[good.com]      (correct)
base=http://a/b/c/d;p?q  rel=g          -> http://a/b/c/g              host=[a]             (correct)
```

**Failure scenario.** 1) An application holds a trusted base — a site root such as
`http://good.com/`, the single most common base form there is — and resolves a relative
reference taken from a redirect `Location`, an HTML link, a sitemap, or a config value. 2) The
attacker supplies `evil.com/`. 3) `Resolve` returns a reference whose `Host` is
`good.comevil.com` — a domain the attacker can register — while the base's authority was never
changed by the input, so nothing in the application's reasoning suggests the host could move. 4)
Any subsequent connect, origin check, or allowlist comparison keyed on `Host` or `Origin` is
pointed at attacker infrastructure. The bug is not confined to hostile input: the entirely benign
`http://good.com/` + `index.html` also yields the garbage host `good.comindex.html`, so this is
simultaneously a total functional break of the most common resolution case.

**Verification notes.** I confirmed the defect by reading (`Remove_Last_Segment` maps both `"/"`
and `"/x"` to `""`, and the `Length > 0` guard then skips the slash) and then by building and
running a program against the library, output above. The reason this survived: the complete
RFC 3986 §5.4.1 + §5.4.2 suite — 42 cases — passes, because every case uses the base
`http://a/b/c/d;p?q`, whose path has an interior slash, so `Prefix` is non-empty and the bug is
masked. `flyology_iri_tests.adb:39` hard-codes exactly that base, and `Check_Resolution` is the
only resolution test in the crate. `Remove_Dot_Segments` itself is correct, verified branch by
branch and by that passing suite, so the defect is solely in the merge step.
`Remove_Last_Segment`'s slash-excluding behaviour is *correct* for its two other call sites
(`:1249`, `:1253`), so the fix belongs at the `:1325` guard, not in the helper. Also affects
`IRI_Syntax`: base `https://例え.テスト/x` + `evil.テスト/p` → host `例え.テストevil.テスト`.

---

## 2. `Raw_Path` scans for `://` across the whole request target, so a query parameter overrides the routed path

- **Severity:** high
- **Category:** routing / authorization bypass
- **Subsystem:** Server routing
- **Location:** `src/flyology-http-server-routing.adb:90` (consumed at `:778`, `:790`, `:847`, `:950`)
- **Verification:** verified; independently reported by two reviewers

`Raw_Path` decides between origin form and absolute form with an *unanchored*
`Index (Target, "://")`. Since `:` is a legal `pchar` and query strings routinely carry URLs, an
origin-form target containing `://` anywhere is re-parsed as `scheme://authority/path`, and the
"path" is taken from after the next `/`. Route selection, `X.Path`, and the whole route policy —
authentication mode, body policy, CORS, rate limit — are all driven by that wrong path.

```ada
Scheme : constant Natural := Ada.Strings.Fixed.Index (Target, "://");
begin
   if Target = "*" then
      return "*";
   elsif Scheme /= 0 then
      Start := 0;
      for Index in Scheme + 3 .. Target'Last loop
         if Target (Index) = '/' then
            Start := Index;
            exit;
```

The `?` guard inside that loop (`:100`) only fires when the `?` follows the `://`; in the attack
it precedes it and is never examined.

| request-target on the wire | `Raw_Path` result |
|---|---|
| `/public?x=a://b/admin/users` | `/admin/users` |
| `/admin/users?x=a://b/public` | `/public` |
| `/callback?redirect_uri=https://app.example.com/done` | `/done` |
| `/search?q=https://example.com` | `/` |

**Failure scenario.** 1) An edge proxy, WAF, or ingress rule authorizes `/public/*` and blocks
`/admin`. 2) The attacker sends `GET /public?x=a://b/admin/users HTTP/1.1`. 3) The proxy
authorizes on the request-line path `/public`. 4) `Validate_Target_And_Authority`
(`src/flyology-http-server.adb:674`) accepts the target as origin form purely because it begins
with `/`, and runs no absolute-form parsing. 5) `Raw_Path` returns `/admin/users`, the router
dispatches the admin handler, and `X.Path` agrees with the wrong path while the wire target says
`/public`.

**Verification notes.** I confirmed both halves in the source rather than relying on either
reviewer's extracted copy. The parser side is decisive: `server.adb:674` is
`elsif Request_Target (Request_Target'First) = '/' then null;`, and the absolute-form branches at
`:676`-`:685` only trigger when the target *starts* with `http://` or `https://`. The two other
places that classify absolute form — `Validate_Target_And_Authority:676` and
`Requests.Authority:212` — both use *anchored* prefix tests, so `Raw_Path` is the only unanchored
one, which is precisely why the layers disagree. Beyond the ACL bypass this unconditionally
misroutes ordinary URLs: `?redirect_uri=https://…` and `?url=http://…` are dispatched to `/done`
or `/`, and `?u=http://x/../y` yields `/../y`, which `Decode_Path` turns into a 400 on a
legitimate request. That a pattern this common breaks is strong evidence the unanchored search is
unintended. HTTP/2 is affected identically because `:path` becomes `Target_Value` verbatim
(`src/flyology-http-server-http_2.adb:1820`). The open-redirect variant is *not* reachable —
`Decode_Path` rejects `//`, so `/x?a=b:////evil.com/y` is a 400 — so this is route confusion, not
open redirect. `tests/http_smoke.adb:2231` covers `?next=/../` (no `://`) and `:2228` a genuine
absolute-form target; no test places `://` inside a query string.

---

## 3. HTTP/2 `:authority` is spliced unvalidated into the request header block, injecting arbitrary headers

- **Severity:** high
- **Category:** injection / request-smuggling
- **Subsystem:** HTTP/2 server
- **Location:** `src/flyology-http-server-http_2.adb:1833`
- **Verification:** verified

HPACK returns pseudo-header values as raw octets with no character filtering, and
`Start_Handler` concatenates `:authority` into `Request.Header_Block` — a buffer the application
layer re-parses as CRLF-delimited `Name: Value` lines. Regular fields are validated by
`Flyology.HTTP.Headers.Add`; pseudo-headers never pass through it.

```ada
if Authority /= ""
  and then Flyology.HTTP.Headers.Count (Fields, "host") = 0
then
   Append
     (Backend.Request_Value.Header_Block,
      "Host: " & Authority & CRLF);
end if;
```

**Failure scenario.** 1) The attacker sends HEADERS on stream 1 with `:method: GET`,
`:scheme: http`, `:path: /`, no `host` field, and `:authority` whose octets are `localhost` CR LF
`Transfer-Encoding: chunked`. 2) `Decode_Request` accepts it — the `:authority` branch assigns
the value with no octet check. 3) `Process_Header_Block` accepts it, since its only checks are
non-empty and "no conflict with a `host` field", and the attack supplies no `host` field. 4)
`Start_Handler` produces `Header_Block = "...Host: localhost\r\nTransfer-Encoding: chunked\r\n"`.
5) `Request.Header (X, "transfer-encoding")` (`src/flyology-http-server.adb:359`) splits that
block on CRLF and returns `"chunked"` — a field HPACK exists specifically to reject as
connection-specific. The same vector injects a second `Host:` line, defeating the single-Host
check, or a `Content-Length` the framework's own parser never saw.

**Verification notes.** Confirmed both halves. At `src/flyology-http-http_2_hpack.adb:507`-`528`
the four pseudo-header values are assigned raw, while only the regular-field branch at `:545`
calls `Headers.Add`, whose validation rejects NUL/CR/LF (`src/flyology-http-headers.adb:22`).
That `:method` is guarded by `To_Method` and `:scheme` by a `"http" | "https"` check while
`:authority` is unguarded indicates an omission. `Validate_Header_Block` (`server.adb:473`) would
catch this, but its only call sites are `:1045` and `:1267`, both HTTP/1.x. The host-mismatch
branch cannot save it: it requires a `host` header, and the attack requires its absence.
`tests/http2_server_peer.py` only ever sends `:authority = "localhost"`.

---

## 4. SSE event name, id, and comment are injectable on the HTTP/2 backend, which drops the HTTP/1.1 validation

- **Severity:** high
- **Category:** injection
- **Subsystem:** SSE / HTTP/2 server
- **Location:** `src/flyology-http-server-http_2.adb:1636` (`Send_Event`) and `:1699` (`Send_SSE_Comment`)
- **Verification:** reviewed

The HTTP/1.1 SSE writer validates `Event` and `Id` for embedded newlines and validates UTF-8
before serializing. The HTTP/2 `Stream_Backend` re-implements the same serialization and drops
every one of those checks, so a newline inside `Event`, `Id`, or a comment is written verbatim
into the `text/event-stream` body and becomes new SSE fields or events.

HTTP/1.1 (`src/flyology-http-server.adb:2090`):

```ada
Validate_SSE_Field (Event, "SSE event name");
Validate_SSE_Field (Id, "SSE id");
if not Valid_UTF8 (Data) or else not Valid_UTF8 (Event) ... then
   raise Program_Error with "SSE fields must contain valid UTF-8";
```

HTTP/2 (`src/flyology-http-server-http_2.adb:1650`):

```ada
if Event /= "" then
   Append (Payload, "event: " & Event & Character'Val (10));
end if;
if Id /= "" or else Include_Id then
   Append (Payload, "id: " & Id & Character'Val (10));
end if;
```

**Failure scenario.** 1) A route registered with `Allow_SSE` is served with
`Mode => ALPN_Negotiated` or `HTTP_2_Only`. 2) A producer publishes an event whose `Event` name
derives from the request — a query parameter, a path segment, or an echoed `Last-Event-ID`, which
the showcase reads at `showcases/http_application_server.adb:1175`. 3) The attacker supplies
`tick` LF `data: {"role":"admin"}`. 4) The stream body becomes two `data:` lines under the `tick`
event, so the victim's `EventSource` `tick` listener receives attacker-chosen JSON; `"a"` LF LF
`"event: b"` splits one event into two. The identical call over HTTP/1.1 raises `Program_Error`
before a byte is written — the vulnerability is purely a function of which transport the same
route is served on.

**Verification notes.** Reviewed. The reviewer confirmed the absence of compensating validation
at every layer above: `Applications.Send_SSE` (`applications.adb:578`) merely dispatches to the
attached backend, `exchange_backends.ads:155`-`174` documents no precondition on `Event`/`Id`,
and `SSE_Handlers` performs only size checks. No test exercises SSE over HTTP/2. The HTTP/2
engine arrived in the most recent commit `33b5705`, so this is a fresh regression from
duplicating the serializer without its guards — which also means the two implementations should
be unified rather than separately patched.

---

## 5. `Diagnose` is a third, non-WHATWG validator that disagrees with `Parse` on ~30% of inputs

- **Severity:** high
- **Category:** spec-deviation / host-confusion / api-safety
- **Subsystem:** `flyology_iri` URL parser
- **Location:** `flyology_iri/src/flyology_iri.adb:735` (also `:594`, `:840`)
- **Verification:** reviewed (measured by reviewer)

`Web_URL_Syntax` has three independent implementations: `Can_Parse` uses `Fast_Can_Parse_Web` or
`Web.Parse`; `Parse`/`Try_Parse` use `Fast_Web_Analysis` or `Web.Parse`; `Diagnose` uses
`Analyze` *only*. `Analyze` skips WHATWG preprocessing — no tab/LF/CR stripping — and skips host
validation entirely in web mode, so it accepts hosts containing space, CR, LF, `\`, and an
unbracketed `[`. The specification asserts the opposite: `flyology_iri.ads:74` documents
`Can_Parse` as returning "True exactly when `Diagnose` reports `No_Error`".

```ada
if Syntax /= Web_URL_Syntax then   --  host character validation skipped for web
   Check := Validate_Range (Input, Host_First, Host_Last, Syntax, 'h');
```

| input | `Diagnose` | `Can_Parse` | `Parse` |
|---|---|---|---|
| `http://exa mple.com/` | `NO_ERROR` | `False` | rejected |
| `http://good.com<CR><LF>evil/` | `NO_ERROR` | `True` | host `good.comevil` |
| `http://good.com\evil.com/` | `NO_ERROR` | `True` | host `good.com`, path `/evil.com/` |
| `http:///foo` | `INVALID_AUTHORITY` | `True` | host `foo` |

**Failure scenario.** A validate-then-use pipeline — `if Diagnose (S, Web_URL_Syntax).Kind = No_Error then Send (S);`
— accepts `http://good.com<CR><LF>evil/`, a CR/LF-bearing host string blessed as a valid web URL,
and `Diagnose`'s own span model attributes the host as `good.com\r\nevil` while `Parse` and a
browser both say `good.comevil`. Equally, `Diagnose` calls `http://good.com\evil.com/` valid with
host span `good.com\evil.com`, where WHATWG and this crate's own `Parse` say host `good.com`.
Because the documented contract says the two agree, a caller has no reason to re-check.

**Verification notes.** Reviewed. The reviewer ran a differential over 300 000 `http://`-prefixed
random inputs and measured 70 699 cases where `Diagnose` reported `No_Error` but `Try_Parse`
failed, plus 20 790 in the opposite direction — roughly 30% disagreement. The 919-case WPT claim
in `README.md` cannot cover this: `tests/wpt_conformance.py` and the CLI only ever call `Parse`,
never `Diagnose` or `Can_Parse`, and `flyology_iri_tests.adb` calls `Diagnose` with
`Web_URL_Syntax` exactly once, on a case that never reaches host analysis. Related dead code
worth removing in the same change: `Normalize_Web` (`:890`-`925`), the only web normalizer built
on `Analyze`, is unreachable because `Try_Parse` returns unconditionally for `Web_URL_Syntax`
before reaching it. Four parallel implementations of one grammar — two fast paths, `Analyze`, and
`Web.Parse` — are the structural root of findings 5, 20, and 21; each pair needs a differential
harness in the suite.

---

## 6. `Expect: 100-continue` with a suppressed body returns an incomplete HTTP/1.1 message's connection to the pool

- **Severity:** high
- **Category:** pool-desync
- **Subsystem:** HTTP client
- **Location:** `src/flyology-http-client.adb:994`
- **Verification:** verified

When a `100-continue` exchange receives a final response before the body is transmitted, the
client skips sending the body but still returns the transport to the pool as reusable. The
request head already declared `Content-Length: N` or `Transfer-Encoding: chunked`, so the server
is still mid-message. Only the 417 retry path closes the connection; `Select_Body_Mode` decides
reusability from response headers alone and never consults whether the body was sent.

```ada
if Data.Mode = No_Body then
   if Length (Data.Pending) > 0 then
      Data.Reusable := False;
   end if;
   Release_Lease (Data, Data.Reusable);
end if;
```

**Failure scenario.** No malice required. 1) The client sends `POST /upload` with
`Expect: 100-continue` and `Content-Length: 1000`. 2) The server rejects on headers with
`HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n` — a 401/403/413 without a close token is
routine. 3) The client returns the 401 and marks the slot idle. 4) The next `Execute` reuses it
and writes `GET /secret HTTP/1.1` with an `Authorization` header. 5) The server consumes those
bytes as the first 1000 octets of the previous POST's body — the credentialed request line and
Authorization header are fed to whatever the upload endpoint does with its payload — then blocks
awaiting the rest. The caller sees a hang or another request's response.

**Verification notes.** I confirmed the reviewer's most surprising claim: the test suite codifies
the reuse rather than catching it. In `tests/http_client_upload_controls_smoke.adb` the server
script does `Expect_Head_Only ("/reject", Head); Send_Empty ("401 Unauthorized");` then
immediately `Expect_Head_Only ("/fallback", Head)` on the same peer socket with no intervening
`Accept_Peer`, while the client asserts `Source.Reads = 0 and then Source.Position = 0` (`:461`)
— body never sent, connection reused. The test server never tracks `Content-Length`, so it never
notices the incomplete message a real server would block on. The 417 branch does force a close,
showing the hazard was understood for that one status; the hole remains for a 417 arriving when
the retry is disallowed (already retried, or deadline exhausted), where the connection is pooled.

---

## 7. DATA on a closed or half-closed-remote stream is never charged to the connection flow-control window

- **Severity:** high
- **Category:** flow-control
- **Subsystem:** HTTP/2 server
- **Location:** `src/flyology-http-server-http_2.adb:562`
- **Verification:** verified

Both closed-stream paths in `Publish_Data` emit RST_STREAM and return *before* the window
accounting at `:578`, so the bytes are neither deducted from `Connection_Receive_Window` nor
returned as credit. The peer has already debited its connection send window for them, so the two
sides diverge permanently and no WINDOW_UPDATE can compensate.

```ada
if Index = 0 then
   if Stream_ID /= 0 and then Stream_ID <= Last_Client_Stream then
      Queue_Control_Frame (...Stream_Closed_Error...);
      Accepted := True;
   end if;
   return;
elsif Streams (Index).Remote_End then
   Queue_Control_Frame (...Stream_Closed_Error...);
   Accepted := True;
   return;
end if;
```

**Failure scenario.** 1) A client POSTs a 1 MB body on stream 1. 2) The handler raises, so
`Mark_Failed` sets `Remote_End := True` and sends RST_STREAM. 3) The remaining in-flight 16 KiB
DATA frames each take the `Remote_End` branch — RST_STREAM again, `Accepted := True`, zero window
accounting. 4) The client has debited 1 MB from its 65 535-byte connection send window and gets
no WINDOW_UPDATE for it, so after roughly the first 65 KB it is blocked forever on *every* stream
of that connection, idling until `Max_Connection_Age` (default 300 s).

**Verification notes.** I confirmed the asymmetry by enumerating every `Receive_Window` and
`Connection_Receive_Window` assignment in both engines. In the server the only consumption is at
`:578`-`:587`, after the early returns above. The client handles the same case correctly —
`src/flyology-http-http_2_client_connection.adb:866`-`877` consumes the connection window and
returns credit for `Index = 0` — which is the strongest available evidence the server's omission
is an oversight. `Mark_Failed`, `Reset_Stream` and `Reject_Stream` do call
`Return_Connection_Credit (Retained_Input)`, but only for bytes already charged and still
buffered. The `Discarding` and 413 paths credit correctly, narrowing this to the closed-stream
paths. The relevant test (`tests/http2_server_peer.py:186`-`192`) sends DATA *then* RST_STREAM —
the case the retained-input code already handles — and never sends DATA after close.

---

## 8. `Release_Stream` never resets `Receive_Window`, so a reused stream slot inherits a window deficit

- **Severity:** high
- **Category:** flow-control
- **Subsystem:** HTTP/2 server
- **Location:** `src/flyology-http-server-http_2.adb:1246`
- **Verification:** verified

`Stream_Record.Receive_Window` is initialized once by its record default and thereafter only
decremented by `Consume` and incremented by flushed credit. Neither `Release_Stream` nor
`Open_Request` resets it, so a slot reused for a new stream starts with the previous stream's
residual window while the peer legitimately assumes `SETTINGS_INITIAL_WINDOW_SIZE`.
`Release_Stream` resets some twenty other fields; this one is absent.

**Failure scenario.** 1) A client opens stream 1 with `content-length: 16000` and sends
16 000 bytes, leaving `Receive_Window = 384`. 2) The client sends RST_STREAM; `Reset_Stream`
returns connection credit only, and `Release_Stream` discards `Pending_Receive_Credit` while
leaving `Receive_Window` at 384. 3) The slot is reaped. 4) The client opens stream 3, which lands
in the same now-free slot, and sends a legal 1 000-byte DATA frame — legal because stream 3's
window is 16 384 per SETTINGS. 5) `Consume (384, 1000)` fails and `Process_Frame` escalates to
`Protocol_Failure (Flow_Control_Error)` — GOAWAY, killing every other concurrent stream. A client
cancelling an upload, an ordinary event, poisons a slot; enough cancellations poison all of them.

**Verification notes.** Confirmed by direct comparison of the two engines. The server's only
`Streams (Index).Receive_Window :=` assignments are at `:455` (credit flush) and `:587`
(consume); there is no reset anywhere. The client performs exactly the missing reset inside
`Clear_Stream` (`http_2_client_connection.adb:463`). The read and discard paths force a credit
flush when `Remote_End`, but `Reset_Stream`, `Reject_Stream` and `Mark_Failed` deliberately skip
stream credit — correct for a closed stream — and nothing compensates at reuse. No test exercises
slot reuse after a mid-upload reset.

---

## 9. HPACK dynamic table desynchronizes after a stream-level field-section error

- **Severity:** high
- **Category:** hpack
- **Subsystem:** HTTP/2 server
- **Location:** `src/flyology-http-http_2_hpack.adb:494`
- **Verification:** reviewed (structure verified)

`Decode_Request` raises `Invalid_Request_Fields` or `Header_List_Too_Large` from the middle of its
representation loop, abandoning the rest of the field block. The server handles both as *stream*
errors — RST_STREAM, connection survives — so every remaining
literal-with-incremental-indexing representation in that block is never inserted into the
connection-scoped dynamic table, while the peer's encoder table has them. HPACK state is
per-connection, so the tables stay divergent for the connection's life.

**Failure scenario.** 1) One HEADERS frame whose block is, in order: literal-with-incremental
`:method: GET`; literal-with-incremental `foo: bar`; literal-*without*-indexing `:path: /`;
literal-with-incremental `baz: qux`. 2) The third is a pseudo-header after a regular field, so
`Decode_Request` raises and never reaches the fourth. 3) The client's encoder table holds
`[baz: qux, foo: bar, :method: GET]`; the server's holds `[foo: bar, :method: GET]`. 4) The
server RST_STREAMs stream 1 and keeps the connection. 5) The client's next request emits indexed
field 62 meaning `baz: qux`; the server resolves it to `foo: bar` and processes a request
containing a field the client never sent, with no error. With a wider offset the index falls past
the table and raises `Compression_Error`, killing the whole multiplexed connection over one
malformed request that RFC 9113 §8.8 requires to be stream-scoped.

**Verification notes.** I verified the structural preconditions: the raise sites are inside the
single representation loop with insertion at its tail, so an abandoned block leaves later
insertions unperformed, and `HPACK.Reset` has no call site in
`src/flyology-http-server-http_2.adb` — `Reject_Header_Block` only calls `Reject_Stream` and
`Clear_Header_Block`. There is no second drain pass. I did not construct the byte-level block and
observe the divergence on a running server, so the index arithmetic rests on the reviewer's
derivation. The HPACK smoke test only asserts that malformed blocks raise; it never decodes a
subsequent block on the same decoder.

---

## 10. Pool `Wait_Source` availability predicate diverges from `Try_Checkout`, spinning past the deadline and cancellation token

- **Severity:** high
- **Category:** dos
- **Subsystem:** HTTP client pool
- **Location:** `src/flyology-http-client-pool_controller.adb:470`
- **Verification:** reviewed

`Try_Checkout` leases an HTTP/2 slot only when `H2_Connections.Can_Open` is true, but
`Wait_Source` reports "checkout possible" using only
`Active_Streams < Maximum_Concurrent_Streams` (32). When the peer's
`SETTINGS_MAX_CONCURRENT_STREAMS` is below 32 the two disagree and `Checkout` alternates between
them without ever blocking. Because the deadline and the cancellation token FD are honoured only
inside `Wait_Any`, which is never reached, both are ignored.

**Failure scenario.** 1) The server sends `SETTINGS_MAX_CONCURRENT_STREAMS = 0` after answering
the first request — legal per RFC 9113 §5.1.2, and applied verbatim with no validation
(`src/flyology-http-http_2_settings.adb:52`). 2) `Is_Usable` stays true, so the slot remains
`Shared` with `Active_Streams = 0`. 3) Every subsequent `Execute` cycles
`Try_Checkout` → `Checkout_Busy` → `Wait_For_Pool` → ready → `Try_Checkout` → … 4) The call never
returns, saturates a core, and ignores both `Timeout => 30.0` and a requested cancellation token;
only `Shutdown` from another task breaks it. The milder variant — any server advertising a limit
below 32 — hot-spins for the duration of the in-flight streams, contending for the very session
lock the pump task needs to free capacity.

**Verification notes.** Not independently re-derived. It rests on the reviewer's reading of the
two cited predicates, the absence of a deadline check on the ready path in `Wait_For_Pool`, and
the absence of any backoff in the `Checkout` loop (`exchange_internals.adb:311`-`373`). The
reviewer notes that the `Available_After` bookkeeping at `pool_controller.adb:143`-`157` *does*
include `Can_Open`, which is why the wake is consumed and the waiter has nothing to block on.
`tests/http_client_pool_races.adb` is HTTP/1-only; the HTTP/2 `"peer-capacity"` scenario with
`MAX_CONCURRENT_STREAMS: 1` reaches the spin but passes because the first stream finishes quickly
and nothing asserts on blocking or CPU. Given the severity, reproduce this before remediating.

---

## 11. The `Authenticate` hook returns its decision through an `out Boolean`, which fails open on an unassigned path

- **Severity:** medium
- **Category:** auth-bypass
- **Subsystem:** Server middleware
- **Location:** `src/flyology-http-server-middleware_authentication.ads:18`
- **Verification:** verified

The security decision crosses the generic boundary as an `out Boolean`. Ada does not copy the
caller's initialization into an `out` scalar, so an application hook with any path that returns
without assigning `Authenticated` leaves the middleware reading an indeterminate value — and any
nonzero byte reads as `True`.

```ada
with procedure Authenticate
  (Scheme        : String;
   Credential    : String;
   Authenticated : out Boolean;
   Principal     : out Ada.Strings.Unbounded.Unbounded_String);
```

**Failure scenario.** 1) A hook is written as
`if Scheme = "Bearer" then ... Authenticated := True/False; end if;` with no `else`. 2) The
attacker sends `Authorization: Basic AAAA` to a `Required_Authentication` route. 3) `Accepted`
holds whatever was on the stack; when nonzero the request is treated as authenticated,
`Set_Principal` installs the attacker-influenced principal, and `Require_Authentication` sees
`Has_Principal` and serves it.

**Verification notes.** I confirmed the signature and its consumption. The middleware's
`Accepted : Boolean := False` (`middleware_authentication.adb:40`) is discarded, because Ada
passes `out` scalars without copy-in. The only backstop,
`Length (Identity) = 0`, does not fire for a realistic hook that sets the principal before or
independently of the boolean. The library already knows the fail-closed idiom:
`Middleware_Errors` declares `Handled : in out Boolean` and pre-initializes it, so the
inconsistency is not deliberate. `-gnatVa` cannot help — any nonzero byte is a valid `Boolean`,
and the hook body is compiled with the application's switches. Medium rather than high because it
requires an application-side omission; the library's contribution is choosing the parameter mode
that makes that omission silently insecure rather than fail-closed.

---

## 12. Buffered-body ingress is reserved at the declared or maximum size and held for the whole slow read

- **Severity:** medium
- **Category:** dos (resource amplification)
- **Subsystem:** HTTP/1.x server
- **Location:** `src/flyology-http-server.adb:1449`
- **Verification:** reviewed

`Buffer_Request_Body` reserves `Item.Body_Limit` (1 MiB default) for *any* chunked request, and
the full declared `Content-Length` for fixed-length requests, before a single body byte arrives,
shrinking to the true size only after the body completes. The shared budget is 64 MiB.

```ada
Reserved :=
  (case Item.Body_Mode is
      when No_Body      => 0,
      when Fixed_Body   => Item.Body_Remaining,
      when Chunked_Body => Item.Body_Limit);
Reserve_Buffered (Item, Reserved);
```

**Failure scenario.** Open 64 connections; on each send a `POST` head with
`Transfer-Encoding: chunked` and then dribble `1\r\nA\r\n` every few seconds, never sending the
terminating chunk. Each connection costs the attacker roughly 60 bytes and pins 1 MiB. At 64 MiB
`Try_Reserve` denies, and every subsequent request to any buffered route gets
`503 ingress-budget-exhausted`. Amplification is roughly 17 000× bytes pinned per byte sent.

**Verification notes.** Reviewed. The reviewer confirmed this is a pre-reservation policy, not a
leak: the release path is correct on both the normal exit and the `when others` path, and a
connection holds at most one reservation. What is missing is any per-peer or per-connection cap
on the number of reservations; `middleware_bulkheads` exists but is opt-in and not wired by
default, and the request timeout bounds the hold time but not the concurrency. Streaming routes
do not reserve and are unaffected.

---

## 13. IDNA performs no validity, bidi, joiner, or Punycode-decode checking; `xn--` labels pass through unvalidated

- **Severity:** medium
- **Category:** spec-deviation / punycode
- **Subsystem:** `flyology_iri` IDNA
- **Location:** `flyology_iri/src/flyology_iri-idna.adb:219`
- **Verification:** verified (probes) / reviewed (Unicode specifics)

`flyology_iri-idna.ads:5` claims conversion "using the URL parser's UTS #46 mapping and Punycode
implementation", but `Map_Input` handles only a hand-written subset — ignorable format
characters, the fullwidth block, ideographic dots, math alphanumerics — and otherwise applies
`To_Lower`. There is no IDNA disallowed-character set, no CheckBidi, no CheckJoiners, and no
Punycode *decoder* at all, so an ASCII label beginning `xn--` is copied verbatim without UTS #46
§4.1's convert-and-validate step.

```ada
if ASCII_Only then
   ...
   if not Valid_ASCII_Label (Text) then
      return "";
   end if;
   Bytes.Append (Result, Text);    --  no "xn--" detection, no Punycode decode
```

**Failure scenario.** `http://xn--/`, `http://xn--a/`, and `http://xn--!!!!/` all parse with the
`xn--` label as the host, where a conforming `ToASCII` must Punycode-decode it and fail (`xn--a`
decodes to U+0080, a disallowed C1 control) — browsers and `ada-url` reject all three. Likewise
accepted: `http://a≠b.com/` → `xn--ab-miv.com` (U+2260 is IDNA-disallowed), a host containing
U+200F RLM (a bidi control), and an RTL label containing an L character (a CheckBidi violation).
A host a conforming resolver or browser refuses is therefore treated as valid and handed
downstream, and the differential makes any blocklist keyed on this parser's `Host` unreliable.

**Verification notes.** I verified the absence of a decoder directly — the unit contains only
`Encode_Digit`, `Adapt`, and the `Punycode` encoder — and confirmed the `xn--` pass-through by
running the built CLI. The Unicode-specific claims (which code points UTS #46 disallows, the
bidi and joiner rules) are the reviewer's. `README.md` partially discloses this ("nor that its
standalone IDNA implementation has been validated against every Unicode conformance file"), but
the `.ads` still asserts UTS #46 mapping and no disclaimer covers the *absence of any*
validity, bidi, or `xn--` checking. Tests cover only positive mappings, never a disallowed code
point or a pre-encoded `xn--` label. Note the Punycode *encoder* is sound: RFC 3492's two
overflow checks are both present and fail closed.

---

## 14. `Release_Stream` never clears `Continuation_Slot`, permanently freezing all connection output

- **Severity:** medium
- **Category:** dos
- **Subsystem:** HTTP/2 server
- **Location:** `src/flyology-http-server-http_2.adb:1246`
- **Verification:** reviewed

While a response field section is fragmented across HEADERS+CONTINUATION, `Continuation_Slot`
pins `Pull_Output` to one slot and suppresses the control-frame branch. If that stream is failed
and reaped mid-block, `Release_Stream` frees the slot without clearing the pin, and `Pull_Output`
can never emit another byte on that connection.

**Failure scenario.** 1) The attacker requests a route whose response head exceeds the
16 384-byte frame size — reachable, since up to 16 KiB of header bytes across 64 fields is
admitted and per-field prefixes add more. 2) `Pull_Output` emits the first fragment without
END_HEADERS and pins the slot. 3) The attacker sends RST_STREAM(CANCEL); the handler is
cancelled, terminates, and the stream reaches `Complete`. 4) `Reap` calls `Release_Stream`,
setting `Phase := Free` while the pin stays set. 5) Every later `Pull_Output` takes the pinned
path, finds no open stream there, and returns nothing — queued SETTINGS ACKs, WINDOW_UPDATEs,
RST_STREAMs, and every other stream's response are frozen until `Max_Connection_Age`.

**Verification notes.** Reviewed. The reviewer verified that a merely-reset, not-yet-reaped stream
self-heals — `Phase` stays `Open` and the response head survives `Mark_Failed`, so the branch
keeps firing until the final fragment clears the pin — correctly narrowing the defect to the reap
path. The same client/server asymmetry as findings 7 and 8 recurs: the client clears the pin in
both teardown paths (`http_2_client_connection.adb:420` and `:435`).

---

## 15. CONTINUATION is accepted outside an open field section and its residue prepends the next header block

- **Severity:** medium
- **Category:** framing
- **Subsystem:** HTTP/2 server and client
- **Location:** `src/flyology-http-server-http_2.adb:2108`; same defect at `src/flyology-http-http_2_client_connection.adb:1375`
- **Verification:** reviewed

RFC 9113 §6.10 requires a CONTINUATION not following an unterminated HEADERS/CONTINUATION to be
a connection error of type PROTOCOL_ERROR. This branch appends the payload unconditionally. With
END_HEADERS clear, `Expect_Continuation` stays false and the bytes remain buffered; the HEADERS
branch never clears the buffer before appending.

**Failure scenario.** 1) The attacker sends `CONTINUATION(stream=1, flags=0, payload = literal "foo: bar")`;
the open-block guard does not fire and the payload is buffered. 2) A normal
`HEADERS(stream=1, END_HEADERS|END_STREAM)` with the four pseudo-headers follows. 3) The block
handed to `Decode_Request` is the concatenation, so `foo: bar` decodes first, `Saw_Regular`
becomes true before `:method`, and a correctly-formed request is rejected — and per finding 9 the
HPACK table is now desynchronized for the rest of the connection. Reversing the payloads yields a
request the server processes whose fields no HEADERS frame carried.

**Verification notes.** Reviewed. The reviewer confirmed accumulation is bounded at 64 KiB, so
this is not the CONTINUATION-flood class (CVE-2024-27316), and explained why h2spec misses it:
its unsolicited-CONTINUATION cases all set END_HEADERS, which reaches header-block processing
with stream 0 and escalates to a connection error by a different route. Only the
END_HEADERS-clear variant leaves residue, and no test sends one.

---

## 16. HTTP/2 `:path` is never validated for control bytes, unlike the HTTP/1 target

- **Severity:** medium
- **Category:** info-leak (log injection)
- **Subsystem:** HTTP/2 server
- **Location:** `src/flyology-http-server-http_2.adb:1973`
- **Verification:** verified

`:path` is assigned straight from the HPACK string decoder, which performs no character
validation, and the HTTP/2 path never applies the target check the HTTP/1 parser enforces at
`src/flyology-http-server.adb:1023`. So `:path` may carry raw CR, LF, NUL, and DEL.

**Failure scenario.** 1) The attacker sends HEADERS with `:path` = `/x` CR LF followed by a forged
log line. 2) Routing rejects the path and calls `Run_Automatic ("flyology.bad_request")`, which
still runs the global middleware chain. 3) `Middleware_Logging` with `Include_Target => True`
passes the raw target to the sink, which writes a forged access-log entry.
`Flyology.HTTP.Server.Logging`'s contract documents no control bytes in `Target`, so sinks have
no reason to escape it.

**Verification notes.** Verified as part of finding 3 — the same unvalidated pseudo-header
assignment and the same bypass of `Headers.Add`. Response-header injection is not reachable from
here: `Add_Header` → `Validate_Header_Value` rejects control bytes, so a handler reflecting the
target into a response header yields a 500, not a split response. Medium because the impact is
confined to log and sink integrity.

---

## 17. Rate-limit and bulkhead middleware silently deny every request for route names longer than 128 characters

- **Severity:** medium
- **Category:** dos
- **Subsystem:** Server middleware
- **Location:** `src/flyology-http-server-middleware_rate_limits.adb:46`; `src/flyology-http-server-middleware_bulkheads.adb:42`
- **Verification:** reviewed

Both limiters key on `X.Route_Name` copied into a fixed `String (1 .. 128)`. An oversized key is
neither truncated nor hashed — the guard returns with the deny value still set, so every request
to that route is refused permanently. The bulkhead behaves the same once `Route_Capacity`
distinct names have been seen, since entries are never released.

```ada
Allowed := False;
if Route'Length = 0 or else Route'Length > Max_Route_Length
  or else Key'Length = 0 or else Key'Length > Max_Key_Length
then
   return;                       --  Allowed stays False -> 429 forever
end if;
```

**Failure scenario.** Route names default to `Method & " " & Pattern` and `Mount` prepends a
prefix, so a mounted REST route such as
`POST /api/v2/organizations/{org}/workspaces/{ws}/projects/{project}/pipelines/{pipeline}/runs/{run}/artifacts/{artifact}`
exceeds 128 characters. Every request to it returns 429 (or 503) with no diagnostic, and nothing
bounds route-name length at registration.

**Verification notes.** Reviewed. Failing closed is the safe direction, hence medium, but the
failure is silent, total, and undiagnosable — `Count_Denial` even swallows metric exceptions. No
length check exists in `Routing.Add`, `Check_Add`, or `Configure_Route`.

---

## 18. Bodyless-by-status responses are pooled without confirming the transport is quiescent

- **Severity:** medium
- **Category:** pool-desync
- **Subsystem:** HTTP client
- **Location:** `src/flyology-http-client-http_1_internals.adb:657`
- **Verification:** reviewed

`HEAD`, `204`, `205`, and `304` force `Mode := No_Body` and immediately return the lease. The only
protection against trailing octets is whether they already landed in `Data.Pending`; bytes
arriving one segment later are left on the socket of a connection already back in the pool. Only
204 and 205 get a framing-consistency check — a `304` or `HEAD` response carrying
`Content-Length: N` is accepted silently.

**Failure scenario.** 1) In a multi-tenant origin the attacker controls one path; the client
issues `HEAD /attacker` and receives a head with `Content-Length: 45`. 2) The client releases the
lease to idle. 3) 50 ms later the server writes 45 bytes forming a complete `HTTP/1.1 200 OK …`
message. 4) The client's next request on that connection — say `GET /victim` with an
`Authorization` header — reads the planted message as its response head, and the caller acts on
an attacker-chosen status and body for a path the attacker does not control.

**Verification notes.** Reviewed. The `Length (Data.Pending) > 0` guard is the intended defence
and does close the connection whenever the stray bytes arrive in the same or an earlier
`Receive` — the normal case for a single server write — so exploitation needs a server that
splits the write, hence medium. No post-release readability probe and no framing rejection for
`HEAD`/`304` with a nonzero `Content-Length` exist.

---

## 19. A `Text_Frame` payload is admitted without UTF-8 validation, then destroys the connection when sent

- **Severity:** medium
- **Category:** dos / correctness
- **Subsystem:** WebSocket server
- **Location:** `src/flyology-http-server-websocket_handlers.adb:180` (admission), `:457` (send); escalation at `src/flyology-http-server.adb:3498`
- **Verification:** reviewed

`Publish`/`Publish_For`/`Try_Publish` admit an outgoing message on size alone. The UTF-8
requirement for `Text_Frame` is enforced later in the owner task, where the resulting
`Constraint_Error` runs `Send_WebSocket`'s catch-all that marks the connection `Terminal` and
`Request_Close` — even though no byte was written.

**Failure scenario.** 1) A relay application forwards bytes from an untrusted source and calls
`Publish (Session, (Kind => Text_Frame, Data => <bytes containing 16#FF#>), Accepted)`. 2)
`Accepted` is `True` — a single 0xFF byte is far under the size limit. 3) On the next `Run`
iteration the send raises `Constraint_Error`; the connection is marked `Terminal`, `Run`'s
`when others` closes the session, drains and discards every other queued message, and re-raises.
One attacker-supplied byte kills the session and drops the outbound queue, and the producer
cannot detect it because `Accepted` was already `True`. The in-progress inbound reassembly state
is also wiped despite the failure being a caller-argument error.

**Verification notes.** Reviewed. `server.ads:477` documents `Text_Frame` as "Validated UTF-8
text payload", the closest thing to a stated precondition — but the enqueue API already rejects
the other invariant (size) via `Accepted` rather than by killing the connection, so the asymmetry
is a real API defect. Not Autobahn-covered: `tests/websocket_conformance_server.adb` calls the
raw `Send_WebSocket` API and never instantiates `WebSocket_Handlers`.

---

## 20. URL host validity depends on letter case: a fast path bypasses the DNS-length checks the slow path enforces

- **Severity:** medium
- **Category:** spec-deviation / parser-differential
- **Subsystem:** `flyology_iri` URL parser
- **Location:** `flyology_iri/src/flyology_iri.adb:980` (bypass), `flyology_iri-idna.adb:163`, `:248` (checks)
- **Verification:** verified by execution; independently reported by the URL reviewer

`Fast_Web_Analysis` handles inputs that already look normalized and sets the reference directly
from the raw input, bypassing `Web.Parse` and therefore `Canonical_Host` and `IDNA.To_ASCII`
entirely. The slow path applies `Valid_ASCII_Label` (rejecting labels over 63 octets) and a
253-octet name limit; the fast path applies neither. Since `Fast_Web_Analysis` bails out on any
uppercase letter in the host (`flyology_iri.adb:149`), validity depends on letter case.

```
label n= 63  lowercase=accepted(len=63)   uppercase=accepted(len=63)
label n= 64  lowercase=accepted(len=64)   uppercase=REJECTED      <-- differential
label n= 70  lowercase=accepted(len=70)   uppercase=REJECTED      <-- differential
label n=100  lowercase=accepted(len=100)  uppercase=REJECTED      <-- differential
name>253     lowercase=accepted(len=304)  uppercase=REJECTED      <-- differential
```

**Failure scenario.** `http://<64 lowercase letters>/` parses with that hostname; the identical
host with one uppercase letter — or a percent-escape, or any non-ASCII character, each of which
also forces the slow path — is rejected as malformed. WHATWG's domain-to-ASCII specifies
`VerifyDnsLength=false`, so browsers accept both: the fast path is conformant and the slow path
is over-strict. A validate-then-normalize pipeline, or an allowlist built from `Can_Parse`, is
therefore order- and case-dependent.

**Verification notes.** Verified by execution, and independently found by the URL reviewer.
Reading alone was misleading here — the slow path's checks look unconditional, and I located the
bypass only after the binary contradicted the traced control flow. The impact direction is
availability and cross-parser disagreement rather than a bypass: the strict path *rejects* what
browsers accept, so an allowlist fails closed. Hence medium. The remedy is to remove the 63/253
checks from `To_ASCII` to match `VerifyDnsLength=false`, not to add them to the fast path. No
test exercises label or name length, and the WPT harness runs only `urltestdata.json`, not
`toascii.json` where the IDNA length cases live.

---

## 21. `Can_Parse` returns True for input `Parse` rejects as `Too_Long`

- **Severity:** medium
- **Category:** api-safety
- **Subsystem:** `flyology_iri`
- **Location:** `flyology_iri/src/flyology_iri.adb:864` versus `:978`
- **Verification:** reviewed (measured by reviewer)

`Can_Parse` compares `Input'Length` against `Max_Length` and then takes the allocation-free fast
path, but `Parse` measures the *serialized* length, which is one byte longer whenever WHATWG
normalization inserts a missing `/`.

**Failure scenario.** `Can_Parse ("http://a", Web_URL_Syntax, 8)` is `True` while
`Parse ("http://a", Web_URL_Syntax, 8)` raises `Malformed_Reference: TOO_LONG`. The idiomatic
guard `if Can_Parse (S, …, N) then R := Parse (S, …, N);` therefore raises where it promised not
to. Combined with finding 20, `Can_Parse` is not a sound precondition for `Parse`.

**Verification notes.** Reviewed and measured by the reviewer. The only `Max_Length` test uses
the URI path and never crosses the boundary by exactly one byte. Together with findings 5 and 20
this is the third distinct symptom of the same root cause — four parallel implementations of one
grammar.

---

## 22. The WPT URL conformance suite never runs in CI

- **Severity:** medium
- **Category:** test-coverage
- **Subsystem:** `flyology_iri` / CI
- **Location:** `flyology_iri/scripts/test.sh:9`
- **Verification:** verified

The crate ships a Web Platform Tests harness that compares its URL results against Ada's pinned
WPT corpus and exits nonzero on any mismatch. It is gated on an environment variable CI never
sets, so the primary conformance oracle for the newest and most security-sensitive component in
the repository never runs automatically.

```sh
if [ -n "${ADA_URL_ROOT:-}" ]; then
  python3 "$crate_root/tests/wpt_conformance.py" \
    "$crate_root/tests/bin/flyology_iri_url_cli" "$ADA_URL_ROOT"
fi
```

**Failure scenario.** A URL-parser regression that WPT would catch — the class that causes
origin-check bypass and SSRF — merges with a green build. Findings 1, 5, 13, 20, and 21 are the
concrete instances: five parser defects, including one critical, in the crate's first release.

**Verification notes.** Verified. `ADA_URL_ROOT` appears only in `flyology_iri/README.md` as a
manual step, in `benchmark.sh`, and in the harness's usage message; it appears nowhere in
`.github/workflows/ci.yml`. The rest of the wiring is correct — the top-level `scripts/test.sh:83`
does invoke the crate's test script, and its unit tests build and pass — so only the WPT stage is
skipped. Note that even when run, the harness exercises `Parse` only: `Can_Parse`, `Diagnose`,
`Resolve`, `Origin`, and `Target` have no corpus coverage, which is exactly why findings 1 and 5
were invisible. Fixing this needs a decision the audit cannot make: fetching the third-party
`ada-url/ada` corpus in CI is a supply-chain dependency, so pin it by commit or vendor it.

---

## 23. `Current_Is_Head` is not reset per request, so a rejected request on a reused connection gets a `Content-Length` with no body

- **Severity:** low
- **Category:** correctness / protocol conformance
- **Subsystem:** HTTP/1.x server
- **Location:** `src/flyology-http-server.adb:1157` (consumed at `:1697`)
- **Verification:** reviewed

`Item.Current_Is_Head` and `Item.Current_Version` are assigned as the *last two statements* of
`Read_Request_Head`, so every `Protocol_Error`, `Payload_Too_Large`, or `Expectation_Failed`
raised earlier leaves the previous request's values in place, and the error response is formatted
against them.

**Failure scenario.** On one keep-alive connection: a `HEAD /` request (setting the flag), then a
`GET /` with an invalid `Content-Length`, which raises well before line 1157. The 400 is emitted
with `Content-Length: 12` and zero body bytes, then FIN. The client sees a 12-byte-short response
and must treat the error as truncated.

**Verification notes.** Reviewed. The reviewer confirmed no reset exists — the fields are written
only at `:1157`/`:1158`, in a procedure that otherwise resets ten other per-request fields — and
checked for escalation into smuggling: every path that can observe the stale flag passes
`Close => True` or an empty payload, so the connection is torn down, capping impact at a malformed
final response rather than a desynchronized pipeline. `Current_Version` is stale the same way but
benign.

---

## 24. Repeated `Cookie` request headers are comma-joined, corrupting every cookie value

- **Severity:** low
- **Category:** correctness (RFC 9110 §5.3 / RFC 6265 §5.4)
- **Subsystem:** HTTP/1.x server
- **Location:** `src/flyology-http-server.adb:359`, consumed at `src/flyology-http-server-requests.adb:115`
- **Verification:** reviewed

`Header` unconditionally joins all field lines of one name with `", "`, which is valid only for
fields whose ABNF is a comma-separated list. `Cookie` is the canonical exception — its delimiter
is `;` — so `Requests.Cookie` splits the joined string on `;` and absorbs a second `Cookie` line
into the value of the first line's last cookie.

**Failure scenario.** `Cookie: sid=good` and `Cookie: x=y` on separate lines yield
`Cookie (X, "sid") = "good, x=y"` instead of `"good"`, and `Cookie (X, "x") = ""`. A session
lookup fails, and any application doing a prefix or substring comparison on the session id
compares against attacker-appended bytes.

**Verification notes.** Reviewed. The reviewer confirmed `Cookie` has no duplicate-count check
anywhere, unlike `Host`, `Content-Length`, and `Transfer-Encoding`, which are all count-checked —
which is why this does not extend to smuggling. The 4096-byte and 64-pair guards do not help
because the joined field parses as one pair.

---

## 25. Percent-decoded query values may contain NUL and control bytes, unlike decoded paths

- **Severity:** low
- **Category:** correctness / defence-in-depth inconsistency
- **Subsystem:** HTTP/1.x server
- **Location:** `src/flyology-http-server-requests.adb:18`
- **Verification:** reviewed

`Decode_Query` emits `Character'Val` of any hex pair with no post-decode filter, whereas the path
decoder explicitly rejects NUL, backslash, and bytes below 32 or equal to 127 after decoding.
Query values are therefore the one request surface that can hand an application embedded NUL and
control bytes.

**Failure scenario.** `GET /f?name=report%2Etxt%00.png` yields
`Query (X, "name") = "report.txt<NUL>.png"`. An application passing that to an interface with C
string semantics sees `report.txt` while an Ada-side extension check sees `.png`.

**Verification notes.** Reviewed. The reviewer confirmed no earlier guard fires:
`Validate_Target_And_Authority` checks only that each `%` is followed by two hex digits and that
*raw* bytes are printable, deliberately not looking at decoded values. Route parameters are safe,
since they come from splitting `Decode_Path`'s filtered output. Low because it requires an
application to mishandle the bytes; the library never uses the decoded query itself.

---

## 26. `Access-Control-Allow-Origin: *` with `Allow-Credentials: true` is reachable when `*` is a member of the origin list

- **Severity:** low
- **Category:** cors
- **Subsystem:** Server middleware
- **Location:** `src/flyology-http-server-cors.adb:24`
- **Verification:** reviewed

`Create` rejects the wildcard/credentials combination only when `Allowed_Origins` is *exactly*
`"*"`. `Origin_Allowed` matches whole space-separated tokens, so `"*"` inside a list matches a
literal `Origin: *` while `Wildcard` stays false, and the middleware echoes the origin and emits
`Allow-Credentials: true`. Rated low because browsers themselves reject `ACAO: *` with
credentials; the browser-reachable variant is listing `"null"`, which a sandboxed iframe or
`data:` document sends to obtain credentialed cross-origin access. `Exact_Word` is otherwise a
genuine exact token match — `evil-example.com` cannot match `example.com` — and `Vary: Origin`
is correctly emitted on every reflection. The defect is that `cors.ads:12` presents `Create` as
the validation point and that guarantee does not hold for list members.

---

## 27. 404/405/OPTIONS/redirect responses bypass per-route rate limiting and concurrency

- **Severity:** low
- **Category:** dos
- **Subsystem:** Server routing
- **Location:** `src/flyology-http-server-routing.adb:830`
- **Verification:** reviewed

`Run_Automatic` configures the exchange with `Concurrency => 0` and `Rate_Per_Second => 0`, and
both limiters treat zero as unlimited, so the unmatched-path surface — which still runs the whole
global middleware chain and writes a response — is unmetered per client. An attacker flooding
`GET /nonexistent-<counter>` has each request generate a request ID, run logging, metrics, and
security headers, and emit a problem+json 404 with the token bucket never consulted; there is no
configuration surface to rate-limit unmatched paths. Low because the bulkhead's *global* limit
still applies, making this a per-client fairness gap rather than unbounded concurrency.

---

## 28. `Add_Header` is append-only, so a handler cannot override middleware security headers

- **Severity:** low
- **Category:** correctness
- **Subsystem:** Server applications
- **Location:** `src/flyology-http-server-applications.adb:296`
- **Verification:** verified

`Add_Header` unconditionally appends and there is no set, replace, or remove operation, so a
handler needing a different value emits two conflicting fields. When the security-headers
middleware emits `X-Frame-Options: SAMEORIGIN` and an embeddable-widget handler adds
`X-Frame-Options: ALLOWALL`, Chrome treats the conflicting duplicate as invalid and ignores it
entirely, leaving *no* framing protection — the opposite of both intents. Duplicate
`Referrer-Policy` fields are comma-merged with the last valid token winning, letting a handler
silently weaken the configured policy. Low because CSP duplication is safe (browsers intersect
policies), confining the blast radius to those two headers. Related ordering hazard, same root: a
limiter registered before the security-headers component short-circuits with 429/503, and those
responses carry no security headers at all.

---

## 29. Default request IDs are a single global monotonic counter, echoed to the client

- **Severity:** low
- **Category:** info-leak
- **Subsystem:** Server middleware
- **Location:** `src/flyology-http-server-middleware_request_ids.adb:6`
- **Verification:** reviewed

With no custom generator, IDs are `fly-<N>` from one process-wide counter, written into the
response header. An attacker sends one request, waits, sends a second, and subtracts the two
`X-Request-ID` values to learn how many requests the server handled in between — a traffic-volume
oracle — and any application treating the ID as unguessable (an idempotency key, a correlation
token) is trivially predictable. Low because `Trust_Inbound` defaults to false and inbound IDs
must pass an `[A-Za-z0-9._-]{1,128}` allowlist before being echoed, so there is no injection
here, nothing in the library uses the ID for a security decision, and a `Generate` hook is
offered.

---

## 30. Middleware added to a subrouter after `Mount` silently does not protect the mounted routes

- **Severity:** low
- **Category:** auth-bypass (configuration footgun)
- **Subsystem:** Server routing
- **Location:** `src/flyology-http-server-routing.adb:627`
- **Verification:** reviewed

`Mount` snapshots the source router's middleware into each copied route at mount time; later
`Add_Middleware` calls on the source affect only the source, with no diagnostic. Setup code that
runs `Mount (Parent, "/api", Sub);` and then `Add_Middleware (Sub, Auth.Call'Access);` leaves
every `/api/...` route running without the authorization middleware and raises no error. Low
because the router's own `Require_Authentication` backstop still protects any route whose policy
is `Required_Authentication`, limiting exposure to authorization enforced purely by a middleware
component. `Add_Middleware`'s documentation says globals "are copied into mounted subrouter
routes" but never states that mount order matters.

---

## 31. HTTP/2 `:path: *` with a non-OPTIONS method reaches a parameterized route

- **Severity:** low
- **Category:** routing
- **Subsystem:** HTTP/2 server
- **Location:** `src/flyology-http-server-http_2.adb:1973`
- **Verification:** reviewed

HTTP/1 rejects asterisk form for anything but OPTIONS (`server.adb:670`); HTTP/2 accepts any
non-empty `:path`, and `Decode_Path`/`Split_Path` special-case `"*"` into a single segment, so it
matches a one-segment parameter pattern. With a route `GET /{id}`, an h2 client sending
`:path: *` matches with `X.Parameter ("id") = "*"`, and a handler interpreting `*` as "all" — a
common convention for scope or tenant identifiers — acts on the wildcard reading from a wire
value HTTP/1 would have rejected. The reviewer confirmed no leading-`/` requirement on `:path`
exists in either the HPACK decode or the header-block processing, and that non-`*` paths without
a leading `/` *are* rejected, making `"*"` the sole escape.

---

## 32. The router's fallback 401 hardcodes `WWW-Authenticate: Bearer`, ignoring the configured challenge

- **Severity:** low
- **Category:** correctness
- **Subsystem:** Server routing
- **Location:** `src/flyology-http-server-routing.adb:742`
- **Verification:** verified

`Require_Authentication` — the router's own fail-closed backstop — always advertises `Bearer`,
while the authentication middleware advertises the application's configured `Challenge`. A
Basic-auth application that registers its auth middleware at the `Application` stage rather than
`Request_Head` places it after `Require_Authentication` in the pipeline, so every request to a
`Required_Authentication` route returns 401 with `WWW-Authenticate: Bearer`, clients never prompt
for Basic credentials, and the route is permanently unreachable with the 401 misattributing the
cause. Structural rather than a simple oversight — `Routing` has no visibility of the
middleware's `Challenge` formal — so the reportable part is that nothing in the `Middleware_Stage`
documentation warns that authentication must run at `Request_Head`, and the failure is a silent
permanent 401 rather than a setup-time error.

---

## 33. DATA and WINDOW_UPDATE on an idle stream report FLOW_CONTROL_ERROR instead of PROTOCOL_ERROR

- **Severity:** low
- **Category:** correctness (spec conformance)
- **Subsystem:** HTTP/2 server
- **Location:** `src/flyology-http-server-http_2.adb:2136`
- **Verification:** reviewed

RFC 9113 §5.1 requires any frame other than HEADERS/PRIORITY on an idle stream to be a connection
error of type PROTOCOL_ERROR. Both `Publish_Data` and `Window_Update` signal the idle case by
leaving `Accepted := False` with no distinguishing flag, and the call sites map that to
FLOW_CONTROL_ERROR, so a peer sending DATA on a never-opened stream gets GOAWAY with code `0x3`
where `0x1` is required. The genuinely flow-control cases *are* routed correctly, so this is not
a blanket miscoding. One conflict the audit could not resolve without running the tool:
`tests/http2-conformance.md` claims a "146 of 146" h2spec 2.6.0 baseline and h2spec's §5.1 tests
assert PROTOCOL_ERROR, so either that baseline is stale on these two cases or h2spec 2.6.0
accepts any GOAWAY code. Worth settling, since it also bears on how much the published baseline
can be relied on.

---

## 34. `Close_WebSocket` silently drops back to the 1 MiB default message limit during the close handshake

- **Severity:** low
- **Category:** correctness
- **Subsystem:** WebSocket server
- **Location:** `src/flyology-http-server.adb:3605`
- **Verification:** reviewed

While draining the peer's close, `Close_WebSocket` reuses the connection's retained limit only if
a receive is still active; otherwise it hardcodes `Default_Max_WebSocket_Message` (1 MiB),
ignoring the application's configured limit, and it has no `Max_Message` parameter with which a
caller could correct this. An application running with `Max_Message => Max_WebSocket_Frame`
(16 MiB — what the published limits profile uses) that finishes a message and then closes, with a
2 MiB frame in flight across the close, hits the 1 MiB limit and calls `Fail (1_009, …)`; because
the close was already sent, `Fail` sends nothing and raises, aborting the TCP connection
mid-handshake instead of completing the clean 1000 close it initiated. Reachable on the normal
shutdown path in `WebSocket_Handlers.Run`, where the outbox draining triggers `Close_WebSocket`
with the receive inactive. Outside the Autobahn campaign, which never calls `Close_WebSocket`.

---

## 35. `WebSocket_Reserved` is write-only dead connection state

- **Severity:** low
- **Category:** correctness
- **Subsystem:** WebSocket server
- **Location:** `src/flyology-http-server.ads:679`
- **Verification:** reviewed

The field is assigned `False` in six places and never read and never set `True`, so whatever
reservation invariant it was meant to track is not tracked at all. No runtime failure; the risk
is a reader concluding that WebSocket ingress reservation is tracked by this flag when the live
accounting is entirely in `Buffered_Bytes`/`Reservation_Budget`, and a future change that starts
reading it will read a constant `False`. Delete it or implement it.

---

## 36. Intermediate redirect bodies are drained with no byte bound

- **Severity:** low
- **Category:** dos
- **Subsystem:** HTTP client
- **Location:** `src/flyology-http-client.adb:1410`
- **Verification:** reviewed

Before following a redirect the client drains the 3xx body in full so the transport can be
reused, with no byte cap — only the shared exchange deadline — even though an intermediate
redirect body is never delivered to the caller. A server answering with `302`, a `Location`, and
`Content-Length: 2147483647`, streaming as fast as the link allows, has the client read and
discard for the whole 30 s default deadline — multiple GB on a fast link — before raising
`Timeout_Error`, once per hop. Low because it is time-bounded rather than unbounded and memory is
not at risk: the drain discards into a fixed 8 KiB buffer. `Read_All` has a `Maximum` parameter
that `Drain` deliberately does not use.

---

## 37. The global pool lock is held across each HTTP/2 session lock

- **Severity:** low
- **Category:** race (contention)
- **Subsystem:** HTTP client pool
- **Location:** `src/flyology-http-client-pool_controller.adb:36`
- **Verification:** reviewed

`Try_Checkout`, inside the `Pool_Controller` protected action, calls `H2_Connections.Can_Open`, a
protected function on each session's own `Controller`, so the client's single admission lock is
held while acquiring each pooled session's lock. Reported with both of the reviewer's
disclaimers, which I consider correct and which is why this stays low: a protected *subprogram*
call is not a potentially-blocking operation under RM 9.5.1(8-16) — only entry calls are — so
there is no `Program_Error`, and the ordering is consistently pool→controller with no callback
into the pool, so there is no deadlock. The real cost is contention amplification: while a task
spins in finding 10, each iteration takes both locks, competing with the pump task that must run
for capacity to free up — so the spinner delays the event it waits for.

---

## 38. No policy hook to reject loopback, link-local, or private connect targets

- **Severity:** low
- **Category:** ssrf (design gap)
- **Subsystem:** HTTP client
- **Location:** `src/flyology-http-client-exchange_internals.adb:120`
- **Verification:** reviewed

`Establish` resolves the configured origin host and connects to the first working address with no
filtering hook, so an application cannot veto a resolved address. An application building an
`Origin` from a user-supplied URL — the shape the new URL parsing invites — will connect to a
hostname resolving to `169.254.169.254` or `127.0.0.1` with no opportunity to intervene, and DNS
rebinding between a validation resolve and this resolve cannot be blocked at all, since the only
defence is validating the hostname string before `Configure`. Reported as the design gap it is:
redirect-driven SSRF is structurally impossible here, because a client is bound to one origin and
redirects leaving it are returned rather than followed. This concerns the initial connect only.

---

## 39. `Valid_IPv4`'s `WHATWG` parameter is dead, so RFC 3986 `dec-octet` leading zeros are accepted

- **Severity:** low
- **Category:** spec-deviation
- **Subsystem:** `flyology_iri`
- **Location:** `flyology_iri/src/flyology_iri.adb:460`, sole call site `:529`
- **Verification:** reviewed (measured by reviewer)

The leading-zero rejection is gated on a parameter that is only ever passed `False`:
`or else (WHATWG and then Leading_0 and then Digit_Count > 1)`. So
`Parse ("http://[::1.2.3.04]/", URI_Syntax)` succeeds with host `::1.2.3.04`, although RFC 3986's
`dec-octet` forbids a leading zero. Two spellings of one address both validate and compare
unequal, so a `Host`-string comparison against an allowlist can be bypassed by zero-padding. The
only IP-literal negative test covers `[2001:::1]`; no leading-zero case exists. The WHATWG path
uses `Web.Canonical_IPv4` instead, which handles zeros correctly.

---

## 40. `IRI_Syntax` accepts any well-formed UTF-8, not RFC 3987 `ucschar`/`iprivate`

- **Severity:** low
- **Category:** spec-deviation
- **Subsystem:** `flyology_iri`
- **Location:** `flyology_iri/src/flyology_iri.adb:388`
- **Verification:** reviewed (measured by reviewer)

For non-URI syntaxes, `Validate_Range` checks only UTF-8 well-formedness for bytes at or above
0x80 and never restricts code points to `ucschar` (which starts at U+00A0) or `iprivate`
(query only). `Diagnose` returns `NO_ERROR` for hosts containing U+0085 NEL, U+2028 LINE
SEPARATOR, U+FFFE (a noncharacter), or U+E000 (private use), all outside `ucschar`, so
`IRI_Syntax` accepts IRIs that RFC 3987's grammar rejects. U+0085 and U+2028 are line terminators
in several downstream contexts, so "validated as an IRI" does not imply "safe to embed".
`URI_Syntax` correctly rejects all four. The IRI tests cover only legitimate `ucschar`, so nothing
pins the boundary.

---

## 41. Web-mode parse failures collapse to `Invalid_Character` at offset 0, discarding the documented error categories

- **Severity:** low
- **Category:** api-safety
- **Subsystem:** `flyology_iri`
- **Location:** `flyology_iri/src/flyology_iri.adb:1011`
- **Verification:** reviewed (measured by reviewer)

`Web.Parse` returns only a boolean, so every WHATWG failure is reported as `Invalid_Character` at
offset 0, contradicting the `Error_Kind` documentation (`flyology_iri.ads:34` describes
`Invalid_Authority` as covering a malformed host or port) and disagreeing with `Diagnose` on the
same input: `http://example.com:65536/` gives `INVALID_AUTHORITY` at offset 24 from `Diagnose`
and `INVALID_CHARACTER` at offset 0 from `Try_Parse`. Callers that branch on `Error.Kind` to
distinguish a bad host from a bad character, or that surface `Offset` to users, get the wrong
answer for every web URL. The test suite asserts error kinds only for `URI_Syntax` inputs, which
take the `Analyze` path where the categories are correct.

---

## 42. A failed `Try_Parse` is indistinguishable from a successful parse of `""` and reports the wrong `Syntax`

- **Severity:** low
- **Category:** api-safety
- **Subsystem:** `flyology_iri`
- **Location:** `flyology_iri/src/flyology_iri.adb:1010`, `:1019`, `:1031`, `:1044`
- **Verification:** reviewed (measured by reviewer)

On failure `Value := (others => <>)` yields the record defaults, including
`Syntax_Value => IRI_Syntax` rather than the requested syntax, and there is no `Valid`/`Is_Error`
accessor on `Reference`, so a caller who ignores `Error` cannot detect failure. A rejected
`Web_URL_Syntax` parse and a successful parse of `""` are component-wise identical apart from
`Syntax`, which is *also* wrong in the failure case. Low because it fails closed for the
dangerous accessors — `Origin` and `Target` raise, component getters return `""` — and the
default-on-failure behaviour is documented; the wrong `Syntax_Value` is neither documented nor
tested.

---

## 43. The `flyology_iri` release profile suppresses runtime checks with no proof discharging them

- **Severity:** low
- **Category:** hardening / proof obligation
- **Subsystem:** `flyology_iri` build configuration
- **Location:** `flyology_iri/flyology_iri.gpr:21` (and `flyology_iri/benchmarks/flyology_iri_benchmarks.gpr:13`)
- **Verification:** verified
- **Status:** intentional by design; recorded as a proof-and-benchmark work item, not as a defect to revert

The `release` build mode adds `-gnatp`, suppressing all Ada runtime checks — index, range,
overflow, discriminant — in a parser whose entire job is consuming hostile input. This is
deliberate and it is doing real work: the crate targets parity with the Ada URL parser, and
`BENCHMARKS.md` reports 20 ns `can_parse` and 103 ns `parse_href` against ada-url 4.0.0's 19 ns
and 104 ns, measured with `FLYOLOGY_IRI_BUILD_MODE=release` exported by
`flyology_iri/scripts/benchmark.sh:21`. So the published numbers *are* the unchecked numbers, and
"just remove `-gnatp`" would silently forfeit the comparison the crate exists to make.

The finding is therefore not that checks are suppressed. It is that the suppression currently
rests on assumption: nothing discharges the obligations `-gnatp` removes, so a latent index or
slice-bound bug anywhere in the URL, IDNA, or IPv4/IPv6 parsers becomes an out-of-bounds access
reachable from a hostile URL rather than a clean `Constraint_Error`. Findings 1 and 20 both show
that reading this crate's control flow is not a reliable substitute for a check — in each case
the source appeared to enforce something it did not.

This repository already has both the machinery and the habit for discharging exactly this kind of
obligation. `scripts/prove.sh` drives `gnatprove --mode=all` over ten policy units, and
`proof/proof-status.md` records for each one precisely what the proof does and does not cover.
`flyology_iri` is the one parser in the tree that is in neither. Absence-of-runtime-error proof is
the standard justification for suppressing checks: with AoRTE discharged, `-gnatp` removes checks
a prover has shown cannot fail, and the performance is kept for a stated reason rather than an
assumed one.

**Suggested experiment, with an acceptance gate.** Hold the `BENCHMARKS.md` medians as the
criterion — no regression beyond run-to-run noise on `can_parse` and `parse_href` against the same
pinned ada-url commit and corpus — and try these in order of cost:

1. *Measure what the switch actually buys, per operation.* Re-run the harness in `checked` mode
   and compare. `parse_href` allocates (unbounded strings, IDNA), so a bounds check there is
   plausibly lost in the noise; `can_parse` at 20 ns is pure fast-path scanning over plain
   `String` and is where suppression should matter. If the delta is noise for one of them, that
   operation needs no suppression at all, and the exposed surface halves for free. Note the
   benchmark project carries its own independent `-gnatp`, so re-baseline both together.
2. *Narrow the scope.* Whole-unit `-gnatp` suppresses every check kind across every subprogram,
   including cold error paths where nothing is gained. Scoped `pragma Suppress (Index_Check)` (and
   friends) around the specific hot loops gives the same code generation there with a far smaller
   blast radius, and it documents in the source which checks are being traded away.
3. *Prove the hot paths.* The subprograms that justify suppression are the plain-`String`
   index-arithmetic ones — `Fast_Web_Analysis`, `Fast_Can_Parse_Web`, `Analyze`,
   `Validate_Range`, `Is_Valid_UTF_8_At`, `Char_At` — and those are the plausibly SPARK-provable
   ones. Be aware of the split before scoping the work: GNATprove does not support
   `Ada.Strings.Unbounded`, so the units built on `Unbounded_String`,
   `Unbounded_Wide_Wide_String`, and `Ada.Strings.UTF_Encoding` (`Web.Parse`'s serialization,
   `IDNA.To_ASCII`) cannot be proved without restructuring — and they are also the allocating
   paths where checks are cheapest to keep. Proving the fast paths and leaving checks on in the
   allocating ones is likely to recover most of the safety at close to zero measured cost, which
   is a better outcome than either extreme.
4. *Guard the unchecked artifact dynamically.* Whatever the release profile ends up doing, a CI
   lane that builds `checked` with `-gnata`/`-gnatVa` and fuzzes gives coverage the release build
   cannot. There is precedent that this works here: the URL reviewer's 600 000-input fuzz across
   all entry points in all three syntaxes, built that way, produced no exception other than
   `Malformed_Reference`, and my own stress corpus of roughly 50 hostile inputs (64 KB paths and
   labels, 5 000 dot-segments, huge percent runs, malformed punycode, NUL and control bytes,
   oversized ports) produced zero crashes. Pair that with finding 22 — the WPT gate that never
   runs — since both are about the same missing automation.

**Verification notes.** Rated low, and the reachability assessment is unchanged by the
reformulation: the default mode is `checked`, nothing in this repository's CI selects `release`
except the benchmark harness, and Alire builds a dependency with the crate's own default, so no
consumer gets an unchecked parser without asking for one. I also checked for the worse version of
this issue — validation that *relies* on catching `Constraint_Error`, which `-gnatp` would
silently delete — and did not find it: the crate's one handler catches
`Ada.Strings.UTF_Encoding.Encoding_Error` (`flyology_iri-idna.adb:185`), an explicit raise from a
separately-compiled runtime, so it survives suppression. That is what keeps this low rather than
medium: today the switch is a standing risk on code with no known reachable check failure, not an
active hole.

---

## Appendix: attack classes checked and found sound

Recorded because knowing what was examined and found correct is part of the audit's value, and
because several of these are places where a plausible-looking vulnerability report would be wrong.

**HTTP/1.x request smuggling — soundly defended.** Duplicate `Content-Length` field lines, a
comma inside a single value, empty and non-digit values, and overflow are all rejected;
`Transfer-Encoding` requires HTTP/1.1, exactly one field line, and a value of exactly `chunked`
after trimming and lowercasing — rejecting `chunked, chunked`, `identity`, `chunked;q=1`,
`xchunked` — and TE together with CL is rejected outright rather than resolved by precedence,
the strongest posture available. The client applies the same rules to responses.

**Bare-LF and obs-fold smuggling — rejected.** `Validate_Header_Block` splits strictly on CRLF,
rejects any line beginning with SP or HTAB, and rejects every control byte below 32 (except HTAB)
and 127 in field values, so a stray LF survives inside a "line" and is caught as a control byte.
`Header_Field_Count` and `Header` use the identical splitter and colon rule, so validation and
lookup cannot disagree. Whitespace before `:` is rejected by the name token check.

**Response header injection — blocked at a single choke point.** `Validate_Header_Name` is a
correct RFC 9110 token check and `Validate_Header_Value` rejects controls and DEL, on every
`Add_Header`, covering `Location`, `Set-Cookie`, `Allow`, the CORS echo, and the request-id echo.
`Content-Type` is separately scanned, `Validate_Extra_Headers` forbids `CRLF CRLF` and the managed
fields, and the `Responses.Builder` NUL-delimited encoding cannot be escaped. On the client side
`Set_Target` rejects every byte outside 33..126 plus `#`, and redirect targets are re-validated,
so a hostile `Location` cannot inject into the next request line.

**Chunk parsing — hardened.** Hex digits only, no `+`/`-`/`0x`, with an overflow guard that both
prevents wraparound and enforces the body limit during parsing; the size line is length-capped;
chunk extensions are token-validated with full quoted-string and quoted-pair handling, and every
branch was traced for termination.

**Trailers are not merged into headers.** The server validates then discards them, rejecting
`connection`, `content-length`, `host`, `trailer`, `transfer-encoding`, and `upgrade`; the client
exposes them only through separate `Trailer*` accessors, never through `Header`.

**Path decoding and traversal — rejected before matching.** Single-pass decode only, with `%2F`,
`%2e%2e`, raw `../`, `%00`, `%5c`, control bytes, `//`, and invalid UTF-8 all rejected via the
SPARK-proved `Decoded_Path_Policy.Classify`. The router matches on the decoded result — the same
string `X.Path` returns — so middleware and router cannot disagree, and wildcard capture cannot
escape its segment because `/` cannot survive decoding. This is what makes finding 2 a
*form*-confusion bug rather than a traversal bug.

**Client redirect handling — safe by construction, not by filtering.** This refutes the entire
credential-leak-across-redirect class. A client is bound to exactly one origin, and a redirect
whose target is not same-origin (scheme, host, and port all compared) is *returned to the caller*
rather than followed, so `Authorization`, `Cookie`, and custom headers can never cross an origin
boundary and an `https`→`http` downgrade is structurally impossible. Non-HTTP schemes are
rejected; protocol-relative `//evil.com` is resolved then origin-checked; userinfo in a redirect
target is rejected. Method rewriting is correct (301/302+POST and 303 → GET, 307/308 preserve)
with content-* headers, trailers, body, and `Expect` cleared. The hop bound is checked before
increment and every prior target recorded, so a re-resolving loop is caught by target identity
rather than depth alone.

**Client TLS — verification on by default and not disableable through the API.** Client contexts
set `SSL_VERIFY_PEER` plus a CA file or the default trust paths; every session sets both SNI and
`SSL_set1_host` or fails; TLS 1.2 is the enforced floor. A handshake failure cleans up and
re-raises with no plaintext fallback. Because redirects never leave the origin, the verified host
is also the final host.

**Client pool origin keying, incomplete bodies, and deadlines.** The pool is keyed by
construction: a client holds one origin and every slot belongs to it, so an `https` transport can
never serve an `http` request. An incomplete response body destroys the transport on every
exception path, and a non-empty pending buffer at body completion marks it non-reusable in all
three completion paths. One monotonic `Ada.Real_Time` deadline is captured once and threaded
through every send, receive, and wait — no `Ada.Calendar` anywhere in the client, so no NTP or
DST sensitivity — and an expired deadline clamps to `0.0`, never to a negative value that would
read as infinite. Findings 6 and 18 are the two gaps in an otherwise careful scheme.

**HPACK and Huffman decoding — the classic CVE classes are handled.** Integer decoding bounds
continuation octets at five with a division-based pre-multiply overflow check; index 0 and
out-of-range indices are rejected; entry size is `Name + Value + 32` with oversized entries
clearing the table, and the eviction condition cannot underflow. Decoded size is bounded both
per-string and per-list against the 16 KiB budget the connection actually advertises, closing the
HPACK-bomb class. Huffman rejects the EOS symbol anywhere, padding longer than 7 bits or not
all-ones, and caps output length.

**HTTP/2 framing, padding, and stream identifiers.** Fixed frame lengths and the
stream-ID-zero rules are enforced per frame type. The padded-frame length comparison happens
*after* advancing past the pad-length and priority octets, each advance length-checked first, so
the CVE-2019-9516 underflow class is closed. Accumulated header blocks are bounded at 64 KiB,
closing the CONTINUATION-flood class (CVE-2024-27316) — finding 15 is a state-machine defect in
the same code, not a flood. Even client-initiated and non-increasing stream IDs are refused,
concurrency is capped with reset-but-unreaped streams still counted, and a 32 KiB control backlog
applies read backpressure against RST_STREAM/PING amplification (CVE-2023-44487).

**HTTP/2 pseudo-header rules.** Pseudo-headers after regular fields, duplicates, unknown
pseudo-headers, and pseudo-headers in trailers are all rejected; connection-specific fields and
`te` with any value but `trailers` are rejected; non-lowercase field names are rejected. What is
missing is *octet* validation of the four accepted values — findings 3 and 16.

**WebSocket handshake and framing — thorough.** `Sec-WebSocket-Accept` uses the correct GUID with
correct SHA-1 padding and Base64; the version must equal 13; `Connection`/`Upgrade` matching is
comma-token-aware and case-insensitive, so substrings do not match; the key must be exactly 24
base64 characters. Origin checks are exact and fail closed — the default rejects any `Origin`, and
`Require_Exact_Origin` requires exactly one byte-equal header, so a request with no `Origin`
cannot bypass an allowlist. Every RFC 6455 MUST-reject is present: unmasked client frame, RSV bits
without a negotiated extension, unknown opcode, fragmented control frame, control payload over
125, non-minimal 16- and 64-bit lengths, 64-bit MSB set, continuation with no preceding fragment,
and a new data frame inside a fragment. The declared length is accumulated in `Unsigned_64` and
bounds-checked *before* narrowing, so a huge length cannot wrap or raise.

**WebSocket masking and UTF-8 across fragments.** The mask offset is computed relative to the
frame payload start with the position persisted in the connection cursor, so it stays correct
across 16 KiB chunk boundaries and across separate receive calls. UTF-8 is validated on the
*complete reassembled message*, which is the correct handling for a multi-byte character split
across fragments, and it runs after inflation. Both validators reject overlong forms, surrogates,
and values above U+10FFFF. Close-code validation accepts exactly 1000–1003, 1007–1014, and
3000–4999, rejects 1-byte payloads, UTF-8 validates the reason, and echoes exactly once.

**permessage-deflate — the decompression bomb is bounded.** `Ensure_Output` raises before the
match-copy loop with the maximum set to the connection's message limit, mapped to close 1009;
`Append_Match` rejects a zero or too-large distance; Huffman trees reject oversubscribed,
incomplete, and duplicate codes; reserved block type 3 and reserved length/distance symbols are
rejected. Window-bits negotiation is safe by construction — the server declines any offer it
cannot honour with its fixed 32 KiB encoder — and extension-parameter parsing rejects duplicates,
unknown parameters, and bad quoting.

**SSE on the HTTP/1.1 path.** Data is newline-split into repeated `data:` fields with correct
CRLF handling; `Event` and `Id` are rejected outright if they contain CR or LF; comments are
newline-split and re-prefixed. No client-controlled value can reach the stream unescaped on this
backend — which is exactly the contrast that makes finding 4 a regression.

**Middleware chain coverage — no alternate entry point.** WebSocket, SSE, and HTTP/2 all run the
identical chain: HTTP/2 dispatches through the same `Routing.Dispatch`, and WebSocket and SSE are
not separate entry points but run from inside an already-routed handler, gated on the route's
upgrade mode. Every response path refuses a sub-400 response on a `Required_Authentication` route
with no principal, and the router appends its own `Require_Authentication` between the
`Request_Head` and `Application` stages, so an application that omits or misplaces its auth
middleware gets a 401 rather than a served request. A genuinely strong fail-closed design;
findings 11 and 30 are holes in it.

**No exception text reaches a response.** `Exception_Message`, `Exception_Information`, and
`Exception_Name` appear nowhere in `src/`. Error paths emit fixed problem+json bodies; tracebacks
reach only the application's log sink.

**Rate-limit arithmetic and bulkhead permits.** `Refilled_Tokens` is SPARK-contracted, saturates
at one second of capacity so a long idle interval is never multiplied out, and defaults to the
monotonic clock; `Admit` initializes its result to `False` and sets it only after a successful
deduction. Bulkhead permits are released by a `Limited_Controlled` `Finalize`, so they cannot leak
on an exception unwind.

**Metrics cardinality.** Protected state, saturating arithmetic throughout, series bounded at a
configurable capacity with drop counting, and route names that come from the registered route
table or a fixed set of literals — never a raw request path — so a client cannot inflate
cardinality.

**Ada range and index safety in the HTTP layer.** Every fixed-offset slice and decrement in scope
was individually checked, including the `'First + 6`/`'First + 7` scheme slices, the bracketed
IPv6 chain, `Read_Line`'s `Marker - 1`, and `Copy_Pending`'s subtraction. Checks are on: there is
no `-gnatp` in `flyology_http.gpr` or its scripts, and nothing under `src/` withs the IRI crate,
so finding 43's suppression cannot reach the HTTP parsers. All overflow concerns in the HTTP layer
are therefore `Constraint_Error` at worst, never memory corruption.

**URL host confusion and SSRF normalization — verified by execution.** Against the built CLI, all
of these parse correctly: `http://evil.com@good.com/`, `http://good.com/@evil.com`,
`http://good.com\@evil.com`, `http://good.com?@evil.com`, `http://a@b@good.com/` (all host
`good.com`); the IPv4 shorthands `127.1`, `0x7f.1`, `2130706433`, `0177.0.0.1` (all normalized to
`127.0.0.1`, so a downstream resolver cannot disagree); tab and newline stripping; full-width and
ideographic dot mapping; `%2e` host decoding; uppercase lowercasing. Port handling rejects
`99999`, `+80`, `-80`; authority handling rejects a bare `:`, an unclosed bracket, a non-IPv6
bracket literal, too many IPv6 groups, a zone ID, NUL, and a space. Path normalization is correct
on `/a/../../b`, `/a/./b`, `/..`, `/a//b` (empty segments preserved, not collapsed), `%2e%2e`, and
`..%2f`. The complete RFC 3986 §5.4 resolution suite passes — which is precisely how finding 1
hid.

**Supply chain and secrets.** No private keys, certificates, or hardcoded credentials are tracked.
CI pins every action by commit SHA, declares `permissions: contents: read`, uses no
`pull_request_target`, and interpolates no untrusted input into `run` blocks. The website kit
submodule is pinned to a commit and there are no npm dependencies. Shell scripts use `mktemp -d`
correctly and carry proper shebangs.

## Appendix: refuted candidates

- **Response splitting via `Add_Header`/`Redirect`.** Refuted: name and value validation reject CR,
  LF, and all controls before the value reaches the header block. A user-controlled `Location`
  yields a `Program_Error`, and thus a 500, not a split response.
- **Metric cardinality explosion from client-controlled route labels.** Refuted: `Route_Name`
  derives from the registered route table or from fixed literals, never from the request path, and
  the sink is capacity-bounded with drop counting regardless.
- **Credential leak across a cross-origin redirect.** Refuted: cross-origin redirects are not
  followed at all; they are returned to the caller.
- **Open redirect via the `Raw_Path` confusion (finding 2).** Refuted as a separate issue:
  `Decode_Path` rejects `//`, so `/x?a=b:////evil.com/y` becomes a 400. Finding 2 is route
  confusion only.
- **Punycode decoder integer overflow (RFC 3492 adaptation loop).** Not applicable rather than
  refuted: the crate implements only the encode direction, whose two overflow guards are both
  present and fail closed. The absence of a decoder is itself reported, as finding 13.
- **CONTINUATION flood (CVE-2024-27316).** Refuted: accumulated header blocks are bounded at
  64 KiB.
- **Runtime "ambiguous HTTP route match" as a request-time DoS.** Refuted: `Check_Add` rejects
  same-method overlapping patterns of equal specificity at registration, making the runtime raise
  unreachable.
- **Blocking operation inside a protected body (`Program_Error`) in the client pool.** Refuted:
  the call is a protected *function* call, which RM 9.5.1(8-16) does not classify as potentially
  blocking. Reported as contention only, finding 37.
- **Unbounded response-body or header memory growth in the client.** Refuted: the response head is
  bounded at 16 KiB and 64 fields, `Read_All` enforces a maximum and abandons the response when
  exceeded, and no `Content-Encoding` decompression exists to bomb.
- **`Flyology.Buffers.With_Readable_Data` performing a blocking write inside a protected body.**
  Refuted: it is a plain subprogram, not a protected operation, so `Program_Error` is not
  possible.
- **Missing shebang in `flyology_iri/scripts/test.sh`.** Refuted by inspection: `#!/bin/sh` is
  present, as in the crate's other scripts.
- **`flyology_iri` not wired into the test suite.** Refuted: `scripts/test.sh:83` invokes the
  crate's test script and its unit tests build and pass. Only the WPT stage is skipped, which is
  finding 22.
- **WebSocket fragmentation bomb from unbounded zero-length continuation frames.** Refuted as a
  memory issue: memory is bounded by the message limit and time by the message timeout and
  connection age. It remains a bounded per-connection CPU cost with no explicit fragment-count
  cap, which the reviewer did not measure.

## Coverage gaps

Stated plainly so the gaps are not mistaken for clean results.

- **Nothing was executed except the `flyology_iri` crate.** The HTTP/1, HTTP/2, WebSocket, and
  client findings are from source reading. The full test suite, h2spec, Autobahn, and the WPT
  corpus were not run, so the conformance-baseline conflict in finding 33 is reported as a
  conflict rather than resolved, and the "146 of 146" and Autobahn claims in `docs/` were not
  independently confirmed.
- **Findings 4, 5, 9, 10, 12, 14, 15, 17, 18, 19, 21, 23, 24, 25, 26, 27, 29, 30, 31, 33, 34, 35,
  36, 37, 38, 39, 40, 41, and 42 rest on a reviewer's reading that I did not independently
  re-derive.** Findings 5, 21, 39, 40, 41, and 42 include measurements the URL reviewer made
  against a build. Finding 10 in particular claims high severity on a livelock that deserves a
  targeted reproduction before remediation.
- **Fresh HTTP/2 and SSE surface is the least-settled area.** The HTTP/2 engine arrived in the
  most recent commits, and five findings (3, 7, 8, 14, 16) plus finding 4 come from it, several
  from the server having diverged from a correct client implementation of the same logic. A
  systematic server/client differential over the two connection state machines would likely find
  more.
- The HTTP/2 SSE backpressure path (`Queue_Data`, flow-control windows, `Await_Drained`) was not
  audited; finding 4 rests on the serializer only.
- The WebSocket *client* has never been run against Autobahn's client-under-test role; its
  conclusions are from reading plus the smoke test.
- The `flyology` runtime dependency (sockets, TLS controller, connections, DNS, buffers, the
  cancellation token, the buffer pool allocator) is out of scope. The client's whole-exchange
  deadline guarantee rests on `Connections.Receive` and `Send_All` honouring the deadlines passed
  to them, which was not verified.
- The 257 Huffman code/length table constants were not checked digit-by-digit against RFC 7541
  Appendix B; the decoder algorithm and its bounds were.
- `App_Context` is shared by reference across per-stream HTTP/2 handler tasks; whether
  application-side mutation of it is race-free was not audited.
- Two `flyology_iri` items the URL reviewer flagged but could not settle without the pinned
  corpus, left unfiled: `Must_Encode` places `^` in the path percent-encode set, which the WHATWG
  set may not include, and `Encode_Opaque_Path` handles only a single trailing space before `?`
  or `#`.
- `Port` returns a `String` and RFC modes accept arbitrary digit strings, so
  `http://example.com:99999999999999999999/` parses. No overflow occurs inside the crate, but
  callers converting `Port` to an integer must bound it themselves, and `flyology_iri.ads:201`
  does not say so.
