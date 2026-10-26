# Android Linux utility tool

`android_linux` is an Agent-facing tool for seven fixed utilities. It uses the
App's native command manager and an Android isolated-UID service. The tool does
not accept executable names, shell source, filesystem paths, environment
variables, URLs, or network destinations.

| Command | Input | Result |
| --- | --- | --- |
| `kernel` | none | `uname -a` |
| `identity` | none | numeric guest UID |
| `sha256` | supplied text | SHA-256 digest |
| `count_bytes` | supplied text | byte count |
| `count_lines` | supplied text | line count |
| `sort_lines` | supplied text | sorted lines |
| `filter_literal` | supplied text and literal | matching lines; exit code 1 means no match |

Text input is at most 64 KiB. Literal patterns are at most 128 UTF-8 bytes.
Native output is capped at 4 KiB. At most two commands run concurrently.
The native carrier enforces a 6.5-second request deadline and cancellation;
the child process has a 1.5-second deadline. Only completed output is shown to
the Agent. The App owner remembers a cancellation that arrives before a run
is admitted, so an aborted tool call cannot later start a delayed command.
After a dispatched cancellation, the App waits for the isolated guest's
terminal receipt, which is sent only after its direct child has been reaped.
An unconfirmed child retirement or host deadline returns no successful output.
The cancellation RPC reports `settled=true` only when the run was never
dispatched or an authenticated guest receipt confirms direct-child retirement.
An uncertain run ID remains blocked from replay while that owner lives, and
the owner stops admitting commands after an unconfirmed retirement.
The Node carrier validates the exact `{cancelRequested, settled}` reply. An
absent, malformed, or `settled=false` reply after dispatch raises an explicit
`outcome-uncertain` error and closes that carrier; it never presents the
original abort as a confirmed cancellation or replays the command. A verified
`WORKER_DIED` result is also treated as uncertain. A confirmed settlement
retains the caller's original abort or timeout reason while withholding any
late output. The execute RPC now carries `retirementConfirmed` for every
terminal kind. A missing or false value withholds the result, raises an
uncertain outcome, and closes the carrier; `ERROR` or `CANCELLED` alone never
proves direct-child retirement.

The Android service checks its isolated UID, denied App-private-data access,
and denied network socket creation before starting a fixed system executable.
If those checks fail, the tool fails closed. This is a small utility surface,
not a general Linux distribution or a container with arbitrary process,
mount, or network capabilities. The optional Alpine rootfs candidate is not
mounted or executed by this tool.
The fixed utilities are single-process commands. Killing their direct child
does not prove that a future shell or PRoot run's descendants have stopped.
General Linux execution stays closed pending a trusted process-group launcher
and on-device termination evidence; Android may kill the Service without
calling `onDestroy()`.

Source-level and JVM tests cover request bounds, cancellation admission, and
receipt projection. A compiled APK alone cannot establish that the isolated
UID and process cleanup behave correctly on the user's device; run
`acceptance-linux-command-device.mjs` when the device is available.
