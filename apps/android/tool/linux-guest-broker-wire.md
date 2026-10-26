# Native Linux guest broker frames

English | [中文](linux-guest-broker-wire.zh.md)

`LinuxGuestBrokerWire` admits complete frames from a future isolated guest transport. The caller supplies the Binder-observed sender UID. Admission checks the UID, run ID, live policy lease, scope, replay ID and call budget. This code does not launch a guest or grant a descriptor, App path or socket. No model tool is enabled.

## Version 2 request

The 82-byte header is `DSHB` (4), version `2` (1), opcode (1), zero flags (2), canonical ASCII run UUID (36), canonical ASCII call UUID (36) and unsigned big-endian payload length (2). The payload is exactly 1–2048 bytes. Version 1, trailing data and malformed UTF-8 are rejected. File paths are virtual exact-file names below `/workspace/`; variable strings have an unsigned big-endian 16-bit UTF-8 byte length.

| Opcode | Payload |
| --- | --- |
| 1 read | path, expected revision, nonnegative signed 32-bit byte offset, unsigned 16-bit maximum chunk (1–3800) |
| 2 search | path, literal query, unsigned 16-bit maximum matches (1–256) |
| 3 edit | path, expected revision, literal needle, replacement (possibly empty), unsigned 16-bit maximum replacements (1–4096) |
| 4 HTTPS | one strict ASCII `https://` URL including path and query, without an inner string-length field |

The expected revision is `missing` for an initial read or new-file edit, or a lowercase 64-character SHA-256. Read pages after offset zero require a revision. A changed page returns an audited `STALE` denial; a caller cannot silently join bytes from two revisions. Search and edit use the existing bounded text validators. HTTPS admission validates the URL and its exact normalized host; the HTTPS broker must still enforce DNS, redirects, TLS and policy.

## App-side file dispatch and reply

`LinuxGuestFileBrokerDispatch` accepts only a pending request owned by this wire. It projects the permitted virtual file onto one exact App-owned `IsolatedCapabilityBroker` grant. The opaque grant handle and App path never cross the wire. The broker uses supplied `WorkspaceOps` and `AuditSink` for anchored operations and durable run/grant/call/terminal records; its cancellation supplier rechecks the live Linux lease. Only after durable settlement and terminalization does the dispatcher call `wire.complete`. Audit failure, uncertain edit commit, expiry and revocation cancel the run without a success reply.

Read success encodes one-byte revision length, ASCII revision, unsigned 32-bit total UTF-8 byte length, unsigned 32-bit requested offset, unsigned 16-bit chunk length and raw chunk bytes. A chunk may split a UTF-8 code point; join chunks of the same revision before decoding. Search success encodes revision, unsigned 16-bit hit count, one-byte truncated flag, then each hit's unsigned 32-bit line and column, unsigned 16-bit UTF-8 preview length and preview. Edit success encodes previous and new revisions with one-byte lengths, then unsigned 32-bit resulting byte count. Reply opcodes `0x81` and `0x82` mean audited success and denial, with at most 4096 body bytes. Denials currently carry a short ASCII status such as `STALE`.

The production caller must supply `IsolatedCapabilityWorkspace` anchored to the App-private workspace and a durable `IsolatedCapabilityJournal`. This dispatch class is a capability seam, not a running native guest. A future transport, PRoot evidence, terminal journal bridge and tool registration are still required. Run `node apps/android/tool/acceptance-linux-guest-broker-wire.mjs` for host protocol and file-broker checks; device behavior is unverified.
