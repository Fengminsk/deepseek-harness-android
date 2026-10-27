# Linux command network approval

English | [中文](linux-network-admission.zh.md)

## Model request

The optional [Linux admission owner](../runtime/linux-network-admission.mjs) adds `networkHosts` and `networkCallLimit` to `linux_exec`. Both must be supplied together: 1–32 distinct, lowercase ASCII public DNS names and 1–64 HTTPS GET requests. Wildcards, IP literals, URLs, local-use names and trailing dots are rejected. The fields describe requested access only. Omitting them keeps the command offline; `sandboxPolicy.networkAllow` is not a user approval. The App-selected persistence policy remains separate, including discard mode for read-only sessions.

This path supports the guest `dsh-fetch` client through the App HTTPS broker, not guest sockets, arbitrary headers, uploads, package managers or general curl/Git networking. Replies are bounded to 64 KiB; redirects require an approved exact host. Product registration still requires the separate native/device acceptance setting and an explicitly composed network admission owner. Source tests do not open that setting.

## Approval and dispatch

The original `ApprovalService.request` owns session policy and the `approval/asked`–`approval/decided` pair. A dedicated answerer handles only this owner's exact request object. `never` rejects before the answerer runs. The answerer sends the command, Session, call ID, original approval audit ID, requested hosts, persistence policy and budgets to the trusted native review page. Only that page's durable, one-time approval can return a token bound to the same run and App-selected network route. A generic `allowed-once` answer without that native decision cannot authorize dispatch.

After the native decision, the Node owner verifies the original logged outcome and flushes the Session. Failure, caller cancellation, replacement of the live tool registration, or a changed persistence policy revokes the unused native grant. It rechecks the live ToolRuntime execution and policy after recovery inspection, immediately before consuming the token. The model never receives the token. A deferred, logged context retains the native approval ID, DSH audit ID, run ID, exact hosts, route, command hash and budgets.

`native.linuxVm.network.review` receives `id`, `sessionId`, `callId`, `approvalAuditId`, `command`, `timeoutMs`, `persistChanges`, `exactHosts` and `networkCallLimit`. A granted response contains matching identities, `outcome:"allowed-once"`, UUID `approvalId` and `token`, and a bounded route summary. `native.linuxVm.executeNetwork` consumes the unchanged command fields with `approvalToken` and `approvalAuditId`; host lists are not resubmitted as authority. Native admission independently matches the reviewed plan and route and supplies the already-admitted lease to the VM manager.

## Cancellation and evidence

`native.linuxVm.network.cancelReview` revokes the named pending review or unused grant and confirms the same run and Session identities. Original DSH cancellation can settle before its answerer; the tool still joins the native review and revocation. An unconfirmed revocation closes the network approval owner. Once consumed, cancellation and uncertain execution follow the [existing Linux receipt rules](linux-vm-runtime.md#persistence-and-failures); cancelling a request does not undo publication or prior network effects. No command is automatically replayed.

The focused host checks are `node --import tsx/esm --test apps/android/tool/linux-network-admission.test.mjs apps/android/tool/native-linux-network.test.mjs`. They use the real ApprovalService, ToolRuntime, AgentLoop and JSONL Session storage with a simulated native transport, including the [recorded Session projection](expected/linux-network-approval.expected.json). They do not certify native UI decisions, Binder UID binding, route selection, HTTPS traffic or lock-screen behavior. Those require the accepted Android artifact and device evidence.

Network execution receipts include `approvalCleanupConfirmed`. If durable approval cleanup is unconfirmed, the receipt preserves the actual command status, output and publication facts but adds `needsReview:true` and a visible explanation. The Node execution owner blocks subsequent commands; the deferred Session receipt retains this failure even if cancellation replaces the immediate tool result. Do not retry the command or infer that its committed effects were undone. A missing cleanup field is an incomplete native response, not confirmation.
