package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

/** Host-only durable admission and uncertain-terminal tests; no network is contacted. */
public final class IsolatedNetworkJournalTest {
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
    private interface Operation { void run() throws Exception; }
    private static void refuses(Operation operation) throws Exception {
        try { operation.run(); }
        catch (IOException expected) { return; }
        throw new AssertionError("Duplicate or damaged audit was accepted");
    }

    public static void main(String[] args) throws Exception {
        Path root = Files.createTempDirectory("isolated-network-journal-");
        try {
            AtomicInteger syncs = new AtomicInteger();
            IsolatedNetworkJournal journal = new IsolatedNetworkJournal(root,
                    ignored -> syncs.incrementAndGet());
            String id = UUID.randomUUID().toString();
            journal.admit(id, "api.example.org");
            check(syncs.get() >= 2, "Directory admission was not synced");
            IsolatedNetworkJournal.Entry admitted = journal.read(id);
            check(admitted.state() == IsolatedNetworkJournal.State.ADMITTED
                    && admitted.status() == null && !admitted.transportEntered(),
                    "Admitted audit did not preserve uncertain state");
            refuses(() -> journal.admit(id, "api.example.org"));
            journal.finish(id, IsolatedNetworkBroker.Status.OK, true);
            IsolatedNetworkJournal.Entry terminal = journal.read(id);
            check(terminal.state() == IsolatedNetworkJournal.State.TERMINAL
                    && terminal.status() == IsolatedNetworkBroker.Status.OK
                    && terminal.transportEntered() && terminal.host().equals("api.example.org"),
                    "Terminal audit lost its call result");
            refuses(() -> journal.finish(id, IsolatedNetworkBroker.Status.CANCELLED, true));

            String truncated = UUID.randomUUID().toString();
            journal.admit(truncated, "api.example.org");
            Path file = root.resolve("isolated-network-calls").resolve(truncated + ".audit");
            Files.write(file, new byte[] {1, 2, 3});
            refuses(() -> journal.read(truncated));
            refuses(() -> journal.admit(truncated, "api.example.org"));
            String next = UUID.randomUUID().toString();
            journal.admit(next, "api.example.org");
            journal.finish(next, IsolatedNetworkBroker.Status.CANCELLED, false);
            check(journal.read(next).status() == IsolatedNetworkBroker.Status.CANCELLED,
                    "Damaged call blocked unrelated admission");

            IsolatedNetworkJournal uncertain = new IsolatedNetworkJournal(root, directory -> {
                if (directory.endsWith("isolated-network-calls"))
                    throw new IOException("Injected directory sync failure");
            });
            String uncertainId = UUID.randomUUID().toString();
            refuses(() -> uncertain.admit(uncertainId, "api.example.org"));
            refuses(() -> journal.admit(uncertainId, "api.example.org"));
            check(journal.read(uncertainId).state() == IsolatedNetworkJournal.State.ADMITTED,
                    "Failed sync erased uncertain admission");

            Path quotaParent = Files.createDirectory(root.resolve("quota-parent"));
            var bounded = new IsolatedNetworkJournal(quotaParent, ignored -> {}, 1, 4096);
            String retainedId = UUID.randomUUID().toString();
            bounded.admit(retainedId, "api.example.org");
            var restarted = new IsolatedNetworkJournal(quotaParent, ignored -> {}, 1, 4096);
            try {
                restarted.admit(UUID.randomUUID().toString(), "api.example.org");
                throw new AssertionError("File quota admitted an additional call");
            } catch (IsolatedNetworkJournal.CapacityExceededException expected) { /* fail closed */ }
            refuses(() -> restarted.admit(retainedId, "api.example.org"));
            check(restarted.read(retainedId).state() == IsolatedNetworkJournal.State.ADMITTED,
                    "Quota removed an uncertain call ID after restart");

            Path tempParent = Files.createDirectory(root.resolve("temp-parent"));
            var tempBounded = new IsolatedNetworkJournal(tempParent, ignored -> {}, 4, 4096);
            String tempId = UUID.randomUUID().toString();
            tempBounded.admit(tempId, "api.example.org");
            Files.write(tempParent.resolve("isolated-network-calls/network-crash.tmp"),
                    new byte[2048]);
            var tempRestarted = new IsolatedNetworkJournal(tempParent, ignored -> {}, 4, 4096);
            try {
                tempRestarted.admit(UUID.randomUUID().toString(), "api.example.org");
                throw new AssertionError("Crash-left temp bytes were excluded from capacity");
            } catch (IsolatedNetworkJournal.CapacityExceededException expected) { /* fail closed */ }
            check(tempRestarted.read(tempId).state() == IsolatedNetworkJournal.State.ADMITTED,
                    "Crash-left temp handling erased the original receipt");
            System.out.println("IsolatedNetworkJournalTest PASS");
        } finally {
            if (!root.toAbsolutePath().normalize().getParent().equals(
                    Path.of(System.getProperty("java.io.tmpdir")).toAbsolutePath().normalize()))
                throw new AssertionError("Refusing to remove unrelated audit test files");
            try (var files = Files.walk(root)) {
                files.sorted(Comparator.reverseOrder()).forEach(path -> {
                    try { Files.delete(path); }
                    catch (IOException error) { throw new java.io.UncheckedIOException(error); }
                });
            }
        }
    }
}
