package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.file.Path;
import java.util.HashSet;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.function.LongSupplier;

/**
 * App-owned accounting for one proposed native guest run. This does not start a process or
 * authorize distribution of the current PRoot candidate. A future launcher must provide
 * Binder-observed UID, independently verified image/ELF digests, an OS-owned event pipe,
 * and a durable result before this session can publish success.
 */
final class LinuxGuestLaunchSession implements AutoCloseable {
    static final int MAX_OUTPUT_BYTES = 64 * 1024;
    static final int MAX_BROKER_CALLS = 128;
    static final int MAX_PENDING_BROKER_CALLS = 16;
    static final long MAX_DEADLINE_MILLIS = 30_000L;

    private final LinuxGuestSandboxPolicy policy;
    private final LinuxTraceeEventWire trace;
    private final String imageDigest;
    private final String launcherDigest;
    private final String loaderDigest;
    private final LongSupplier monotonicNanos;
    private final long startedNanos;
    private final long deadlineNanos;
    private final Set<String> pendingBrokerCalls = new HashSet<>();
    private final Set<String> settledBrokerCalls = new HashSet<>();
    private int guestUid = -1;
    private int brokerCalls;
    private int fileCalls;
    private int networkCalls;
    private int outputBytes;
    private boolean traceFinished;
    private boolean durableResult;
    private boolean publicationCommitted;
    private boolean cancelled;
    private boolean closed;
    private String failure;

    /** Production admission seam: inspect package-installed bytes before accepting their digests. */
    static LinuxGuestLaunchSession admitInstalled(LinuxGuestSandboxPolicy policy,
                                                   String imageDigest, Path nativeLibraryDir,
                                                   long deadlineMillis) throws IOException {
        LinuxGuestInstalledElfVerifier.Verified installed =
                LinuxGuestInstalledElfVerifier.verify(nativeLibraryDir);
        return new LinuxGuestLaunchSession(policy, imageDigest, installed.launcherSha256(),
                installed.loaderSha256(), deadlineMillis);
    }

    LinuxGuestLaunchSession(LinuxGuestSandboxPolicy policy, String imageDigest,
                            String launcherDigest, String loaderDigest,
                            long deadlineMillis) {
        this(policy, imageDigest, launcherDigest, loaderDigest, deadlineMillis,
                System::nanoTime);
    }

    LinuxGuestLaunchSession(LinuxGuestSandboxPolicy policy, String imageDigest,
                            String launcherDigest, String loaderDigest,
                            long deadlineMillis, LongSupplier monotonicNanos) {
        this.policy = Objects.requireNonNull(policy);
        this.monotonicNanos = Objects.requireNonNull(monotonicNanos);
        if (!policy.active() || !LinuxImageLeaseOwner.SHA256.equals(imageDigest)
                || !digest(launcherDigest) || !digest(loaderDigest)
                || deadlineMillis < 1 || deadlineMillis > MAX_DEADLINE_MILLIS)
            throw new IllegalArgumentException("Linux guest run has no live, pinned admission");
        this.imageDigest = imageDigest;
        this.launcherDigest = launcherDigest;
        this.loaderDigest = loaderDigest;
        this.trace = new LinuxTraceeEventWire(policy.runId());
        this.startedNanos = monotonicNanos.getAsLong();
        this.deadlineNanos = deadlineMillis * 1_000_000L;
    }

    /**
     * The UID must come from the bound isolated Service's Binder sendingUid. Digest arguments
     * must come from the App's package/image verifiers, not from the guest message body.
     */
    synchronized boolean guestConnected(String runId, int sendingUid, int reportedUid,
                                        int appUid, String imageSha256,
                                        String launcherSha256, String loaderSha256) {
        if (!live() || guestUid != -1 || sendingUid <= 0 || appUid <= 0
                || sendingUid == appUid || sendingUid != reportedUid
                || !policy.runId().equals(runId) || !imageDigest.equals(imageSha256)
                || !launcherDigest.equals(launcherSha256)
                || !loaderDigest.equals(loaderSha256))
            return reject("Linux guest identity or executable provenance changed");
        guestUid = sendingUid;
        return true;
    }

    /** Records a request to the App's actual broker; this precheck grants no file descriptor. */
    synchronized boolean beginFileCall(String callId, String virtualPath,
                                       IsolatedCapabilityBroker.Action action) {
        if (fileCalls >= policy.fileCallLimit())
            return reject("Linux guest file broker budget exhausted");
        if (!beginBrokerCall(callId, policy.permitsBrokeredFile(virtualPath, action))) return false;
        fileCalls++;
        return true;
    }

    /** Records a request to the App's actual HTTPS broker; this grants no socket. */
    synchronized boolean beginHttpsCall(String callId, String exactHost) {
        if (networkCalls >= policy.networkCallLimit())
            return reject("Linux guest HTTPS broker budget exhausted");
        if (!beginBrokerCall(callId, policy.permitsBrokeredHttpsHost(exactHost))) return false;
        networkCalls++;
        return true;
    }

    private boolean beginBrokerCall(String callId, boolean permitted) {
        if (!live() || guestUid < 0 || traceFinished || !permitted || !canonicalUuid(callId)
                || pendingBrokerCalls.contains(callId) || settledBrokerCalls.contains(callId)
                || brokerCalls >= MAX_BROKER_CALLS
                || pendingBrokerCalls.size() >= MAX_PENDING_BROKER_CALLS)
            return reject("Linux guest broker request is outside its live scope");
        pendingBrokerCalls.add(callId);
        brokerCalls++;
        return true;
    }

    /** Only a completed and audited App-broker call may settle a pending request. */
    synchronized boolean settleBrokerCall(String callId, boolean audited) {
        if (!live() || !audited || !pendingBrokerCalls.remove(callId))
            return reject("Linux guest broker result is missing or unaudited");
        settledBrokerCalls.add(callId);
        return true;
    }

    /** Output is counted before it is exposed to a caller; the transport owns the bytes. */
    synchronized boolean accountOutput(int byteCount) {
        if (!live() || guestUid < 0 || traceFinished || byteCount < 0
                || byteCount > MAX_OUTPUT_BYTES - outputBytes)
            return reject("Linux guest output exceeds its run budget");
        outputBytes += byteCount;
        return true;
    }

    /** Feed only bytes read from the OS-owned PRoot event pipe, never a guest IPC payload. */
    synchronized boolean acceptTrace(byte[] bytes, int offset, int length) {
        if (!live() || guestUid < 0 || traceFinished || !trace.accept(bytes, offset, length))
            return reject("Linux guest process trace is incomplete or malformed");
        return true;
    }

    /** Call only on actual pipe EOF after observing the tracer process exit. */
    synchronized boolean traceEnded(boolean pipeEof, boolean tracerExitedNormally,
                                    int tracerExitCode) {
        if (!live() || guestUid < 0 || traceFinished || !pipeEof
                || !trace.endOfStream(tracerExitedNormally, tracerExitCode))
            return reject("Linux guest tracer retirement is unconfirmed");
        traceFinished = true;
        return true;
    }

    synchronized boolean readyToPersistSuccess() {
        return live() && guestUid > 0 && traceFinished && pendingBrokerCalls.isEmpty()
                && trace.mayPublishSuccess();
    }

    /** The trusted App calls this only after writing and fsyncing its terminal receipt. */
    synchronized boolean markDurableSuccess() {
        if (durableResult) return false;
        if (!readyToPersistSuccess())
            return reject("Linux guest terminal result is not ready for publication");
        durableResult = true;
        return true;
    }

    /** Called by the App journal only after the final publication marker is fsynced. */
    synchronized boolean markPublicationCommitted() {
        if (!durableResult || publicationCommitted) return false;
        publicationCommitted = true;
        return true;
    }

    synchronized boolean mayPublishSuccess() {
        // The durable candidate and the decision are both private intermediate states.
        return publicationCommitted;
    }

    synchronized void cancel() {
        if (durableResult) return;
        cancelled = true;
        trace.requestCancellation();
    }

    synchronized String failure() {
        if (durableResult) return null;
        if (failure != null) return failure;
        if (cancelled) return "Linux guest run cancelled";
        if (closed) return "Linux guest launch session closed";
        if (!policy.active()) return "Linux guest policy lease expired or revoked";
        if (monotonicNanos.getAsLong() - startedNanos >= deadlineNanos)
            return "Linux guest run deadline exceeded";
        return trace.failure();
    }
    synchronized boolean matchesRunId(String runId) {
        return live() && policy.runId().equals(runId);
    }
    synchronized boolean matchesGuestUid(int sendingUid) {
        return live() && guestUid > 0 && guestUid == sendingUid;
    }
    synchronized int outputBytes() { return outputBytes; }

    @Override public synchronized void close() {
        closed = true;
        if (!durableResult) trace.requestCancellation();
        pendingBrokerCalls.clear();
    }

    private boolean live() {
        return !durableResult && !closed && !cancelled && failure == null && policy.active()
                && monotonicNanos.getAsLong() - startedNanos < deadlineNanos;
    }

    private boolean reject(String reason) {
        if (durableResult) return false;
        if (failure == null) failure = reason;
        trace.requestCancellation();
        return false;
    }

    private static boolean digest(String value) {
        return value != null && value.matches("[0-9a-f]{64}");
    }

    private static boolean canonicalUuid(String value) {
        try { return value != null && UUID.fromString(value).toString().equals(value); }
        catch (IllegalArgumentException invalid) { return false; }
    }
}
