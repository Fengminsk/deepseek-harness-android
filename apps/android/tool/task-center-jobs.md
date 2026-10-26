# Independent jobs in the Android task center

English | [中文](task-center-jobs.zh.md)

The task center's fresh `tasks.list` response includes the current process's detached `ctx.jobs.snapshot()` projections in addition to the per-session turn history. This makes an independent job visible from the background settings entry point even when no conversation is selected. The list shows status, producer progress, and the owning conversation, and opens the existing output page directly. The output page still follows the original non-consuming `job.follow` stream; an owned job uses its exact owner session for the access fence.

An unowned job is followed without a session. Its stop button invokes `tasks.killUnownedJob`, which calls the original registry `kill` with no caller; the registry rejects an owned job under this route. Owned jobs continue to use `job.kill` with their owning session. A stop receipt does not imply settlement: the page waits for the terminal follow frame and invalidates a pending receipt on reconnect.

The roster is process-local. A replacement runtime clears the task center's live job list and obtains a new baseline; it never displays a prior-process job as still running or replays it. Durable session job registration and settlement events remain in task history, where an unclosed record after process loss is unconfirmed. The output ring is a live retained tail, not a durable transcript, so restarting the Host cannot recover past output bytes. The task center also distinguishes a missing job registry (`jobs: null`) from a confirmed empty roster (`jobs: []`).

Host coverage: `tasks-runtime.test.mjs` checks pre-observation baseline and the no-session kill fence, while `tasks_test.dart` and `jobs_test.dart` check global navigation, owner-scoped follow, and unowned follow/stop routing. Device acceptance remains outstanding: inspect a real running bash or PTY job from background settings, verify progress and cancellation settle, then terminate and restart the service to confirm the old live row disappears while session history remains.
