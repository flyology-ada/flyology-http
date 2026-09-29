Title: A server that raises Max_Stream_Data_Bidi_Remote advertises credit it cannot honour and closes a compliant peer
Labels: bug
Refs: none

## Summary

`Transport_Settings` is a public parameter of `Serve_Listener`, `Serve_HTTP_3` and their siblings, and nothing in its specification says the default values are ceilings. The settings are copied straight into the encoded transport parameters, while the receive path is sized by two fixed constants: a 16,384-byte per-stream reassembly ring and 32 stream slots. A caller who raises `Max_Stream_Data_Bidi_Remote` to accept larger request bodies gets a server that advertises the larger credit and then closes the connection with transport error 0x01 when a compliant peer uses it.

## Problem

Commit `f078732`.

`Transport_Settings` appears in the public interface with its fields documented as credit and limits and typed over the whole varint range, with no bound stated (`flyology_quic/src/flyology-quic-connections.ads:93-109`):

```ada
   --  @field Max_Stream_Data_Bidi_Remote Receive credit on peer bidi streams
   ...
   type Transport_Settings is record
      Max_UDP_Payload_Size        : Stream_Offset := Max_Datagram_Length;
      Max_Data                    : Stream_Offset := 524_288;
      Max_Stream_Data_Bidi_Local  : Stream_Offset := 16_384;
      Max_Stream_Data_Bidi_Remote : Stream_Offset := 16_384;
      Max_Stream_Data_Uni         : Stream_Offset := 16_384;
      Max_Streams_Bidi            : Stream_Offset := 29;
      Max_Streams_Uni             : Stream_Offset := 3;
   end record;
```

It is a caller-supplied parameter at `src/flyology-http-server-http_3.ads:66`, `:103` and `:142`, and at `src/flyology-http-server-routing.ads:998`, `:1060`, `:1131` and `:1202`, in each case defaulted to `(others => <>)`. Raising a field is the obvious way to accept a larger request body.

`Encode_Parameters` copies each field into the transport parameters with no comparison against anything (`flyology_quic/src/flyology-quic-connections.adb:191-199`):

```ada
      Value.Initial_Max_Data := (True, Settings.Max_Data);
      Value.Initial_Max_Stream_Data_Bidi_Local :=
        (True, Settings.Max_Stream_Data_Bidi_Local);
      Value.Initial_Max_Stream_Data_Bidi_Remote :=
        (True, Settings.Max_Stream_Data_Bidi_Remote);
      Value.Initial_Max_Stream_Data_Uni :=
        (True, Settings.Max_Stream_Data_Uni);
      Value.Initial_Max_Streams_Bidi := (True, Settings.Max_Streams_Bidi);
      Value.Initial_Max_Streams_Uni := (True, Settings.Max_Streams_Uni);
```

The receive path is fixed. `Stream_Reassembly_Policy.Max_Stream_Data` is 16,384 (`flyology_quic/src/flyology-quic-stream_reassembly_policy.ads:18`), `Stream_Table_Policy.Max_Streams` is 32 (`flyology_quic/src/flyology-quic-stream_table_policy.ads:17`), and the ring simply refuses anything past its capacity (`flyology_quic/src/flyology-quic-stream_reassembly_policy.adb:72-76`):

```ada
      if Ending > Item.Base
        and then Ending - Item.Base > Absolute_Offset (Max_Stream_Data)
      then
         return;
```

That refusal becomes `Stream_Table_Policy.Stream_Data_Too_Large`, then `Application_Space.Stream_Data_Too_Large`, and then transport error 0x01 (`flyology_quic/src/flyology-quic-connection_driver.adb:581-582`):

```ada
         when Application_Space.Stream_Capacity_Exceeded
            | Application_Space.Stream_Data_Too_Large => 16#01#,
```

RFC 9000 section 4.1: "QUIC employs a limit-based flow control scheme where a receiver advertises the limit of total bytes it is prepared to receive on a given stream or for the entire connection". The peer stayed inside the limit this server advertised.

No test covers it, because every maintained lane uses `Transport_Settings'(others => <>)` (`tests/flyology-quic-test_connections.adb:91`, `:102`, `tests/http3_public_smoke.adb:24`, `src/flyology-http-server-http_3.adb:1477`), whose 16,384 default happens to equal the ring exactly.

## What happens now

Spike: it builds a server with `Max_Stream_Data_Bidi_Remote => 32_768` and everything else defaulted, completes a handshake with a client, opens one bidirectional stream and sends eighteen 1,100-byte chunks on it, returning the server's acknowledgements each time so the sender is never the binding constraint. The server's application never consumes the stream, which is what an application that has not yet read the request body does.

```ada
   Server_Settings : constant QUIC.Transport_Settings :=
     (QUIC.Transport_Settings'(others => <>) with delta
        Max_Stream_Data_Bidi_Remote => 32_768);
   ...
   for Index in 1 .. 18 loop
      QUIC.Build_Stream_Datagram
        (Client, Stream, Offset, Fin => False, Data => Chunk,
         Now => QUIC.Timestamp (1_000 + Index),
         Packet => Packet, Status => Sent);
      exit when Sent /= QUIC.Sent;
      Give (Packet, Server, Server_Output, Server_Status);
   end loop;
```

```
  ok   precondition: the handshake completed
  note server advertised Max_Stream_Data_Bidi_Remote = 32768
  note client sent 16500 bytes within the advertised 32768; last client status SENT; server status SUCCEEDED; server state FAILED
  FAIL a server accepts stream data inside the per-stream credit it advertised (RFC 9000 s4.1)
  FAIL all 18 chunks are delivered within the advertised credit
         expected: 19800   actual: 16500
checks: 3  failures: 2
BUG REPRODUCED
```

The server accepts 16,500 bytes, half of what it advertised, and then moves to `Failed`.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A server must accept stream data it has granted credit for, so either the advertised credit must never exceed what the receive path can hold, or the receive path must be able to hold whatever the caller configures. The specification should say which, because today it says neither.

## Suggested treatment

The immediate fix is to stop advertising more than can be honoured: clamp each field in `Encode_Parameters` (`flyology_quic/src/flyology-quic-connections.adb:176-201`) against `Stream_Reassembly_Policy.Max_Stream_Data` and `Stream_Table_Policy.Max_Streams`, or reject an out-of-range `Transport_Settings` at initialisation with `Invalid_Transport_Settings`, which `Initialize_Server_From_Initial` already returns for an unencodable setting.

Clamping silently is not obviously right, because a caller who asked for 64 KiB and got 16 KiB has been ignored. The alternative is to make the ring sizeable so the configured value can actually be honoured.

This needs a maintainer decision, and it is a decision about where a currently implicit ceiling lives, not only about its value. Under "Decision authority" and "Ada interface values" the options are: keep the bound a private implementation value and reject settings above it; make it a caller parameter alongside `Transport_Settings`; make the reassembly capacity a generic formal of `Stream_Reassembly_Policy`; make it a discriminant on the stream table or the connection so each connection is sized at creation; derive the advertised credit from the reassembly type's own bound so the two cannot disagree; make it build-time configuration; or state it as a deliberately public constant and document in `flyology-quic-connections.ads` that `Transport_Settings` fields are capped by it. Whichever is chosen, the `.ads` comment on `Transport_Settings` should say what the accepted range is, since today it does not.

The regression test belongs in `flyology_quic/tests/src/flyology-quic-application_space-smoke.adb` for the policy half and in the HTTP crate's `tests/http3_public_smoke.adb` for the public-parameter half; both currently use only the defaults. The spike is the test. No existing test asserts the current behaviour. `flyology-quic-stream_reassembly_policy.adb` and `flyology-quic-stream_table_policy.adb` are both proved by `./scripts/prove.sh`, so a change that makes the capacity a generic formal or a discriminant must keep those proofs discharging with `--checks-as-errors=on`; `flyology-quic-connections.adb` is not proved.

## Severity

A caller who raises a documented public setting gets a server that violates flow control against a compliant peer and closes the connection with INTERNAL_ERROR partway through the request body. It is not the default configuration, but it is the configuration a caller reaches for as soon as request bodies exceed 16 KiB, and nothing in the specification warns against it. The same shape applies to `Max_Streams_Bidi` above 32. Deterministic.
