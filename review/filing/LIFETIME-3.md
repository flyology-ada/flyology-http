Title: `Request_Tasks` and `Applications` claim Ada enforces a token borrow that `'Unchecked_Access` suppresses
Labels: bug
Refs: none

## Summary

`src/flyology-http-server-request_tasks.ads:30-31` tells the caller to declare a scope with `Parent => X.Cancellation` "so Ada enforces the request-token borrow". `Exchange.Cancellation` returns `Item.Token_Handle.all'Unchecked_Access`, which is the attribute whose purpose is to suppress exactly that check. The recommended idiom is therefore the one with no enforcement, and a heap-allocated scope whose `Parent` designates a token that goes out of scope one statement later compiles and runs with no error, statically or at run time. A control program identical except for using `Stop'Access` instead is rejected by the compiler, with the same diagnostic the repository already pins for the WebSocket session pool, so the accessibility machinery is live and only this idiom escapes it. `src/flyology-http-server-applications.ads:63-65` makes the same claim for three things and two of them hold.

## Problem

Commit `f078732`.

The first sentence (`src/flyology-http-server-request_tasks.ads:25-31`):

```ada
   --  Inherit the Exchange cancellation identity and current absolute
   --  deadline. Subsequent Exchange narrowing does not retroactively update a
   --  configured scope, so configure it after request middleware completes.
   --  The scope links parent cancellation downward into a private child token;
   --  sibling failure never requests the parent request token.
   --  Item must be declared with Parent => X.Cancellation so Ada enforces the
   --  request-token borrow.
```

The second (`src/flyology-http-server-applications.ads:63-65`):

```ada
   --  Construct one exchange around values owned by the active handler.
   --  Access discriminants let Ada reject an exchange whose request,
   --  connection, or token would not outlive it.
```

The mechanism that makes the first one false is one expression (`src/flyology-http-server-applications.adb:122-126`):

```ada
   function Cancellation
     (Item : Exchange) return access Flyology.Cancellation.Token
   is
     (if Item.Token_Handle = null then null
      else Item.Token_Handle.all'Unchecked_Access);
```

`'Unchecked_Access` exists to suppress the accessibility check the sentence promises (RM 13.10 and RM 3.10.2). So the discriminant actual the sentence mandates carries library-level accessibility, and no allocator built from it can be rejected.

Nothing downstream replaces the check. `Request_Tasks.Configure` forwards the deadline and nothing else (`src/flyology-http-server-request_tasks.adb:3-10`):

```ada
   procedure Configure
     (Item : in out Operations.Scope;
      X    : Applications.Exchange;
      Cancel_Siblings_On_Failure : Boolean := True) is
   begin
      Operations.Configure
        (Item, X.Deadline, Cancel_Siblings_On_Failure);
   end Configure;
```

It never compares `Item.Parent` with `X.Cancellation`, so a scope configured with `Parent => null` or with a foreign token is accepted and its children are linked to that token's fate instead of the request's, while the comment four lines above the declaration says "Inherit the Exchange cancellation identity".

Why the tests do not catch it: `scripts/test.sh:269-305` pins three compile-time lifetime claims with a `grep -E` on the diagnostic, and `tests/compile_fail/` contains exactly the three matching programs, `http_client_response_lifetime_fail.adb`, `http_client_body_source_lifetime_fail.adb` and `websocket_pool_lifetime_fail.adb`. Neither of the two sentences above has a case. The only `Request_Tasks` test is a happy path (`tests/http_smoke.adb:4368-4369` declares the scope and `:4372-4378` spawns two children and checks the sum), and it never requests `X.Cancellation` or narrows `X.Deadline`, so neither half of "Inherit the Exchange cancellation identity and current absolute deadline" is asserted anywhere in this repository.

## What happens now

Spike: four programs read as one experiment, and two of them are expected not to compile. A build rejection is reported as exit status 2 and is the *passing* outcome for a control, because it means the compiler enforced the claim; a program that reaches `BUG REPRODUCED` and exit status 1 compiled and ran, which means the claim is false.

The main program parses a fixture request, builds an `Exchange` around locals, and then allocates an `Operations.Scope` whose `Parent` is `X.Cancellation` into an access variable declared in the enclosing subprogram, so the scope outlives the token. That is the exact idiom the specification sentence mandates.

```ada
      declare
         X : App.Exchange := App.Create
           (Value    => Value,
            Item     => Peer_Connection,
            Peer     => Sockets.Network_Endpoint (Sockets.Loopback_IPv4, 1),
            Token    => Stop'Access,
            Deadline => Ada.Real_Time.Clock + Ada.Real_Time.Seconds (30));
      begin
         Escaped := new Operations.Scope
           (Capacity => 1, Parent => X.Cancellation);
```

```
  note request_tasks.ads:29-31 claims Ada enforces the request-token
  note borrow; applications.ads:63-65 claims access discriminants let Ada
  note reject an exchange that outlives its token.  Neither has a
  note tests/compile_fail case (scripts/test.sh:275-305 pins three others).
  ok   fixture request parsed
  FAIL a Scope whose Parent is X.Cancellation cannot outlive the token
  note the allocator compiled and ran; no accessibility check fired
  note Escaped.Parent now designates a token that is about to die
  FAIL no Scope survives the cancellation token it borrowed
checks: 3  failures: 2
BUG REPRODUCED
```

Three controls settle what that means. Their file names are omitted from the diagnostics below; everything else is as the compiler printed it.

**Control one: the same program with `Parent => Stop'Access` instead of `Parent => X.Cancellation`.** The build is rejected, which is the correct outcome:

```
164:42: error: prefix of attribute has deeper level than allocator type
```

That is *precisely* the diagnostic this repository already pins for the WebSocket session pool at `scripts/test.sh:303-305`. The accessibility machinery is live for `Operations.Scope`'s `Parent` discriminant. Only the idiom the sentence recommends escapes it.

**Control two: an `Exchange` allocated so that it outlives its request and connection.** The build is rejected on both:

```
158:25: error: actual for aliased formal "Value" has wrong accessibility in allocator (RM 6.4.1(6.4))
159:25: error: actual for aliased formal "Item" has wrong accessibility in allocator (RM 6.4.1(6.4))
```

Two thirds of `src/flyology-http-server-applications.ads:63-65` therefore hold: `Request` and `Connection` are `aliased in out` formals of `Create` and GNAT rejects the allocator under RM 6.4.1(6.4).

**Control three: the same allocation with the request and connection at the allocator's own level, so that only the token is deeper.** It compiles and runs:

```
  ok   fixture request parsed
  FAIL an Exchange cannot outlive its request, connection or token
  FAIL no Exchange survives the request it borrowed
checks: 3  failures: 2
BUG REPRODUCED
```

No `Program_Error` is raised either, so the token discriminant is unchecked at compile time and at run time both. This is reported as an observation about what the code enforces, not as a claim about compiler conformance: the sentence lists three things and enforces two.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

Either the two sentences describe what is actually enforced, or the enforcement they describe exists. A specification sentence that says "so Ada enforces" is the stated reason there is no run-time check, so a reader who believes it is being told not to be careful.

## Suggested treatment

This needs a maintainer decision, because the three options differ in what the specification promises afterwards and one of them changes the signature of a public accessor.

- **Correct the sentences.** Rewrite `src/flyology-http-server-request_tasks.ads:30-31` to say that the caller must pass `X.Cancellation` and that nothing checks it, and rewrite `src/flyology-http-server-applications.ads:63-65` to say that the request and connection discriminants are checked and the token is not. This is the smallest change and leaves the property unenforced.
- **Check it at run time.** Have `Request_Tasks.Configure` raise `Program_Error` when `Item.Parent /= X.Cancellation`. `Item.Parent` and `X.Cancellation` are a comparable anonymous-access pair, so this is one comparison in `src/flyology-http-server-request_tasks.adb:8-9` and it turns the specification's "must" into a check. It introduces a new raise from `Configure`, so the `@exception` documentation on the declaration has to say so.
- **Restore the static check.** Stop returning `'Unchecked_Access` from `Exchange.Cancellation` (`src/flyology-http-server-applications.adb:122-126`) so the discriminant actual carries the exchange's own accessibility. This is the only option that makes the sentence true as written, and it is the largest: it changes what callers of a public accessor can do with the result, and every handler that stores the token would have to be checked.

The reason to prefer one of the last two is that the sentence is the stated justification for there being no run-time check; correcting the prose alone removes the justification without replacing it.

Whichever is chosen, the regression coverage belongs in the existing compile-time lifetime harness at `scripts/test.sh:269-305`, as a fourth case beside the three there, with its own file in `tests/compile_fail/` pinned on `deeper level than allocator type`. That case only becomes possible once `Cancellation` stops returning `'Unchecked_Access`, so under the first two options the coverage is instead a behavioural case in `tests/http_smoke.adb` beside the existing `Request_Tasks` test at `:4363-4379`: request `X.Cancellation` while a spawned child is blocked on its token and assert that the child's result re-raises `Operation_Cancelled`, and narrow `X.Deadline` before `Configure` and assert the child sees `Timeout_Error`. Neither half is asserted today.

The change is confined to `src/flyology-http-server-request_tasks.ad[bs]` and `src/flyology-http-server-applications.ad[bs]`, none of which `./scripts/prove.sh` proves.

## Severity

A specification sentence states a property of the language that is false for the exact idiom it mandates, and it is the stated reason no run-time check exists. A handler that stores a configured scope, or passes one to a longer-lived structure, gets no diagnostic of any kind, and its children are then linked to a token that has already gone out of scope. The practical blast radius is small, because the natural handler idiom declares the scope locally in the handler body where nothing can escape, which is what the one existing test does. What makes it worth fixing rather than noting is that the sentence tells a reader the compiler is watching when it is not. Deterministic.
