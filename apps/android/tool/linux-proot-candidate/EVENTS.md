# PRoot tracee event candidate

The candidate build applies `patch-proot-events.py` only after verifying the
upstream archive SHA-256. It also verifies the three edited upstream files and
requires each patch anchor exactly once. The original source archive remains
unchanged. A changed archive, source file, or anchor aborts the build.

Before guest launch, the host must pass a **pipe write descriptor** (number 3 or
higher) as `DSH_TRACEE_EVENT_FD` and a lowercase canonical UUID as
`DSH_TRACEE_RUN_ID`. The tracer validates both, sets close-on-exec, removes the
environment variables, and closes its copy of the pipe in the first tracee.
Without both values, this candidate refuses to run. The host must read the
pipe concurrently so the tracer cannot block forever on a full pipe.

Each bounded line is a single atomic pipe write:

```
DSH_TRACE_V1<TAB>run-uuid<TAB>wire-sequence<TAB>event<TAB>first<TAB>second<LF>
```

Wire sequence starts at 1 and increments across **all** events. Expected
events are:

| Event | First | Second | Observation point |
| --- | --- | --- | --- |
| `ROOT` | root PID | 0 | Parent obtained the initial fork PID |
| `ARM` | root PID | confirmed ptrace option bits | `PTRACE_SETOPTIONS` returned success |
| `FORK`, `VFORK`, `CLONE` | parent PID | child PID | Child registered, before restart |
| `REAP` | PID | raw final wait status | `waitpid` returned `WIFEXITED` or `WIFSIGNALED` |
| `DRAIN` | tracer exit status | 0 | `waitpid` returned `ECHILD` |

The host must validate run ID, exact frame grammar, monotonically consecutive
wire sequence, and event ordering. Feed the `ROOT` PID into
`LinuxTraceeRetirementLedger`, the `ARM` option bits into `arm`, then translate
each `FORK`/`VFORK`/`CLONE`, `REAP`, and `DRAIN` sequence to the ledger's
post-arm sequence (wire sequence minus 2). Treat a malformed, missing,
duplicate, truncated, or out-of-order frame as failure. `DRAIN` alone does
not prove retirement: the host must also observe tracer process exit, pipe EOF,
and the ledger's empty live set. A lost pipe write makes the tracer exit with
failure and omits `DRAIN`. Cancellation cannot publish success.

This is an **unpackaged, untested-on-device** candidate. A successful NDK
compile does not prove that Android's kernel delivers every ptrace event or
that all guest descendants are retired. The event pipe does not make PRoot a
security sandbox. The isolated Android UID and capability broker remain
required before granting any file or network access.
