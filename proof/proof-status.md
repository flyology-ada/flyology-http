# Proof Status: Fable 5 prevention coverage
<!-- Reflect the top-level goal given. Items in the list below are moved from
     Not Started to In Progress to Reviewed and finally to Proved and Finalized. -->

Findings #5, #8, #10, #12, #13, #14, #15, #16, #17, #18, #19, and #47 are
prevented by production-consumed SPARK units. Their assigned targeted
subprogram proofs and fresh whole-unit widenings passed at level 1.
Finding #8 proves the scalar dequeue transition consumed by both bounded-channel
receive paths: its vacated position is the old head, while its next head and
count are the corresponding ring advance and decrement. The generic channel
body, its use of the returned position, arbitrary element resource semantics,
and controlled assignment/finalization remain outside SPARK. Capacity-two wrap,
controlled-retention, and exceptional-ordering tests cover that boundary in
both task lanes.
Finding #10 proves only that the Ada listener descriptor token is consumed
after the imported close function returns. It does not model `close(2)`, its
return semantics, or descriptor reuse; focused fault-enabled coverage exercises
that boundary in both task lanes.
The finding #6 fix consumes the pre-existing proved
`Flyology.Time_Math.To_Nanoseconds`; this follow-up required no new policy unit.
The chunk encoder proof includes complete hexadecimal-digit consumption through
`Natural'Last`, so the historical seven-digit capacity cannot prove.
Finding #13 proves the negotiated encoder-window bound. Finding #18 proves only
exact distance-tree classification and missing-distance enforcement; it
excludes reserved-symbol rejection and does not claim general DEFLATE
correctness.
The WebSocket timeout classifier treats failed-or-terminal state as an input
and does not prove that the I/O core sets that state, so behavioral integration
coverage remains required.
Finding #12 uses the production connection's persistent frame cursor. Its
proved transitions preserve payload phase, frame identity, remaining bytes,
absolute mask position, and the separate completion and abandonment reset
boundaries. Focused behavioral coverage exercises the surrounding I/O paths;
protocol I/O itself remains outside SPARK.
Finding #47 proves that the classifier consumed by `Decode_Path` rejects
exactly slash-delimited `.` and `..` segments in its decoded string input. It
does not prove percent decoding, request-target extraction and query removal,
UTF-8 validation, or HTTP error mapping; focused routing integration coverage
exercises those surrounding behaviors.
Finding #1 has partial prevention coverage. Its targeted proofs and fresh
whole-unit widening passed at level 1 and mode all, establishing only bounded
batch budgets and the deterministic Ada file-drain latch and state transitions
consumed by Linux `Wait_Batch`. They do not prove kernel readiness or liveness,
eventfd, epoll, io_uring, the C bridge, CQE existence or delivery, or buffer
ownership; Linux integration and stress coverage remain authoritative for
those behaviors. The widening continued with partial representation data after
the non-code-generating root package spec `s-flyolo.ads` produced no
representation information; the poller-policy unit itself was analyzed with no
warning, assumption, justified check, or unproved check.
The production-used bounded timer-set policy proves indexed-heap validity,
exact arm/cancel/clear transitions, root-minimum selection, and complete unique
extraction of every id armed and due at the supplied monotonic-clock sample.
Task suspension and clock sampling remain outside SPARK and require behavioral
lane-parity coverage.
The WebSocket client proof establishes the scalar decisions consumed by the
production receive and send framing core: canonical short, 16-bit, and 64-bit
length forms; rejection of reserved bits, masked server frames, unsupported
opcodes, invalid control framing, noncanonical lengths, and frames above the
16 MiB bound; valid fragmentation and message-capacity transitions; and the
accepted close-code set, including registered codes 1012 through 1014. The
fragmentation classifier has mutually exclusive and complete contract cases
that determine its exact result for every permitted input. It does not prove
HTTP upgrade parsing, SHA-1, Base64, operating-system entropy, masking byte
application, UTF-8 validation,
socket or TLS I/O, deadline delivery, or the coupling between parsed bytes and
classifier inputs. Native/lightweight integration and boundary tests cover
those surrounding behaviors.
The HTTP client upload-policy review adds a production-consumed SPARK boundary
for request/source compatibility, exact known-length pull completion,
informational-response accounting, stale-connection replay eligibility, and
the one-attempt `417 Expectation Failed` fallback. It does not prove request or
response I/O, response-head extraction, source callback behavior, rewind byte
identity, trailer-field definition rules, or the connection-lifecycle actions
selected by those classifications. Exhaustive policy matrices and focused
wire, adapter, ownership, and retry tests cover that integration boundary.

The fixed-response policy proves overflow-safe 64-bit accounting for declared
response lengths, including exact completion, overrun rejection before the
transport write, underrun classification, and HEAD suppression. It does not
prove header encoding, protocol stream state, transport I/O, backpressure,
deadline delivery, or cancellation. Focused HTTP/1.1, HTTP/2, and HTTP/3
behavioral tests cover those adapters and their connection or stream failure
boundaries.

Finding #43 records an undischarged obligation rather than a proof. The
`flyology_iri` release profile passes `-gnatp` to one body, `flyology_iri.adb`,
suppressing every runtime check in it: index, range, discriminant, overflow,
and the rest. Nothing discharges those obligations. GNATprove does not support
`Ada.Strings.Unbounded`, on which `Reference`, `Set_Reference`,
`Remove_Dot_Segments`, and `Resolve` are built, so the unit cannot enter SPARK
as it stands, and an absence-of-runtime-error proof would first require
separating its plain-`String` index arithmetic from its construction half.
Measurement decided the scope. On the pinned 100,025-URL corpus that body's
checks cost `can_parse` 26 ns against 20 ns and `parse_href` 165 ns against
96 ns, so the suppression buys the published medians; suppressing
`flyology_iri-web.adb`, `flyology_iri-idna.adb`, and the benchmark harness
bought nothing, so those three now keep every check in every mode and the
WHATWG serialization, punycode, percent decoding, and IP-literal code is
checked even in a release build. Narrowing further, to
`pragma Suppress (Index_Check, Range_Check, Overflow_Check)` inside `Char_At`,
`Fast_Dot_Segment`, `Fast_Web_Analysis`, `Fast_Can_Parse_Web`, `Can_Parse`,
`Is_Valid_UTF_8_At`, `Validate_Range`, and `Analyze`, recovered `parse_href` at
94 ns but left `can_parse` at 22 ns against the 20 ns gate, and it would have
removed those checks from the default build as well, so it was not taken. What
substitutes for proof today is dynamic and partial: `checked` is the default
build, no lane in this repository selects `release` except the benchmark
harness, the crate's tests are compiled with `-gnata -gnatVa` against the
checked library, and they drive every entry point in all three syntaxes over a
hostile corpus of oversized components, deep dot-segment nesting, truncated
percent escapes, malformed punycode, control bytes, and out-of-range ports. A
test reads both project files back so a widened suppression cannot land
unnoticed. That is coverage of the suppressed body, not a proof of it.

## Proved and Finalized
<!-- Before marking an item complete here, follow the Widen Scope step
     (Strategic Loop Step 5) in workflow.md in the /gnatprove Skill.
     Remember: changes to types used by or called subprograms in a given
     subprogram may cause it to regress to an unproved state. Reproving at the
     wider scope is thus a critical means to detect these situations. -->

- [x] Pre-change application policy suite (level 1, mode all)
- [x] Pre-change runtime scheduling policy suite (level 1, mode all)
- [x] Production-used bounded timer-set policy (level 1, mode all)
  - [x] Indexed heap mapping, order, repair, insertion, and removal
  - [x] Exact arm, cancellation, clearing, and earliest-deadline contracts
  - [x] Complete unique due-batch extraction with survivor framing
  - [x] Whole `Flyology.Timer_Set_Policy` unit widening
  - [x] Application and runtime policy suite widening
- [x] Finding #8 production-used bounded-channel dequeue transition
      (level 1, mode all)
  - [x] `Flyology.Channel_Policy.Next_Dequeue`
  - [x] `Flyology.Channel_Policy.Apply_Dequeue`
  - [x] Whole `Flyology.Channel_Policy` unit widening
- [x] Finding #10 production-used listener close-attempt ownership transition
      (level 1, mode all)
  - [x] `Flyology.Structured_Server_Policy.Consume_After_Close_Attempt`
  - [x] Whole `Flyology.Structured_Server_Policy` unit widening
- [x] Finding #1 production-used deterministic poller batch policy
      (level 1, mode all; partial prevention boundary)
  - [x] `System.Flyology.Poller_Policy.Plan_Batch`
  - [x] `System.Flyology.Poller_Policy.Remaining_Budget`
  - [x] `System.Flyology.Poller_Policy.After_Wake`
  - [x] `System.Flyology.Poller_Policy.After_Drain`
  - [x] `System.Flyology.Poller_Policy.After_Batch`
  - [x] Whole `System.Flyology.Poller_Policy` unit widening
- [x] Finding #5 production-used nonzero generation-successor policy
      (level 1, mode all)
  - [x] `Flyology.Counter_Policy.Nonzero_Successor`
  - [x] Whole `Flyology.Counter_Policy` unit widening
- [x] Finding #14 production-used rate-limit refill policy
      (level 1, mode all)
  - [x] `Flyology.Rate_Limit_Policy.Refilled_Tokens`
  - [x] Whole `Flyology.Rate_Limit_Policy` unit widening
- [x] Finding #16 production HTTP chunk-size encoder
      (level 1, mode all)
  - [x] `Flyology.HTTP_Chunk_Encoding.Encode`
  - [x] Whole `Flyology.HTTP_Chunk_Encoding` unit widening
- [x] Finding #12 production-used incremental WebSocket frame cursor
      (level 1, mode all)
  - [x] `Flyology.WebSocket_Policy.Begin_Frame`
  - [x] `Flyology.WebSocket_Policy.Mask_Offset`
  - [x] `Flyology.WebSocket_Policy.Advance`
  - [x] `Flyology.WebSocket_Policy.Complete_Frame`
  - [x] `Flyology.WebSocket_Policy.Abandon_Frame`
  - [x] Whole `Flyology.WebSocket_Policy` unit widening
- [x] Finding #19 production-used WebSocket timeout retry policy
      (level 1, mode all)
  - [x] `Flyology.WebSocket_Policy.Classify_Timeout`
  - [x] Whole `Flyology.WebSocket_Policy` unit widening
- [x] Finding #15 production-used HTTP Expect/version classification
      (level 1, mode all)
  - [x] `Flyology.HTTP.Expect_Policy.Classify`
  - [x] Whole `Flyology.HTTP.Expect_Policy` unit widening
- [x] Finding #17 production-used route-parameter capacity transition
      (level 1, mode all)
  - [x] `Flyology.HTTP.Route_Parameter_Policy.Advance`
  - [x] Whole `Flyology.HTTP.Route_Parameter_Policy` unit widening
- [x] Finding #47 production-used decoded dot-segment classification
      (level 1, mode all)
  - [x] `Flyology.HTTP.Decoded_Path_Policy.Classify`
  - [x] Whole `Flyology.HTTP.Decoded_Path_Policy` unit widening
- [x] Finding #13 production-used negotiated encoder-window bound
      (level 1, mode all)
  - [x] `Flyology.WebSocket_Deflate_Policy.Negotiated_Server_Window_Bits`
  - [x] Whole `Flyology.WebSocket_Deflate_Policy` unit widening
- [x] Finding #18 production-used distance-tree classification and
      missing-distance enforcement (level 1, mode all)
  - [x] `Flyology.WebSocket_Deflate_Policy.Select_Distance_Tree`
  - [x] `Flyology.WebSocket_Deflate_Policy.Distance_Requirement_Is_Satisfied`
  - [x] Whole `Flyology.WebSocket_Deflate_Policy` unit widening
- [x] Production HTTP client upload policy (level 1, mode all)
  - [x] `Flyology.HTTP.Client_Policy.Validate_Upload`
  - [x] `Flyology.HTTP.Client_Policy.Classify_Pull`
  - [x] `Flyology.HTTP.Client_Policy.Classify_Stale_Retry`
  - [x] `Flyology.HTTP.Client_Policy.Classify_Informational`
  - [x] `Flyology.HTTP.Client_Policy.Next_Informational_Count`
  - [x] `Flyology.HTTP.Client_Policy.Classify_Expectation_Response`
  - [x] Whole `Flyology.HTTP.Client_Policy` unit widening
- [x] Production WebSocket client framing policy (level 1, mode all)
  - [x] `Flyology.WebSocket_Client_Policy.Form_For`
  - [x] `Flyology.WebSocket_Client_Policy.Validate_Header`
  - [x] `Flyology.WebSocket_Client_Policy.Classify_Data`
  - [x] `Flyology.WebSocket_Client_Policy.Valid_Close_Code`
  - [x] Whole `Flyology.WebSocket_Client_Policy` unit widening

## Reviewed
<!-- Before marking an item complete here, review it following the Review
     step (Strategic Loop Step 4) in workflow.md in the /gnatprove Skill -->

- [x] Finding #5 prevention coverage
- [x] Finding #8 bounded-channel dequeue-transition prevention coverage
- [x] Finding #14 prevention coverage
- [x] Finding #16 prevention coverage
- [x] Finding #12 prevention coverage
- [x] Finding #19 prevention coverage
- [x] Finding #15 prevention coverage
- [x] Finding #17 prevention coverage
- [x] Finding #47 decoded dot-segment prevention coverage
- [x] Finding #13 prevention coverage
- [x] Finding #18 missing-distance prevention coverage
- [x] Finding #1 deterministic poller-policy boundary
- [x] Finding #10 listener close-attempt ownership boundary
- [x] `Flyology.Timer_Set_Policy.Precedes` (level 1, mode all)
- [x] `Flyology.Timer_Set_Policy.Armed_Count` (level 1, mode all)
- [x] `Flyology.Timer_Set_Policy.Mapping_Valid` (level 1, mode all)
- [x] `Flyology.Timer_Set_Policy.Heap_Ordered` (level 1, mode all)
- [x] `Flyology.Timer_Set_Policy.Is_Valid` (level 1, mode all)
- [x] `Flyology.Timer_Set_Policy.Swap` (level 1, mode all)
- [x] `Flyology.Timer_Set_Policy.Up_Ready` (level 1, mode all)
- [x] `Flyology.Timer_Set_Policy.Sift_Up` (level 1, mode all)
- [x] `Flyology.Timer_Set_Policy.Down_Ready` (level 1, mode all)
- [x] `Flyology.Timer_Set_Policy.Sift_Down` (level 1, mode all)
- [x] `Flyology.Timer_Set_Policy.Remove_At` (level 1, mode all)
- [x] `Flyology.Timer_Set_Policy.Cancel` (level 1, mode all)
- [x] `Flyology.Timer_Set_Policy.Clear` (level 1, mode all)
- [x] `Flyology.Timer_Set_Policy.Arm` (level 1, mode all)
- [x] `Flyology.Timer_Set_Policy.Lemma_Root_Minimum` (level 1, mode all)
- [x] `Flyology.Timer_Set_Policy.Earliest_Deadline` (level 1, mode all)
- [x] `Flyology.Timer_Set_Policy.Collect_Due` (level 1, mode all)
- [x] HTTP client upload-policy proof and integration boundary
- [x] WebSocket client framing-policy proof and integration boundary

## In Progress
<!-- A subagent executes the Tactical Loop for the subprogram below.
     It should update this section as it works. -->

- None.

## Not Started
<!-- Whenever a subprogram is added (due to refactoring) or discovered
     during assessment (Strategic Loop Steps 1-2), list it here so it
     is not forgotten. -->

- [ ] Finding #43 absence-of-runtime-error proof for the `flyology_iri.adb`
      index arithmetic the release profile suppresses checks in:
      `Flyology_IRI.Char_At`, `Flyology_IRI.Fast_Dot_Segment`,
      `Flyology_IRI.Fast_Web_Analysis`, `Flyology_IRI.Fast_Can_Parse_Web`,
      `Flyology_IRI.Is_Valid_UTF_8_At`, `Flyology_IRI.Validate_Range`,
      `Flyology_IRI.Valid_IPv4`, `Flyology_IRI.Valid_IP_Literal`, and
      `Flyology_IRI.Analyze`

## Discovered Obligations

- [x] Strengthen `Down_Ready` so every direct child of a nonroot position is
      ordered after that position's parent
- [x] Re-verify callers of the strengthened `Down_Ready` predicate
- [x] Prove `Down_Ready` immediately after each `Sift_Down` swap
- [x] Prove `Sift_Down` loop-invariant initialization and preservation plus
      its increasing-current variant
- [x] Prove `Sift_Up` loop-invariant initialization and preservation plus its
      decreasing-current variant
- [x] Re-verify both `Arm` policy callers supply room for a new id while
      allowing a full-set reschedule
- [x] Prove root-minimum lifting from local parent-child heap order
- [x] Prove `Clear` processed-entry loop-invariant initialization and
      preservation
- [x] Require explicit capacity for an unarmed `Arm` target and prove the
      insertion arithmetic and index checks
- [x] Prove a root-minimum heap lemma by induction over parent positions for
      `Earliest_Deadline`
- [x] Re-verify callers after adding the `Remove_At` semantic/frame contract
- [x] Re-verify callers after adding the `Precedes` indexed-heap preconditions
      and other helper frame postconditions
- [x] Prove the complete due-set extraction contract, including uniqueness,
      preservation of later arms, and removal of every due arm
- [x] Prove `Collect_Due` old-minus-current membership, output, frame, and
      count loop invariants
- [x] Fresh whole-unit widening of `Flyology.Timer_Set_Policy` at level 1 and
      mode all
- [x] Re-run the application proof suite after adding the production policy
- [x] Prove finding #8 old-head dequeue action at targeted subprogram scope
- [x] Prove finding #8 scalar dequeue commit at targeted subprogram scope
- [x] Record that the controlled generic slot assignment is outside SPARK;
      omission or misdirection remains covered by behavioral tests
- [x] Widen the complete `Flyology.Channel_Policy` unit at level 1 and mode all
- [x] Confirm production `Receive` and `Try_Receive` consume the scalar
      transition and clear its returned vacated position; the generic body and
      this call-site coupling remain outside SPARK
- [x] Cover multi-slot dequeue position and circular wrap behavior alongside
      controlled resource release and exceptional ordering in both task lanes
- [x] Independent read-only review confirmed the scalar proof and controlled
      ordering, and its documentation-boundary finding was corrected
- [x] Re-ran the application and runtime proof suites serially after finding #8
      integration
- [x] Re-ran the full behavioral suite after rebasing findings #8 and #47 and
      strengthening the capacity-two wrong-slot coverage
- [x] Final post-rebase read-only review found the blocking-tail test gap; the
      strengthened sequence was independently rechecked with no findings
- [x] Re-verified callers of `Begin_Frame`, `Mask_Offset`, `Advance`,
      `Complete_Frame`, and `Abandon_Frame` contracts
- [x] Fresh host `-f` widening for `Begin_Frame`
- [x] Fresh host `-f` widening for `Mask_Offset`
- [x] Fresh host `-f` widening for `Advance`
- [x] Fresh host `-f` widening for `Complete_Frame`
- [x] Fresh host `-f` widening for `Abandon_Frame`
- [x] Production `Begin_Frame` caller supplies the unconstrained
      cursor required for its discriminant-changing transition
- [x] Production `Complete_Frame` caller supplies the
      unconstrained cursor required for its discriminant-changing transition
- [x] Production `Abandon_Frame` callers supply the unconstrained cursor
      required for its discriminant-changing transition
- [x] Widened the revised `Flyology.WebSocket_Policy` unit at level 1 and mode
      all after the tactical subprogram proofs
- [x] Production `Receive_WebSocket` consumes the cursor state and
      transitions, including phase-gated header parsing
- [x] Deterministically cover repeated mid-header and masked mid-payload
      quantum timeouts with fragmented data and an interleaved control frame
- [x] Re-ran the focused production build and WebSocket smoke tests after the
      final cursor contracts
- [x] Re-ran the application and runtime proof suites serially after integration
- [x] Prove finding #1 `Poller_Policy.Plan_Batch` at targeted subprogram scope
- [x] Prove finding #1 `Poller_Policy.After_Wake` at targeted subprogram scope
- [x] Prove finding #1 `Poller_Policy.Remaining_Budget` at targeted subprogram
      scope
- [x] Prove finding #1 `Poller_Policy.After_Batch` at targeted subprogram scope
- [x] Cover finding #1 `Poller_Policy.After_Drain` in the whole-unit widening
- [x] Widen finding #1 through the whole `Poller_Policy` unit
- [x] Production listener finalizer consumes
      `Consume_After_Close_Attempt` after the imported close returns
- [x] Boundary tests cover descriptor zero, the descriptor upper bound, and a
      close failure followed by descriptor-number reuse in both task lanes
- [x] Fresh targeted proof of `Consume_After_Close_Attempt` at level 1 and
      mode all
- [x] Fresh whole-unit widening of `Flyology.Structured_Server_Policy` at
      level 1 and mode all
- [x] Linux `Wait_Batch` consumes the bounded batch budgets and persistent
      file-drain state transitions
- [x] Boundary tests cover a consumed wake with a full 64-event epoll batch,
      conservative drain retention, and one-result source alternation
- [x] Prove `Flyology.HTTP.Expect_Policy.Classify`, then widen its whole unit
- [x] Prove `Flyology.HTTP.Route_Parameter_Policy.Advance`, then widen its
      whole unit
- [x] Prove `Flyology.HTTP.Decoded_Path_Policy.Classify`, then widen its whole
      unit
- [x] Production HTTP parser consumes the `Expect_Policy.Classify` action
- [x] Production `Validate_Pattern` consumes `Route_Parameter_Policy.Advance`
- [x] Production `Decode_Path` consumes
      `Decoded_Path_Policy.Classify` after percent decoding
- [x] Boundary tests cover the Expect truth table and route capacity transition
- [x] Policy and routing tests cover exact decoded `.` and `..` rejection plus
      raw, encoded, mixed-case, query, absolute-form, wildcard/remainder, and
      benign dotted-name behavior
- [x] Independent read-only review found no proof antipattern, missing
      integration, overflow issue, or performance regression
- [x] Re-ran the application and runtime proof suites serially after finding
      #47 integration
- [x] Re-ran the full behavioral suite after finding #47 integration for both
      project defaults
- [x] Re-ran GNATdoc after finding #47 integration with no undocumented-entity
      warnings or errors
- [x] Production `Native_Executors.Submit` consumes `Nonzero_Successor`
- [x] Production rate-limit middleware consumes `Refilled_Tokens`
- [x] Production HTTP chunk and SSE paths consume `HTTP_Chunk_Encoding.Encode`
- [x] Production high-level WebSocket handler consumes
      `WebSocket_Policy.Classify_Timeout`
- [x] Boundary tests cover generation rollover, refill saturation, and chunk
      encoding through `Natural'Last`
- [x] Behavioral tests cover failed exchange state and propagation for terminal
      control-write and message-deadline timeouts, plus active receive-quantum
      retry
- [x] Prove finding #13 window capability at targeted subprogram scope
- [x] Prove finding #18 distance-tree selection at targeted subprogram scope
- [x] Prove finding #18 missing-distance enforcement at targeted subprogram
      scope
- [x] Review finding #18 policy revision for proof antipatterns
- [x] Widen the revised WebSocket DEFLATE policy unit at level 1 and mode all
- [x] Production negotiation and the fixed-window encoder consume one shared
      WebSocket DEFLATE capability policy
- [x] Production dynamic-block tree construction and symbol decoding consume
      the empty-distance-tree classification and missing-distance policy;
      reserved-symbol rejection remains separate
- [x] Focused policy tests cover supported and unsupported window offers, the
      exact one-zero-code `No_Tree` shape, missing-distance enforcement, and
      the separate 286/287 reserved-symbol boundary
- [x] Full behavioral suite passed after integration for both project defaults
- [x] Deterministic stress and fault campaign passed after integration
- [x] Native Linux/AArch64 Docker validation passed, including the optimized
      poller-policy inlining guard
- [x] GNATdoc completed with no undocumented-entity warnings or errors
- [x] Prove upload validation and exact known-length source completion
- [x] Prove bounded informational-response classification and count advance
- [x] Prove stale-connection replay and one-attempt 417 fallback eligibility
- [x] Confirm production request, upload, response, and retry paths consume the
      proved classifications
- [x] Exhaustively cover the policy truth tables and integer boundaries
- [x] Cover exact-length source completion, channel overrun ownership, duplicate
      trailers, early final responses, 417 retry, and stale rewind behavior
- [x] Full behavioral suite and deterministic HTTP client conformance campaign
      passed after upload-policy integration
- [x] Correct the pool model's concurrent descriptor-baseline fixture and
      repeat its leak check after the conformance campaign exposed the race
- [x] Record socket I/O, parser extraction, source callbacks, rewind fidelity,
      trailer-field semantics, and connection disposal outside the SPARK model
- [x] Prove the complete fixed-response policy at level 1 and mode all,
      including overflow safety through `Body_Size'Last`
- [x] Confirm HTTP/1.1, HTTP/2, and HTTP/3 response writers consume the proved
      write and finish classifications
- [x] Cover exact, zero, one-byte-chunk, overrun, underrun, HEAD, large logical
      length, backpressure, exception, cancellation, deadline, and reuse paths
- [x] Re-run the complete HTTP proof suite: 2,950 checks proved
- [ ] GNATcoverage was not run because the required `gnatcov_bin` tool crate
      is not installed in the available Alire tool environment
- [x] Measure what `-gnatp` buys per operation and per body, and keep it only
      where it does
- [x] Pin the release profile's suppression scope with a test that reads both
      `flyology_iri` project files back
- [x] Cover the suppressed body with a hostile corpus through every entry
      point in every syntax, built with `-gnata -gnatVa`
- [ ] Separate `flyology_iri.adb`'s plain-`String` scanning from its
      `Ada.Strings.Unbounded` construction so the scanning half can enter
      SPARK at all
- [ ] Fuzz the checked `flyology_iri` build in continuous integration so the
      release profile's unchecked body has a standing dynamic guard
