---
kind: reference
title: Native Linux network approval
---

# Native Linux network approval

English | [中文](linux-network-native-approval.zh.md)

## Summary

The [native coordinator](../android/app/src/main/kotlin/com/minnnng/dsh_android/LinuxVmNetworkApprovalCoordinator.kt) turns a pending Linux network request into a one-time token only after the existing native approval dialog records a trusted user decision. A JSON request cannot grant access. The [model admission owner](linux-network-admission.md) owns the Session policy, audit and flush requirements; the [Linux network broker](linux-vm-network.md) owns permitted HTTPS traffic.

## Contents

- [Review and UI](#review-and-ui)
- [Consumption and retirement](#consumption-and-retirement)
- [Host checks](#host-checks)
- [Dev Note](#dev-note)

<a id="review-and-ui"></a>
## Review and UI

`native.linuxVm.network.review` accepts the run ID, Session ID, call ID, original approval audit ID, command, timeout, persistence choice, exact host list and network call budget defined by the model admission owner. Native validation rejects extra fields and invalid identities or budgets before preparing an approval. The immutable request includes the current App-selected proxy route and is written to a unique private run directory. The Inbox snapshot binds this request to its network-only scope: no file roots, no readable or writable paths, zero file calls, exact approved hosts and a bounded network call count.

The request is offered only to a registered, resumed [MainActivity](../android/app/src/main/kotlin/com/minnnng/dsh_android/MainActivity.kt). It never launches an Activity in the background. Without a viable foreground UI, the request returns `unavailable`. The [glass dialog](../android/app/src/main/kotlin/com/minnnng/dsh_android/IsolatedApprovalDialog.kt) obtains the command, route, hosts, timeout and persistence choice from the native Inbox and checks the expected snapshot before showing them. Dismissal rejects the request. Approval uses the existing native Messenger gesture path; neither an App JSON reply nor a model-supplied boolean can approve it.

Pending review expires after 120 seconds. A durable Inbox approval produces the response with outcome `allowed-once`, approval ID, opaque UUID token and route summary. An unused token expires after 30 seconds. Rejected, cancelled and unavailable responses contain no token, approval ID or route. A native policy lease lasts the reviewed command timeout plus five seconds, at most 125 seconds; this does not enlarge the command timeout.

The approved route is the configuration applied in the Agent process. A change to that applied route invalidates pending or unused approvals and revokes an active lease. Saving a setting in the Flutter process alone does not establish immediate cross-process revocation; the existing apply/restart flow remains responsible for applying it.

<a id="consumption-and-retirement"></a>
## Consumption and retirement

`native.linuxVm.executeNetwork` matches the token, run, Session, command, timeout, persistence choice and approval audit ID against the reviewed request, then checks the applied route again. Only one caller can consume the token. The original durable policy owner writes the admission marker before the coordinator calls the real VM manager with the five execution fields, admitted network-only lease and captured route. Reusing a token or changing its fields cannot dispatch a second command or revoke a legitimate command already running.

`native.linuxVm.network.cancelReview` revokes only a pending request or unused token. Cancellation that arrives before its review creates a bounded tombstone, preventing a reordered request from receiving authority. After token consumption, cancellation belongs to `native.linuxVm.cancel` and the original execution result; a late review cancellation does not cancel that run. No request or uncertain command is replayed automatically.

Inbox dismissal and service shutdown revoke leases synchronously, while native cancellation and durable cleanup run outside the Inbox monitor and main Looper. Execution cleanup retains the VM manager's actual terminal receipt. Every complete network receipt includes `approvalCleanupConfirmed`; an unconfirmed cleanup adds the stable category `durable-revocation-unconfirmed`, preserves actual execution and disk publication facts, and stops new approvals until the coordinator is recreated. It is not evidence that the command had no effects.

Coordinator close waits within a shared 15-second limit for entry cleanup and cancellation workers. A timeout or failed durable denial remains a failure; close does not report unconfirmed retirement as successful. Historical private approval records are retained, and a new store never restores an active lease from them.

<a id="host-checks"></a>
## Host checks

Run `node apps/android/tool/acceptance-linux-network-approval.mjs` with JDK 17 or newer, the repository's cached Kotlin compiler dependencies and Android 36 SDK sources. The [runner](acceptance-linux-network-approval.mjs) compiles the production coordinator, Inbox, policy owner and approval store with the SDK JSON implementation, then runs the [owning checks](../android/app/src/test/kotlin/com/minnnng/dsh_android/LinuxVmNetworkApprovalCoordinatorTest.kt). Its temporary output stays under the repository cache and is removed after the run.

The checks cover absent UI, field binding, one-time consumption, pending and unused expiry, route changes, early and late cancellation, concurrent duplicate execution, failed durable approval/admission, nonblocking Inbox dismissal, joined cleanup workers and retention of actual results after cleanup failure. The UI decision is invoked directly and the VM executor and directory sync are test callbacks. These host checks do not certify an Android user gesture, Binder identity, Android directory durability, real guest HTTPS traffic, screen behavior or process-death recovery.

<a id="dev-note"></a>
## Dev Note

The [service integration](../android/app/src/main/kotlin/com/minnnng/dsh_android/AgentService.kt) owns coordinator lifetime and the three native RPC methods. It preserves the independent manual isolated-script approval path. Native networking remains subject to the product's existing capability availability checks; this coordinator does not enable them.
