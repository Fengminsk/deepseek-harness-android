# Linux guest HTTPS dispatch boundary

`LinuxGuestHttpsDispatch` is an App-owned adapter between an already admitted
`LinuxGuestBrokerWire` v2 `HTTPS_HOST` frame and `IsolatedNetworkBroker`. The
operation carries a canonical ASCII HTTPS URL, even though its historical enum
name is `HTTPS_HOST`. The native guest receives no socket, network permission,
cookie, request body, arbitrary header, or App filesystem path.

For each pending request the adapter checks the wire-owned request identity,
the live policy lease, and the exact URL host before invoking the broker. The
broker permits GET only, bounds calls to ten seconds, resolves DNS against a
deadline and selected Android network, rejects non-public DNS addresses, pins
the TLS connection to the vetted address and hostname, and checks every
redirect against the same exact-host allowlist. Its App-private journal admits
the call ID before DNS and records a terminal status before the adapter replies.
The adapter independently reads that terminal record and compares the call ID,
host and status. Missing, uncertain, duplicate, or damaged audit state cancels
the guest run without a reply. Lease revocation closes an active socket.

The result payload is `DSHH` version 1: magic (4 bytes), version (1), broker
status tag (1), HTTP code (2), redirects (1), URL length (2), MIME length
(2), body length (2), then ASCII final URL, UTF-8 MIME and raw body. Lengths are
big endian. The body is capped at 1,536 bytes, one reply at 4,096 bytes, and
all replies per dispatcher at 64 KiB. The guest must treat a non-OK broker
status as a failed request; the frame's error opcode mirrors that status.
Status tags are fixed: 0 OK, 1 policy denied, 2 offline, 3 deadline, 4 response
too large, 5 failed, 6 cancelled, 7 audit unavailable, 8 audit full, 9 audit
uncertain, and 10 replay denied. Tags 7–10 are never sent: they cancel the run.

`AndroidLinuxGuestHttpsDispatch.open` uses the `:agent` process's durable
journal, bounded Android DNS resolver and pinned TLS transport. This is an
integration component, not a launched Linux environment: native guest IPC,
guest image verification, process retirement and model-tool exposure remain
separate gates. Run `node apps/android/tool/acceptance-linux-guest-https-dispatch.mjs`
for host-only adapter checks. They use synthetic DNS/transport and do not prove
Android device behavior.

Keep one dispatcher for the admitted run; closing it revokes network and closes
the wire, which cancels an unfinished run. Do not create and close one per call.
