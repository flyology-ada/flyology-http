# SSE client reconnect assurance boundary

## Algorithmic question

The protocol-neutral SSE client must preserve EventSource reconnect state while
the underlying HTTP exchange can use HTTP/1.1, HTTP/2, or HTTP/3.  After an
accepted event stream ends or a recoverable transport attempt fails, the next
attempt must use the current reconnect delay and the latest event id.  An empty
id resets that value and therefore suppresses the next `Last-Event-ID` header.
Cancellation, the caller's absolute deadline, a fatal response, and HTTP 204
must terminate the lifecycle without a later reconnect or event delivery.

## Authority and product inputs

The [WHATWG HTML EventSource processing model](https://html.spec.whatwg.org/multipage/server-sent-events.html)
establishes the `text/event-stream` media type, UTF-8 decoding, `data`, `event`,
`id`, and `retry` field semantics, automatic reconnect, `Last-Event-ID`, and
HTTP 204 termination.  Those are protocol values and transitions rather than
project policy.

The caller supplies the maximum retained event bytes, initial reconnect delay,
maximum accepted reconnect delay, absolute lifecycle deadline, and optional
cancellation token.  The API publishes no default for any of them.  TLC's
finite identifiers, delays, and reconnect generations are exploration geometry
only and do not become implementation limits.

## State and actions

The model retains the lifecycle phase, EventSource last event ID, current
stream's event ID buffer, ID placed on the latest reconnect request, current
reconnect delay, and delay selected for an active wait.  Its actions map to the
implementation as follows:

| TLA+ action | Ada boundary |
| --- | --- |
| `ConnectionAccepted` | the private `Exchange_To_Response` child completes with a 200 response and valid `text/event-stream` metadata |
| `ConnectionNoContent` | an HTTP 204 response |
| `ConnectionRecoverableFailure` | a recoverable typed response-head or response-body exchange failure |
| `ConnectionFatalFailure` | invalid status, media type, or caller limit |
| `ReceiveID` | an accepted `id` field updates the current stream buffer |
| `ReceiveRetry` | an accepted integer-millisecond `retry` field is converted through the production fixed-point boundary and updates the reconnection time |
| `DispatchEvent` | a blank line commits the stream ID buffer, even without data |
| `EndOfBody` | clean end of an accepted response body |
| `ReconnectWaitElapsed` | terminal `Flyology.IO.Timers.Timer_Operation` completion, followed by the policy transition before the next response-head exchange |
| `Stop` | cancellation or deadline expiry makes the lifecycle terminal |

`Read_Operation` owns those response-head, response-body, and timer children in
one caller completion set. The zero-duration owner deadline used between a
terminal child callback and the next child start is an operation-scheduler
refinement: it selects the next completion-set snapshot and does not alter the
modeled or caller-selected reconnect delay. The blocking `Read` overload waits
for and finishes this same operation, so there is no second lifecycle to map.

## Required properties

Safety:

- every reconnect request carries exactly the latest event id, including an
  empty reset;
- every reconnect wait uses the delay current when the prior attempt ended;
- only a valid 200 event-stream response enters the open phase;
- HTTP 204, fatal response, cancellation, and deadline expiry are terminal;
- terminal state cannot publish another event or begin another connection.

Progress:

- under weak fairness of the owned reconnect timer, a waiting lifecycle
  eventually reconnects or terminates;
- under weak fairness of a pending connection resolution, a connecting
  lifecycle eventually opens, waits again, or terminates;
- an open server is allowed to remain open indefinitely without producing an
  event, so event-delivery liveness is not claimed.

## Evidence boundaries

- TLC exhaustively explores the configured finite state graph, checks type and
  safety invariants, the two progress properties, action coverage, and an
  intentional stale-`Last-Event-ID` negative probe.
- TLAPS proves initialization and action-by-action preservation of the
  unbounded safety kernel.  It does not prove byte parsing or transport code.
- The Ada trace adapter replays stable TLC actions through the lifecycle policy
  and fixed-point millisecond conversion used by the client, then compares every
  modeled post-state. Replay establishes conformance only for the retained
  traces; ordinary tests remain responsible for the byte-level field grammar.
- HTTP/1.1, HTTP/2, and HTTP/3 integration tests explicitly start and finish a
  composable read, then continue through the blocking wait-over-operation
  overload. Together they establish response framing, incremental parsing, an
  ID-only dispatch boundary, reconnect headers, retry timing selection, HTTP
  204 termination, and resource cleanup on their maintained local transports.
  They do not establish browser interoperability or production qualification.
