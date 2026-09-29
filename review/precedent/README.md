# Bug reproduction programs

Each `src/repro_<id>.adb` demonstrates one finding from the correctness
review. A program asserts the CORRECT behavior, so on the current sources it
prints `BUG REPRODUCED` and exits 1; after a fix it prints `PASS` and exits 0.
A hang is reported as exit 124 by the `timeout` wrapper.

```sh
cd tests/repros
./run.sh repro_<id>          # build one program and run it (60 s limit)
./run.sh repro_<id> 10       # custom time limit in seconds
```

`src/repro_support.ad?` provides the in-memory transport mirrored from
`tests/src/tests.adb`, plus `Check`/`Note`/`Finish` helpers.
