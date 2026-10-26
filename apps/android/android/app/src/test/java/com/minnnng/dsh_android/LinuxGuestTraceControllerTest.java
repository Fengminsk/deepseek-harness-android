package com.minnnng.dsh_android;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Comparator;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;

/** Host-only stream, lifecycle and durability tests; native device proof is a separate gate. */
public final class LinuxGuestTraceControllerTest {
    private static final String ID = "01234567-89ab-cdef-0123-456789abcdef";
    private static final String CALL = "11111111-1111-1111-1111-111111111111";

    private static final class Source implements LinuxGuestTraceController.SupervisorSource {
        InputStream out = new ByteArrayInputStream(trace().getBytes(StandardCharsets.US_ASCII));
        InputStream err = new ByteArrayInputStream(new byte[0]);
        Integer exit = 0;
        Runnable onWait = () -> { };
        final AtomicBoolean killed = new AtomicBoolean();
        @Override public InputStream stdout() { return out; }
        @Override public InputStream stderr() { return err; }
        @Override public Integer awaitExit(long millis) {
            onWait.run();
            return exit;
        }
        @Override public void cancel() { killed.set(true); }
    }

    private static final class Fixture implements AutoCloseable {
        final Path root;
        final Path workspace;
        final LinuxGuestRunJournal journal;
        final IsolatedExecutionPolicyOwner owner;
        final LinuxGuestLaunchSession session;
        final Source source = new Source();

        Fixture(boolean brokerScope, boolean failPublication) throws Exception {
            Path cache = Paths.get(System.getProperty("dsh.test.cache",
                    System.getProperty("java.io.tmpdir"))).toRealPath();
            root = Files.createTempDirectory(cache, "guest-trace-controller-");
            workspace = Files.createDirectory(root.resolve("workspace"));
            journal = new LinuxGuestRunJournal(root, directory -> {
                if (failPublication && directory.getFileName().toString().equals("publications"))
                    throw new IOException("Injected publication sync failure");
            });
            owner = new IsolatedExecutionPolicyOwner("owner", ID,
                    journal.admission(), (before, after) -> { }, System::nanoTime);
            if (brokerScope)
                owner.replace(IsolatedExecutionPolicyOwner.Scope.granted("owner", ID, 2,
                        root, workspace, Set.of("notes.txt"), Set.of("notes.txt"),
                        Set.of("example.com"), 3, 3, 30_000));
            session = new LinuxGuestLaunchSession(
                    LinuxGuestSandboxPolicy.fromLease(owner.admit(ID)),
                    LinuxImageLeaseOwner.SHA256, "a".repeat(64), "b".repeat(64), 5_000);
            require(session.guestConnected(ID, 50000, 50000, 10000,
                    LinuxImageLeaseOwner.SHA256, "a".repeat(64), "b".repeat(64)));
        }

        LinuxGuestTraceController controller(long millis) {
            return new LinuxGuestTraceController(session, journal, ID, source, millis);
        }

        @Override public void close() throws Exception {
            session.close();
            owner.close();
            Path cache = Paths.get(System.getProperty("dsh.test.cache",
                    System.getProperty("java.io.tmpdir"))).toRealPath();
            if (!root.toRealPath().startsWith(cache)
                    || !root.getFileName().toString().startsWith("guest-trace-controller-"))
                throw new AssertionError("Unsafe test fixture cleanup");
            try (java.util.stream.Stream<Path> paths = Files.walk(root)) {
                for (Path path : paths.sorted(Comparator.reverseOrder()).toList())
                    Files.delete(path);
            }
        }
    }

    public static void main(String[] args) throws Exception {
        completesOnlyAfterJournalMarker();
        rejectsTruncatedTrace();
        rejectsMissingStdoutEof();
        rejectsMissingStderrEof();
        rejectsDeadline();
        rejectsProcessDeath();
        rejectsCancellationAndLateExit();
        rejectsPendingBrokerCall();
        rejectsPublicationFailure();
        System.out.println("LinuxGuestTraceControllerTest passed");
    }

    private static void completesOnlyAfterJournalMarker() throws Exception {
        try (Fixture f = new Fixture(false, false)) {
            require(f.controller(1_000).observe());
            require(f.source.killed.get());
            require(f.session.mayPublishSuccess());
            require(f.journal.read(ID).state() == IsolatedScriptReceipt.State.COMPLETED);
        }
    }

    private static void rejectsTruncatedTrace() throws Exception {
        try (Fixture f = new Fixture(false, false)) {
            byte[] full = trace().getBytes(StandardCharsets.US_ASCII);
            f.source.out = new ByteArrayInputStream(full, 0, full.length - 1);
            require(!f.controller(1_000).observe());
            unsuccessful(f);
        }
    }

    private static void rejectsMissingStdoutEof() throws Exception {
        try (Fixture f = new Fixture(false, false)) {
            f.source.out = new InputStream() {
                @Override public int read() throws IOException { throw new IOException("pipe broke before EOF"); }
            };
            require(!f.controller(1_000).observe());
            unsuccessful(f);
        }
    }

    private static void rejectsProcessDeath() throws Exception {
        try (Fixture f = new Fixture(false, false)) {
            f.source.exit = 9;
            require(!f.controller(1_000).observe());
            require(f.journal.read(ID).state() == IsolatedScriptReceipt.State.WORKER_DIED);
            unsuccessful(f);
        }
    }

    private static void rejectsMissingStderrEof() throws Exception {
        try (Fixture f = new Fixture(false, false)) {
            f.source.err = new InputStream() {
                @Override public int read() throws IOException { throw new IOException("stderr pipe broke"); }
            };
            require(!f.controller(1_000).observe());
            unsuccessful(f);
        }
    }

    private static void rejectsDeadline() throws Exception {
        try (Fixture f = new Fixture(false, false)) {
            f.source.exit = null;
            require(!f.controller(1_000).observe());
            require(f.journal.read(ID).state() == IsolatedScriptReceipt.State.TIMED_OUT);
            unsuccessful(f);
        }
    }

    private static void rejectsCancellationAndLateExit() throws Exception {
        try (Fixture f = new Fixture(false, false)) {
            LinuxGuestTraceController controller = f.controller(1_000);
            f.source.onWait = controller::cancel;
            require(!controller.observe());
            require(f.journal.read(ID).state() == IsolatedScriptReceipt.State.CANCELLED);
            unsuccessful(f);
        }
    }

    private static void rejectsPendingBrokerCall() throws Exception {
        try (Fixture f = new Fixture(true, false)) {
            require(f.session.beginFileCall(CALL, "/workspace/notes.txt",
                    IsolatedCapabilityBroker.Action.READ));
            require(!f.controller(1_000).observe());
            unsuccessful(f);
        }
    }

    private static void rejectsPublicationFailure() throws Exception {
        try (Fixture f = new Fixture(false, true)) {
            try {
                f.controller(1_000).observe();
                throw new AssertionError("Publication failure was ignored");
            } catch (IOException expected) { /* candidate remains unpublishable */ }
            require(!f.session.mayPublishSuccess());
            require(f.journal.read(ID).state()
                    == IsolatedScriptReceipt.State.INTERRUPTED_UNCONFIRMED);
        }
    }

    private static void unsuccessful(Fixture f) throws IOException {
        require(!f.session.mayPublishSuccess());
        require(f.journal.read(ID).state() != IsolatedScriptReceipt.State.COMPLETED);
    }

    private static String trace() {
        return frame(1, "ROOT", 100, 0)
                + frame(2, "ARM", 100, LinuxTraceeRetirementLedger.REQUIRED_OPTIONS)
                + frame(3, "REAP", 100, 0) + frame(4, "DRAIN", 0, 0);
    }

    private static String frame(int sequence, String event, int first, int second) {
        return "DSH_TRACE_V1\t" + ID + "\t" + sequence + "\t" + event
                + "\t" + first + "\t" + second + "\n";
    }

    private static void require(boolean condition) {
        if (!condition) throw new AssertionError("Unconfirmed guest run was published");
    }
}
