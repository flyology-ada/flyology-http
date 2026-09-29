Title: PATH_CHALLENGE is parsed and ignored, so no PATH_RESPONSE is ever sent
Labels: bug
Refs: none

## Summary

`Application_Frame_Policy` decodes PATH_CHALLENGE and PATH_RESPONSE, but the frame loop in the application space has no branch for either. A received PATH_CHALLENGE is counted as ack-eliciting and discarded, and no PATH_RESPONSE is ever built. A peer that validates a new path, which is what a stock peer does after a NAT rebinding, never gets an answer, cannot use the unvalidated path, and the connection dies at its idle timeout.

## Problem

Commit `f078732`.

RFC 9000 section 8.2.2: "On receiving a PATH_CHALLENGE frame, an endpoint MUST respond by echoing the data contained in the PATH_CHALLENGE frame in a PATH_RESPONSE frame. An endpoint MUST NOT delay transmission of a packet containing a PATH_RESPONSE frame unless constrained by congestion control."

The frame is decoded correctly (`flyology_quic/src/flyology-quic-application_frame_policy.adb:386-395`):

```ada
         when 16#1A# | 16#1B# =>
            Result.Kind :=
              (if Result.Frame_Type = 16#1A# then Path_Challenge else Path_Response);
            if Data_Length - Position < 8 then
               Result.Status := Truncated;
               return Result;
            end if;
            Result.Path_Data_Offset := Position;
            Position := Position + 8;
            Finish;
```

The frame chain in `Application_Space.Process_Packet` (`flyology_quic/src/flyology-quic-application_space.adb:1283-1512`) has branches for HANDSHAKE_DONE, CRYPTO, NEW_TOKEN, both closes, STREAM, RESET_STREAM, STOP_SENDING, MAX_DATA, MAX_STREAM_DATA, both MAX_STREAMS, both STREAMS_BLOCKED and ACK. `Path_Challenge` and `Path_Response` appear nowhere in that body, so both fall through to the end of the loop and are dropped. Nothing else in the crate builds a PATH_RESPONSE.

Neither pinned peer challenges a stable path, which is why the interop lane passes and says nothing about this. aioquic 1.3.0 writes a PATH_CHALLENGE for any path that is neither validated nor already challenged (`quic/connection.py:3022-3033`), but a client's own path is created pre-validated by `connect()` (`:516`) and a server's path is validated when a Handshake-epoch packet arrives (`:1060-1064`). quic-go 0.54.1 enqueues one only when its path manager sees a new remote address (`path_manager.go:122-137`) or probes an alternative path (`path_manager_outgoing.go:267`). Both would challenge a rebound path.

`flyology_quic/tests/src/flyology-quic-application_frame_policy-smoke.adb:59-60` parses the two frames and asserts nothing about answering them. `flyology_quic/tests/qualification.md:144` lists "NAT rebinding, and path validation" among the areas not yet covered.

## What happens now

Spike: it initialises the application space with an opened bidirectional stream, delivers one 1-RTT packet carrying PATH_CHALLENGE with eight octets of data, then decrypts the endpoint's next outgoing packet and looks for a PATH_RESPONSE echoing those octets.

```ada
   --  PATH_CHALLENGE (type 0x1A) with eight octets of data.
   Application_Connection.Build_One_RTT
     (Remote,
      (16#1A#, 16#01#, 16#02#, 16#03#, 16#04#,
       16#05#, 16#06#, 16#07#, 16#08#),
      Packet, Built);
   ...
   Scan_Reply ("next outgoing packet");
   Check (Saw_Response, ...);
```

```
  note PATH_CHALLENGE processed as PROCESSED; frames seen 1; ack-eliciting TRUE
  ok   precondition: the PATH_CHALLENGE frame is accepted
  note next outgoing packet: reply frames 02 00 00 00 00
  FAIL an endpoint that receives PATH_CHALLENGE echoes the data in a PATH_RESPONSE (RFC 9000 s8.2.2)
checks: 2  failures: 1
BUG REPRODUCED
```

The frame is accepted and counted, and the only frame in the reply is an ACK.

Host: macOS 26.6.2, arm64, GNAT via Alire. Peer behaviour above read from the pinned sources of aioquic 1.3.0 and quic-go 0.54.1, not observed in a new peer run.

## What should happen

An endpoint that receives a PATH_CHALLENGE must put a PATH_RESPONSE echoing the same eight octets in the next packet it sends, as RFC 9000 section 8.2.2 requires.

## Suggested treatment

Add a `Path_Challenge` branch to the frame chain in `Application_Space.Process_Packet` that records the eight octets, and emit the PATH_RESPONSE in the next outgoing packet the way the pending ACK is emitted today. `Application_Frame_Policy` already has the frame type and the data offset, so only an encoder for 0x1B and one pending-response slot are new. A received PATH_RESPONSE should at least be accepted rather than dropped silently, even while path validation as a whole is not implemented.

Holding pending challenges needs a bound on how many an endpoint will remember before it starts dropping them. This needs a maintainer decision under "Decision authority" and "Ada interface values". The options are a private implementation value in the application space body, a single slot with a documented replace-the-oldest rule, a generic formal, a discriminant on the application-space state, a value derived from the peer's `active_connection_id_limit`, build-time configuration, or a deliberately public constant.

The regression test belongs in `flyology_quic/tests/src/flyology-quic-application_space-smoke.adb`, extending the 1-RTT frame coverage that is already there. The spike is the test. No existing test asserts the current behaviour. `flyology-quic-application_space.adb` is not among the units `./scripts/prove.sh` proves; `flyology-quic-application_frame_policy.adb` is, so a new encoder there must keep the proof discharging with `--checks-as-errors=on`.

## Severity

This is an unambiguous MUST that is not implemented, but reaching it needs the peer to validate a path, which on a stable path neither pinned peer does. After a NAT rebinding, which is ordinary for a mobile client, a stock peer challenges the new address, never receives a response, cannot send beyond the anti-amplification limit on the unvalidated path, and the connection blackholes until its idle timeout rather than failing cleanly. Deterministic in the frame handling; the path change that triggers it is not reproduced against a live peer.
