# Linux guest broker request policy

English | [中文](linux-guest-sandbox-policy.zh.md)

The trusted App creates `LinuxGuestSandboxPolicy` only from an active, durably admitted `IsolatedExecutionPolicyOwner.Lease`. Its default scope denies both files and network. The policy is a precheck for native guest broker requests; it does not confine a native process, implement a mount, issue a descriptor, open a socket, or authorize a Shell command. Each request still needs the App-side file or HTTPS broker to check the same live lease, limits, revision, destination and durable audit.

A file request names `/workspace/<relative-file>`. The `/workspace/` prefix is a virtual broker namespace, never a bind mount of the App's private workspace. The underlying App path stays in the policy owner and file broker. The existing `IsolatedCapabilityBroker.GrantSpec` rejects absolute targets, traversal segments, empty segments, backslashes, colon syntax, controls, invalid UTF-8 and excessive depth or length. A read or search needs an approved readable path; a write also needs a writable path and rejects `.git`, `.agents`, `.codex` and `.aws` segments even under a broader writable directory. A directory name alone is not a file operation.

Network prechecks compare one normalized ASCII DNS host against the lease's exact host set and nonzero call budget. They do not parse URLs or allow redirects. `IsolatedNetworkBroker` must separately require HTTPS, resolve DNS within the deadline, pin the route and TLS peer, check each redirect, cap the response and record the call. The native guest receives no raw network grant. A child scope may only narrow the owner, Session, paths, hosts, budgets and lease duration through `IsolatedExecutionPolicyOwner.admitChild`.

Revocation, policy replacement or lease expiry makes subsequent prechecks fail. No result from this policy may be treated as proof that an already running Linux descendant stopped, or that PRoot confines host paths or direct sockets. The corresponding process-tree and non-root device checks remain required before a generic Linux command becomes available to the Agent.

Host check: `node apps/android/tool/acceptance-linux-guest-sandbox-policy.mjs`. It covers default denial, path and host exactness, protected writes, child attenuation, and revocation. It does not establish device isolation or actual PRoot execution.
