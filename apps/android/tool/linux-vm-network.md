# Linux VM bounded HTTPS

English | [中文](linux-vm-network.zh.md)

The Android implementation provides `dsh-fetch` for bounded HTTPS GET through an App-approved exact-host lease. Ordinary Linux execution remains offline. This is not a socket interface or routing for curl, package managers or Git. The native code and device fixture compile independently; device acceptance and the model approval UI remain separate evidence requirements. The host probe boots the same TinyEMU/Alpine image and runs the shipped client, but cannot establish Android acceptance or enable a production gate.

## Run

Use the existing Windows TinyEMU host build, its pinned compiler runtime, JDK 17, and an Alpine candidate with verified image hashes. Each run keeps its evidence under `.cache/android/linux-vm-network/run-*`; the source candidate and its disks are never written back. The probe verifies image bytes and the JNI source/library identity, not the candidate's older corresponding-source archive. A release still requires a freshly verified source closure.

```powershell
node apps/android/tool/acceptance-linux-vm-network.mjs
python -B -m unittest apps/android/tool/test_linux_vm_network_client.py
node apps/android/tool/acceptance-linux-vm-network.mjs --proxyPort=7897 --candidate=.cache/android/linux-vm-candidates/alpine-tthk3anu --mode=live
node apps/android/tool/acceptance-linux-vm-network.mjs --proxyPort=7897 --candidate=.cache/android/linux-vm-candidates/alpine-tthk3anu --mode=wrong-host
node apps/android/tool/acceptance-linux-vm-network.mjs --proxyPort=7897 --candidate=.cache/android/linux-vm-candidates/alpine-tthk3anu --mode=revoked
node apps/android/tool/acceptance-linux-vm-network.mjs --proxyPort=7897 --candidate=.cache/android/linux-vm-candidates/alpine-tthk3anu --mode=proxy-unavailable
```

The first command runs deterministic loopback TCP, mailbox, App-exchange and corrupt-reply tests; the Python command checks the shipped client's frame parser and consecutive call sequence. Live mode requires the selected local HTTP proxy, fetches `https://example.com/`, verifies `Example Domain` inside the guest, and records the body hash. Wrong-host mode returns an audited policy denial. Revoked mode withdraws the lease when the guest asks to resolve the destination and stops the VM without publishing a reply. Proxy-unavailable mode selects a closed loopback port and requires an offline response; it cannot fall back to direct Internet access. Reports include native and guest exit codes; a crash does not count as a successful denial.

## Request and isolation rules

`LinuxVmHttpsMailbox` owns a dedicated direct buffer inside the isolated Service. A request includes the exact run UUID, a fresh call UUID, sequence, bounded URL and SHA-256. `LinuxVmNetworkGuest` sends a bounded Binder request; `LinuxVmRunner` checks the actual sender UID against its started isolated Service, and `LinuxVmNetworkHostBridge` checks the per-run nonce. The App-owned `LinuxVmHttpsBrokerExchange` independently checks the run, call sequence, lease and budget before using the existing HTTPS broker. Replies require a matching terminal audit and an active lease, with at most 64 KiB of body. Invalid frames, replay, overlapping requests or unconfirmed audits retire the capability. No file grants, App paths, credentials, arbitrary headers or raw sockets cross this channel. SHA-256 detects torn frame bytes; authorization comes from the lease and Binder binding.

The client uses `/dev/vdd` with sector-aligned `O_DIRECT` I/O and a file lock to serialize separate client processes. The isolated interpreter polls only during console reads between execution steps. The App never maps this buffer; it receives copied Binder fields on a bounded worker. Cancellation or lease revocation closes the transport, wakes the guest waiter and stops the VM. A proxy change invalidates the captured route instead of switching an admitted call. The manager waits for network-worker retirement before returning; an unconfirmed cleanup is an uncertain outcome, never a successful retry signal.

`PinnedTlsTransport.throughLocalHttpProxy` connects only to `127.0.0.1` at the trusted configured port and sends CONNECT for the validated public IPv4 address on port 443. It then performs TLS with default trust anchors, SNI and HTTPS hostname verification for the original host. The local connection explicitly disables JVM proxy selection. Proxy refusal, malformed or oversized headers, timeout and cancellation all fail without a direct fallback. The old transport constructor retains its DNS-bound direct-network behavior for existing callers.

## Android admission and pending device evidence

`LinuxVmManager.executeApprovedNetwork` requires the exact admitted lease, Session/run identity and reviewed proxy snapshot from trusted App code. It rejects file grants and never derives a grant from model-supplied hosts or an `approved` boolean. The caller must bind the command, persistence choice, timeout, hosts, budget and route to the user's one-use approval. The manager reads `NetworkProxyPreferences`, uses `AndroidDeadlineResolver` and `AndroidNetworkJournal`, and injects the bundled client into `/tmp` for that invocation. Network failures do not authorize direct fallback. An already published disk remains published if cancellation arrives later; inspect the final receipt.

`LinuxVmNetworkAcceptanceInstrumentation` runs in the Agent process with its own UUID Session and durable test approval. Its modes are `wrong-host` (terminal policy denial), `budget` (second request retires the VM), `revoked` (revoke after observing the fixture's own committed denial) and `live` (verify public HTTPS content inside Linux). It retains its own audit and does not change proxy preferences or user grants. These test approvals do not certify the model-facing approval UI. Android Binder identity, directory durability, default/VPN and local FlClash routing, process death and lock-screen behavior remain device-pending; the host report explicitly reports that limitation.

The instrumentation uses the [black foreground acceptance lease](device-runtime-acceptance.md): the phone must already be unlocked and interactive, the black window must draw and retain focus, and losing visibility revokes the test lease. It never wakes or unlocks the phone. Do not run it while the user requires uninterrupted screen protection; an instrumentation start or process replacement cannot guarantee that protection.
