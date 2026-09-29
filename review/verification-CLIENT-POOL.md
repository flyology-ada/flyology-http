# Verification: CLIENT-POOL

Commit: f078732

Findings examined: 8. Confirmed: 4. Refuted: 0. Partial: 2. Other: 2
(1 duplicate of a confirmed finding in another area, and CLIENT-POOL-6 whose code
disagreement is confirmed while the race is unreproducible here).

| ID | Discovery severity | Verdict | Final severity | Repro |
|----|--------------------|---------|----------------|-------|
| CLIENT-POOL-1 | P1 | CONFIRMED | P1 | `repro_client_pool_1` |
| CLIENT-POOL-2 | P1 | CONFIRMED | P1 | `repro_client_pool_2` |
| CLIENT-POOL-3 | P1 | DUPLICATE of H1-CLIENT-2 (CONFIRMED there) | P1 | `repro_h1_client_2` (owned by H1-CLIENT) |
| CLIENT-POOL-4 | P2 | CONFIRMED | P2 | `repro_client_pool_4` |
| CLIENT-POOL-5 | P2 | CONFIRMED | P2 | none possible (documentation and dead proved code) |
| CLIENT-POOL-6 | P2 | PARTIALLY CONFIRMED (code disagreement yes; race UNVERIFIABLE-BY-SPIKE) | P2 | none |
| CLIENT-POOL-7 | P2 | PARTIALLY CONFIRMED (defect yes; "reachable" no) | P2 | none |
| CLIENT-POOL-8 | P2 | PARTIALLY CONFIRMED (defect yes; trigger needs a seam) | P2 | none |

Nothing was refuted. Two severities moved in neither direction; all eight kept the
discovery's rating, which is unusual and worth saying plainly rather than dressing up: this
discovery set was accurate. The corrections I did make are to *premises*, not verdicts —
CLIENT-POOL-6's "hard without a hook" is wrong for one of its two routes (a barrier point
already exists, and no QUIC peer is needed), and CLIENT-POOL-7's "reachable" is weaker than
stated (abort only). Both are recorded in place.

Run every spike from the worktree root:

```sh
./tests/repros/run.sh repro_client_pool_1 90
./tests/repros/run.sh repro_client_pool_2 120
./tests/repros/run.sh repro_client_pool_4 120
```

## CLIENT-POOL-1: Same-origin relative redirect whose query contains `://` raises `Redirect_Error`

- **Verdict:** CONFIRMED
- **Severity:** P1 (discovery said P1; unchanged)
- **Repro:** `tests/repros/src/repro_client_pool_1.adb`, run with
  `./tests/repros/run.sh repro_client_pool_1 90`
- **Output:**

```
  note Location served: /next?u=https://example.com/home
  note peer saw request 1: GET /login HTTP/1.1
  note peer saw request 2:
  note Execute raised: FLYOLOGY.HTTP.CLIENT.REDIRECT_ERROR: unsupported redirect URI scheme
  FAIL Execute follows a same-origin relative redirect whose query contains "://" instead of raising Redirect_Error
  FAIL the resolved same-origin target is requested on the reused transport
         expected: [GET /next?u=https://example.com/home HTTP/1.1]
         actual:   []
  FAIL Execute returns the status served at the target
         expected: 200   actual:-1
  FAIL Execute returns the target's body
         expected: [ok]
         actual:   []
checks: 4  failures: 4
BUG REPRODUCED
EXIT=1
```

- **Description:** `Resolve_Redirect` (`src/flyology-http-client.adb:6301`) selects its
  absolute-URI branch with an unanchored scan, `Ada.Strings.Fixed.Index (Reference, "://")
  /= 0`. The anchored classifier `Has_URI_Scheme` at `:6256-6265` — which does require the
  colon to precede any `/` or `?` — sits in the *following* `elsif`, so it never sees a
  reference that contains `://` anywhere. For the ordinary return-to / OAuth `redirect_uri`
  shape `Location: /next?u=https://example.com/home`, the text before the first `://`
  becomes the scheme name `"/next?u=https"`, which matches neither `"http"` nor `"https"`,
  and `Redirect_Error "unsupported redirect URI scheme"` is raised. RFC 3986 s4.2 defines
  `relative-ref` as beginning with `relative-part`, and s3.1 defines `scheme` as
  `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )` terminated by the first `:`; a reference
  beginning with `/` therefore has no scheme component and RFC 9110 s10.2.2 requires
  `Location` to be resolved as a URI-reference per RFC 3986 s5. `flyology-http-client.ads:46`
  promises `Follow_Same_Origin` "Follow eligible redirects within the client origin". The
  spike shows the peer never receives the second request: the caller gets an exception
  instead of the resource. Reachable through `Execute`/`Execute_Redirects`
  (`src/flyology-http-client.adb:6663`) and through the SSE client's
  `Resolve_Redirect_Target` (`src/flyology-http-client-sse.adb:761`). Under the default
  `Return_Redirects` mode the response is handed back untouched, so only following breaks.
- **Not a security defect.** I checked the misclassification for an open-redirect direction:
  `Name` can only equal `http`/`https` when the reference genuinely starts with that scheme,
  and `Parse_Absolute` recomputes the split from the *first* `://`, so a hostile
  `http://good/x?u=https://evil/` still parses `good` as the authority. The failure mode is
  refusal, not retargeting.
- **Same class as a previously fixed site.** The previous audit's finding 2 was the
  identical unanchored `://` scan in the server's `Raw_Path`
  (`src/flyology-http-server-routing.adb`). That one was fixed — `Absolute_Form_Authority`
  at `routing.adb:283-286` now uses an anchored `Has_Scheme_Prefix` test, with the comment
  "Searching the whole target for `://` would treat a query string that carries a URL as the
  request-target's own authority". The client-side twin was not fixed. A maintainer should
  know the remedy already exists one file over.
- **Coverage gap:** `tests/http_client_redirects.adb:266` is the closest case
  (`../next?x=1#ignored`); no `Location` value anywhere under `tests/` contains `://` after
  the first path character. The green baselines do not cover it either: this is a
  client-side reference classifier and none of h2spec, Autobahn, the HTTP/3 interop run or
  the PycURL differential (`review/baselines/18-differential-run.log`) drives redirect
  following with a URL-bearing query.

## CLIENT-POOL-2: Synchronous 417 fallback retries after body transmission with a consumed, un-rewound source

- **Verdict:** CONFIRMED
- **Severity:** P1 (discovery said P1; unchanged — see the severity note below)
- **Repro:** `tests/repros/src/repro_client_pool_2.adb`, run with
  `./tests/repros/run.sh repro_client_pool_2 120`
- **Output:**

```
  note request 1 head: POST /late-417 HTTP/1.1\x0d\x0aHost: 127.0.0.1:52544\x0d\x0aExpect: 100-continue\x0d\x0aContent-Length: 17\x0d\x0a\x0d\x0a
  note request 1 body: [late-417-body-xyz]
  note request 2 head: POST /late-417 HTTP/1.1\x0d\x0aHost: 127.0.0.1:52544\x0d\x0aContent-Length: 17\x0d\x0a\x0d\x0a
  note Execute raised: FLYOLOGY.HTTP.CLIENT.REQUEST_BODY_ERROR: flyology-http-client.adb:6584
  note source reads: 2
  ok   precondition: the whole declared body reached the origin before 417
  FAIL Execute returns the 417 instead of failing on a consumed source
  FAIL the 417 received after body transmission is the caller's response
         expected: 417   actual:-1
  FAIL no second request: the .ads retries only a 417 received BEFORE body transmission
         expected: []
         actual:   [POST /late-417 HTTP/1.1
Host: 127.0.0.1:52544
Content-Length: 17

]
  note chunked request 1 body: 11\x0d\x0alate-417-body-xyz\x0d\x0a0\x0d\x0a\x0d\x0a
  note chunked retry on the wire: POST /late-417-chunked HTTP/1.1\x0d\x0aHost: 127.0.0.1:52544\x0d\x0aTransfer-Encoding: chunked\x0d\x0a\x0d\x0a0\x0d\x0a\x0d\x0a
  note chunked status: 200
  ok   precondition: the whole chunked body reached the origin before 417
  FAIL Unknown_Length: no second POST is sent after body transmission
         expected: []
         actual:   [POST /late-417-chunked HTTP/1.1
Host: 127.0.0.1:52544
Transfer-Encoding: chunked

0

]
  FAIL Unknown_Length: the 417 is the caller's response
         expected: 417   actual: 200
checks: 7  failures: 5
BUG REPRODUCED
EXIT=1
```

- **Description:** `flyology-http-client.ads:222-227` scopes the fallback precisely: "A
  positive wait expiry with no partial response sends the body ... A 417 final response
  received **before body transmission** is retried once on a fresh transport without the
  expectation." The wrapper's branch at `src/flyology-http-client.adb:6636-6647` tests only
  `Status (Reply) = 417 and then Current.Expect_Continue and then not Retried`. It consults
  neither a body-sent flag nor `Reply.Data.Request_Incomplete`, and it hands the same
  `Request_Body_Source` object, at its current position, to the next
  `Execute_Operation_Once` without rewinding it or requiring
  `Rewindable_Request_Body_Source`. The engine does not enforce "before body transmission"
  either: once `Continue_Wait` expires, `Probe_Early_Response`
  (`src/flyology-http-client.adb:3779-3790`) clears `Expect_Waiting`, sets
  `Request_Incomplete := False` and resumes `Pulling_Source`, after which any final response
  — including 417 — arrives as an ordinary `Response_Complete`. RFC 9110 s10.1.1 says a
  server that cannot meet the expectation "MUST respond with a 417 (Expectation Failed)
  status code"; nothing in the clause requires that response to precede the body, and it
  also permits the client to send the body after waiting, so the scenario is legitimate
  origin behaviour rather than a hostile peer.
  Both observed outcomes are in the spike's transcript:
  - **Known length.** The retry announces `Content-Length: 17` on a fresh transport, then
    `Pull_Source` (`:3612-3618`) sees `Source_Finished` with `Source_Transferred = 0 /= 17`
    and fails `Request_Source_Failed`, which the wrapper turns into `Request_Body_Error`
    (`:6584`). The caller gets an exception instead of the 417 the origin actually sent,
    and the origin is left holding a truncated POST message.
  - **Unknown length (chunked).** The retry is worse because it is *silent*: a second,
    well-formed `POST /late-417-chunked` goes out with `0\r\n\r\n`, i.e. an empty body under
    the same non-idempotent method and target. In the spike the origin answers 200 and the
    caller receives 200, having no way to learn that the server saw one 17-byte POST
    followed by one empty POST. RFC 9110 s9.2.2 notes that POST is not idempotent, so
    re-sending it with different content is a semantic change the client must not make on
    its own.
- **The dropped guard is on record.** This condition used to be a proved SPARK input.
  `git show f0d630d -- src/flyology-http-client.adb` removes the call

```ada
-                        if Classify_Expectation_Response
-                          (Expectation_Sent => Use_Expectation,
-                           Body_Sent        => Body_Sent,
-                           Already_Retried  => Retried,
-                           Status           => Result.Data.Status_Value,
```

  and nothing replaced the `Body_Sent` input. See CLIENT-POOL-5.
- **Severity note.** I considered P0 for the chunked case under "silent corruption of
  request or response bytes", and settled on P1: no byte is corrupted, the second request is
  a syntactically valid message, and the trigger needs the origin to answer 417 after
  accepting the body. It is nonetheless the more serious of the two shapes and the fix must
  cover it — requiring a rewindable source and rewinding it would repair the known-length
  case while leaving the silent empty re-POST in place. The correct fix is the `Body_Sent`
  guard the proved classifier already carries.
- **Coverage gap:** `tests/http_client_upload_controls_smoke.adb:318-330,522-528` covers
  417 arriving *before* the body (`Expect_Head_Only` then 417), which is the retryable case,
  and `:505-513` covers a 0.02 s wait expiring followed by a 200. No maintained test sends a
  417 after the body. None of the green baselines reach it either: the PycURL differential
  (`review/baselines/18-differential-run.log`) does not script a late 417, and h2spec and
  Autobahn are server-side.

## CLIENT-POOL-3: Negative `Expect: 100-continue` wait sends the body immediately

- **Verdict:** DUPLICATE of `H1-CLIENT-2` (which is CONFIRMED, P1)
- **Severity:** P1, as recorded by the owning entry
- **Repro:** none written here by design. `review/verification-H1-CLIENT.md` already carries
  the primary entry and its reproduction, `tests/repros/src/repro_h1_client_2.adb`, whose
  transcript shows 4096 body bytes reaching the peer before 100 Continue with
  `Wait_Timeout => -1.0` against 0 bytes with `Wait_Timeout => 1.0`.
- **Description:** the same statement at the same site
  (`src/flyology-http-client.adb:3768-3782`, `Probe_Early_Response`) and the same `.ads`
  sentence. I independently confirmed the runtime half of the argument against the pinned
  dependency rather than the discovery text:
  `~/.local/share/alire/releases/flyology_0.1.1_bd95746d/src/flyology-operations-drivers.ads:58-63`
  documents `Arm_Deadline` as "Set or replace one operation deadline. A nonpositive interval
  is due on the next completion-set drive." Neither `Duration'Min (Continue_Wait, Remaining
  (State.Deadline))` nor the unlimited-deadline branch normalizes a negative
  `Continue_Wait`, and `Set_Expect_Continue` (`:2217-2224`) stores it unchanged. Close
  CLIENT-POOL-3 against H1-CLIENT-2; do not fix it twice.
- **Provenance nit for the coordinator, so two reports do not look contradictory.**
  `review/verification-H1-CLIENT.md` attributes the same `Arm_Deadline` sentence to
  `flyology_6f91b1af`. That directory is the pinned **`flyology_allocators`** crate, not the
  runtime. Mapping `alire/alire.lock` crate-by-crate gives `flyology =
  bd95746d5c9c31f5b41b611db9ba82a016ceaaa4`, `flyology_allocators = 6f91b1af...`,
  `flyology_cachelines = 8e046108...`, `flyology_quic = eb09a80a...`, so the runtime that
  owns `Flyology.Operations.Drivers` is `flyology_0.1.1_bd95746d`. I read the sentence there
  and it is word-for-word identical, so H1-CLIENT-2's finding is unaffected — only its cited
  path needs correcting.

## CLIENT-POOL-4: Synchronous safe-method exchanges can replay twice

- **Verdict:** CONFIRMED
- **Severity:** P2 (discovery said P2; unchanged — the rubric's "wrong diagnostics ... or
  contract drift" is exactly this)
- **Repro:** `tests/repros/src/repro_client_pool_4.adb`, run with
  `./tests/repros/run.sh repro_client_pool_4 120`
- **Output:**

```
  note pooled transports that received the retried head: 2
  note Stale_Retries charged to the exchange: 2
  ok   Execute completes the exchange
  ok   the fresh transport answers 200
  ok   the response body arrives
  FAIL the .ads documents Stale_Retries as an idempotent exchange 'retried once'
         expected: 1   actual: 2
checks: 4  failures: 1
BUG REPRODUCED
EXIT=1
```

- **Description:** `flyology-http-client.ads:162-163` documents `Stale_Retries` as
  "Idempotent exchanges retried **once** after an existing transport failed before producing
  response bytes". Two independent retry sites can both fire for one `Execute`. The engine's
  internal stale retry (`src/flyology-http-client.adb:925-957`) is guarded by
  `Safe_Retry_Used`, but it re-enters `Exchange_Idle`, and the next `Checkout_Idle`
  (`:5455-5457`) sets `Was_Reused := True` again. Admission is monotonic across that retry —
  the code says so in place, "admission certainty is monotonic across an internal
  stale-connection retry" (`:946-948`) — so it stays `Possibly_Admitted`, which disables the
  engine's second pass but still satisfies the wrapper's predicate at `:6529-6548`. The
  wrapper's own `Retried.all` flag is never touched by the engine retry. The spike primes
  two idle HTTP/1 transports, has the origin drop each one only after reading the retried
  head (the post-handoff shape that
  `tests/http_client_composable_stale_reuse.adb:240-246` deliberately arranges), and
  observes both pooled transports receiving the retried head and `Stale_Retries` advancing
  by 2 for the one exchange. Three transports are touched where the contract describes two.
  Only safe methods with no request source reach the engine branch, so there is no semantic
  harm on the wire; what drifts is the documented retry bound and the diagnostic counter a
  caller would use to detect churn.
- **By inspection, not reproduced:** the engine's *second* branch, the pre-handoff replay at
  `:958-971` (`Admission = Not_Admitted and then Was_Reused`), has no `Safe_Retry_Used`-style
  guard at all and also clears only `Was_Reused`, so on its own terms it can fire once per
  dead idle transport. My spike's count of 2 is equally consistent with branch 1 plus the
  wrapper, so I am not claiming the unbounded case; it is worth a look when this is fixed.
- **Existing coverage:** `tests/http_client_composable_stale_reuse.adb:305-306` asserts
  `Stale_Retries = 1` with a single stale idle connection, which is the case that behaves.
  No maintained test primes two.

## CLIENT-POOL-5: Four proved `Client_Policy` classifiers have no production caller; `proof-status.md` still says they are consumed

- **Verdict:** CONFIRMED
- **Severity:** P2 (discovery said P2; unchanged). Not a runtime defect: nothing
  misbehaves at run time because of this entry alone. What is wrong is a proof-evidence
  claim that is false, plus four proved subprograms that are dead outside their own smoke
  test. It matters because it is the mechanism behind CLIENT-POOL-2.
- **Repro:** none, and none is possible: there is no runtime behaviour to observe. The
  claim is exactly checkable and I checked it mechanically rather than by reading the
  discovery text.

```
$ rg -n 'Classify_Stale_Retry|Classify_Expectation_Response|Validate_Upload|Classify_Pull' src/
  (only src/flyology-http-client_policy.ads and .adb match)

$ rg -n 'Classify_Informational|Next_Informational_Count|Classify_Redirect' src/
src/flyology-http-client-http_1_internals.adb:332,343,538,547
src/flyology-http-client.adb:6629

$ git log --oneline -S'Classify_Expectation_Response' -- src/flyology-http-client.adb
f0d630d Problem: HTTP client exchanges block inside duplicate protocol engines
1a25f7f Problem: Flyology HTTP is coupled to the runtime repository
```

  The same two-commit history holds for `Classify_Stale_Retry`, `Validate_Upload` and
  `Classify_Pull`: introduced in `1a25f7f`, last caller removed in `f0d630d`
  (2026-08-23). `git show f0d630d -- src/flyology-http-client.adb` shows all three
  call sites being deleted (`-      case Validate_Upload`,
  `-              (Classify_Stale_Retry`, `-                        if
  Classify_Expectation_Response`) with nothing added in their place.
- **The false sentences.** `proof/proof-status.md:68-70` still says:

```text
The HTTP client upload-policy review adds a production-consumed SPARK boundary
for request/source compatibility, exact known-length pull completion,
informational-response accounting, stale-connection replay eligibility, and
the one-attempt `417 Expectation Failed` fallback.
```

  and `:402-403` still ticks:

```text
- [x] Confirm production request, upload, response, and retry paths consume the
      proved classifications
```

  Of the five boundaries named, only informational-response accounting is production
  consumed (`Classify_Informational` and `Next_Informational_Count` in
  `http_1_internals.adb`); `Classify_Redirect` is consumed at `client.adb:6629` but is not
  one of the five. Request/source compatibility (`Validate_Upload`), exact known-length pull
  completion (`Classify_Pull`), stale-connection replay eligibility
  (`Classify_Stale_Retry`) and the one-attempt 417 fallback
  (`Classify_Expectation_Response`) have no caller under `src/`. Their behaviour now lives
  in hand-written predicates with different inputs: the replay decision in `Fail_Exchange`
  (`:925-971`) and `Execute_Operation_Once` (`:6513-6548`), split into a safe-vs-idempotent
  pair with `Has_Mutation_Condition`; the pull decision inline in `Pull_Source`
  (`:3574-3640`); and the 417 decision in `Execute_Redirects` (`:6636-6647`) with no
  `Body_Sent` input at all.
- **Why the suite cannot see it.** `tests/flyology-http-client_policy-smoke.adb` calls all
  four directly, so both the behavioural suite and `./scripts/prove.sh` stay green while the
  shipped paths no longer consume them. A reader of `proof-status.md` or the CHANGELOG would
  take the SPARK proof as evidence for the shipped replay and 417 behaviour; CLIENT-POOL-2
  and CLIENT-POOL-4 are the two places where that reading is wrong. A `scripts/test.sh`
  invariant that each proved policy function has at least one caller under `src/` outside
  its own unit would have caught this at the commit that broke it.

## CLIENT-POOL-6: Shutdown racing HTTP/3 establishment reports `Transport_Failed`/`Device_Error`

- **Verdict:** PARTIALLY CONFIRMED — the classification disagreement is confirmed by
  reading and quoted in full below; the race itself is UNVERIFIABLE-BY-SPIKE
- **Severity:** P2 (discovery said P2; unchanged)
- **Repro:** none written. I want to correct the discovery's premise here rather than
  repeat it: a usable seam **does** exist for one of the two routes. `client.adb:3335-3337`
  parks at `Connection_Test_Hooks.Barrier (16)` —
  `Flyology.IO.Connections.Testing.Barrier_Point'Pos (Before_HTTP_Client_Connect) = 16`,
  `tests/flyology-io-connections-testing.ads:2-19` — immediately before the
  `if State.Creating_HTTP_3 then Start_HTTP_3_Connection (Address);` at `:3348-3349`, and
  `Publish_Connecting` (`:3271-3273`) runs after a purely local UDP `Connect_Socket`, so
  **no live QUIC peer is needed** to make it raise `Client_Closed`: park a `Require_HTTP_3`
  exchange at that barrier, call `Shutdown` from a second task, release, and the outer
  `others` at `:6017-6022` turns it into `Transport_Failed` / `Device_Error`. I did not
  build it because the seam is compiled out of the reproduction harness:
  `flyology_http.gpr:7-20` selects `src/test_hooks/connection/enabled/` only when the
  external `FLYOLOGY_CONNECTION_TEST_HOOKS` is `"true"`, `tests/repros/run.sh` does not set
  it, and turning it on would rebuild the object directory that the other verifiers' spikes
  share while they are running. **What would settle it:** that two-task test in the
  maintained suite (where the hooks build already exists — `lib/http-client-connection-hooks`
  and `lib/behavioral-connection-hooks` are built with it), asserting
  `Kind = Client_Unavailable` and `Execute` raising `Client_Closed`. The second route,
  `Pool.Install` inside the `HTTP_3_Open_Request` arm, has no barrier and would additionally
  need one there.
- **The three sites disagree; all three quoted.**

TCP connect — `src/flyology-http-client.adb:5592-5596`, `Waiting_For_Connect`:

```ada
               when Error : others =>
                  ...
                  Fail_Exchange
                    (Item,
                     (if Owner.Pool.Is_Stopping
                      then Client_Unavailable else Connection_Failed));
```

TLS — `src/flyology-http-client.adb:5652-5656`, `Waiting_For_TLS`:

```ada
               when Error : others =>
                  ...
                  Fail_Exchange
                    (Item,
                     (if Owner.Pool.Is_Stopping
                      then Client_Unavailable else Connection_Failed));
```

HTTP/3 — `src/flyology-http-client.adb:5414-5417`, the handler closing
`Drive_HTTP_3_Protocol`:

```ada
      exception
         when Error : others =>
            Remember_Failure (State, Error);
            Fail_Exchange (Item, Transport_Failed);
      end Drive_HTTP_3_Protocol;
```

  The DNS arm at `:5560-5563` carries the same `Is_Stopping` test as the TCP and TLS arms,
  so the H3 handler is the only one of the four establishment handlers without it.
- **Description:** `Pool_Controller.Install` and `Publish_Connecting` both
  `raise Client_Closed` when the pool is `Stopping`
  (`src/flyology-http-client-pool_controller.adb:292-293` and `:339-340`). On the HTTP/3
  path that exception has two routes and both lose the classification. `Pool.Install` at
  `:4963-4967`, inside the `HTTP_3_Open_Request` arm, is caught by the handler quoted above
  and becomes `Transport_Failed`. `Publish_Connecting` at `:3272`, reached from
  `Preparing_Connect`/`Preparing_Resolved_Address` (`:5499`, `:5502`) when the origin needs
  no DNS lookup, has no arm-local handler at all and falls through to the engine's outer
  `others` at `:6017-6022`, which also produces `Transport_Failed`. (Reached instead through
  `Waiting_For_DNS` at `:5530` it *is* mapped correctly, so the outcome depends on whether a
  name lookup was required — which is itself a reason to fix it.) The synchronous wrapper
  re-raises `Failure_Cause` only for `TLS_Error`, `Protocol_Error`, `Response_Too_Large`,
  `Device_Error`, `Socket_Error` and `Request_Source_Failed` (`:6549-6566`); `Client_Closed`
  is not in that set, so `Execute` falls to `when Transport_Failed => raise
  Flyology.IO.Device_Error` (`:6580-6581`). The caller therefore sees
  `Flyology.IO.Device_Error` where `flyology-http-client.ads:510` documents
  "`@exception Client_Closed` Client is stopping", and a composable caller sees
  `Transport_Failed` where `:690` defines "`Client_Unavailable` Client is stopped or cannot
  admit new work". In `Negotiate_HTTP_3` the address-retry branch replays through TCP, where
  `Try_Checkout` returns `Checkout_Closed` and `Fail_Exchange (Item, Client_Unavailable)`
  (`:5494`), so the outcome self-corrects; under `Require_HTTP_3` it does not. I did not
  re-derive the discovery's `Negotiate_HTTP_3` claim by execution.

## CLIENT-POOL-7: `Exchange_Operation.Finalize` frees a response-head `Reply_Data` without returning its lease

- **Verdict:** PARTIALLY CONFIRMED — the code defect is confirmed and is contradicted by
  its own in-source comment; the "reachable path" half does not hold, so there is no
  reproduction
- **Severity:** P2 (discovery said P2; unchanged). It would be P1 or P0 if reachable
  without abort, because an unreturned lease stalls the pool permanently, but see below.
- **Repro:** none. Reachability is abort-only or caller-contract-violation, as detailed
  below; I did not manufacture one with `abort`, because a spike that has to abort a task to
  hit a window says nothing the code reading does not already say.
- **The defect.** `src/flyology-http-client.adb:1926-1929`:

```ada
         Release_Exchange_Borrows (Item.State.all);
         if Item.State.Reply_Data /= null then
            Free_Response_Data (Item.State.Reply_Data);
         end if;
```

  `Free_Response_Data` is a plain `Ada.Unchecked_Deallocation` (`:535`). For
  `Response_Head_Target` the record it frees is the one `Finish_Response_Head` built at
  `:1167-1175`, which carries `Connection`, `Slot_Index` and `Retains_Owner => True` after
  `Candidate.Owner.Lifetime.Retain_Response`. `Finish_Response_Head` deliberately nulls
  `State.Connection`, `State.Slot_Index` and `State.Metadata` before `Complete_Exchange`
  ("Ownership is now exclusively in Reply_Data", `:1177-1179`), so the two
  `Release_Exchange_Transport` calls earlier in `Finalize` see nothing to release. The
  routine that knows how to retire such a record is `Response.Finalize` (`:7369-7403`),
  which calls `Abandon_Response` and then `Release_Response`; `Exchange_Operation.Finalize`
  calls neither. The consequence if it is ever reached: the pool slot stays `Leased`,
  `Leased_Count` never decrements, `Await_Drained`'s barrier never opens, `Shutdown` raises
  `Timeout_Error`, and `Client_State` is never freed because the response count never
  reaches zero.
- **Why this is still worth fixing.** `Finalize` is written as a deliberate safety net —
  its own comment two statements above says "Retry idempotent cleanup once after all
  operation children have been finalized. **Never erase an unresolved pool lease.**"
  (`:1920-1921`). Freeing a `Reply_Data` that still holds `Connection` and `Slot_Index` is
  exactly erasing an unresolved pool lease. The hole is in the code whose stated purpose is
  to prevent it.
- **Reachability, precisely.** Two candidate routes, and neither is an ordinary caller path:
  1. **Synchronous.** `Execute_Operation_Once` (`:6503-6505`) runs `Wait_All (Set)`, then
     one field read, then `Finish (Operation, Result, Reply)`, which nulls `Reply_Data`
     (`:1733-1734`). Nothing between them can raise on a normal path. Only `abort` of the
     calling task, or `Wait_All` raising after the operation already went terminal (an
     internal invariant failure), leaves `Reply_Data` set at finalization.
  2. **Composable.** `Exchange_To_Response` is declared in the *private* part of
     `flyology-http-client.ads` (`:1340-1350`) and marked `@exclude`, so no ordinary
     application can call it; only `Flyology.HTTP.Client.SSE` and other child units do. SSE
     always routes through `Finish_Exchange` (`sse.adb:1003-1013`). Abandoning a terminal
     operation without `Finish` is in any case a caller contract violation: the pinned
     runtime's `flyology-operations.ads:236-238` says "Terminal operations are retained
     until their provider-specific Finish operation consumes them", and `:246-256` says of
     `Continue_After` that "Parent must call Child's provider-specific Finish and Release
     from that drive before continuing."
  So the discovery's "reachable through abort or an exception between terminal completion
  and `Finish`" is right, and abort is the only route that is not itself a bug elsewhere.
  P2 stands.
- **Suggested fix shape, for the maintainer:** have `Finalize` retire a non-null
  `Reply_Data` through the same `Abandon_Response` + lifetime-release sequence
  `Response.Finalize` uses, instead of `Free_Response_Data` alone. That needs no task and no
  new state.

## CLIENT-POOL-8: `Response.Finalize` exception path frees the lease record without returning the pool slot

- **Verdict:** PARTIALLY CONFIRMED — the code defect is confirmed by reading; the
  triggering condition needs a fault-injection seam that does not exist, so there is no
  reproduction
- **Severity:** P2 (discovery said P2; unchanged)
- **Repro:** none, and none is possible in-process today: the handler runs only when
  `Abandon_Response` itself raises, which requires an `H2_Connections` or lease primitive to
  raise, and there is no seam to make one do so. **What would settle it:** a fault-injection
  point in `H2_Connections.Cancel_Stream` or `Release_Stream`, then a test that finalizes a
  `Response` holding an HTTP/2 lease while that primitive raises, asserting
  `Diagnostics.Reusable_Transports + Active_Exchanges` returns to zero and `Shutdown`
  completes.
- **The defect.** `src/flyology-http-client.adb:7387-7401`:

```ada
   exception
      when others =>
         if Item.Data /= null and then Item.Data.Retains_Owner
           and then Owner /= null
         then
            Item.Data.Retains_Owner := False;
            begin
               Owner.Lifetime.Release_Response (Final_Reference);
            exception
               when others => null;
            end;
         end if;
         Free_Response_Data (Item.Data);
```

  The handler releases the lifetime retention but never the lease. I checked which raise
  actually leaves a lease outstanding: `Abandon_Response` (`:2151-2170`) returns immediately
  when `Data.Connection = null`, and otherwise ends in `Release_Lease`, which nulls
  `Data.Connection` before any further step. So if the raise comes from
  `Owner.Lifetime.Release_Response` — the statement after `Abandon_Response` — `Connection`
  is already null and nothing leaks. The leak is specifically the case where
  `Abandon_Response` raises *before* `Release_Lease` runs: `H2_Connections.Is_Usable`,
  `Cancel_Stream` or `Release_Stream` raising on an HTTP/2 response, or `Release_Lease`
  raising its own `Program_Error`. Then `Item.Data.Connection` is still set when
  `Free_Response_Data` discards the record: the slot stays `Leased` holding a
  `Pooled_Connection` pointer nothing will ever dispose. Nothing is freed twice, so there is
  no use-after-free — the slot, the connection object and its socket simply leak until the
  process exits, and `Shutdown`'s drain barrier never opens.
- **Reachability** depends on `H2_Connections` internals that this area did not review and
  that no maintained test perturbs. Confidence in the code reading is high; confidence that
  it can be reached at all is low, which is why it stays P2.
- **Suggested fix shape:** null `Item.Data.Connection` only through `Release_Lease`, and in
  the handler attempt the lease return again (guarded by its own `when others => null`)
  before `Free_Response_Data`, mirroring the doubled `Release_Exchange_Transport` that
  `Exchange_Operation.Finalize` already does for the same reason.

## Areas re-checked with no new findings

- **The discovery's "no findings" sections.** I spot-checked the two claims that would have
  changed my verdicts. `Release_Lease` does null `Data.Connection` before any further step,
  which is what makes `Abandon_Response` idempotent and confines CLIENT-POOL-8 to the
  narrow window above. `Deadline_After` does map negative to `No_Deadline`, so
  CLIENT-POOL-3 really is the only negative value that reaches an arm call.
- **No new findings were raised.** Nothing I tripped over in `Resolve_Redirect`,
  `Execute_Redirects`, `Fail_Exchange`, `Probe_Early_Response`, `Pull_Source` or
  `Response.Finalize` was outside the eight entries I was given.

## Harness state

- `./tests/repros/run.sh repro_smoke` PASSES (exit 0) on the tree as I left it. I did not
  edit `src/seam_check.adb`, `src/repro_smoke.adb`, `run.sh`, `repros.gpr` or any other
  finding's spike. I ran no `alr`, `gprbuild`, `scripts/test.sh` or suite script directly;
  every build went through `tests/repros/run.sh`.
- Spikes added: `tests/repros/src/repro_client_pool_1.adb`,
  `tests/repros/src/repro_client_pool_2.adb`, `tests/repros/src/repro_client_pool_4.adb`.
