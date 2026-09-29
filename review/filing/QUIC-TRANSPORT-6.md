Title: STOP_SENDING is validated and dropped, so no RESET_STREAM is sent and no layer sees the cancellation
Labels: bug
Refs: none

## Summary

The application space runs the flow-control admission check on a received STOP_SENDING frame and then falls through without doing anything with it. No RESET_STREAM is emitted, `Process_Result` has no field that would let a higher layer act, and the local sender can still put more data on the stream. A peer that cancels a request keeps receiving the whole response, and the sender keeps consuming the peer's flow-control credit for bytes the peer discards.

## Problem

Commit `f078732`.

RFC 9000 section 3.5: "A STOP_SENDING frame requests that the receiving endpoint send a RESET_STREAM frame. An endpoint that receives a STOP_SENDING frame MUST send a RESET_STREAM frame if the stream is in the 'Ready' or 'Send' state."

The frame is admitted and then abandoned (`flyology_quic/src/flyology-quic-application_space.adb:1392-1402`):

```ada
         elsif Frame.Kind = Application_Frame_Policy.Stop_Sending then
            Receive_Status :=
              Receive_Flow_Control_Policy.Check_Stop_Sending
                (Candidate_Receive, Frame.Stream_ID, Local_Bidi_Opened,
                 Local_Uni_Opened);
            if Receive_Status /= Receive_Flow_Control_Policy.Reserved
              and then Receive_Status /= Receive_Flow_Control_Policy.Retired
            then
               Result.Status := Process_Status_For (Receive_Status);
               return;
            end if;
```

`Stop_Sending` appears nowhere else in that body, and `Process_Result` has no field carrying it (`flyology_quic/src/flyology-quic-application_space.ads:241-252`):

```ada
   type Process_Result is record
      Status          : Process_Status := Envelope_Rejected;
      Number          : Packet_Number := 0;
      Frame_Count     : Natural := 0;
      Resolved_Count  : Natural := 0;
      ACK_Eliciting   : Boolean := False;
      Handshake_Done  : Boolean := False;
      Peer_Closed     : Boolean := False;
      Application_Close : Boolean := False;
      Close_Error     : Varint_Policy.Value_Type := 0;
      Triggering_Frame_Type : Varint_Policy.Value_Type := 0;
   end record;
```

So the HTTP/3 layer above cannot act on it either.

The machinery to answer already exists and is simply not wired to this frame. `Application_Space.Build_Stream_Abort_Packet` (`flyology_quic/src/flyology-quic-application_space.ads:127`) encodes RESET_STREAM followed by STOP_SENDING through the proved `Application_Frame_Policy.Encode_Stream_Abort`, and is reached today only from `flyology-quic-connection_driver.adb:290`.

Stock peers do send this frame in ordinary use. quic-go 0.54.1's HTTP/3 package calls `CancelRead` on the request stream after a handler returns (`http3/server.go:674`) and on a response body that is closed without being read to the end (`http3/body.go:70`), and `CancelRead` queues a STOP_SENDING unless the stream already reached the end or was cancelled remotely (`receive_stream.go:379-392`). aioquic 1.3.0 sends it when the application aborts a read (`quic/connection.py:3128-3129`).

The interop lane passing is not evidence that the peers do not send it. The pinned oracle reads the whole body first (`tests/oracle/quic-go/main.go:131` calls `io.ReadAll` before the `Close` on the next line), which makes `CancelRead` a no-op, and the aioquic scripts never cancel. The lane is silent on this frame.

`flyology_quic/tests/src/flyology-quic-receive_flow_control_policy-smoke.adb:51-59` tests the admission check only. `flyology_quic/tests/qualification.md:141` lists "reset/stop semantics" among the areas not yet covered.

## What happens now

Spike: it opens stream 0 in the client role, sends data on it so the stream is in the Send state, then delivers a 1-RTT packet carrying STOP_SENDING for stream 0 with application error 0x10, which is H3_REQUEST_CANCELLED. It decrypts the endpoint's next outgoing packet and looks for a RESET_STREAM, then tries to send more data on the same stream.

```ada
   --  STOP_SENDING (type 0x05) for stream 0, application error 0x10
   --  (H3_REQUEST_CANCELLED).
   Application_Connection.Build_One_RTT
     (Remote, (16#05#, 16#00#, 16#10#), Packet, Built);
   ...
   Scan_Reply ("next outgoing packet");
   Check (Saw_Reset, ...);
   Build_Stream_Packet
     (Client, Stream_ID => 0, Offset => 2, Fin => False,
      Data => (16#63#, 16#64#), Now => 300, Packet => Packet,
      Result => Sent_Data);
```

```
  ok   precondition: stream 0 is in the Send state
  note STOP_SENDING processed as PROCESSED; frames seen 1
  note next outgoing packet: reply frames 02 00 00 00 00
  FAIL an endpoint that receives STOP_SENDING for a stream in the Send state sends a RESET_STREAM (RFC 9000 s3.5)
  note sending more data on the cancelled stream: SENT
  FAIL a stream that the peer asked to stop is no longer sendable (RFC 9000 s3.5 moves it to Reset Sent)
checks: 3  failures: 2
BUG REPRODUCED
```

The only frame in the reply is an ACK.

Host: macOS 26.6.2, arm64, GNAT via Alire. Peer behaviour above read from the pinned sources of quic-go 0.54.1 and aioquic 1.3.0, not observed in a new peer run.

## What should happen

An endpoint that receives STOP_SENDING for a stream in the Ready or Send state must send a RESET_STREAM for that stream, and the stream must move to Reset Sent so the local sender stops producing data for it, as RFC 9000 section 3.5 requires.

## Suggested treatment

Record the frame where it is validated, and act on it: move the send-side stream state to Reset Sent, and schedule a RESET_STREAM carrying the peer's application error code through the existing `Build_Stream_Abort_Packet`. Surfacing it upward matters as much as answering it, because the HTTP/3 server should stop generating the response body rather than stream it into a reset stream.

Surfacing it changes a public record and a public status set. This needs a maintainer decision under "Decision authority" and "Ada interface values": adding a field to `Process_Result` and a way for the layer above to see the stream id and the error code is a new variant or a new parameter on an interface, not an implementation detail. The options are a private implementation value with the reset scheduled entirely inside the application space and nothing surfaced, a new `Process_Result` field carrying the stream id and error code, a caller-supplied callback, a new `Process_Status` value, or a separate query the driver calls after processing. The choice also decides whether the reset is emitted automatically on the next flight or only when the layer above asks for it.

The regression test belongs in `flyology_quic/tests/src/flyology-quic-application_space-smoke.adb`, which already drives an application connection through 1-RTT frames. The spike is the test. `flyology_quic/tests/src/flyology-quic-receive_flow_control_policy-smoke.adb:51-59` asserts only the admission check and stays correct. `flyology-quic-application_space.adb` is not among the units `./scripts/prove.sh` proves; `flyology-quic-application_frame_policy.adb` and `flyology-quic-receive_flow_control_policy.adb` are, so any change there must keep the proofs discharging with `--checks-as-errors=on`.

## Severity

Nothing fails and no wrong result is delivered: the peer discards the data it asked to stop and the connection survives. The cost is wasted work, a response streamed in full after it was cancelled, and the peer's per-stream credit consumed for it. The trigger is common rather than unusual, since a Go client that closes a response body early and a Go handler that does not drain the request body both send the frame, though that was read from the pinned peer sources and not observed against a live peer here. A further consequence, that an Ada server streaming a response larger than the peer's per-stream window onto a cancelled stream would stall until the request deadline because the peer stops issuing credit for an abandoned stream, is not verified against a peer. Deterministic.
