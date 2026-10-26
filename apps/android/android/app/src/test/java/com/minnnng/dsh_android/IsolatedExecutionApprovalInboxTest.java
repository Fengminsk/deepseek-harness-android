package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

public final class IsolatedExecutionApprovalInboxTest {
    private static final String PROGRAM = "(input) => input.value + 1";
    private static final String INPUT = "{\"value\":1}";
    private static final int DEADLINE = 1000;
    private static String id() { return UUID.randomUUID().toString(); }
    private static void check(boolean condition, String detail) {
        if (!condition) throw new AssertionError(detail);
    }
    private static void rejects(Checked action) throws Exception {
        try { action.run(); throw new AssertionError("Stale or forged approval succeeded"); }
        catch (IllegalArgumentException | IllegalStateException expected) { /* Denied. */ }
    }
    private interface Checked { void run() throws Exception; }

    private static final class Decision implements IsolatedExecutionApprovalInbox.Decision {
        final AtomicInteger approvals = new AtomicInteger();
        final AtomicInteger denials = new AtomicInteger();
        boolean failApproval;
        @Override public void approve(IsolatedExecutionPolicyOwner.Scope scope,
                                      String runId, String approvalId) throws IOException {
            check(scope.version() == 2 && UUID.fromString(runId) != null
                    && UUID.fromString(approvalId) != null, "Scope or one-run identity changed");
            approvals.incrementAndGet();
            if (failApproval) throw new IOException("Uncertain durable write");
        }
        @Override public void deny(String runId) { denials.incrementAndGet(); }
    }

    public static void main(String[] args) throws Exception {
        Path root = Files.createTempDirectory("approval-inbox-");
        Path workspace = Files.createDirectory(root.resolve("work"));
        Path secondWorkspace = Files.createDirectory(
                Files.createDirectory(root.resolve("other")).resolve("work"));
        String session = id();
        var scope = IsolatedExecutionPolicyOwner.Scope.granted("task", session, 2,
                root, workspace, Set.of("notes/"), Set.of("notes/out.txt"),
                Set.of("example.com"), 4, 2, 8_000);
        AtomicLong clock = new AtomicLong(1_000);
        var inbox = new IsolatedExecutionApprovalInbox(clock::get);
        Decision first = new Decision();
        String runId = id();
        var review = inbox.prepare(runId, scope, PROGRAM, INPUT, DEADLINE, first);
        check(inbox.list().size() == 1 && review.workspacePath().equals(workspace.toRealPath().toString())
                && review.readablePaths().equals(java.util.List.of("notes/"))
                && review.writablePaths().equals(java.util.List.of("notes/out.txt"))
                && review.exactHosts().equals(java.util.List.of("example.com")),
                "Review failed to expose the exact bounded scope");
        check(review.program().equals(PROGRAM) && review.programSha256().length() == 64
                && review.snapshotSha256().length() == 64
                && inbox.list().get(0).snapshotSha256().equals(review.snapshotSha256()),
                "Review did not preserve the immutable program and digest");
        var secondScope = IsolatedExecutionPolicyOwner.Scope.granted("task", session, 2,
                root, secondWorkspace, Set.of("notes/"), Set.of("notes/out.txt"),
                Set.of("example.com"), 4, 2, 8_000);
        var secondReview = inbox.prepare(id(), secondScope, PROGRAM, INPUT, DEADLINE, new Decision());
        check(!review.workspacePath().equals(secondReview.workspacePath())
                && review.workspacePath().endsWith("work")
                && secondReview.workspacePath().endsWith("work"),
                "Same-named workspaces were indistinguishable in approval review");
        inbox.deny(secondReview.id(), secondReview.challenge());
        rejects(() -> inbox.approve(review.id(), id(), review.snapshotSha256()));
        rejects(() -> inbox.approve(review.id(), review.challenge(), secondReview.snapshotSha256()));
        rejects(() -> inbox.prepare(runId, scope, PROGRAM, INPUT, DEADLINE, new Decision()));
        check(first.approvals.get() == 0, "Forged challenge authorized a run");
        inbox.approve(review.id(), review.challenge(), review.snapshotSha256());
        check(first.approvals.get() == 1 && inbox.list().get(0).active(),
                "Exact review did not authorize once");
        rejects(() -> inbox.approve(review.id(), review.challenge(), review.snapshotSha256()));
        inbox.deny(review.id(), review.challenge());
        check(first.denials.get() == 1 && inbox.list().isEmpty(),
                "Revocation did not consume the active decision");
        rejects(() -> inbox.approve(review.id(), review.challenge(), review.snapshotSha256()));

        Decision expired = new Decision();
        var older = inbox.prepare(id(), scope, PROGRAM, INPUT, DEADLINE, expired);
        clock.set(older.expiresAtMillis());
        check(inbox.list().isEmpty() && expired.denials.get() == 1,
                "Expired review was still actionable or left its owner open");
        rejects(() -> inbox.approve(older.id(), older.challenge(), older.snapshotSha256()));

        Decision finished = new Decision();
        var timeBound = inbox.prepare(id(), scope, PROGRAM, INPUT, DEADLINE, finished);
        inbox.approve(timeBound.id(), timeBound.challenge(), timeBound.snapshotSha256());
        clock.set(timeBound.expiresAtMillis() + scope.leaseMillis());
        check(inbox.list().isEmpty() && finished.denials.get() == 1,
                "Finished grant was not retired after its bounded review and lease");

        Decision uncertain = new Decision();
        uncertain.failApproval = true;
        var failed = inbox.prepare(id(), scope, PROGRAM, INPUT, DEADLINE, uncertain);
        try { inbox.approve(failed.id(), failed.challenge(), failed.snapshotSha256());
            throw new AssertionError("Uncertain approval appeared successful");
        } catch (IOException expected) { /* No retry. */ }
        check(uncertain.approvals.get() == 1 && uncertain.denials.get() == 1
                && inbox.list().isEmpty(), "Uncertain approval was replayable");
        rejects(() -> inbox.approve(failed.id(), failed.challenge(), failed.snapshotSha256()));
        rejects(() -> inbox.prepare(id(), IsolatedExecutionPolicyOwner.Scope.denied(
                "task", session, 2), PROGRAM, INPUT, DEADLINE, new Decision()));
        inbox.close();
        rejects(() -> inbox.prepare(id(), scope, PROGRAM, INPUT, DEADLINE, new Decision()));
        System.out.println("IsolatedExecutionApprovalInboxTest passed");
    }
}
