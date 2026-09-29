Title: A zero-length DATA frame on a HEAD, 204 or 304 response is rejected as a malformed message
Labels: bug
Refs: H3-QPACK-14

## Summary

`On_Response_Frame` rejects any DATA frame on a response that is not allowed content, with no exemption for a zero-length payload. A peer that terminates a HEAD, 204 or 304 response with an empty DATA frame carrying FIN therefore gets `Message_Error`, which the client turns into a stream reset with H3_MESSAGE_ERROR. A zero-length DATA frame carries no content, so the response was not in fact carrying anything the status forbids. The HTTP/2 client in this repository was changed to accept exactly that shape.

## Problem

Commit `f078732`.

The DATA branch tests only `Body_Allowed` (`src/flyology-http-http_3_message_policy.adb:113-117`):

```ada
      elsif Frame_Type = HTTP_3_Frame_Policy.Data_Frame then
         if State.Phase /= Final_Response_Open then
            Result.Status := Frame_Unexpected;
         elsif not State.Body_Allowed then
            Result.Status := Message_Error;
```

`Data_Length` is not consulted before the rejection, and `Body_Allowed` is set from the request method and the status code alone (`src/flyology-http-http_3_message_policy.adb:94-96`):

```ada
                  Result.State.Body_Allowed :=
                    not State.Request_Is_Head
                    and then Response_Code not in 204 | 304;
```

RFC 9110 section 6.4.1 states: "Responses to the HEAD request method (Section 9.3.2) never include content" and "All 1xx (Informational), 204 (No Content), and 304 (Not Modified) responses do not include content." A DATA frame of length zero includes no content, so it does not offend either sentence. RFC 9114 section 4.1 and section 7.2.1 place no constraint on zero-length DATA frames and do not list one among the malformed conditions in section 4.1.2.

The two layers of the client also disagree about 205. The proved policy allows a body on 205, since `Body_Allowed` excludes only 204 and 304, while the client controller forbids it (`src/flyology-http-http_3_client_connection.adb:355-357`):

```ada
                              Stream.Body_Forbidden :=
                                Stream.Body_Forbidden
                                  or else Code in 204 | 205 | 304;
```

so `Body_Forbidden` fails the exchange at `src/flyology-http-http_3_client_connection.adb:411-421` for a case the policy accepts. That divergence was confirmed by reading and is not separately reproduced below.

Commit 80e7f6b made this repository's HTTP/2 client accept an empty HEAD stream completion, so the two protocol families now disagree on the same shape. No HTTP/3 test covers it.

## What happens now

Spike: the program drives the proved policy directly. For a HEAD response, a 204 and a 304 it advances the response state past the final HEADERS frame, then offers a DATA frame of length zero, and asserts that the frame is accepted. It records the 205 case without asserting it.

```ada
   procedure Probe (Label : String; Code : Natural; Head : Boolean) is
      State  : constant Response_State := After_Final (Code, Head);
      Update : constant Response_Update :=
        On_Response_Frame (State, Data_Frame, Data_Length => 0);
```

```
  note a HEAD response: Body_Allowed FALSE, empty DATA gives MESSAGE_ERROR
  FAIL an empty DATA frame on a HEAD response is accepted
  note a 204 response: Body_Allowed FALSE, empty DATA gives MESSAGE_ERROR
  FAIL an empty DATA frame on a 204 response is accepted
  note a 304 response: Body_Allowed FALSE, empty DATA gives MESSAGE_ERROR
  FAIL an empty DATA frame on a 304 response is accepted
  note a 205 response: Body_Allowed TRUE (the policy permits a body on 205)
checks: 3  failures: 3
BUG REPRODUCED
exit status 1
```

The last line records the layer disagreement: the policy permits a body on 205 while the client controller does not.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A DATA frame of length zero on a response that may not carry content should be accepted and ignored, because it transfers no content and therefore does not violate RFC 9110 section 6.4.1. The two client layers should also agree on which status codes forbid content.

## Suggested treatment

Exempt `Data_Length = 0` from the `Body_Allowed` rejection in `src/flyology-http-http_3_message_policy.adb:113-117`, so that an empty DATA frame leaves the response state unchanged. Then reconcile `Body_Forbidden` at `src/flyology-http-http_3_client_connection.adb:355-357` with `Body_Allowed` at `src/flyology-http-http_3_message_policy.adb:94-96`, so that one of the two layers is the single authority on which status codes forbid content. Per "Ada source style" the policy is where that rule belongs, since the controller can read it from the policy state it already carries.

This needs a maintainer decision on the 205 disagreement, because resolving it changes which responses the client accepts. RFC 9110 section 15.3.6 states that "Since the 205 status code implies that no additional content will be provided, a server MUST NOT generate content in a 205 response", so the controller is arguably right and the policy is the one to change. That is a behaviour choice rather than a new value, so no new constant is implied either way; the alternative of leaving both layers as they are is not viable, since they disagree.

`src/flyology-http-http_3_message_policy.adb` is proved by `./scripts/prove.sh`; the exemption must keep it discharging with `--checks-as-errors=on`. `src/flyology-http-http_3_client_connection.adb` is not proved. The regression test belongs in `tests/flyology-http-http_3_message_policy-smoke.adb`, and the spike above is the test. No maintained test asserts the current rejection. {{ISSUE:H3-QPACK-14}} is the same pattern in the header policy and touches the same two layers.

## Severity

A response the peer framed with an empty DATA frame instead of a bare FIN fails with a stream reset, so a HEAD request, a 204 or a 304 from such a peer never completes. No stock server was observed emitting that shape over HTTP/3, so the trigger is not established against a named peer; what is established is that the two protocol families in this repository disagree, since the HTTP/2 client was deliberately changed to accept it. The 205 divergence between the proved policy and the client controller is a latent inconsistency rather than an observed failure. Deterministic; not reproduced against a live peer.
