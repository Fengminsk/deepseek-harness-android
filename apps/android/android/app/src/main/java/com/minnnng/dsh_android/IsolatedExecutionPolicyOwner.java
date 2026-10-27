package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.function.LongSupplier;

/** App-owned internal script policy admission; not an App-UID Shell or model-tool policy. */
public final class IsolatedExecutionPolicyOwner {
    public static final int MAX_ACTIVE_LEASES = 128;
    public static final int MAX_CHILD_DEPTH = 16;
    /**
     * The caller must durably reserve the run ID before this method returns. A failed or uncertain
     * reservation must throw and must never make the ID reusable. IsolatedScriptReceipt can supply
     * this operation; no guest or model input may supply an implementation.
     */
    public interface DurableAdmission { void reserve(String runId, Scope policy) throws IOException; }

    /**
     * The trusted App records the approval or policy change before the new scope becomes active.
     * A failed record leaves this owner closed to new admissions; old leases remain revoked.
     */
    public interface DurableTransition { void record(Scope previous, Scope next) throws IOException; }

    /** Immutable App-side scope. The guest must never receive either root pathname. */
    public static final class Scope {
        private final String ownerId;
        private final String sessionId;
        private final long version;
        private final Path appPrivateRoot;
        private final Path workspaceRoot;
        private final Set<String> readablePaths;
        private final Set<String> writablePaths;
        private final Set<String> exactHosts;
        private final int fileCallLimit;
        private final int networkCallLimit;
        private final long leaseMillis;

        private Scope(String ownerId, String sessionId, long version, Path appPrivateRoot,
                      Path workspaceRoot, Set<String> readablePaths, Set<String> writablePaths,
                      Set<String> exactHosts, int fileCallLimit, int networkCallLimit,
                      long leaseMillis) {
            if (ownerId == null || ownerId.isEmpty() || ownerId.length() > 128
                    || !ownerId.matches("[A-Za-z0-9._:-]+"))
                throw new IllegalArgumentException("Invalid policy owner");
            IsolatedScriptWire.requireSessionId(sessionId);
            if (version < 1 || version == Long.MAX_VALUE) throw new IllegalArgumentException("Invalid policy version");
            Objects.requireNonNull(readablePaths);
            Objects.requireNonNull(writablePaths);
            Objects.requireNonNull(exactHosts);
            if (readablePaths.isEmpty() && !writablePaths.isEmpty())
                throw new IllegalArgumentException("Writable scope needs a readable scope");
            if (!readablePaths.isEmpty())
                new IsolatedCapabilityBroker.SandboxPolicy(readablePaths, writablePaths);
            if (readablePaths.isEmpty() && fileCallLimit != 0
                    || !readablePaths.isEmpty() && (fileCallLimit < 1
                    || fileCallLimit > IsolatedCapabilityBroker.MAX_CALLS))
                throw new IllegalArgumentException("Invalid file-call limit");
            new IsolatedNetworkBroker.Policy(exactHosts);
            if (exactHosts.isEmpty() && networkCallLimit != 0
                    || !exactHosts.isEmpty() && (networkCallLimit < 1
                    || networkCallLimit > IsolatedNetworkBroker.MAX_CALLS))
                throw new IllegalArgumentException("Invalid network-call limit");
            if (leaseMillis < 1 || leaseMillis > Math.min(IsolatedCapabilityBroker.MAX_LEASE_MILLIS,
                    IsolatedNetworkBroker.MAX_LEASE_MILLIS))
                throw new IllegalArgumentException("Invalid policy lease");
            if ((!readablePaths.isEmpty() || !writablePaths.isEmpty()) && workspaceRoot == null)
                throw new IllegalArgumentException("File scope needs an App-selected workspace");
            if ((appPrivateRoot == null) != (workspaceRoot == null))
                throw new IllegalArgumentException("Workspace identity is incomplete");
            this.ownerId = ownerId;
            this.sessionId = sessionId;
            this.version = version;
            this.appPrivateRoot = appPrivateRoot;
            this.workspaceRoot = workspaceRoot;
            this.readablePaths = AndroidJava28.copySet(readablePaths);
            this.writablePaths = AndroidJava28.copySet(writablePaths);
            this.exactHosts = AndroidJava28.copySet(exactHosts);
            this.fileCallLimit = fileCallLimit;
            this.networkCallLimit = networkCallLimit;
            this.leaseMillis = leaseMillis;
        }

        public static Scope denied(String ownerId, String sessionId, long version) {
            return new Scope(ownerId, sessionId, version, null, null, AndroidJava28.setOf(), AndroidJava28.setOf(),
                    AndroidJava28.setOf(), 0, 0, IsolatedCapabilityBroker.MAX_LEASE_MILLIS);
        }

        /**
         * Only trusted App code may construct a granted scope after verifying the user choice.
         * Resolving the root here does not replace the broker's descriptor-anchored file checks.
         */
        public static Scope granted(String ownerId, String sessionId, long version,
                                    Path appPrivateRoot, Path workspaceRoot,
                                    Set<String> readablePaths, Set<String> writablePaths,
                                    Set<String> exactHosts, int fileCallLimit,
                                    int networkCallLimit, long leaseMillis) throws IOException {
            if ((appPrivateRoot == null) != (workspaceRoot == null))
                throw new IllegalArgumentException("Workspace identity is incomplete");
            Path privateRoot = null;
            Path workspace = null;
            if (appPrivateRoot != null) {
                privateRoot = appPrivateRoot.toRealPath();
                workspace = workspaceRoot.toRealPath();
                if (!Files.isDirectory(privateRoot, LinkOption.NOFOLLOW_LINKS)
                        || !Files.isDirectory(workspace, LinkOption.NOFOLLOW_LINKS)
                        || Files.isSymbolicLink(workspaceRoot)
                        || workspace.equals(privateRoot) || !workspace.startsWith(privateRoot))
                    throw new IOException("Workspace is outside the App-private root");
            }
            return new Scope(ownerId, sessionId, version, privateRoot, workspace,
                    readablePaths, writablePaths, exactHosts, fileCallLimit,
                    networkCallLimit, leaseMillis);
        }

        public String ownerId() { return ownerId; }
        public String sessionId() { return sessionId; }
        public long version() { return version; }
        public Path appPrivateRoot() { return appPrivateRoot; }
        public Path workspaceRoot() { return workspaceRoot; }
        public Set<String> readablePaths() { return readablePaths; }
        public Set<String> writablePaths() { return writablePaths; }
        public Set<String> exactHosts() { return exactHosts; }
        public int fileCallLimit() { return fileCallLimit; }
        public int networkCallLimit() { return networkCallLimit; }
        public long leaseMillis() { return leaseMillis; }

        /** A child may lose scope or budget, but cannot add a path, host, workspace or lease. */
        public boolean within(Scope parent) {
            return parent != null && ownerId.equals(parent.ownerId)
                    && sessionId.equals(parent.sessionId) && version == parent.version
                    && Objects.equals(workspaceRoot, parent.workspaceRoot)
                    && Objects.equals(appPrivateRoot, parent.appPrivateRoot)
                    && readablePaths.stream().allMatch(path -> covered(parent.readablePaths, path))
                    && writablePaths.stream().allMatch(path -> covered(parent.writablePaths, path))
                    && parent.exactHosts.containsAll(exactHosts)
                    && fileCallLimit <= parent.fileCallLimit
                    && networkCallLimit <= parent.networkCallLimit
                    && leaseMillis <= parent.leaseMillis;
        }

        private static boolean covered(Set<String> roots, String path) {
            for (String root : roots) {
                if (root.endsWith("/") ? path.startsWith(root) : path.equals(root)) return true;
            }
            return false;
        }
    }

    public final class Lease {
        private final String runId;
        private final Scope policy;
        private final Lease parent;
        private final int depth;
        private final long startedNanos;
        private volatile boolean revoked;
        private final List<Runnable> revocationHooks = new ArrayList<>();

        private Lease(String runId, Scope policy, Lease parent) {
            this.runId = runId;
            this.policy = policy;
            this.parent = parent;
            this.depth = parent == null ? 0 : parent.depth + 1;
            this.startedNanos = monotonicNanos.getAsLong();
        }

        public String runId() { return runId; }
        public Scope policy() { return policy; }
        /** Shared monotonic deadline for an in-flight network call. */
        public long deadlineNanos() {
            long own = startedNanos + policy.leaseMillis() * 1_000_000L;
            return parent == null ? own : Math.min(own, parent.deadlineNanos());
        }

        /** Trusted App capabilities register before dispatch; already revoked leases fire immediately. */
        public void onRevoked(Runnable hook) {
            Objects.requireNonNull(hook);
            synchronized (IsolatedExecutionPolicyOwner.this) {
                if (revoked || closed || !active(policy.version())) hook.run();
                else revocationHooks.add(hook);
            }
        }

        private void revokeLocked() {
            if (revoked) return;
            revoked = true;
            for (Runnable hook : revocationHooks) {
                try { hook.run(); }
                catch (RuntimeException ignored) {
                    // Revocation still invalidates the lease. Capability hooks must fail closed.
                }
            }
            revocationHooks.clear();
        }
        public boolean active(long expectedVersion) {
            return !revoked && !closed && expectedVersion == current.version()
                    && expectedVersion == policy.version()
                    && monotonicNanos.getAsLong() - startedNanos
                    < policy.leaseMillis() * 1_000_000L
                    && (parent == null || parent.active(expectedVersion));
        }
    }

    private final DurableAdmission admission;
    private final DurableTransition transition;
    private final LongSupplier monotonicNanos;
    private final Map<String, Lease> leases = new HashMap<>();
    private volatile Scope current;
    private volatile boolean closed;

    public IsolatedExecutionPolicyOwner(String ownerId, String sessionId,
                                        DurableAdmission admission, DurableTransition transition) {
        this(ownerId, sessionId, admission, transition, System::nanoTime);
    }

    /** A verified approval store may resume only a denied scope at its durable version. */
    IsolatedExecutionPolicyOwner(Scope recoveredDenied,
                                 DurableAdmission admission, DurableTransition transition) {
        if (recoveredDenied == null || !recoveredDenied.readablePaths().isEmpty()
                || !recoveredDenied.writablePaths().isEmpty()
                || !recoveredDenied.exactHosts().isEmpty())
            throw new IllegalArgumentException("Recovered policy must deny all capabilities");
        this.current = recoveredDenied;
        this.admission = Objects.requireNonNull(admission);
        this.transition = Objects.requireNonNull(transition);
        this.monotonicNanos = System::nanoTime;
    }

    IsolatedExecutionPolicyOwner(String ownerId, String sessionId,
                                 DurableAdmission admission, DurableTransition transition,
                                 LongSupplier monotonicNanos) {
        this.current = Scope.denied(ownerId, sessionId, 1);
        this.admission = Objects.requireNonNull(admission);
        this.transition = Objects.requireNonNull(transition);
        this.monotonicNanos = Objects.requireNonNull(monotonicNanos);
    }

    public Scope current() { return current; }

    /** All live leases are revoked before a persisted policy replacement is exposed. */
    public synchronized void replace(Scope next) throws IOException {
        requireOpen();
        Objects.requireNonNull(next);
        if (!next.ownerId().equals(current.ownerId()) || !next.sessionId().equals(current.sessionId())
                || next.version() != current.version() + 1)
            throw new IllegalArgumentException("Policy replacement changed identity or skipped a version");
        closed = true;
        revokeAllLocked();
        transition.record(current, next);
        current = next;
        closed = false;
    }

    /** Reservation must be durable before a guest Service can be bound. */
    public synchronized Lease admit(String runId) throws IOException {
        return reserve(runId, current, null);
    }

    /** Child budgets and scopes are a subset of the live parent run. */
    public synchronized Lease admitChild(String parentRunId, String runId, Scope child) throws IOException {
        requireOpen();
        Lease parent = leases.get(parentRunId);
        if (parent == null || !parent.active(current.version()) || !child.within(parent.policy()))
            throw new IllegalArgumentException("Child policy exceeds its active parent");
        if (parent.depth >= MAX_CHILD_DEPTH)
            throw new IllegalArgumentException("Child policy exceeds nesting limit");
        return reserve(runId, child, parent);
    }

    private Lease reserve(String runId, Scope scope, Lease parent) throws IOException {
        requireOpen();
        IsolatedScriptWire.requireUuid(runId);
        if (leases.containsKey(runId)) throw new IOException("Run ID has already been admitted");
        if (leases.size() >= MAX_ACTIVE_LEASES) throw new IOException("Active policy lease capacity reached");
        try {
            admission.reserve(runId, scope);
        } catch (IOException failedReservation) {
            closed = true;
            revokeAllLocked();
            throw failedReservation;
        }
        Lease lease = new Lease(runId, scope, parent);
        leases.put(runId, lease);
        return lease;
    }

    public synchronized void revoke(String runId) {
        Lease lease = leases.get(runId);
        if (lease == null) return;
        List<Lease> affected = new ArrayList<>();
        for (Lease candidate : leases.values()) {
            for (Lease ancestor = candidate; ancestor != null; ancestor = ancestor.parent) {
                if (ancestor == lease) {
                    affected.add(candidate);
                    break;
                }
            }
        }
        for (Lease candidate : affected) leases.remove(candidate.runId());
        affected.forEach(Lease::revokeLocked);
    }

    /** A restarted App constructs a new default-deny owner; no old lease is rehydrated. */
    public synchronized void close() {
        closed = true;
        revokeAllLocked();
    }

    private void revokeAllLocked() {
        List<Lease> affected = new ArrayList<>(leases.values());
        leases.clear();
        affected.forEach(Lease::revokeLocked);
    }

    private void requireOpen() {
        if (closed) throw new IllegalStateException("Execution policy owner is closed");
    }
}
