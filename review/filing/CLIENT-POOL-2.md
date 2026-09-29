Title: Synchronous 417 fallback retries after body transmission with a consumed, un-rewound source
Labels: bug
Refs: CLIENT-POOL-5

## Summary

`Set_Expect_Continue` documents that only a 417 received *before body transmission* is retried, but the synchronous wrapper's 417 branch tests nothing except the status, the expectation flag and a one-shot retry flag. When the continue wait expires, the client sends the body and a later 417 still triggers the retry, with the same request body source at its current position. For an unknown-length source the retry is silent: a second, well-formed `POST` goes out carrying `0\r\n\r\n`, the origin answers it, and the caller has no way to learn that the server saw one 17-byte POST followed by one empty POST. For a known-length source the retry announces the full `Content-Length` over an exhausted source and `Execute` raises `Request_Body_Error` instead of returning the 417 the origin sent.

## Problem

Commit `f078732`.

The contract is explicit about when the fallback applies (`src/flyology-http-client.ads:220-226`):

```ada
   --  A positive wait expiry with no partial response sends the body; a
   --  negative value waits within the whole exchange deadline and zero sends
   --  immediately after the head. A final response suppresses body reads and
   --  transmission. A 417 final response received before body transmission
   --  is retried once on a fresh transport without the expectation, within
   --  the same deadline and shared automatic-retry budget. The whole exchange
   --  deadline is never extended.
```

The branch that implements it consults no body-sent condition (`src/flyology-http-client.adb:6636-6647`):

```ada
               if Status (Reply) = 417
                 and then Current.Expect_Continue
                 and then not Retried
               then
                  --  A complete 417 conclusively rejects the expectation
                  --  before this adapter has consumed Source. Retry once
                  --  without the Expect field, inside the original absolute
                  --  budget.
                  Drain (Reply, Max_Redirect_Drain_Bytes, Token);
                  Current.Expect_Continue := False;
                  Retried := True;
                  Retry_Expectation := True;
```

The comment states a precondition the code does not test. The same `Source` object is handed to the next `Execute_Operation_Once` at its current position; it is neither rewound nor required to be a `Rewindable_Request_Body_Source`.

The engine does not enforce "before body transmission" either. Once the continue wait expires, `Probe_Early_Response` clears the waiting state and resumes the body (`src/flyology-http-client.adb:3767-3786`):

```ada
            when Connection_Drivers.Need_Read =>
               if State.Expect_Waiting
                 and then Event /= Flyology.Operations.Deadline_Reached
               then
                  ...
               else
                  State.Expect_Waiting := False;
                  State.Metadata.Request_Incomplete := False;
                  State.Driver_State := State.Resume_After_Probe;
```

After that, any final response including a 417 arrives as an ordinary `Response_Complete`.

This is legitimate origin behaviour, not a hostile peer. RFC 9110 section 10.1.1 says of a client using this expectation: "A client that sends a 100-continue expectation is not required to wait for any specific length of time; such a client MAY proceed to send the content even if it has not yet received a response." The server's final status code may therefore arrive after the content, and section 10.1.1 also says a client receiving 417 "SHOULD repeat that request without a 100-continue expectation". Nothing licenses repeating it with different content.

### Unknown length: a silent second POST

This is the shape that matters, because it changes what the fix has to do. With an unknown-length source the request is chunked, the source is already finished, and the retry emits a complete, well-formed message with an empty body. Nothing fails. The origin answers it and the caller receives that answer as if it were the answer to the request it made. RFC 9110 section 9.2.2 defines the property this breaks: "A request method is considered "idempotent" if the intended effect on the server of multiple identical requests with that method is the same as the effect for a single such request. Of the request methods defined by this specification, PUT, DELETE, and safe request methods are idempotent." POST is not among them, so re-sending it with different content is a semantic change the client makes on its own.

### Known length: a wrong exception

With a known-length source the retry declares the original `Content-Length` and then finds nothing to send. `Pull_Source` fails the exchange (`src/flyology-http-client.adb:3609-3617`):

```ada
            when Source_Finished =>
               if Count /= 0
                 or else
                   (State.Source_Length.Is_Known
                      and then State.Source_Transferred /=
                        State.Source_Length.Bytes)
               then
                  State.Metadata.Request_Incomplete := True;
                  Fail_Exchange (Item, Request_Source_Failed);
```

The wrapper maps that to `Request_Body_Error` (`src/flyology-http-client.adb:6583-6584`), so the caller gets an exception rather than the 417 the origin actually sent, and the origin is left holding a truncated POST message.

### The guard that would have prevented this was removed

This condition used to be a proved SPARK input. `Flyology.HTTP.Client_Policy.Classify_Expectation_Response` still takes it (`src/flyology-http-client_policy.ads:171-188`), with a contract case that returns `Retry_Without_Expectation` only for `Expectation_Sent and then not Body_Sent and then not Already_Retried and then Status = 417 and then Attempt_Allowed`. `git show f0d630d -- src/flyology-http-client.adb` removes the call and puts nothing in its place:

```ada
-                        Result.Data.Request_Incomplete :=
-                          Use_Expectation
-                            and then Has_Request_Body
-                            and then not Body_Sent;
-                        if Classify_Expectation_Response
-                          (Expectation_Sent => Use_Expectation,
-                           Body_Sent        => Body_Sent,
-                           Already_Retried  => Retried,
-                           Status           => Result.Data.Status_Value,
```

The classifier is now dead code that the proof documentation still describes as production consumed; that is {{ISSUE:CLIENT-POOL-5}}.

Why the tests do not catch it: `tests/http_client_upload_controls_smoke.adb:316-321` scripts a 417 arriving *before* the body (`Expect_Head_Only` then `Send_Empty ("417 Expectation Failed")`) with the client at `:525-528`, which is the case that behaves correctly, and `:509-512` covers a 0.02 s wait expiring followed by a 200. No maintained test sends a 417 after the body.

## What happens now

Spike: a loopback origin reads the head, lets the 0.02 s continue wait expire, reads the whole declared body, and only then answers `417 Expectation Failed`. It runs twice, once with a known-length one-shot source and once with the same payload declared `Unknown_Length` so the engine frames it chunked. The program asserts what the contract requires: the body has been transmitted, so the 417 is the caller's response and no second request is sent.

```ada
   Payload : constant String := "late-417-body-xyz";   --  17 bytes
...
   overriding function Declared_Length
     (Item : One_Shot_Source) return Client.Body_Length is
     (Client.Known_Length (Payload'Length));
...
   overriding function Declared_Length
     (Item : Chunked_Source) return Client.Body_Length is
     (Client.Unknown_Length);
...
            --  RFC 9110 s10.1.1 does not require a 417 to precede the body.
            Send
              ("HTTP/1.1 417 Expectation Failed" & CRLF &
               "Content-Length: 0" & CRLF &
               "Connection: close" & CRLF & CRLF);
...
         Client.Set_Method (Request, Flyology.HTTP.Methods.POST);
         Client.Set_Target (Request, "/late-417");
         Client.Set_Expect_Continue (Request, Wait_Timeout => 0.02);
```

```
  note request 1 head: POST /late-417 HTTP/1.1\x0d\x0aHost: 127.0.0.1:56112\x0d\x0aExpect: 100-continue\x0d\x0aContent-Length: 17\x0d\x0a\x0d\x0a
  note request 1 body: [late-417-body-xyz]
  note request 2 head: POST /late-417 HTTP/1.1\x0d\x0aHost: 127.0.0.1:56112\x0d\x0aContent-Length: 17\x0d\x0a\x0d\x0a
  note Execute raised: FLYOLOGY.HTTP.CLIENT.REQUEST_BODY_ERROR: flyology-http-client.adb:6584
  note source reads: 2
  ok   precondition: the whole declared body reached the origin before 417
  FAIL Execute returns the 417 instead of failing on a consumed source
  FAIL the 417 received after body transmission is the caller's response
         expected: 417   actual:-1
  FAIL no second request: the .ads retries only a 417 received BEFORE body transmission
         expected: []
         actual:   [POST /late-417 HTTP/1.1
Host: 127.0.0.1:56112
Content-Length: 17

]
  note chunked request 1 body: 11\x0d\x0alate-417-body-xyz\x0d\x0a0\x0d\x0a\x0d\x0a
  note chunked retry on the wire: POST /late-417-chunked HTTP/1.1\x0d\x0aHost: 127.0.0.1:56112\x0d\x0aTransfer-Encoding: chunked\x0d\x0a\x0d\x0a0\x0d\x0a\x0d\x0a
  note chunked status: 200
  ok   precondition: the whole chunked body reached the origin before 417
  FAIL Unknown_Length: no second POST is sent after body transmission
         expected: []
         actual:   [POST /late-417-chunked HTTP/1.1
Host: 127.0.0.1:56112
Transfer-Encoding: chunked

0

]
  FAIL Unknown_Length: the 417 is the caller's response
         expected: 417   actual: 200
checks: 7  failures: 5
BUG REPRODUCED
```

The chunked transcript is the important one: the second `POST /late-417-chunked` is syntactically valid, carries `0\r\n\r\n`, and the caller receives the origin's 200 for it with no indication that two POSTs were sent.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

Once any request content has been transmitted, a 417 is the caller's response and no second request is sent, exactly as `src/flyology-http-client.ads:220-226` states. The retry remains correct only for a 417 that arrives while the client is still waiting on the expectation.

## Suggested treatment

Restore the body-sent condition to the 417 branch at `src/flyology-http-client.adb:6636-6647`. `Flyology.HTTP.Client_Policy.Classify_Expectation_Response` already carries the exact predicate with a proved contract case, so the smallest fix is to track whether any content byte left the exchange and feed that value back into the classifier, returning the 417 to the caller when it is `True`. Note that `Flyology.HTTP.Client_Policy` is one of the units `./scripts/prove.sh` proves, so any change to it must keep the proof discharging with `--checks-as-errors=on`; restoring the call site alone does not touch the proved body.

Requiring a rewindable source and rewinding it is not a sufficient fix on its own. It would repair the known-length shape and leave the silent empty re-POST in place, because a rewound unknown-length source would simply produce a second full body instead of a second empty one, which is still a second POST.

This needs a maintainer decision: the wrapper has no body-sent signal today, so the fix adds one, and both the carrier and the surrounding contract are choices to make rather than to assume.

- how the wrapper observes it: a private field in the exchange state read through an existing private accessor, a new field on the typed exchange result that the composable path would also see, or a value derived from the existing `Request_Incomplete` metadata;
- whether the remaining before-body retry should additionally require `Rewindable_Request_Body_Source`, which would narrow the documented fallback and is a contract change to `src/flyology-http-client.ads:220-226`;
- whether the `.ads` sentence should also state what the caller receives when the 417 arrives after transmission, since it currently only says when the retry happens.

The regression test belongs in the existing upload-controls suite, `tests/http_client_upload_controls_smoke.adb`, next to the before-body 417 case at `:316-321`, and must cover both the known-length and the unknown-length shapes. The spike above is that test. No existing test asserts the current behaviour, so the before-body cases at `:316-321` and `:525-528` keep passing unchanged.

## Severity

A POST with `Expect: 100-continue` whose origin answers 417 after accepting the content is either failed with the wrong exception or, for an unknown-length body, sent twice with the second copy empty. The second shape is silent: no exception, no diagnostic, and a 200 returned to the caller for a request the caller did not make. It needs a slow origin, an expiring continue wait and a late 417, which is an unusual combination, and no byte is corrupted. Reaching it requires the opt-in `Set_Expect_Continue` handshake on an HTTP/1.1 client. Deterministic.
