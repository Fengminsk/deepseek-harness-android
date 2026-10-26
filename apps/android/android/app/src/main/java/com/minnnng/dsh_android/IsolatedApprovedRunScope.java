package com.minnnng.dsh_android;

import java.util.Set;

/** App-owned approval checked against a narrower Node request; no request can create authority. */
public final class IsolatedApprovedRunScope {
    private IsolatedApprovedRunScope() {}

    public static void verify(IsolatedExecutionPolicyOwner.Scope approved,
                              String expectedSessionId, String expectedWorkspaceId,
                              String sessionId, String workspaceId, String ownerId, long version,
                              Set<String> readable, Set<String> writable, Set<String> hosts,
                              long fileCalls, long networkCalls, long leaseMillis) {
        if (approved == null || !approved.sessionId().equals(expectedSessionId)
                || !expectedSessionId.equals(sessionId)
                || !approved.ownerId().equals(ownerId) || approved.version() != version
                || !(expectedWorkspaceId == null ? workspaceId == null
                    : expectedWorkspaceId.equals(workspaceId))
                || readable == null || writable == null || hosts == null
                || !approved.readablePaths().containsAll(readable)
                || !approved.writablePaths().containsAll(writable)
                || !approved.exactHosts().containsAll(hosts)
                || !readable.containsAll(writable)
                // HostBridge enforces limits from the policy lease. Until it owns
                // per-request counters/deadlines, a retained category keeps its
                // approved budget. A dropped category has no broker and zero calls.
                || fileCalls != (readable.isEmpty() ? 0 : approved.fileCallLimit())
                || networkCalls != (hosts.isEmpty() ? 0 : approved.networkCallLimit())
                || leaseMillis != approved.leaseMillis()
                || (readable.isEmpty() && hosts.isEmpty())) {
            throw new IllegalArgumentException("Run scope exceeds the App-approved plan");
        }
        // This bridge currently maps each approved name to one exact-file GrantSpec.
        // A directory subtree requires its own bounded enumeration and review semantics.
        if (readable.stream().anyMatch(name -> name.endsWith("/"))
                || writable.stream().anyMatch(name -> name.endsWith("/")))
            throw new IllegalArgumentException("Directory grants are unavailable in this bridge");
        if (!readable.isEmpty() && (expectedWorkspaceId == null
                || approved.workspaceRoot() == null || approved.appPrivateRoot() == null))
            throw new IllegalArgumentException("File grant lacks an App-selected workspace");
        new IsolatedNetworkBroker.Policy(hosts);
        if (!readable.isEmpty()) new IsolatedCapabilityBroker.SandboxPolicy(readable, writable);
    }
}
