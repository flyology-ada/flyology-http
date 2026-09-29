Title: Four proved `Client_Policy` classifiers have no caller under `src/`, and `proof-status.md` still says they are consumed
Labels: bug, documentation
Refs: CLIENT-POOL-2, CLIENT-POOL-4

## Summary

`Validate_Upload`, `Classify_Pull`, `Classify_Stale_Retry` and `Classify_Expectation_Response` are proved SPARK functions with no caller anywhere under `src/`. Their last call sites were deleted in `f0d630d` and nothing replaced them; the decisions they encoded now live in hand-written predicates with different inputs. `proof/proof-status.md` still describes all five named boundaries as a "production-consumed SPARK boundary" and still ticks the box confirming that the shipped paths consume the proved classifications. Only one of the five is actually consumed. Nothing misbehaves at run time because of this entry alone, but it is why two live defects exist: the dropped `Body_Sent` input is the mechanism behind {{ISSUE:CLIENT-POOL-2}}, and the split of one replay classifier into two disagreeing predicates is the mechanism behind {{ISSUE:CLIENT-POOL-4}}.

## Problem

Commit `f078732`. This is reported from reading the code; no reproduction was made because there is no runtime behaviour to observe. The claim is exactly checkable by searching the tree, and it was checked that way rather than by reading the code that calls it.

The four functions are declared at `src/flyology-http-client_policy.ads:15`, `:52`, `:86` and `:171`. Searching for each name under `src/` matches only `flyology-http-client_policy.ads` and `flyology-http-client_policy.adb`, that is, the declaration and the body. Searching for the three functions of the same unit that *are* consumed matches four call sites in `src/flyology-http-client-http_1_internals.adb` (`:332`, `:343`, `:538`, `:547`) and one in `src/flyology-http-client.adb` (`:6629`).

`git log --oneline -S'Classify_Expectation_Response' -- src/flyology-http-client.adb` returns exactly two commits, `1a25f7f` (introduced) and `f0d630d` (last caller removed). The same two-commit history holds for `Classify_Stale_Retry`, `Validate_Upload` and `Classify_Pull`. `git show f0d630d -- src/flyology-http-client.adb` shows all three call sites being deleted, with nothing added in their place.

The sentences that are now false (`proof/proof-status.md:68-71`):

```text
The HTTP client upload-policy review adds a production-consumed SPARK boundary
for request/source compatibility, exact known-length pull completion,
informational-response accounting, stale-connection replay eligibility, and
the one-attempt `417 Expectation Failed` fallback.
```

and (`proof/proof-status.md:403-404`):

```text
- [x] Confirm production request, upload, response, and retry paths consume the
      proved classifications
```

Of the five boundaries that sentence names, only informational-response accounting is consumed, by `Classify_Informational` and `Next_Informational_Count` in `src/flyology-http-client-http_1_internals.adb`. `Classify_Redirect` is consumed at `src/flyology-http-client.adb:6629` but is not one of the five. Request and source compatibility (`Validate_Upload`), exact known-length pull completion (`Classify_Pull`), stale-connection replay eligibility (`Classify_Stale_Retry`) and the one-attempt 417 fallback (`Classify_Expectation_Response`) have no caller under `src/`.

Their behaviour now lives in hand-written predicates with different inputs:

- the replay decision in `Fail_Exchange` (`src/flyology-http-client.adb:927-972`) and in `Execute_Operation_Once` (`:6513-6548`), split into a safe-versus-idempotent pair with a separate `Has_Mutation_Condition` term;
- the pull decision inline in `Pull_Source` (`src/flyology-http-client.adb:3574-3680`);
- the 417 decision in `Execute_Redirects` (`src/flyology-http-client.adb:6636-6647`), with no `Body_Sent` input at all, although the proved classifier still declares one (`src/flyology-http-client_policy.ads:171-188`).

Why the tests do not catch it: `tests/flyology-http-client_policy-smoke.adb` calls all four functions directly, so both the behavioural suite and `./scripts/prove.sh` stay green while the shipped paths no longer consume them. `Flyology.HTTP.Client_Policy` is one of the units `./scripts/prove.sh` proves (`scripts/prove.sh:31`), and the proof still discharges; what is wrong is the claim about what the proof covers.

## Failure scenario

1. A maintainer reads `proof/proof-status.md:68-71` and takes the SPARK proof as evidence about the shipped stale-connection replay and 417 fallback behaviour.
2. The proof is evidence about four functions no shipped path calls. The replay decision is made twice, by two predicates that disagree, and the 417 decision is made without the `Body_Sent` input the proved contract case requires.
3. A change to either shipped predicate is reviewed as though a proof constrained it. Nothing fails, because the proved unit is still proved and its smoke test still passes.

## What should happen

Either the shipped paths consume the proved classifications, as `proof/proof-status.md:68-71` and `:403-404` state, or the document says what is actually proved and what is actually consumed. A proved subprogram with no caller outside its own unit and its own smoke test is not evidence about the shipped behaviour.

## Suggested treatment

This needs a maintainer decision: the two dispositions differ in what the proof is afterwards evidence for, and one of them changes a package specification.

- **Restore the callers.** Have `Fail_Exchange`, `Execute_Operation_Once`, `Pull_Source` and `Execute_Redirects` decide through `Classify_Stale_Retry`, `Classify_Pull` and `Classify_Expectation_Response` again, and route the request and source compatibility check through `Validate_Upload`. This is also the fix {{ISSUE:CLIENT-POOL-2}} asks for and the single decision point {{ISSUE:CLIENT-POOL-4}} needs. `Flyology.HTTP.Client_Policy` is proved by `./scripts/prove.sh`, so any adjustment to its contracts must keep the proof discharging with `--checks-as-errors=on`; restoring call sites in `src/flyology-http-client.adb` alone does not touch the proved body.
- **Remove the dead functions and correct the document.** `Flyology.HTTP.Client_Policy` is a private package, so deleting the four declarations is not an API break, but it also deletes the proof and leaves the two live defects without the guard they need. If this is chosen, `proof/proof-status.md:68-71` and `:403-404` must be rewritten to name only the boundaries that remain, and the corresponding entries in `tests/flyology-http-client_policy-smoke.adb` removed.

Whichever is chosen, add an invariant to `scripts/test.sh` that each function declared in `src/flyology-http-client_policy.ads` has at least one caller under `src/` outside its own unit, for example a `grep -r` over `src/` excluding `flyology-http-client_policy.ad[bs]`. That check would have failed at the commit that broke this. Use a tool the script already requires rather than adding a new build dependency.

The regression coverage belongs with that invariant in `scripts/test.sh`, not in a new test file; `tests/flyology-http-client_policy-smoke.adb` already covers the functions themselves and is not the thing that is wrong.

## Severity

No runtime behaviour is wrong because of this entry alone. What is wrong is a proof-evidence claim: two sentences in `proof/proof-status.md` state that the shipped request, upload, response and retry paths consume four proved classifications that they have not consumed since `f0d630d`, dated 2026-08-23. A maintainer relying on those sentences reviews the shipped replay and 417 logic as though a proof constrained it. It matters because both places where that reading is wrong are live defects. Deterministic.
