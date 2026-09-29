Title: A 204 or 1xx response carrying content-length is treated as malformed by the HTTP/3 recipient
Labels: bug
Refs: H3-QPACK-11

## Summary

`Validate_Response` marks a response malformed when it carries `content-length` together with an interim status or 204. RFC 9110 section 8.6 constrains the sender, not the recipient, and RFC 9114 section 4.1.2 explicitly anticipates a Content-Length on a response that never has content without calling it malformed. Frameworks that emit `content-length: 0` on a 204 are therefore unreachable over HTTP/3. The client controller enforces the 204 half independently, so a fix has to touch both layers.

## Problem

Commit `f078732`.

The proved header policy rejects the combination (`src/flyology-http-http_3_header_policy.adb:414-418`):

```ada
         if Result.Has_Content_Length
           and then (Result.Is_Interim or else Code = 204)
         then
            Result.Status := Invalid_Content_Length;
         end if;
```

The client controller enforces the 204 half again (`src/flyology-http-http_3_client_connection.adb:367-373`):

```ada
                                 if not Length_Valid
                                   or else
                                     (Code = 204
                                        and then
                                          Stream.Has_Expected_Length)
                                 then
                                    Stream.Phase := Failed;
```

RFC 9110 section 8.6 is a sender requirement: "A server MUST NOT send a Content-Length header field in any response with a status code of 1xx (Informational) or 204 (No Content)." It says nothing about how a recipient treats one that arrives.

RFC 9114 section 4.1.2 lists the malformed conditions, and content-length on a 1xx or 204 is not among them. It goes further and describes the case directly: "A response that is defined as never having content, even when a Content-Length is present, can have a non-zero Content-Length header field even though no content is included in DATA frames." A recipient that treats such a response as malformed is doing something the specification anticipated and declined to require.

No existing test covers the combination over HTTP/3.

## What happens now

Spike: the program calls `Validate_Response` on a 204 carrying `content-length: 0` and on a 103 carrying the same field, and asserts that neither is malformed. It validates a 200 carrying the identical field as a control.

```ada
   procedure Probe (Label, Code, Length : String) is
      Block : QPACK.Header_Block;
   begin
      Block.Count := 2;
      Block.Fields (1) := QPACK.Make_Field (":status", Code);
      Block.Fields (2) := QPACK.Make_Field ("content-length", Length);
      declare
         Result : constant Validation_Result := Validate_Response (Block);
```

```
  note 204 with content-length: 0: INVALID_CONTENT_LENGTH
  FAIL 204 with content-length: 0 is not a malformed message for the recipient
  note 103 with content-length: 0: INVALID_CONTENT_LENGTH
  FAIL 103 with content-length: 0 is not a malformed message for the recipient
  note control, 200 with content-length: 0: VALID
checks: 2  failures: 2
BUG REPRODUCED
exit status 1
```

The control line rules out an explanation in the content-length parsing: the identical field on a 200 validates, so the status code is the only variable.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A recipient should accept a 1xx or 204 response that carries `content-length` and ignore the field, since RFC 9114 section 4.1.2 does not list the combination among the malformed conditions and explicitly contemplates a Content-Length on a response that never has content. Only a DATA frame with actual content on such a response is a message error, which the message policy handles separately.

## Suggested treatment

Drop the `Is_Interim or else Code = 204` clause from `src/flyology-http-http_3_header_policy.adb:414-418` and let `Has_Content_Length` be recorded without failing validation, so the length is parsed for diagnostics and then ignored for a status that cannot carry content. Remove the matching `Code = 204 and then Stream.Has_Expected_Length` clause at `src/flyology-http-http_3_client_connection.adb:367-373`, leaving the `not Length_Valid` syntax check in place. The content-forbidding rule then lives in one place, the message policy's `Body_Allowed`, which is where {{ISSUE:H3-QPACK-11}} also lands.

No new constant, default, capacity or parameter is implied, so this is not a decision under "Decision authority"; `Invalid_Content_Length` stays in the status enumeration for the syntax and duplication cases that genuinely need it.

`src/flyology-http-http_3_header_policy.adb` is proved by `./scripts/prove.sh`; the change must keep the unit discharging with `--checks-as-errors=on`. `src/flyology-http-http_3_client_connection.adb` is not proved. The regression test belongs in `tests/flyology-http-http_3_header_policy-smoke.adb`, which already exercises the response validator; the spike above is the test. No maintained test asserts the current rejection.

## Severity

A server that emits `content-length: 0` on a 204, which several widely used frameworks do, cannot be talked to over HTTP/3 by this client: the response is malformed at the header policy and the exchange fails. The same applies to a 1xx interim response carrying the field, which is rarer. The sender is in the wrong under RFC 9110 section 8.6, but RFC 9114 section 4.1.2 does not make the recipient reject it, and the practical effect is that a conforming exchange is lost over a field the recipient could ignore. No specific peer emitting this shape over HTTP/3 was identified here. Deterministic; not reproduced against a live peer.
