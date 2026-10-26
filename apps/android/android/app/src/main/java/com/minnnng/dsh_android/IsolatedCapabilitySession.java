package com.minnnng.dsh_android;

import java.io.IOException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Objects;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.BooleanSupplier;

/** One App-owned capability lease for one separately identified isolated guest. */
public final class IsolatedCapabilitySession implements AutoCloseable {
    public record Offer(String runId, String nonce, List<IsolatedCapabilityBroker.GrantHandle> grants) {
        public Offer { grants = AndroidJava28.copyList(grants); }
    }
    /** Guest input carries only a grant ID. The App-owned broker retains the corresponding path. */
    public record Request(String nonce, IsolatedCapabilityBroker.Call call) {
        public Request { Objects.requireNonNull(nonce); Objects.requireNonNull(call); }
    }

    private final Object gate = new Object();
    private final IsolatedCapabilityBroker broker;
    private final int appUid;
    private final String nonce;
    private final AtomicBoolean stopped = new AtomicBoolean();
    private final ScheduledThreadPoolExecutor watchdog = new ScheduledThreadPoolExecutor(1, task -> {
        Thread thread = Executors.defaultThreadFactory().newThread(task);
        thread.setDaemon(true);
        thread.setName("dsh-capability-lease");
        return thread;
    });
    private int guestUid = -1;
    private boolean busy;
    private boolean finishProposed;

    public IsolatedCapabilitySession(String ownerId, IsolatedCapabilityBroker.WorkspaceOps workspace,
                                     IsolatedCapabilityBroker.AuditSink audit,
                                     List<IsolatedCapabilityBroker.GrantSpec> grants,
                                     IsolatedCapabilityBroker.SandboxPolicy policy,
                                     long leaseMillis, int appUid) throws IOException {
        if (appUid < 0) throw new IllegalArgumentException("Invalid App UID");
        this.appUid = appUid;
        this.nonce = randomNonce();
        this.broker = new IsolatedCapabilityBroker(ownerId, workspace, audit, grants, policy, leaseMillis);
        watchdog.setRemoveOnCancelPolicy(true);
        watchdog.schedule(this::timeout, leaseMillis, TimeUnit.MILLISECONDS);
    }

    public Offer offer() { return new Offer(broker.runId(), nonce, broker.handles()); }
    public IsolatedCapabilityBroker.Terminal terminal() { return broker.terminal(); }
    public boolean auditUncertain() { return broker.auditUncertain(); }

    /** Bind the first verified Binder sender to this lease; the UID field is corroboration only. */
    public boolean attach(int sendingUid, int reportedUid, String offeredRunId, String offeredNonce) {
        synchronized (gate) {
            if (!identity(sendingUid, reportedUid, offeredRunId, offeredNonce)
                    || broker.terminal() != null || guestUid != -1) {
                failLocked();
                return false;
            }
            guestUid = sendingUid;
            return true;
        }
    }

    /** Execute off the Android main thread. Only one request may be outstanding per guest lease. */
    public IsolatedCapabilityBroker.CallResult dispatch(int sendingUid, int reportedUid,
                                                         Request request, BooleanSupplier callerCancelled) {
        Objects.requireNonNull(request);
        Objects.requireNonNull(callerCancelled);
        synchronized (gate) {
            if (!identity(sendingUid, reportedUid, request.call().runId(), request.nonce())
                    || guestUid != sendingUid || busy || finishProposed) {
                failLocked();
                return IsolatedCapabilityBroker.CallResult.error(IsolatedCapabilityBroker.Status.DENIED,
                        "Guest call failed session admission");
            }
            if (broker.terminal() != null) {
                return IsolatedCapabilityBroker.CallResult.error(terminalStatus(),
                        "Capability lease is already terminal");
            }
            busy = true;
        }
        try {
            return broker.execute(request.call(), () -> stopped.get() || callerCancelled.getAsBoolean());
        } finally {
            synchronized (gate) { busy = false; }
        }
    }

    /** Guest FINISH stops new calls; it is not a durable successful terminal result. */
    public boolean proposeFinish(int sendingUid, int reportedUid,
                                 String runId, String guestNonce) {
        synchronized (gate) {
            if (!identity(sendingUid, reportedUid, runId, guestNonce)
                    || guestUid != sendingUid || busy || finishProposed || broker.terminal() != null) {
                failLocked();
                return false;
            }
            finishProposed = true;
            stopped.set(true);
            return true;
        }
    }

    /** App-only: call after the bound guest Binder has died and binding cleanup succeeded. */
    public IsolatedCapabilityBroker.Terminal retiredAfterCleanup() {
        synchronized (gate) {
            if (!finishProposed || busy || broker.terminal() != null) {
                IsolatedCapabilityBroker.Terminal outcome = broker.workerDied();
                finishTimer();
                return outcome;
            }
            IsolatedCapabilityBroker.Terminal outcome = broker.complete();
            finishTimer();
            return outcome;
        }
    }

    public boolean finishProposed() { synchronized (gate) { return finishProposed; } }

    public IsolatedCapabilityBroker.Terminal cancel() {
        synchronized (gate) {
            stopped.set(true);
            IsolatedCapabilityBroker.Terminal outcome = broker.cancel();
            finishTimer();
            return outcome;
        }
    }
    public IsolatedCapabilityBroker.Terminal workerDied() {
        synchronized (gate) {
            stopped.set(true);
            IsolatedCapabilityBroker.Terminal outcome = broker.workerDied();
            finishTimer();
            return outcome;
        }
    }
    public IsolatedCapabilityBroker.Terminal fail() {
        synchronized (gate) { return failLocked(); }
    }
    public IsolatedCapabilityBroker.Terminal timeout() {
        synchronized (gate) {
            stopped.set(true);
            IsolatedCapabilityBroker.Terminal outcome = broker.timeout();
            finishTimer();
            return outcome;
        }
    }
    @Override public void close() { cancel(); }

    private IsolatedCapabilityBroker.Terminal failLocked() {
        stopped.set(true);
        IsolatedCapabilityBroker.Terminal outcome = broker.fail();
        finishTimer();
        return outcome;
    }
    private void finishTimer() { watchdog.shutdownNow(); }
    private IsolatedCapabilityBroker.Status terminalStatus() {
        return switch (broker.terminal()) {
            case CANCELLED -> IsolatedCapabilityBroker.Status.CANCELLED;
            case EXPIRED -> IsolatedCapabilityBroker.Status.EXPIRED;
            case WORKER_DIED -> IsolatedCapabilityBroker.Status.WORKER_DIED;
            case AUDIT_UNCERTAIN -> IsolatedCapabilityBroker.Status.AUDIT_UNCERTAIN;
            case COMPLETED, FAILED -> IsolatedCapabilityBroker.Status.DENIED;
        };
    }
    private boolean identity(int sendingUid, int reportedUid, String runId, String guestNonce) {
        return sendingUid >= 0 && sendingUid != appUid && sendingUid == reportedUid
                && broker.runId().equals(runId) && guestNonce != null && guestNonce.length() == 64
                && MessageDigest.isEqual(nonce.getBytes(StandardCharsets.US_ASCII),
                        guestNonce.getBytes(StandardCharsets.US_ASCII));
    }
    private static String randomNonce() {
        byte[] value = new byte[32];
        new SecureRandom().nextBytes(value);
        StringBuilder encoded = new StringBuilder(64);
        for (byte octet : value) encoded.append(Character.forDigit((octet >>> 4) & 15, 16))
                .append(Character.forDigit(octet & 15, 16));
        return encoded.toString();
    }
}
