# Bug reproduction programs

Each `src/repro_<ID>.adb` demonstrates one finding from the correctness review,
where `<ID>` is the finding identifier used in `FINDINGS.md` (for example
`repro_h2_3`). A program asserts the CORRECT behaviour, so on current sources it
prints `BUG REPRODUCED` and exits 1; after a fix it prints `PASS` and exits 0. A
hang is reported as exit 124 by the `timeout` wrapper. `repro_smoke` is the
harness self-test and is the one program that must PASS on current sources.

```sh
./scripts/test.sh                 # once, to prepare build/rts
cd tests/repros
./run.sh repro_h2_3               # build and run one program (60 s limit)
./run.sh repro_h2_3 10            # custom time limit in seconds
./run-all.sh                      # every program, one line each
```

`run.sh` builds the way `scripts/test.sh` builds `tests/http_tests.gpr`: it
re-executes itself under `alr exec`, unsets `GPR_CONFIG`, applies the macOS
sysroot workaround, sets `FLYOLOGY_TLS_TEST_HOOKS`, and uses the version-matched
runtime under `build/rts`. It takes a build lock so concurrent spikes do not
share one gprbuild invocation.

`src/repro_support.ad?` provides `Check`, `Note`, `Expect_Equal`, `Finish`, byte
helpers, and `Ephemeral_Port`. It depends only on the Ada standard library and
`GNAT.Sockets`. A spike that needs an in-memory server transport, the client
testing seam, or a QUIC test connection declares it locally, mirroring the
nearest program under `tests/`. `Source_Dirs` includes `tests/`, so the barrier
points in `flyology-io-connections-testing.ads`, `tls_test_provider.ads`, and
`flyology-quic-test_connections.ads` are available.

Spikes must bind loopback ports through `Ephemeral_Port`. The maintained suites
bind fixed ports and a spike run beside one would collide.

This directory is untracked working material for the review.

## Reaching a private unit

Several policy units are `private package` declarations (for example
`Flyology.HTTP.Decoded_Path_Policy`, and the QPACK and HTTP/3 policy units). An
ordinary spike cannot `with` one. Do what the maintained smoke tests do and make
the spike a child unit of the same parent, as
`tests/flyology-http-decoded_path_policy-smoke.adb` does. Name the file
`flyology-http-<unit>-repro_<id>.adb` and declare
`procedure Flyology.HTTP.<Unit>.Repro_<Id>`. Pass that unit name to `run.sh`.

Exceptions live where the spec puts them: `Flyology.HTTP.Protocol_Error` but
`Flyology.HTTP.Client.Response_Too_Large`.

`src/seam_check.adb` proves the client parser seam and is not a finding spike;
it must PASS.
