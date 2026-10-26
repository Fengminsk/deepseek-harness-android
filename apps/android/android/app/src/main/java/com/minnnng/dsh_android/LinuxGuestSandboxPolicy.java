package com.minnnng.dsh_android;

import java.util.Objects;

/**
 * App-side precheck for a native Linux guest's broker requests. It grants no direct mount,
 * filesystem descriptor, socket, executable, or App path. The file and HTTPS brokers must
 * still validate and audit each operation against the live lease.
 */
final class LinuxGuestSandboxPolicy {
    private static final String VIRTUAL_WORKSPACE = "/workspace/";

    private final IsolatedExecutionPolicyOwner.Lease lease;
    private final long version;
    private final IsolatedCapabilityBroker.SandboxPolicy files;
    private final IsolatedNetworkBroker.Policy network;
    private final int fileCallLimit;
    private final int networkCallLimit;

    private LinuxGuestSandboxPolicy(IsolatedExecutionPolicyOwner.Lease lease) {
        this.lease = Objects.requireNonNull(lease);
        IsolatedExecutionPolicyOwner.Scope scope = lease.policy();
        version = scope.version();
        if (!lease.active(version)) throw new IllegalStateException("Linux guest lease is inactive");
        files = scope.readablePaths().isEmpty() ? null
                : new IsolatedCapabilityBroker.SandboxPolicy(
                        scope.readablePaths(), scope.writablePaths());
        network = new IsolatedNetworkBroker.Policy(scope.exactHosts());
        fileCallLimit = scope.fileCallLimit();
        networkCallLimit = scope.networkCallLimit();
    }

    /** Only the trusted App may project a durably admitted, live policy lease. */
    static LinuxGuestSandboxPolicy fromLease(IsolatedExecutionPolicyOwner.Lease lease) {
        return new LinuxGuestSandboxPolicy(lease);
    }

    String runId() { return lease.runId(); }
    boolean active() { return lease.active(version); }
    int fileCallLimit() { return fileCallLimit; }
    int networkCallLimit() { return networkCallLimit; }

    /**
     * The virtual name is a broker request, never a PRoot bind source. A matching result
     * authorizes only asking the App-owned file broker for an opaque grant handle.
     */
    boolean permitsBrokeredFile(String virtualPath, IsolatedCapabilityBroker.Action action) {
        if (!active() || files == null || fileCallLimit == 0 || action == null
                || virtualPath == null || !virtualPath.startsWith(VIRTUAL_WORKSPACE)) return false;
        String relative = virtualPath.substring(VIRTUAL_WORKSPACE.length());
        try {
            IsolatedCapabilityBroker.GrantSpec grant = new IsolatedCapabilityBroker.GrantSpec(
                    relative, AndroidJava28.setOf(action));
            return !grant.directory() && files.permits(grant);
        } catch (IllegalArgumentException invalid) {
            return false;
        }
    }

    /** Exact host only; the HTTPS broker separately validates scheme, redirects, DNS and TLS. */
    boolean permitsBrokeredHttpsHost(String exactHost) {
        return active() && networkCallLimit > 0 && exactHost != null
                && network.permits(exactHost);
    }
}
