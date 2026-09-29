Title: The "no helper task in client units" check fails open and passes five kinds of violating source
Labels: bug
Refs: none

## Summary

`scripts/test.sh:75-84` is the only thing that enforces the publicly stated property that the HTTP client creates no helper task. It is an `rg` invocation inside an `if` condition under `set -eu`. If `rg` is not on `PATH` the command exits 127 *inside a condition*, where `set -e` does not fire, the `if` takes the false branch, and a tree containing the exact violation the check was written for passes. `rg` is used exactly once in the whole repository, this line, nothing checks for it, and no CI step installs it. Four further evasions are reachable by ordinary Ada that the pattern or the file set does not cover. The invariant itself holds at this commit; what is reported here is that the check has almost no detection power left.

## Problem

Commit `f078732`.

The check (`scripts/test.sh:75-84`, under `set -eu` at `:2`):

```sh
if rg -n \
  '^[[:space:]]*task([[:space:]]+(type|body))?[[:space:]]' \
  src/flyology-http-client*.ad[bs] \
  src/flyology-http-http_2_client_connection.ad[bs] \
  src/flyology-http-http_3_client_connection.ad[bs]
then
  printf '%s\n' \
    "HTTP client owner-driven engine declares a forbidden helper task" >&2
  exit 1
fi
```

**The invariant holds at this commit.** Searching `src/` for a task declaration finds them only in `src/flyology-http-server-http_2.adb`, `src/flyology-http-server-http_3.adb` and `src/flyology-http-server-routing.adb`, all server units, and the only `Flyology.Task_Scopes` instantiation is the server-side one at `src/flyology-http-server-request_tasks.ads:22-23`. Nothing is wrong with the sources; what is wrong is the check.

The property it guards is stated publicly in three places, so it is not an internal convention: `website/guide/client/index.html:344` says "the composable path creates no helper task or thread", `:383` says "the client creates no connector or protocol-pump helper task", and `src/flyology-http-http_3_client_connection.ads:8` opens with "Bounded, task-free coordination".

Five ways the check misses a violation:

1. **It fails open without `rg`.** With `rg` absent, the command exits 127 inside the `if` condition. `set -e` does not fire on a condition, so the `if` takes the false branch and the script walks on to the next check. `rg` appears exactly once in this repository, at `scripts/test.sh:75`, and nothing requires it: not `scripts/test.sh`, not `scripts/alire-test-context.sh`, not `scripts/find-alr.sh`, not `tests/alire_action_context.sh`. No CI step installs it either; the `ubuntu-latest` and `macos-latest` test matrix at `.github/workflows/ci.yml:63-111` has no such step. Whether a hosted runner image happens to ship ripgrep is a property of a third party; what the repository controls is that the check's correctness rests on an undeclared tool and that a developer running `./scripts/test.sh` without it gets a silent pass.
2. **Case.** Ada reserved words follow the identifier rules of RM 2.3 and RM 2.9, so they are not case-sensitive. The pattern is case-sensitive, so `Task Probe;` and `TASK TYPE Probe;` are task declarations the pattern does not match.
3. **Line break.** `task` on one line with the name on the next is legal Ada and does not match `task[[:space:]]` within a single line.
4. **Indirection.** `package Helpers is new Flyology.Task_Scopes (...)` contains no `task` keyword at all. The pinned `flyology` runtime dependency allocates its workers inside `Configure` (`flyology-task_scopes.ads:66-67`, with the `Worker` task type at `:164`), so this is the most plausible shape a future client-side helper task would take.
5. **Scope.** The three globs cover `src/flyology-http-client*`, `src/flyology-http-http_2_client_connection*` and `src/flyology-http-http_3_client_connection*` only. A `task` declared in `src/flyology-http-http_1_internals.adb`, `src/flyology-http-websocket_client.adb` or `src/flyology-http-http_3.adb`, all of which the client withs, is not scanned at all, in any spelling, with `rg` present.

There is no test of the check; the check is itself the test.

## What happens now

Spike: a shell program that lifts the check verbatim out of the tracked script with `sed -n '74,84p'` rather than retyping it, so it cannot drift from the file it tests, then runs the extracted check against sandboxes whose `src/` holds real copies of exactly the files the three globs name. The program asserts the correct behaviour: a sandbox containing a task declaration must be rejected, in every spelling and with or without `rg` on `PATH`. It builds nothing.

```sh
# The gate, lifted verbatim out of the tracked script.
{
  printf '%s\n' '#!/bin/sh' 'set -eu' 'http_root="$1"'
  sed -n '74,84p' "$http_root/scripts/test.sh"
  printf '%s\n' 'exit 0'
} > "$work/gate.sh"
...
run_gate_without_rg () {
  ( PATH="$work/empty_path"; export PATH; \
    "$work/gate.sh" "$1" >/dev/null 2>&1; echo $? )
}
```

```
  note gate extracted from scripts/test.sh:74-84
  ok   control: lowercase 'task Probe;' is rejected (exit 1)
  ok   control: unmodified sources pass (exit 0) -- the invariant holds at HEAD
  FAIL no rg on PATH: gate PASSED a tree containing 'task Probe;' (exit 0)
  note rg exits 127 inside the if condition; set -e does not fire there
  FAIL capitalised 'Task Probe;' was NOT rejected (exit 0)
  FAIL upper-case 'TASK TYPE Probe;' was NOT rejected (exit 0)
  FAIL 'task' + newline + name was NOT rejected (exit 0)
  FAIL Task_Scopes instantiation in a client unit was NOT rejected (exit 0)
  FAIL task in withed sibling units (http_1_internals, websocket_client, http_3) was NOT rejected (exit 0)
  note the three globs do not cover them
checks: 8  failures: 6
BUG REPRODUCED
```

The two controls are what make the failures mean something. The first shows the extraction is faithful: a plain lowercase `task Probe;` *is* rejected. The second shows the invariant genuinely holds at this commit: the unmodified sources pass. The six failures then cover the five evasions above, with the case evasion exercised in two spellings.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A check that guards a publicly stated property fails when it cannot run, and matches the language it is checking. A missing tool is a failure, Ada keywords are matched without regard to case, a declaration split across lines is found, and the file set covers the units the client actually withs.

## Suggested treatment

Four changes, all in `scripts/test.sh:75-84`:

- require the tool before using it, for example `command -v rg >/dev/null || exit 1` ahead of the check, or drop the dependency entirely and use `grep -REi`, which is already available to every other step in the script and removes the undeclared build requirement;
- match case-insensitively, which `grep -i` gives directly and `rg -i` also gives;
- widen the file set from the three globs to the client's actual closure, including `src/flyology-http-http_1_internals.*`, `src/flyology-http-websocket_client.*` and `src/flyology-http-http_3.*`;
- reject the indirect shape as well, by also failing on an instantiation of `Flyology.Task_Scopes` in any of those files.

Dropping the `rg` dependency is the change that fixes the first and hardest evasion and the case evasion at once, and it removes the only use of that tool in the repository.

The line-break evasion needs either a multi-line match or a deliberate decision not to cover it. This needs a maintainer decision: the options are a `grep -Pzo` style multi-line pattern, which is not portable across the macOS and Linux runners in the matrix, an awk or python3 pass over the same file set, which the script already uses python3 for elsewhere, or accepting that a declaration split across lines is out of scope and saying so in a comment beside the check.

The regression coverage is the check itself; it belongs in `scripts/test.sh`, not in a new file. The spike above is the test of the check and should be kept as a case that runs the extracted check against a sandbox, so the next change to the pattern is measured against the same five evasions.

## Severity

Rated on two scales, because the repository's severity rubric has no class for a check that cannot fail.

On test and CI integrity this is the more serious rating: one evasion is unconditional, since a missing `rg` means no failure ever, and two more, keyword case and a line break, are reachable by ordinary formatting, so the check has essentially no detection power. A helper task could be added to a client unit and every documented check would still pass.

On product correctness it is the lesser rating: no behaviour is wrong at this commit. The invariant holds, as the second control run confirms, and nothing a caller does today is affected. The cost is entirely prospective, which is what a check is for.

Deterministic.
