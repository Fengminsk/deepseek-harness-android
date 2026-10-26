# Linux guest run lifecycle contract

English | [中文](linux-guest-run-journal.zh.md)

`LinuxGuestRunJournal` is a dormant trusted-App execution contract. It neither launches a Linux guest nor exposes Shell to the model. The caller must create it under an App-private directory and pass `admission()` to `IsolatedExecutionPolicyOwner`, durably reserving the run ID before binding the isolated Service. Its receipt tree is separate from V8 script receipts and must not be handed to the script result reader.

Successful retirement follows this order: verify UID, image and launcher digests, all tracee reaps from the OS-owned event pipe, broker settlements and the live policy lease; write and fsync a candidate receipt; recheck the lease and call `markDurableSuccess()` for the in-memory decision; atomically publish and fsync the completion marker; then call `markPublicationCommitted()`. A caller may display success or send a completion notification only when `LinuxGuestRunJournal.complete()` returns `true` and `mayPublishSuccess()` is `true`.

Cancellation, Service/Binder death, process interruption and unconfirmed descendant retirement cannot produce a successful receipt. On restart, `recover()` records unfinished runs as `INTERRUPTED_UNCONFIRMED`. A candidate receipt without a valid completion marker also reads as uncertain, and its run ID cannot be replayed. Duplicate terminal writes are rejected. A marker that conflicts with its receipt fails closed.

The real guest launcher, Binder identity collection, kernel/PRoot event-pipe wiring, Service lifecycle caller, task notification wiring and device acceptance remain outstanding. Do not attach App-UID Shell or unrestricted network access to this contract.
