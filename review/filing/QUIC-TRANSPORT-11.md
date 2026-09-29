Title: Packet-driven Connections operations raise Constraint_Error instead of returning Invalid_State
Labels: bug
Refs: none

## Summary

`Flyology.QUIC.Connections` guards the null backend in its query functions but not in any of its packet-driven operations. `Process_Datagram` on a fresh `Connection` dereferences a null address and raises `Constraint_Error` from the access check. The package documents `Invalid_State` as "The operation is not valid in the current phase" and `State` reports `Uninitialized` for such an object, so the status a caller has every reason to expect is never produced.

## Problem

Commit `f078732`.

The query functions test the backend (`flyology_quic/src/flyology-quic-connections.adb:216-222`):

```ada
   function State (Item : Connection) return Connection_State is
     (if Item.Backend = System.Null_Address then Uninitialized
      else Public_State (Connection_Driver.State (Impl (Item).Driver)));

   function Is_Connected (Item : Connection) return Boolean is
     (Item.Backend /= System.Null_Address
      and then Connection_Driver.Is_Connected (Impl (Item).Driver));
```

The packet-driven operations do not. `Process_Datagram` writes through `Impl (Item)` with no guard (`flyology_quic/src/flyology-quic-connections.adb:416-420`):

```ada
      Connection_Driver.Process_Datagram
        (Impl (Item).Driver, Packet, Internal_Output, Result,
         Application_Space.Timestamp (Now));
      Copy (Internal_Output, Output);
      Status := Public_Status (Result.Status);
```

`Start_Client`, both `Process_Datagram` overloads, `Process_Timeout`, `Open_Stream` and all the `Build_*_Datagram` procedures share that shape.

The specification points the other way. `Operation_Status` is documented with "@enum Invalid_State The operation is not valid in the current phase" (`flyology_quic/src/flyology-quic-connections.ads:314`), and the `Process_Datagram` precondition constrains only the packet length (`flyology_quic/src/flyology-quic-connections.ads:349-355`):

```ada
   procedure Process_Datagram
     (Item   : in out Connection;
      Packet : Ada.Streams.Stream_Element_Array;
      Output : out Datagram_Batch;
      Status : out Operation_Status;
      Now    : Timestamp := 0)
   with Pre => Packet'Length <= Max_Datagram_Length;
```

Other operations in the same specification do constrain the state, for example `Start_Client` with `Pre => State (Item) = Client_Initial` (`:340`), so the absence here reads as a deliberate runtime-status contract rather than a caller obligation.

No test covers the uninitialized case.

## What happens now

Spike: it declares a fresh `Connection`, confirms the three guarded queries behave, and then calls `Process_Datagram` on it inside a handler.

```ada
   Check (QUIC.State (Item) = QUIC.Uninitialized,
          "a fresh Connection reports Uninitialized");
   ...
   begin
      QUIC.Process_Datagram (Item, Datagram, Output, Status);
   exception
      when Error : others =>
         Raised := True;
   end;
   Check (not Raised and then Status = QUIC.Invalid_State, ...);
```

```
  ok   a fresh Connection reports Uninitialized
  ok   Is_Connected guards the null backend
  ok   Has_Recovery_Timeout guards the null backend
  note Process_Datagram raised CONSTRAINT_ERROR: flyology-quic-connections.adb:417 access check failed
  FAIL Process_Datagram on an uninitialized connection reports Invalid_State instead of raising
checks: 4  failures: 1
BUG REPRODUCED
```

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

An operation called on an uninitialized connection should return `Invalid_State`, the status the specification documents for exactly this case, rather than propagating a language-level check failure from the implementation.

## Suggested treatment

Add the same null-backend guard the query functions already use to each packet-driven operation, setting `Status` to `Invalid_State` and leaving `Output` empty. The guard is one test per subprogram and introduces no new value or variant. The alternative is to state the obligation in the specification instead, by adding `Pre => State (Item) /= Uninitialized` to each of these operations, which would move the failure to a precondition violation; that is a contract change to a public interface, so under "Decision authority" the choice between the two belongs to the maintainer. The status arm already exists either way, so nothing new becomes visible in the first option.

This is not a memory-safety problem. `flyology_quic/config/flyology_quic_config.gpr` builds with `-O3 -gnatn` and does not pass `-gnatp`, so the access check is present in the release profile as well.

The regression test belongs in `tests/http3_public_smoke.adb`, which already exercises the public QUIC surface. The spike is the test. No existing test asserts the current behaviour. `flyology-quic-connections.adb` is not among the units `./scripts/prove.sh` proves.

## Severity

A public-API hygiene defect. A caller that drives a connection before initialising it gets `Constraint_Error` from inside the implementation rather than the documented status, which is harder to diagnose and harder to handle. It is not reachable through the maintained HTTP/3 server: `Serve_Connection` raises `Protocol_Error` when `Initialize_Server_From_Initial` does not return `Initialized`, before any `Process_Datagram` call (`src/flyology-http-server-http_3.adb:1860-1868`), and the worker task catches it. Deterministic.
