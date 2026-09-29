Title: QPACK Encode refuses field sections over 1,109 bytes, so the documented 16 KiB field value cannot be sent
Labels: bug
Refs: none

## Summary

The public HTTP/3 contract advertises a 16 KiB bound on field values and names long `:path` values as the reason. The send path cannot honour it: `Encode` refuses any field section whose encoding exceeds 1,109 bytes, and the measured ceiling for a single value in a two-field section is 1,096 bytes. The failure is reported as `QPACK_Decompression_Failed`, which becomes a 500 on the server and a transport failure on the client, so a response with a large header or a request with a long target fails for a reason unrelated to what went wrong.

## Problem

Commit `f078732`.

The public contract (`src/flyology-http-http_3.ads:17-22`):

```ada
   --  Largest field value retained by the bounded QPACK profile.
   --  Bounded field-value size, including long :path values used by
   --  presigned object requests.
   Max_Value_Length : constant := 16 * 1_024;
   --  Largest number of fields retained in one field section.
   Max_Fields : constant := 32;
```

and `CHANGELOG.md:79-81` repeats it: "Raised bounded metadata limits for S3-style requests: client request targets to 16 KiB, HTTP/1 request heads to 32 KiB, and QPACK field values to 16 KiB."

The send path has a much smaller bound (`src/flyology-http-qpack_field_section_policy.ads:17-21`):

```ada
   Max_Encoded_Length : constant := 65_535;
   --  Encoded field sections are immediately wrapped in a bounded HTTP/3
   --  frame.  Decoding retains the full protocol bound, but send results only
   --  need room for the largest useful single-datagram field section.
   Max_Encode_Length  : constant := 1_109;
```

`Encode` returns `Section_Too_Large` above it, and every caller collapses that into a QPACK protocol error (`src/flyology-http-http_3_connection.adb:862-866`):

```ada
      Encoded := QPACK_Field_Section_Policy.Encode (Headers);
      if Encoded.Status /= QPACK_Field_Section_Policy.Encoded then
         Status := QPACK_Decompression_Failed;
         return;
      end if;
```

From there the server turns `QPACK_Decompression_Failed` into `Device_Error` in `Send_Headers` and `Try_Send_Response`, which `Dispatch_Request` turns into a 500, and the client turns it into `Fail_Exchange (Item, Transport_Failed)` (`src/flyology-http-client.adb:5223-5229`).

No RFC is violated here. The violated contract is the repository's own specification and CHANGELOG.

No existing test sends a large field section. `tests/http3_public_smoke.adb:92-99` covers only the peer-advertised `Peer_Field_Section_Too_Large` case, and `tests/corpus/http-client-scenarios.json` has no long-target scenario although its scenarios run over `h3`.

## What happens now

Spike: the program calls `Encode` directly on two field sections that the public contract admits, a 1,200-byte `content-security-policy` on a 200 response and a 16 KiB `:path` on a GET, and asserts that both encode. It then binary-searches for the actual ceiling.

```ada
   Block.Count := 2;
   Block.Fields (1) := Make_Field (":status", "200");
   Block.Fields (2) :=
     Make_Field ("content-security-policy", (1 .. 1_200 => 'a'));
   ...
   Block.Count := 2;
   Block.Fields (1) := Make_Field (":method", "GET");
   Block.Fields (2) := Make_Field (":path", (1 .. 16 * 1_024 => 'p'));
```

```
  note Max_Value_Length = 16384, Max_Fields = 32, Max_Encode_Length = 1109
  note 1,200-byte value: Encode returns SECTION_TOO_LARGE, length 8
  FAIL a 1,200-byte field value, inside the documented 16 KiB bound, encodes for sending
  note 16 KiB :path: Encode returns SECTION_TOO_LARGE
  FAIL a 16 KiB :path, the exact size the contract names, encodes
  note largest sendable single x-long value: 1096 bytes
checks: 2  failures: 2
BUG REPRODUCED
exit status 1
```

The measured ceiling of 1,096 bytes rules out any reading in which only the 16 KiB extreme fails: the cutoff is an order of magnitude below the documented bound, so an ordinary `content-security-policy`, a 1 KiB `set-cookie` or a set of `link` preloads is already past it.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A field section whose names and values are inside the bounds `src/flyology-http-http_3.ads:15-22` publishes must be encodable and sendable, since those constants are the profile's public statement of what it accepts. If the send path genuinely cannot carry more, then the public bound is wrong and should say what is actually supported. Either way the two must agree, and a section that is too large to send should not be reported as a QPACK decoding failure.

## Suggested treatment

Raise `Max_Encode_Length` to the size implied by the public `Max_Name_Length`, `Max_Value_Length` and `Max_Fields` bounds, and frame a field section that exceeds one datagram across several QUIC stream writes instead of requiring it to fit in one. `Build_Stream_Datagram` currently accepts at most 1,100 bytes (`Max_Stream_Payload : constant := 1_100;` at `flyology_quic/src/flyology-quic-connections.ads:21`), which is the reason for the 1,109 figure, so the send path has to loop over the encoded section rather than pass it in one call.

This needs a maintainer decision, because both directions change a published value. Under "Decision authority" and "Ada interface values" the options are: a private implementation value, if `Max_Encode_Length` moves out of the visible part of `src/flyology-http-qpack_field_section_policy.ads`; a caller parameter; a generic formal; a value derived from the existing `Max_Name_Length`, `Max_Value_Length` and `Max_Fields` contract, which is the option that makes the specification self-consistent; build-time configuration; or a deliberately public constant. The alternative decision is to lower the advertised `Max_Value_Length` in `src/flyology-http-http_3.ads:20` and amend the CHANGELOG entry, which is a narrowing of a published contract and needs the same authorization. Growing the encode buffer also grows `Encode_Result`, which is a stack-resident record, so the memory cost is part of the decision.

`src/flyology-http-qpack_field_section_policy.adb` is proved by `./scripts/prove.sh`, and its bounds contracts are written against `Max_Encode_Length`; the fix must keep the unit discharging with `--checks-as-errors=on`. The regression test belongs in `tests/flyology-http-qpack_field_section_policy-smoke.adb`, which already consumes the RFC 9204 Appendix B.1 vector; the spike above is the test. No maintained test asserts the current ceiling.

## Severity

Any response whose headers exceed about 1 KiB becomes a 500, and any client request whose target exceeds about 1 KiB fails as a transport error, in both cases with a message naming QPACK decompression, which is not what happened. A single `content-security-policy` header, a session cookie, or a presigned object URL of the kind the specification comment explicitly names is enough. The public contract and the CHANGELOG both promise sixteen times what the code delivers. Deterministic.
