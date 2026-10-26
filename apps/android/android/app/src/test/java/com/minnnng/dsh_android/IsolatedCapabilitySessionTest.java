package com.minnnng.dsh_android;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.BooleanSupplier;

/** App-side admission checks; Android Binder sender attribution still needs device validation. */
public final class IsolatedCapabilitySessionTest {
    private static final String PATH = "notes/today.txt";
    private static final String REVISION = "a".repeat(64);
    private static final int APP_UID = 10041;
    private static final int GUEST_UID = 90041;

    public static void main(String[] args) throws Exception {
        validReadAndOneTerminal();
        wrongUidNonceAndPathScope();
        replayAndConcurrentCall();
        cancellationAndDeath();
        finishAdmissionAndRetirement();
        auditFailureAndLateCallback();
        leaseDeadline();
    }

    private static void validReadAndOneTerminal() throws Exception {
        List<IsolatedCapabilityBroker.Event> audit = new ArrayList<>();
        try (var session = open(new MemoryWorkspace(), audit, 10_000)) {
            var offer = session.offer();
            check(offer.grants().size() == 1 && !offer.toString().contains(PATH), "Guest offer leaked App path");
            check(session.attach(GUEST_UID, GUEST_UID, offer.runId(), offer.nonce()), "Guest HELLO denied");
            var result = session.dispatch(GUEST_UID, GUEST_UID, request(offer, id()), () -> false);
            check(result.status() == IsolatedCapabilityBroker.Status.OK
                    && "allowed".equals(result.read().text()), "Granted read did not execute");
            check(session.proposeFinish(GUEST_UID, GUEST_UID, offer.runId(), offer.nonce()),
                    "Guest FINISH was denied");
            check(session.terminal() == null && audit.stream().noneMatch(e -> e.phase()
                    == IsolatedCapabilityBroker.Phase.RUN_FINISHED),
                    "Guest FINISH incorrectly became a durable success before process retirement");
            check(session.retiredAfterCleanup() == IsolatedCapabilityBroker.Terminal.COMPLETED,
                    "Confirmed guest retirement did not complete the run");
            check(audit.stream().filter(e -> e.phase() == IsolatedCapabilityBroker.Phase.CALL_STARTED).count() == 1,
                    "Read admission lacks durable start");
            check(audit.stream().filter(e -> e.phase() == IsolatedCapabilityBroker.Phase.CALL_SETTLED).count() == 1,
                    "Read result lacks durable settlement");
            check(audit.stream().anyMatch(e -> e.phase() == IsolatedCapabilityBroker.Phase.RUN_FINISHED
                    && e.terminal() == IsolatedCapabilityBroker.Terminal.COMPLETED), "No terminal audit");
        }
    }

    private static void wrongUidNonceAndPathScope() throws Exception {
        for (int wrongUid : new int[]{APP_UID, -1}) {
            try (var session = open(new MemoryWorkspace(), new ArrayList<>(), 10_000)) {
                var offer = session.offer();
                check(!session.attach(wrongUid, wrongUid, offer.runId(), offer.nonce()),
                        "Invalid Binder sender attached");
                check(session.terminal() == IsolatedCapabilityBroker.Terminal.FAILED,
                        "Invalid attach left a live run");
            }
        }
        try (var session = open(new MemoryWorkspace(), new ArrayList<>(), 10_000)) {
            var offer = session.offer();
            check(!session.attach(GUEST_UID, GUEST_UID, offer.runId(), "wrong"), "Forged nonce attached");
        }
        try (var session = open(new MemoryWorkspace(), new ArrayList<>(), 10_000)) {
            var offer = session.offer();
            check(session.attach(GUEST_UID, GUEST_UID, offer.runId(), offer.nonce()), "Guest attach failed");
            var result = session.dispatch(GUEST_UID, GUEST_UID + 1, request(offer, id()), () -> false);
            check(result.status() == IsolatedCapabilityBroker.Status.DENIED
                    && session.terminal() == IsolatedCapabilityBroker.Terminal.FAILED,
                    "Reported UID spoof remained admitted");
        }
        try {
            new IsolatedCapabilitySession(id(), new MemoryWorkspace(), event -> {},
                    List.of(new IsolatedCapabilityBroker.GrantSpec("notes/other.txt",
                            Set.of(IsolatedCapabilityBroker.Action.READ))),
                    IsolatedCapabilityBroker.SandboxPolicy.readOnly(Set.of(PATH)), 10_000, APP_UID);
            throw new AssertionError("Guest target exceeded App-approved scope");
        } catch (IllegalArgumentException expected) { /* No session is opened. */ }
    }

    private static void replayAndConcurrentCall() throws Exception {
        var workspace = new BlockingWorkspace();
        try (var session = open(workspace, new ArrayList<>(), 10_000)) {
            var offer = session.offer();
            check(session.attach(GUEST_UID, GUEST_UID, offer.runId(), offer.nonce()), "Guest attach failed");
            String callId = id();
            AtomicReference<IsolatedCapabilityBroker.CallResult> first = new AtomicReference<>();
            Thread reader = new Thread(() -> first.set(session.dispatch(GUEST_UID, GUEST_UID,
                    request(offer, callId), () -> false)));
            reader.start();
            check(workspace.entered.await(2, TimeUnit.SECONDS), "Read did not start");
            var second = session.dispatch(GUEST_UID, GUEST_UID, request(offer, id()), () -> false);
            check(second.status() == IsolatedCapabilityBroker.Status.DENIED
                    && session.terminal() == IsolatedCapabilityBroker.Terminal.FAILED,
                    "Concurrent guest call was not terminally refused");
            workspace.release.countDown();
            reader.join(2000);
            check(!reader.isAlive() && first.get() != null, "In-flight call was not settled");
        }
        try (var session = open(new MemoryWorkspace(), new ArrayList<>(), 10_000)) {
            var offer = session.offer();
            check(session.attach(GUEST_UID, GUEST_UID, offer.runId(), offer.nonce()), "Guest attach failed");
            String callId = id();
            check(session.dispatch(GUEST_UID, GUEST_UID, request(offer, callId), () -> false).status()
                    == IsolatedCapabilityBroker.Status.OK, "First call failed");
            check(session.dispatch(GUEST_UID, GUEST_UID, request(offer, callId), () -> false).status()
                    == IsolatedCapabilityBroker.Status.DENIED, "Replay was accepted");
        }
    }

    private static void cancellationAndDeath() throws Exception {
        try (var cancelled = open(new MemoryWorkspace(), new ArrayList<>(), 10_000)) {
            var offer = cancelled.offer();
            check(cancelled.attach(GUEST_UID, GUEST_UID, offer.runId(), offer.nonce()), "Guest attach failed");
            cancelled.cancel();
            check(cancelled.terminal() == IsolatedCapabilityBroker.Terminal.CANCELLED,
                    "Cancellation did not revoke session");
        }
        try (var dead = open(new MemoryWorkspace(), new ArrayList<>(), 10_000)) {
            dead.workerDied();
            check(dead.terminal() == IsolatedCapabilityBroker.Terminal.WORKER_DIED,
                    "Binder death did not revoke session");
        }
        try (var vanishedAfterFinish = open(new MemoryWorkspace(), new ArrayList<>(), 10_000)) {
            var offer = vanishedAfterFinish.offer();
            check(vanishedAfterFinish.attach(GUEST_UID, GUEST_UID, offer.runId(), offer.nonce()),
                    "Guest attach failed");
            check(vanishedAfterFinish.proposeFinish(GUEST_UID, GUEST_UID, offer.runId(), offer.nonce()),
                    "FINISH proposal failed");
            vanishedAfterFinish.workerDied(); // Cleanup was not proven.
            check(vanishedAfterFinish.terminal() == IsolatedCapabilityBroker.Terminal.WORKER_DIED,
                    "Guest FINISH masked unconfirmed cleanup");
            check(vanishedAfterFinish.retiredAfterCleanup() == IsolatedCapabilityBroker.Terminal.WORKER_DIED,
                    "Late cleanup confirmation rewrote a failed terminal outcome");
        }
    }

    private static void leaseDeadline() throws Exception {
        try (var expired = open(new MemoryWorkspace(), new ArrayList<>(), 1_000)) {
            var offer = expired.offer();
            check(expired.attach(GUEST_UID, GUEST_UID, offer.runId(), offer.nonce()), "Guest attach failed");
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
            while (expired.terminal() == null && System.nanoTime() < deadline)
                Thread.sleep(20);
            check(expired.terminal() == IsolatedCapabilityBroker.Terminal.EXPIRED,
                    "Idle guest lease did not expire independently of calls");
            check(expired.dispatch(GUEST_UID, GUEST_UID, request(offer, id()), () -> false).status()
                    == IsolatedCapabilityBroker.Status.EXPIRED, "Late callback escaped expired lease");
        }
        try (var neverExited = open(new MemoryWorkspace(), new ArrayList<>(), 1_000)) {
            var offer = neverExited.offer();
            check(neverExited.attach(GUEST_UID, GUEST_UID, offer.runId(), offer.nonce()), "Guest attach failed");
            check(neverExited.proposeFinish(GUEST_UID, GUEST_UID, offer.runId(), offer.nonce()),
                    "FINISH proposal failed");
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
            while (neverExited.terminal() == null && System.nanoTime() < deadline) Thread.sleep(20);
            check(neverExited.terminal() == IsolatedCapabilityBroker.Terminal.EXPIRED,
                    "Guest FINISH silently succeeded while process remained alive");
        }
    }

    private static void finishAdmissionAndRetirement() throws Exception {
        try (var noFinish = open(new MemoryWorkspace(), new ArrayList<>(), 10_000)) {
            check(noFinish.retiredAfterCleanup() == IsolatedCapabilityBroker.Terminal.WORKER_DIED,
                    "Retirement without a FINISH proposal falsely completed");
        }
        try (var duplicate = open(new MemoryWorkspace(), new ArrayList<>(), 10_000)) {
            var offer = duplicate.offer();
            check(duplicate.attach(GUEST_UID, GUEST_UID, offer.runId(), offer.nonce()),
                    "Guest attach failed");
            check(duplicate.proposeFinish(GUEST_UID, GUEST_UID, offer.runId(), offer.nonce()),
                    "First FINISH proposal failed");
            check(!duplicate.proposeFinish(GUEST_UID, GUEST_UID, offer.runId(), offer.nonce())
                    && duplicate.terminal() == IsolatedCapabilityBroker.Terminal.FAILED,
                    "Duplicate FINISH remained admissible");
            check(duplicate.retiredAfterCleanup() == IsolatedCapabilityBroker.Terminal.FAILED,
                    "Late cleanup rewrote a duplicate-FINISH failure");
        }
        try (var lateCall = open(new MemoryWorkspace(), new ArrayList<>(), 10_000)) {
            var offer = lateCall.offer();
            check(lateCall.attach(GUEST_UID, GUEST_UID, offer.runId(), offer.nonce()),
                    "Guest attach failed");
            check(lateCall.proposeFinish(GUEST_UID, GUEST_UID, offer.runId(), offer.nonce()),
                    "FINISH proposal failed");
            check(lateCall.dispatch(GUEST_UID, GUEST_UID, request(offer, id()), () -> false).status()
                    == IsolatedCapabilityBroker.Status.DENIED
                    && lateCall.terminal() == IsolatedCapabilityBroker.Terminal.FAILED,
                    "Call after FINISH was admitted");
        }
    }

    private static void auditFailureAndLateCallback() throws Exception {
        var events = new ArrayList<IsolatedCapabilityBroker.Event>();
        try (var session = new IsolatedCapabilitySession(id(), new MemoryWorkspace(), event -> {
            if (event.phase() == IsolatedCapabilityBroker.Phase.CALL_SETTLED)
                throw new IOException("simulated audit fsync failure");
            events.add(event);
        }, List.of(new IsolatedCapabilityBroker.GrantSpec(PATH,
                Set.of(IsolatedCapabilityBroker.Action.READ))),
                IsolatedCapabilityBroker.SandboxPolicy.readOnly(Set.of(PATH)), 10_000, APP_UID)) {
            var offer = session.offer();
            check(session.attach(GUEST_UID, GUEST_UID, offer.runId(), offer.nonce()), "Guest attach failed");
            var result = session.dispatch(GUEST_UID, GUEST_UID, request(offer, id()), () -> false);
            check(result.status() == IsolatedCapabilityBroker.Status.AUDIT_UNCERTAIN
                    && session.auditUncertain(), "Audit failure was hidden by the dispatcher");
            check(session.dispatch(GUEST_UID, GUEST_UID, request(offer, id()), () -> false).status()
                    == IsolatedCapabilityBroker.Status.AUDIT_UNCERTAIN,
                    "Late callback escaped an uncertain audit terminal");
        }
    }

    private static IsolatedCapabilitySession open(IsolatedCapabilityBroker.WorkspaceOps workspace,
                                                   List<IsolatedCapabilityBroker.Event> audit,
                                                   long lease) throws IOException {
        return new IsolatedCapabilitySession(id(), workspace, audit::add,
                List.of(new IsolatedCapabilityBroker.GrantSpec(PATH,
                        Set.of(IsolatedCapabilityBroker.Action.READ))),
                IsolatedCapabilityBroker.SandboxPolicy.readOnly(Set.of(PATH)), lease, APP_UID);
    }
    private static IsolatedCapabilitySession.Request request(IsolatedCapabilitySession.Offer offer,
                                                              String callId) {
        return new IsolatedCapabilitySession.Request(offer.nonce(), IsolatedCapabilityBroker.Call.read(
                offer.runId(), callId, offer.grants().get(0).id()));
    }
    private static String id() { return UUID.randomUUID().toString(); }
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static class MemoryWorkspace implements IsolatedCapabilityBroker.WorkspaceOps {
        @Override public IsolatedCapabilityBroker.ReadData read(String filename, BooleanSupplier cancelled)
                throws Exception {
            check(PATH.equals(filename), "Broker selected an ungranted target");
            return new IsolatedCapabilityBroker.ReadData(REVISION, "allowed");
        }
        @Override public IsolatedCapabilityBroker.SearchData search(String filename, String query,
                int maxMatches, BooleanSupplier cancelled) { throw new AssertionError("Unexpected SEARCH"); }
        @Override public IsolatedCapabilityBroker.EditData edit(String filename, String expectedRevision,
                String needle, String replacement, int maxReplacements,
                BooleanSupplier cancelled) { throw new AssertionError("Unexpected EDIT"); }
    }
    private static final class BlockingWorkspace extends MemoryWorkspace {
        final CountDownLatch entered = new CountDownLatch(1);
        final CountDownLatch release = new CountDownLatch(1);
        @Override public IsolatedCapabilityBroker.ReadData read(String filename, BooleanSupplier cancelled)
                throws InterruptedException {
            entered.countDown();
            check(release.await(2, TimeUnit.SECONDS), "Test did not release read");
            return new IsolatedCapabilityBroker.ReadData(REVISION, "allowed");
        }
    }
}
