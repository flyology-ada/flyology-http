Title: Handshake, master, exporter and traffic secrets survive a successful QUIC handshake and the release of the connection
Labels: bug
Refs: none

## Summary

`TLS_Session` clears every secret it holds when a handshake fails, but on the success path it clears only the ephemeral X25519 private key and, on the server, the signing key. The handshake secret, the master secret, both handshake traffic secrets, both finished keys and the exporter secret are all dead once the session reaches `Connected`, yet all of them stay in the `Session` for the life of the connection and are still in the heap block after the connection is finalized, because `Connections.Finalize` deallocates without overwriting. The success path therefore breaks a discipline the failure path already keeps.

## Problem

Commit `f078732`.

`Mark_Failed` clears everything (`flyology_quic/src/flyology-quic-tls_session.adb:33-46`):

```ada
   procedure Mark_Failed (Item : in out Session) is
   begin
      Item.Current_State := Failed;
      Item.X25519_Private := (others => 0);
      Item.Signing_Key := (others => 0);
      TLS_Key_Schedule.Clear (Item.Handshake_Secrets);
      TLS_Key_Schedule.Clear (Item.Application_Secrets);
      TLS_Key_Schedule.Clear (Item.Client_Handshake_Keys);
      TLS_Key_Schedule.Clear (Item.Server_Handshake_Keys);
      TLS_Key_Schedule.Clear (Item.Client_Application_Keys);
      TLS_Key_Schedule.Clear (Item.Server_Application_Keys);
```

The client success transition clears two things (`flyology_quic/src/flyology-quic-tls_session.adb:789-791`):

```ada
      TLS_Key_Schedule.Clear (Resumption);
      Item.X25519_Private := (others => 0);
      Item.Current_State := Connected;
```

and the server transition three (`flyology_quic/src/flyology-quic-tls_session.adb:850-853`):

```ada
      TLS_Key_Schedule.Clear (Resumption);
      Item.X25519_Private := (others => 0);
      Item.Signing_Key := (others => 0);
      Item.Current_State := Connected;
```

`Resumption` is a local temporary. `Item.Handshake_Secrets` and `Item.Application_Secrets` are untouched, although `TLS_Key_Schedule` exports a `Clear` for each of them (`flyology_quic/src/flyology-quic-tls_key_schedule.ads:99-102`) and their last consumers, `Derive_Application`, `Derive_Resumption`, `Derive_QUIC_Keys` and `Finished_Verify_Data`, have all already run by this point. `Application_Secrets.Exporter` (`flyology_quic/src/flyology-quic-tls_key_schedule.ads:25`) is never read anywhere in the crate. The two handshake `QUIC_Traffic_Keys` records are dead once the handshake is confirmed, which is what RFC 9001 section 4.9.2 asks an endpoint to act on.

`Session` is a plain `limited record` with no finalizer (`flyology_quic/src/flyology-quic-tls_session.ads:148-175`), and the connection implementation that holds it is released without being overwritten (`flyology_quic/src/flyology-quic-connections.adb:29-30` and `:48-56`):

```ada
   procedure Release is new Ada.Unchecked_Deallocation
     (Connection_Impl, Impl_Conversions.Object_Pointer);
```

```ada
   overriding procedure Finalize (Item : in out Connection) is
      Value : Impl_Conversions.Object_Pointer;
   begin
      if Item.Backend /= System.Null_Address then
         Value := Impl (Item);
         Release (Value);
```

RFC 9001 section 4.9 is the directional authority: it is titled "Discarding Unused Keys" and requires endpoints to discard Initial and Handshake keys once they can no longer be needed, so that they are not retained for the life of a connection. RFC 8446 mandates no erasure of the key-schedule secrets, which is why this is a hygiene defect rather than a protocol violation.

The existing test asserts the failure path only. `flyology_quic/tests/src/flyology-quic-tls_session-smoke.adb:215-218` flips a byte of the server Finished and then asserts:

```ada
      pragma Assert
        (Result.Status = Finished_Failed
         and then State (Client_Session) = Failed
         and then not Has_Peer_Parameters (Client_Session));
```

Nothing checks the success path or what survives finalization.

## What happens now

Spike: it drives a complete in-process handshake between a client `Session` and a server `Session`, then reads each secret field on both and asserts it is zero. It then repeats the handshake with the sessions allocated on the heap, records the client's master secret, releases both with `Ada.Unchecked_Deallocation`, allocates a block of the same size, and scans it for the recorded bytes. Reading the fresh block is an ordinary read of uninitialized storage the program owns, not a read of freed memory.

Each check on the connected sessions is `Is_Zero (Item.Handshake_Secrets.Master)` and the same for the other six fields. The heap half is:

```ada
      Master := Client_Session.Handshake_Secrets.Master;
      Free (Client_Session);
      Free (Server_Session);
      for Attempt in 1 .. 4 loop
         Reused := new Block;
         for Start in Reused'First .. Reused'Last - 31 loop
            if Bytes (Reused (Start .. Start + 31)) = Bytes (Master) then
               Found := True;
               Matches := Matches + 1;
            end if;
         end loop;
         exit when Found;
      end loop;
```

```
  FAIL client: handshake secret cleared at Connected
  FAIL client: master secret cleared at Connected
  FAIL client: client handshake traffic secret cleared
  FAIL client: server handshake traffic secret cleared
  FAIL client: client finished key cleared
  FAIL client: server finished key cleared
  FAIL client: exporter secret cleared (never used by this crate)
  FAIL server: handshake secret cleared at Connected
  FAIL server: master secret cleared at Connected
  FAIL server: client handshake traffic secret cleared
  FAIL server: server handshake traffic secret cleared
  FAIL server: client finished key cleared
  FAIL server: server finished key cleared
  FAIL server: exporter secret cleared (never used by this crate)
  note client master secret at Connected = 88 de a9 2a b6 6e 01 69 67 d8 d7 c1 42 b6 52 9b b6 4a 8d 2d 55 67 1d ac 41 5c e9 3e 77 5c 9d 1a
  note heap Session size = 83368 bytes; master secret = 27 a5 0c a8 5e 4b a0 cf 1d 3d 9d 95 48 aa 7b 7d fe de c1 d3 f7 9e f3 fa 2c a4 06 52 11 ca 6c 1d
  note master secret copies found in reused heap storage = 1
  FAIL the master secret is not recoverable from reused heap storage after the session is released
checks: 15  failures: 15
BUG REPRODUCED
```

All six handshake secrets and the exporter secret survive on both roles at `Connected`, and the master secret of a released session is recovered intact from freshly allocated storage. The two secrets printed differ because they come from two separate handshakes in the same run.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

Once a session reaches `Connected`, the secrets that can no longer be used should be zero, exactly as they are when the session reaches `Failed`. Releasing the connection should not leave the master secret in heap storage that the allocator hands back to the same process.

## Suggested treatment

Clear `Item.Handshake_Secrets` and `Item.Application_Secrets` at both success transitions with the `Clear` operations `TLS_Key_Schedule` already exports, and clear the two handshake `QUIC_Traffic_Keys` records once the handshake is confirmed. `Application_Secrets.Exporter` should be cleared as soon as `Derive_Application` returns, since nothing in the crate reads it. That closes the `Connected` half without touching any interface.

The finalization half needs a maintainer decision, because every option changes something declared in a specification: give `Session` a controlled finalizer, which changes its type from a plain `limited record` and therefore changes how `Connection_Impl` may embed it; add an explicit wipe operation to `TLS_Session` and call it from `Connections.Finalize` before `Release`; or wipe the whole `Connection_Impl` block in `Connections.Finalize` without a new `TLS_Session` operation. The options for the choice are a private implementation value, a caller parameter, a generic formal, a discriminant, a value derived from a type or contract, build-time configuration, or a deliberately public declaration. Do not settle it here.

The regression test belongs beside the existing failure-path assertion in `flyology_quic/tests/src/flyology-quic-tls_session-smoke.adb`, which is a child unit of the private package and can therefore read the fields directly, as the spike does. The spike is the test. No existing test asserts the current behaviour, so none has to change. `flyology_quic/src/flyology-quic-tls_session.adb` and `flyology-quic-tls_key_schedule.adb` are not units `./scripts/prove.sh` proves, so no proof obligation is affected.

## Severity

No remote peer can trigger or observe this, and there is no memory-safety error: the spike reads storage the program owns. What it costs is that a process memory disclosure, a core dump, or a swap or hibernation image exposes the master secret and the handshake traffic secrets of connections that have already finished, not only the keys of the connection in use, which is the exposure that zeroization exists to bound. It is raised above a documentation-grade nit because the crate already keeps this discipline on the failure path and exports a `Clear` for every secret type, so the success path contradicts an internal contract the code holds elsewhere. Deterministic.
