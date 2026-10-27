# Linux VM HTTPS host probe

English | [中文](linux-vm-network.zh.md)

The host probe runs Python inside the existing TinyEMU/Alpine image, sends a bounded HTTPS GET through a dedicated virtual block device, and validates the response inside Linux. It does not enable network access in the Android App or provide sockets, curl routing, package downloads, or Git transport. The Android VM manager, production gates and default APK remain unchanged.

## Run

Use the existing Windows TinyEMU host build, its pinned compiler runtime, JDK 17, and an Alpine candidate with verified image hashes. Each run keeps its evidence under `.cache/android/linux-vm-network/run-*`; the source candidate and its disks are never written back. The probe verifies image bytes and the JNI source/library identity, not the candidate's older corresponding-source archive. A release still requires a freshly verified source closure.

```powershell
node apps/android/tool/acceptance-linux-vm-network.mjs
node apps/android/tool/acceptance-linux-vm-network.mjs --proxyPort=7897 --candidate=.cache/android/linux-vm-candidates/alpine-tthk3anu --mode=live
node apps/android/tool/acceptance-linux-vm-network.mjs --proxyPort=7897 --candidate=.cache/android/linux-vm-candidates/alpine-tthk3anu --mode=wrong-host
node apps/android/tool/acceptance-linux-vm-network.mjs --proxyPort=7897 --candidate=.cache/android/linux-vm-candidates/alpine-tthk3anu --mode=revoked
node apps/android/tool/acceptance-linux-vm-network.mjs --proxyPort=7897 --candidate=.cache/android/linux-vm-candidates/alpine-tthk3anu --mode=proxy-unavailable
```

The first command runs deterministic loopback TCP and mailbox tests. The live mode requires the selected local HTTP proxy, fetches `https://example.com/`, verifies `Example Domain` inside the guest, and records the body hash. Wrong-host mode returns an audited policy denial. Revoked mode withdraws the lease when the guest asks to resolve the destination and stops the VM without publishing a reply. Proxy-unavailable mode selects a closed loopback port and requires an offline response; it cannot fall back to direct Internet access. Reports include native and guest exit codes; a crash does not count as a successful denial.

## Request and isolation rules

`LinuxVmHttpsMailbox` accepts a dedicated direct mapping and an App-owned `IsolatedExecutionPolicyOwner.Lease`. A request includes the exact run UUID, a fresh call UUID, sequence, bounded URL and SHA-256. The existing HTTPS broker applies the live exact-host policy, DNS/public-IP checks, redirect checks, deadline and audit admission. Repeated call IDs or invalid frames retire the mailbox. Replies require a matching terminal audit and an active lease, with at most 64 KiB of body. No file grants, App paths, credentials, arbitrary headers or raw sockets cross this mapping. A SHA-256 frame digest detects torn data; authorization comes from the lease and channel binding, not from the digest.

The probe uses `/dev/vdd`; guest Python performs sector-aligned `O_DIRECT` I/O. The host polls only from console reads on the interpreter thread, between guest execution steps, so native block writes and Java frame reads never race. It is not a shared-memory API for concurrent interpreter and network threads. Run cancellation must close the mailbox or revoke its lease to close an active socket. The shared VM cancellation flag alone is checked on the next callback. Revocation or a configured proxy change must retire the old lease; they must not silently change the route of an admitted request.

`PinnedTlsTransport.throughLocalHttpProxy` connects only to `127.0.0.1` at the trusted configured port and sends CONNECT for the validated public IPv4 address on port 443. It then performs TLS with default trust anchors, SNI and HTTPS hostname verification for the original host. The local connection explicitly disables JVM proxy selection. Proxy refusal, malformed or oversized headers, timeout and cancellation all fail without a direct fallback. The old transport constructor retains its DNS-bound direct-network behavior for existing callers.

## Android integration still required

The host CLI grants a test lease and file-syncs its admission and journal files; its directory-sync callback is deliberately a host fixture. This does not establish Android durable approvals, Binder identity, directory fsync, default/VPN routing, local FlClash access, process death recovery, or lock-screen behavior. Android integration must bind the mailbox to the admitted isolated Service, deliver only that mapping, choose the route from `NetworkProxyPreferences`, use `AndroidDeadlineResolver` and `AndroidNetworkJournal`, and retire both mailbox and VM on session cancellation, policy change or proxy change. None of those production integrations is claimed by the host report.
