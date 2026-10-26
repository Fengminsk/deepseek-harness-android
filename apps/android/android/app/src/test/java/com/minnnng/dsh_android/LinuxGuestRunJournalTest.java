package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Comparator;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

/** Host contract tests. Android Binder identity and actual tracer retirement remain device gates. */
public final class LinuxGuestRunJournalTest {
    private static final String ID = "01234567-89ab-cdef-0123-456789abcdef";
    private static final String OUTPUT = "{\"exitCode\":0,\"stdout\":\"ok\"}";

    private static final class Fixture implements AutoCloseable {
        final Path root;
        final AtomicLong now = new AtomicLong(1_000_000_000L);
        final AtomicBoolean revokeOnCandidateSync = new AtomicBoolean();
        final AtomicBoolean revokeOnPublicationSync = new AtomicBoolean();
        final AtomicBoolean failPublicationSync = new AtomicBoolean();
        final LinuxGuestRunJournal journal;
        final IsolatedExecutionPolicyOwner owner;
        final LinuxGuestLaunchSession session;

        Fixture() throws Exception {
            Path cache = Paths.get(System.getProperty("dsh.test.cache",
                    System.getProperty("java.io.tmpdir"))).toRealPath();
            root = Files.createTempDirectory(cache, "guest-run-journal-");
            final IsolatedExecutionPolicyOwner[] holder = new IsolatedExecutionPolicyOwner[1];
            journal = new LinuxGuestRunJournal(root, directory -> {
                String name = directory.getFileName().toString();
                if ((name.equals("isolated-script-runs")
                        && revokeOnCandidateSync.compareAndSet(true, false))
                        || (name.equals("publications")
                        && revokeOnPublicationSync.compareAndSet(true, false))) {
                    holder[0].revoke(ID);
                }
                if (name.equals("publications")
                        && failPublicationSync.compareAndSet(true, false))
                    throw new IOException("Injected publication directory sync failure");
            });
            owner = new IsolatedExecutionPolicyOwner("owner", ID,
                    journal.admission(), (before, after) -> { }, now::get);
            holder[0] = owner;
            session = new LinuxGuestLaunchSession(
                    LinuxGuestSandboxPolicy.fromLease(owner.admit(ID)),
                    LinuxImageLeaseOwner.SHA256, "a".repeat(64), "b".repeat(64),
                    5_000, now::get);
        }

        void ready() {
            require(session.guestConnected(ID, 50000, 50000, 10000,
                    LinuxImageLeaseOwner.SHA256, "a".repeat(64), "b".repeat(64)));
            String trace = frame(1, "ROOT", 100, 0)
                    + frame(2, "ARM", 100, LinuxTraceeRetirementLedger.REQUIRED_OPTIONS)
                    + frame(3, "REAP", 100, 0) + frame(4, "DRAIN", 0, 0);
            byte[] bytes = trace.getBytes(StandardCharsets.US_ASCII);
            require(session.acceptTrace(bytes, 0, bytes.length));
            require(session.traceEnded(true, true, 0));
            require(session.readyToPersistSuccess());
        }

        @Override public void close() throws Exception {
            session.close();
            owner.close();
            Path cache = Paths.get(System.getProperty("dsh.test.cache",
                    System.getProperty("java.io.tmpdir"))).toRealPath();
            if (!root.toRealPath().startsWith(cache)
                    || !root.getFileName().toString().startsWith("guest-run-journal-"))
                throw new AssertionError("Unsafe test fixture cleanup");
            try (java.util.stream.Stream<Path> paths = Files.walk(root)) {
                for (Path path : paths.sorted(Comparator.reverseOrder()).toList())
                    Files.delete(path);
            }
        }
    }

    public static void main(String[] args) throws Exception {
        normalCompletionAndDuplicateTerminal();
        revocationBeforeDecisionLeavesUncertainCandidate();
        revocationAfterDecisionKeepsCompletedResult();
        publicationWriteFailureDoesNotPublish();
        publicationSyncFailureDoesNotPublish();
        serviceDeathAndAppRestartFailClosed();
        System.out.println("LinuxGuestRunJournalTest passed");
    }

    private static void normalCompletionAndDuplicateTerminal() throws Exception {
        try (Fixture f = new Fixture()) {
            f.ready();
            require(f.journal.complete(f.session, ID, OUTPUT));
            require(f.session.mayPublishSuccess());
            require(f.journal.read(ID).state() == IsolatedScriptReceipt.State.COMPLETED);
            require(!f.journal.complete(f.session, ID, OUTPUT));
            try {
                f.journal.fail(f.session, ID, IsolatedScriptReceipt.State.CANCELLED, "duplicate");
                throw new AssertionError("Duplicate terminal was accepted");
            } catch (IOException expected) { /* terminal is immutable */ }
            f.session.cancel();
            f.owner.revoke(ID);
            f.now.addAndGet(10_000_000_000L);
            require(f.session.mayPublishSuccess());
            require(f.journal.read(ID).state() == IsolatedScriptReceipt.State.COMPLETED);
            require(f.journal.recover().get(0).state() == IsolatedScriptReceipt.State.COMPLETED);
        }
    }

    private static void revocationBeforeDecisionLeavesUncertainCandidate() throws Exception {
        try (Fixture f = new Fixture()) {
            f.ready();
            f.revokeOnCandidateSync.set(true);
            require(!f.journal.complete(f.session, ID, OUTPUT));
            require(!f.session.mayPublishSuccess());
            require(f.journal.read(ID).state() == IsolatedScriptReceipt.State.INTERRUPTED_UNCONFIRMED);
            require(f.journal.recover().get(0).state()
                    == IsolatedScriptReceipt.State.INTERRUPTED_UNCONFIRMED);
            try {
                f.owner.admit(ID);
                throw new AssertionError("Uncertain run ID was replayed");
            } catch (IOException expected) { /* durable reservation survived */ }
        }
    }

    private static void revocationAfterDecisionKeepsCompletedResult() throws Exception {
        try (Fixture f = new Fixture()) {
            f.ready();
            f.revokeOnPublicationSync.set(true);
            require(f.journal.complete(f.session, ID, OUTPUT));
            require(f.session.mayPublishSuccess());
            require(f.journal.read(ID).state() == IsolatedScriptReceipt.State.COMPLETED);
        }
    }

    private static void publicationWriteFailureDoesNotPublish() throws Exception {
        try (Fixture f = new Fixture()) {
            f.ready();
            Path marker = f.root.resolve("linux-guest-runs").resolve("publications")
                    .resolve(ID + ".published");
            Files.createDirectory(marker);
            try {
                f.journal.complete(f.session, ID, OUTPUT);
                throw new AssertionError("Publication write failure was ignored");
            } catch (IOException expected) { /* durable candidate cannot be shown */ }
            require(!f.session.mayPublishSuccess());
            try {
                f.journal.read(ID);
                throw new AssertionError("Damaged marker was accepted");
            } catch (IOException expected) { /* reader fails closed */ }
        }
    }

    private static void publicationSyncFailureDoesNotPublish() throws Exception {
        try (Fixture f = new Fixture()) {
            f.ready();
            f.failPublicationSync.set(true);
            try {
                f.journal.complete(f.session, ID, OUTPUT);
                throw new AssertionError("Publication sync failure was ignored");
            } catch (IOException expected) { /* marker was withdrawn */ }
            require(!f.session.mayPublishSuccess());
            require(f.journal.read(ID).state()
                    == IsolatedScriptReceipt.State.INTERRUPTED_UNCONFIRMED);
        }
    }

    private static void serviceDeathAndAppRestartFailClosed() throws Exception {
        try (Fixture f = new Fixture()) {
            f.journal.serviceDied(f.session, ID);
            require(f.journal.read(ID).state() == IsolatedScriptReceipt.State.RETIRE_UNCONFIRMED);
            require(!f.session.mayPublishSuccess());
        }
        try (Fixture f = new Fixture()) {
            require(f.journal.recover().get(0).state()
                    == IsolatedScriptReceipt.State.INTERRUPTED_UNCONFIRMED);
            require(!f.session.mayPublishSuccess());
        }
    }

    private static String frame(int sequence, String event, int first, int second) {
        return "DSH_TRACE_V1\t" + ID + "\t" + sequence + "\t" + event
                + "\t" + first + "\t" + second + "\n";
    }

    private static void require(boolean condition) {
        if (!condition) throw new AssertionError("Guest journal published an uncertain result");
    }
}
