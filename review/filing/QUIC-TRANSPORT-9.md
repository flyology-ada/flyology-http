Title: An ACK frame with 64 or more ACK ranges is answered with CONNECTION_CLOSE PROTOCOL_VIOLATION
Labels: bug
Refs: none

## Summary

`ACK_Range_Policy.Decode` rejects a frame whose ACK Range Count reaches 64, before it checks anything about the frame's validity. The rejection becomes `ACK_Range_Capacity_Exceeded` and then transport error 0x0A, so the driver answers a well-formed ACK frame with a CONNECTION_CLOSE. RFC 9000 sets no maximum on ACK Range Count, and the limit it does define constrains what an endpoint sends, not what it must accept.

## Problem

Commit `f078732`.

RFC 9000 section 19.3 defines the field as "ACK Range Count: A variable-length integer specifying the number of ACK Range fields in the frame" and states no maximum. Section 13.2.3 puts the limit on the sending side: "A receiver limits the number of ACK Ranges (Section 19.3.1) it remembers and sends in ACK frames".

The count is tested first, ahead of every validity check (`flyology_quic/src/flyology-quic-ack_range_policy.adb:64-66`):

```ada
      if Frame.ACK_Range_Count >= Max_Ranges then
         Result.Status := Too_Many_Ranges;
         return Result;
```

`Max_Ranges` is 64 (`flyology_quic/src/flyology-quic-ack_range_policy.ads:18`), and because the test is `>=`, 64 ranges are already too many.

The application space turns that into a capacity status (`flyology_quic/src/flyology-quic-application_space.adb:1452-1460`):

```ada
            if Ranges.Status /= ACK_Range_Policy.Decoded then
               Result.Status :=
                 (case Ranges.Status is
                     when ACK_Range_Policy.Too_Many_Ranges =>
                       ACK_Range_Capacity_Exceeded,
```

and `Transport_Error_For` maps that to PROTOCOL_VIOLATION (`flyology_quic/src/flyology-quic-connection_driver.adb:576-578`):

```ada
            | Application_Space.ACK_Range_Capacity_Exceeded
            | Application_Space.Acknowledges_Unsent_Packet
            | Application_Space.Conflicting_Stream_Data => 16#0A#,
```

The Initial and Handshake spaces map the same status the same way (`flyology_quic/src/flyology-quic-initial_space.adb:380-388`, `flyology_quic/src/flyology-quic-connection_driver.adb:504-505` and `:524-525`).

`flyology_quic/tests/src/flyology-quic-ack_range_policy-smoke.adb:42-47` asserts `Too_Many_Ranges` at the policy level, which pins the current choice and will have to change with it.

Whether any stock peer emits 64 or more ACK ranges is not verified against a peer here; peers cap what they send, and the caps were not measured.

## What happens now

Spike: it puts 200 real packets behind the sender, with the peer acknowledging every eighth so that neither the congestion window nor the 64-entry sent-packet ledger interferes, and then delivers ACK frames whose every range names packets the sender actually sent. Only the range count varies.

```ada
   for Index in 1 .. 200 loop
      Build_Stream_Packet
        (Client, Stream_ID => 0,
         Offset => Varint_Policy.Value_Type (Index - 1),
         Fin => False, Data => (1 => 16#61#),
         Now => Timestamp (1_000 * Index), Packet => Packet,
         Result => Sent_Data);
      ...
   end loop;
   Try (62);
   Try (63);
   Try (64);
   Check (Received.Status = Processed,
          "an ACK with 64 ranges is accepted (RFC 9000 s19.3 sets no"
          & " maximum on ACK Range Count)");
```

```
  note highest packet number the sender reached: 199
  ok   precondition: enough packets were sent for a 64-range ACK
  note ACK largest 199 with 62 ranges (smallest 75): PROCESSED
  ok   precondition: an ACK with 62 ranges is accepted
  note ACK largest 199 with 63 ranges (smallest 73): PROCESSED
  ok   an ACK with 63 ranges is accepted
  note ACK largest 199 with 64 ranges (smallest 71): ACK_RANGE_CAPACITY_EXCEEDED
  FAIL an ACK with 64 ranges is accepted (RFC 9000 s19.3 sets no maximum on ACK Range Count)
checks: 4  failures: 1
BUG REPRODUCED
```

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A well-formed ACK frame must not be a connection error because of how many ranges it carries. An endpoint that cannot remember every range should apply the ones it can and ignore the rest; ranges are descending, so the ones it drops are the oldest packets, which at worst are retransmitted spuriously.

## Suggested treatment

Change `ACK_Range_Policy.Decode` to consume the whole frame, so the frame boundary stays correct, while retaining only the newest `Max_Ranges` ranges, and report that outcome as a success rather than as `Too_Many_Ranges`. The callers in `Application_Space` and `Initial_Space` then need no mapping to a transport error at all.

Whether 64 is the right number to retain is a separate question from whether exceeding it should close the connection. This needs a maintainer decision under "Decision authority" and "Ada interface values": `Max_Ranges` is a visible constant in `flyology-quic-ack_range_policy.ads:18` that sizes the decoded range array and the `Range_Count` and `Range_Index` subtypes, so its value, its name and its visibility are the maintainer's choice. The options are a private implementation value, a caller parameter, a generic formal on the policy package, a discriminant on the decode result, a value derived from the sent-packet ledger's own capacity, build-time configuration, or a deliberately public constant with its rationale recorded next to it.

The regression test belongs in `flyology_quic/tests/src/flyology-quic-ack_range_policy-smoke.adb` for the policy half and in `flyology_quic/tests/src/flyology-quic-application_space-smoke.adb` for the connection half. The spike is the test. The existing assertion at `flyology-quic-ack_range_policy-smoke.adb:42-47` asserts the current rejection and must change. `flyology-quic-ack_range_policy.adb` is proved by `./scripts/prove.sh`, so the fix must keep that proof discharging with `--checks-as-errors=on`, which is the main constraint on how the truncation is written.

## Severity

A peer whose receive history has many gaps, which is what heavy alternating loss produces, sends a legitimate ACK and gets its connection closed with PROTOCOL_VIOLATION. Whether any stock peer reaches 64 ranges depends on its own ACK-range cap, which is not verified against a peer here, so the reachability in practice is not established. The code path itself is deterministic and the frame that triggers it is well-formed. Deterministic; not reproduced against a live peer.
