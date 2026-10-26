package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.List;
import java.util.UUID;

/** Pure-Java recovery checks; Android directory durability still needs device evidence. */
public final class IsolatedCapabilityJournalRecoveryTest {
    private static final String OWNER = "task:recovery";
    private static final String TARGET = "work/notes.txt";
    private static final String REVISION = "a".repeat(64);

    public static void main(String[] args) throws Exception {
        completeHistoryCanBeArchived();
        unfinishedReadNeedsInspection();
        unfinishedEditRetainsExpectedRevision();
        uncertainEditNeedsInspectionEvenAfterFinish();
        tornAndMalformedFramesFailClosed();
        uncertainDirectorySyncCannotReopenAdmission();
    }

    private static void completeHistoryCanBeArchived() throws Exception {
        withRoot(root -> {
            var journal = journal(root);
            journal.requireCleanAdmission();
            String run = id(), call = id(), grant = id();
            journal.record(event(IsolatedCapabilityBroker.Phase.RUN_OPENED, run, null, null,
                    null, null, null, null, null));
            admissionDenied(journal);
            journal.record(event(IsolatedCapabilityBroker.Phase.CALL_STARTED, run, call, grant,
                    IsolatedCapabilityBroker.Action.READ, null, null, null, null));
            journal.record(event(IsolatedCapabilityBroker.Phase.CALL_SETTLED, run, call, grant,
                    IsolatedCapabilityBroker.Action.READ, IsolatedCapabilityBroker.Status.OK, null, null, null));
            journal.record(event(IsolatedCapabilityBroker.Phase.RUN_FINISHED, run, null, null,
                    null, null, IsolatedCapabilityBroker.Terminal.COMPLETED, null, null));
            check(journal.inspect().canAppend(), "Complete history was classified as unresolved");
            journal.requireCleanAdmission();
            var reopened = journal(root);
            check(reopened.startupReport().canAppend(), "Complete history did not recover on startup");
            Path archive = reopened.archiveSettled();
            check(Files.isRegularFile(archive) && Files.size(archive) > 0,
                    "Archival lost the settled history");
            String nextRun = id();
            reopened.record(event(IsolatedCapabilityBroker.Phase.RUN_OPENED, nextRun, null, null,
                    null, null, null, null, null));
            reopened.record(event(IsolatedCapabilityBroker.Phase.RUN_FINISHED, nextRun, null, null,
                    null, null, IsolatedCapabilityBroker.Terminal.COMPLETED, null, null));
            check(reopened.inspect().canAppend(), "New journal could not accept work after archival");
        });
    }

    private static void unfinishedReadNeedsInspection() throws Exception {
        withRoot(root -> {
            var journal = journal(root);
            String run = id(), call = id(), grant = id();
            journal.record(event(IsolatedCapabilityBroker.Phase.RUN_OPENED, run, null, null,
                    null, null, null, null, null));
            journal.record(event(IsolatedCapabilityBroker.Phase.CALL_STARTED, run, call, grant,
                    IsolatedCapabilityBroker.Action.READ, null, null, null, null));
            // A terminal event can precede settlement of an in-flight call.
            journal.record(event(IsolatedCapabilityBroker.Phase.RUN_FINISHED, run, null, null,
                    null, null, IsolatedCapabilityBroker.Terminal.WORKER_DIED, null, null));
            var reopened = journal(root);
            var report = reopened.startupReport();
            check(report.requiresInspection() && !report.runs().get(0).unfinished()
                    && report.runs().get(0).calls().get(0).callId().equals(call)
                    && report.runs().get(0).calls().get(0).reason().equals("CALL_NOT_SETTLED"),
                    "In-flight read was hidden by the terminal event");
            denied(reopened, root);
            admissionDenied(reopened);
        });
    }

    private static void unfinishedEditRetainsExpectedRevision() throws Exception {
        withRoot(root -> {
            var journal = journal(root);
            String run = id(), call = id(), grant = id();
            journal.record(event(IsolatedCapabilityBroker.Phase.RUN_OPENED, run, null, null,
                    null, null, null, null, null));
            journal.record(event(IsolatedCapabilityBroker.Phase.CALL_STARTED, run, call, grant,
                    IsolatedCapabilityBroker.Action.EDIT, null, null, REVISION, null));
            var report = journal(root).startupReport();
            var review = report.runs().get(0);
            check(review.unfinished() && review.calls().get(0).action() == IsolatedCapabilityBroker.Action.EDIT
                    && REVISION.equals(review.calls().get(0).expectedRevision())
                    && review.calls().get(0).resultRevision() == null,
                    "Unsettled edit lost the revision needed for manual inspection");
            denied(journal(root), root);
            admissionDenied(journal(root));
        });
    }

    private static void uncertainEditNeedsInspectionEvenAfterFinish() throws Exception {
        withRoot(root -> {
            var journal = journal(root);
            String run = id(), call = id(), grant = id();
            journal.record(event(IsolatedCapabilityBroker.Phase.RUN_OPENED, run, null, null,
                    null, null, null, null, null));
            journal.record(event(IsolatedCapabilityBroker.Phase.CALL_STARTED, run, call, grant,
                    IsolatedCapabilityBroker.Action.EDIT, null, null, REVISION, null));
            journal.record(event(IsolatedCapabilityBroker.Phase.CALL_SETTLED, run, call, grant,
                    IsolatedCapabilityBroker.Action.EDIT, IsolatedCapabilityBroker.Status.COMMIT_UNCERTAIN,
                    null, REVISION, "b".repeat(64)));
            journal.record(event(IsolatedCapabilityBroker.Phase.RUN_FINISHED, run, null, null,
                    null, null, IsolatedCapabilityBroker.Terminal.FAILED, null, null));
            var report = journal(root).startupReport();
            check(report.requiresInspection()
                    && "b".repeat(64).equals(report.runs().get(0).calls().get(0).resultRevision())
                    && "COMMIT_UNCERTAIN".equals(report.runs().get(0).calls().get(0).reason()),
                    "Completed run hid a potentially committed edit");
            denied(journal(root), root);
            admissionDenied(journal(root));
        });
    }

    private static void tornAndMalformedFramesFailClosed() throws Exception {
        for (String damage : List.of("{\"v\":1", "{\"unexpected\":true}\n", "\u00ff\n")) {
            withRoot(root -> {
                var journal = journal(root);
                String run = id();
                journal.record(event(IsolatedCapabilityBroker.Phase.RUN_OPENED, run, null, null,
                        null, null, null, null, null));
                Files.write(root.resolve("isolated-capabilities.jsonl"),
                        damage.equals("\u00ff\n") ? new byte[] {(byte)0xff, '\n'}
                                : damage.getBytes(StandardCharsets.UTF_8),
                        java.nio.file.StandardOpenOption.APPEND);
                var reopened = journal(root);
                check(reopened.startupReport().damaged() && reopened.startupReport().requiresInspection(),
                        "Damaged journal frame was accepted");
                denied(reopened, root);
                admissionDenied(reopened);
            });
        }
    }

    private static void uncertainDirectorySyncCannotReopenAdmission() throws Exception {
        withRoot(root -> {
            var journal = new IsolatedCapabilityJournal(root, ignored -> {
                throw new IOException("Injected directory sync failure");
            });
            journal.requireCleanAdmission();
            try {
                journal.record(event(IsolatedCapabilityBroker.Phase.RUN_OPENED, id(), null, null,
                        null, null, null, null, null));
                throw new AssertionError("Directory sync failure did not fail the record");
            } catch (IOException expected) { /* A complete-looking line is not a confirmed append. */ }
            admissionDenied(journal);
            admissionDenied(journal(root));
        });
    }

    private static void admissionDenied(IsolatedCapabilityJournal journal) throws Exception {
        try {
            journal.requireCleanAdmission();
            throw new AssertionError("Unresolved capability journal admitted another file grant");
        } catch (IOException expected) { /* The App must inspect the retained facts. */ }
    }

    private static IsolatedCapabilityBroker.Event event(IsolatedCapabilityBroker.Phase phase,
            String run, String call, String grant, IsolatedCapabilityBroker.Action action,
            IsolatedCapabilityBroker.Status status, IsolatedCapabilityBroker.Terminal terminal,
            String expected, String result) {
        return new IsolatedCapabilityBroker.Event(phase, OWNER, run, call, grant,
                call == null ? null : TARGET, null, action, status, terminal, expected, result);
    }

    private static void denied(IsolatedCapabilityJournal journal, Path root) throws Exception {
        try {
            journal.record(event(IsolatedCapabilityBroker.Phase.RUN_OPENED, id(), null, null,
                    null, null, null, null, null));
            throw new AssertionError("Unresolved journal admitted another run");
        } catch (IOException expected) { /* Recovery review owns the unresolved state. */ }
        try {
            journal.archiveSettled();
            throw new AssertionError("Unresolved journal was archived");
        } catch (IOException expected) { /* Archival must preserve unresolved facts. */ }
        check(Files.exists(root.resolve("isolated-capabilities.jsonl")),
                "Denial removed the audit evidence");
    }

    private static IsolatedCapabilityJournal journal(Path root) throws IOException {
        return new IsolatedCapabilityJournal(root, ignored -> {});
    }
    private static String id() { return UUID.randomUUID().toString(); }
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    private interface TestBody { void run(Path root) throws Exception; }
    private static void withRoot(TestBody body) throws Exception {
        Path root = Files.createTempDirectory("capability-recovery-");
        try { body.run(root); }
        finally {
            try (var paths = Files.walk(root)) {
                for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.delete(path);
            }
        }
    }
}
