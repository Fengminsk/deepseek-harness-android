# Linux guest Binder transport seam

English | [中文](linux-guest-binder-transport.zh.md)

`IsolatedLinuxGuestBinderService` is a distinct, non-exported `isolatedProcess` Service. It performs an App-initiated `OPEN`/`HELLO` handshake and can [stage a pinned Alpine archive as data](linux-guest-image-handoff.md) when the trusted App explicitly supplies a broker. It has **no native guest frame source**. A successful handshake or image-staging receipt does not mean Linux, PRoot, or a model command started. There is no UI or Agent tool entry to this service.

`LinuxGuestBinderBinding` is constructed by trusted App code only for a durably `ADMITTED` run. It binds one isolated Service instance with a random nonce, checks `Message.sendingUid` against the reported UID and App UID, checks the run ID and nonce, and feeds the verified identity to `LinuxGuestLaunchSession`. A future Service implementation may emit `FRAME` messages of at most `LinuxGuestBrokerWire.MAX_REQUEST_BYTES`. The App copies the bytes and uses `LinuxGuestBinderBridge` to admit the version 2 frame against the live lease, then dispatches it to the existing exact-file or HTTPS broker. Replies are bounded; malformed, out-of-scope, unaudited or late calls retire the bridge.

Binding loss, Binder death, lease revocation, timeout and malformed envelopes close the wire and persist `RETIRE_UNCONFIRMED` through `LinuxGuestRunJournal`. A receipt persistence failure is exposed as `journalFailure`; recovery still cannot publish a candidate without its publication marker. The current Service intentionally rejects `FRAME_REPLY` because there is no native guest to receive it. Neither the binding nor the Service calls `LinuxGuestRunJournal.complete`.

The future native supervisor has a separate `DSH_TRACE_V1` event pipe and process-tree retirement contract. Binder frames cannot substitute for that OS-owned evidence. Wiring a real native frame producer and supervisor, installing only reviewed executable bytes, Android instrumentation of Binder UID/death paths and phone execution remain required.

Host admission tests: `node apps/android/tool/acceptance-linux-guest-binder-bridge.mjs`. `LinuxGuestBinderInstrumentation` checks the device handshake; `LinuxGuestImageHandoffInstrumentation` checks rejection of an unpinned offer and a mismatched snapshot call. Both are registered in AndroidTest, compiled, and not yet run on a phone. Neither starts a guest. Host tests cannot prove Android's Binder identity semantics.
