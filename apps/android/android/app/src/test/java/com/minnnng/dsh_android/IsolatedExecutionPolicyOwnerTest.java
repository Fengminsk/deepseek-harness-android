package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

public final class IsolatedExecutionPolicyOwnerTest {
    private static String id() { return UUID.randomUUID().toString(); }
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    private static void rejects(Runnable action, String message) {
        try { action.run(); throw new AssertionError(message); }
        catch (IllegalArgumentException | IllegalStateException expected) { /* Invalid input did not acquire authority. */ }
    }

    public static void main(String[] arguments) throws Exception {
        defaultDenyAndDurableReservation();
        failedReservationClosesOwner();
        scopedChildAndRevocation();
        rejectedPolicyChangeClosesOwner();
        invalidWorkspaceAndGrants();
        receiptBackedAdmissionIsSingleUse();
        revocationHooksAreSynchronous();
        reentrantRevocationCannotRetainOldAuthority();
        childDeadlineCannotOutliveParent();
        System.out.println("IsolatedExecutionPolicyOwnerTest passed");
    }

    private static void childDeadlineCannotOutliveParent() throws Exception {
        String ownerId = "deadline.task";
        String sessionId = id();
        AtomicLong clock = new AtomicLong();
        var owner = new IsolatedExecutionPolicyOwner(ownerId, sessionId,
                (runId, scope) -> {}, (before, after) -> {}, clock::get);
        var parent = owner.admit(id());
        clock.addAndGet(100_000_000L);
        var child = owner.admitChild(parent.runId(), id(), parent.policy());
        check(child.deadlineNanos() == parent.deadlineNanos(),
                "Child network deadline extended beyond its parent policy lease");
    }

    private static void revocationHooksAreSynchronous() throws Exception {
        String ownerId = "hook.task";
        String sessionId = id();
        var owner = new IsolatedExecutionPolicyOwner(ownerId, sessionId,
                (runId, scope) -> {}, (before, after) -> {});
        var parent = owner.admit(id());
        var child = owner.admitChild(parent.runId(), id(), parent.policy());
        AtomicInteger parentCalls = new AtomicInteger();
        AtomicInteger childCalls = new AtomicInteger();
        parent.onRevoked(parentCalls::incrementAndGet);
        child.onRevoked(childCalls::incrementAndGet);
        owner.revoke(parent.runId());
        check(parentCalls.get() == 1 && childCalls.get() == 1,
                "Parent revocation did not synchronously cancel all descendant capabilities");
        parent.onRevoked(parentCalls::incrementAndGet);
        check(parentCalls.get() == 2, "Late revocation registration was not cancelled immediately");

        var replaced = owner.admit(id());
        AtomicInteger replaceCalls = new AtomicInteger();
        replaced.onRevoked(replaceCalls::incrementAndGet);
        owner.replace(IsolatedExecutionPolicyOwner.Scope.denied(ownerId, sessionId, 2));
        check(replaceCalls.get() == 1, "Policy replacement returned before capability cancellation");

        var closed = owner.admit(id());
        AtomicInteger closeCalls = new AtomicInteger();
        closed.onRevoked(closeCalls::incrementAndGet);
        owner.close();
        check(closeCalls.get() == 1, "Policy owner closed without cancelling capabilities");
    }

    private static void reentrantRevocationCannotRetainOldAuthority() throws Exception {
        String ownerId = "reentrant.task";
        String sessionId = id();
        AtomicInteger reservations = new AtomicInteger();
        var owner = new IsolatedExecutionPolicyOwner(ownerId, sessionId,
                (runId, scope) -> reservations.incrementAndGet(), (before, after) -> {});
        var first = owner.admit(id());
        AtomicInteger refusedDuringReplace = new AtomicInteger();
        first.onRevoked(() -> {
            try { owner.admit(id()); throw new AssertionError("Old policy admitted a callback run"); }
            catch (IllegalStateException expected) { refusedDuringReplace.incrementAndGet(); }
            catch (IOException failure) { throw new AssertionError(failure); }
        });
        owner.replace(IsolatedExecutionPolicyOwner.Scope.denied(ownerId, sessionId, 2));
        check(refusedDuringReplace.get() == 1 && reservations.get() == 1,
                "Policy replacement allowed reentrant admission before recording");

        var parent = owner.admit(id());
        var child = owner.admitChild(parent.runId(), id(), parent.policy());
        parent.onRevoked(() -> owner.revoke(child.runId()));
        owner.revoke(parent.runId());
        check(!parent.active(2) && !child.active(2),
                "Reentrant descendant revocation retained authority");
    }

    private static void defaultDenyAndDurableReservation() throws Exception {
        String owner = "task.1";
        String session = id();
        Set<String> reserved = new HashSet<>();
        AtomicInteger records = new AtomicInteger();
        AtomicLong clock = new AtomicLong();
        var policy = new IsolatedExecutionPolicyOwner(owner, session,
                (runId, scope) -> {
                    if (!reserved.add(runId)) throw new IOException("Duplicate durable run ID");
                    check(scope.readablePaths().isEmpty() && scope.writablePaths().isEmpty()
                            && scope.exactHosts().isEmpty(), "First admission was not default deny");
                }, (before, after) -> records.incrementAndGet(), clock::get);
        check(policy.current().version() == 1 && policy.current().workspaceRoot() == null,
                "Default scope was not empty");
        String first = id();
        var old = policy.admit(first);
        check(old.active(1), "Durably admitted lease is inactive");
        try { old.policy().readablePaths().add("private"); throw new AssertionError("Scope set was mutable"); }
        catch (UnsupportedOperationException expected) { /* Callers cannot mutate the App snapshot. */ }
        try { policy.admit(first); throw new AssertionError("Live run ID replayed"); }
        catch (IOException expected) { check(reserved.size() == 1, "Duplicate changed reservation"); }

        policy.replace(IsolatedExecutionPolicyOwner.Scope.denied(owner, session, 2));
        check(records.get() == 1 && !old.active(1), "Policy version did not revoke old lease");
        String second = id();
        var next = policy.admit(second);
        check(next.active(2) && !next.active(1), "Policy version was not checked at callback");
        clock.addAndGet(next.policy().leaseMillis() * 1_000_000L);
        check(!next.active(2), "Expired lease remained active");
        policy.close();
        check(!next.active(2), "Closed owner retained a lease");

        var restarted = new IsolatedExecutionPolicyOwner(owner, session,
                (runId, scope) -> {
                    if (!reserved.add(runId)) throw new IOException("Duplicate durable run ID");
                }, (before, after) -> {});
        check(restarted.current().readablePaths().isEmpty()
                && restarted.current().exactHosts().isEmpty(), "Restart restored authority");
        try { restarted.admit(first); throw new AssertionError("Restart replayed a run ID"); }
        catch (IOException expected) { check(reserved.size() == 2, "Restart consumed an ID"); }
    }

    private static void failedReservationClosesOwner() throws Exception {
        String session = id();
        AtomicInteger reservations = new AtomicInteger();
        var owner = new IsolatedExecutionPolicyOwner("receipt.failure", session,
                (runId, scope) -> {
                    if (reservations.incrementAndGet() == 2) throw new IOException("Receipt directory sync failed");
                }, (before, after) -> {});
        var first = owner.admit(id());
        AtomicInteger revocations = new AtomicInteger();
        first.onRevoked(revocations::incrementAndGet);
        try { owner.admit(id()); throw new AssertionError("Failed reservation admitted a run"); }
        catch (IOException expected) {
            check(!first.active(1) && revocations.get() == 1,
                    "Durability failure retained older run authority");
        }
        rejects(() -> {
            try { owner.admit(id()); }
            catch (IOException failure) { throw new AssertionError(failure); }
        }, "Owner admitted work after reservation became uncertain");
        check(reservations.get() == 2, "Closed owner issued another reservation");
    }

    private static void scopedChildAndRevocation() throws Exception {
        Path root = Files.createTempDirectory("policy-owner-");
        Path workspace = Files.createDirectory(root.resolve("workspace"));
        try {
            String owner = "task.2";
            String session = id();
            Set<String> ids = new HashSet<>();
            var policy = new IsolatedExecutionPolicyOwner(owner, session,
                    (runId, scope) -> { if (!ids.add(runId)) throw new IOException("Replay"); },
                    (before, after) -> check(after.version() == before.version() + 1,
                            "Transition omitted a version"));
            var granted = IsolatedExecutionPolicyOwner.Scope.granted(owner, session, 2,
                    root, workspace, Set.of("notes/"), Set.of("notes/"),
                    Set.of("example.com"), 16, 4, 10_000);
            policy.replace(granted);
            var parent = policy.admit(id());
            var childScope = IsolatedExecutionPolicyOwner.Scope.granted(owner, session, 2,
                    root, workspace, Set.of("notes/todo.txt"), Set.of("notes/todo.txt"),
                    Set.of("example.com"), 2, 1, 1_000);
            check(childScope.within(granted), "Exact child file was not within directory scope");
            var child = policy.admitChild(parent.runId(), id(), childScope);
            check(child.active(2), "Narrowed child lease is inactive");
            var widerHost = IsolatedExecutionPolicyOwner.Scope.granted(owner, session, 2,
                    root, workspace, Set.of("notes/todo.txt"), Set.of(),
                    Set.of("other.example.com"), 2, 1, 1_000);
            rejects(() -> {
                try { policy.admitChild(parent.runId(), id(), widerHost); }
                catch (IOException failure) { throw new AssertionError(failure); }
            }, "A new host was inherited");
            policy.revoke(parent.runId());
            check(!parent.active(2) && !child.active(2), "Parent revocation did not reach child");
            check(ids.size() == 2, "Rejected child reserved an ID");
            var next = policy.admit(id());
            check(next.active(2), "Revocation retained a stale lease slot");
            var nested = next;
            for (int depth = 0; depth < IsolatedExecutionPolicyOwner.MAX_CHILD_DEPTH; depth++)
                nested = policy.admitChild(nested.runId(), id(), childScope);
            String finalParent = nested.runId();
            rejects(() -> {
                try { policy.admitChild(finalParent, id(), childScope); }
                catch (IOException failure) { throw new AssertionError(failure); }
            }, "Unbounded child policy nesting was admitted");
        } finally {
            Files.delete(workspace);
            Files.delete(root);
        }
    }

    private static void rejectedPolicyChangeClosesOwner() throws Exception {
        String session = id();
        var failedAdmission = new IsolatedExecutionPolicyOwner("task.3", session,
                (runId, scope) -> { throw new IOException("Receipt fsync failed"); },
                (before, after) -> { throw new IOException("Approval fsync failed"); });
        try { failedAdmission.admit(id()); throw new AssertionError("Failed receipt created a lease"); }
        catch (IOException expected) {
            check(failedAdmission.current().version() == 1, "Failed admission changed policy");
        }
        rejects(() -> {
            try { failedAdmission.admit(id()); }
            catch (IOException failure) { throw new AssertionError(failure); }
        }, "Failed receipt retained admission authority");
        var owner = new IsolatedExecutionPolicyOwner("task.3", session,
                (runId, scope) -> {},
                (before, after) -> { throw new IOException("Approval fsync failed"); });
        try {
            owner.replace(IsolatedExecutionPolicyOwner.Scope.denied(
                    owner.current().ownerId(), owner.current().sessionId(), 2));
            throw new AssertionError("Failed policy transition was published");
        } catch (IOException expected) {
            check(owner.current().version() == 1, "Unrecorded policy was published");
            rejects(() -> {
                try { owner.admit(id()); }
                catch (IOException failure) { throw new AssertionError(failure); }
            }, "Uncertain owner accepted new work");
        }
    }

    private static void invalidWorkspaceAndGrants() throws Exception {
        Path root = Files.createTempDirectory("policy-path-");
        Path inside = Files.createDirectory(root.resolve("inside"));
        Path outside = Files.createTempDirectory("policy-outside-");
        try {
            String session = id();
            var networkOnly = IsolatedExecutionPolicyOwner.Scope.granted("task", session, 2,
                    null, null, Set.of(), Set.of(), Set.of("example.com"), 0, 1, 1000);
            check(networkOnly.workspaceRoot() == null && networkOnly.exactHosts().size() == 1,
                    "Network policy required an unrelated file workspace");
            try {
                IsolatedExecutionPolicyOwner.Scope.granted("task", session, 2, root, outside,
                        Set.of("a.txt"), Set.of(), Set.of(), 1, 0, 1000);
                throw new AssertionError("Outside workspace was allowed");
            } catch (IOException expected) { /* The root must remain App-owned. */ }
            rejects(() -> {
                try {
                    IsolatedExecutionPolicyOwner.Scope.granted("task", session, 2, root, inside,
                            Set.of("../escape"), Set.of(), Set.of(), 1, 0, 1000);
                } catch (IOException failure) { throw new AssertionError(failure); }
            }, "Traversal was admitted");
            rejects(() -> {
                try {
                    IsolatedExecutionPolicyOwner.Scope.granted("task", session, 2, root, inside,
                            Set.of(), Set.of(), Set.of("*.example.com"), 0, 1, 1000);
                } catch (IOException failure) { throw new AssertionError(failure); }
            }, "Wildcard host was admitted");
            rejects(() -> {
                try {
                    IsolatedExecutionPolicyOwner.Scope.granted("task", session, 2, root, inside,
                            Set.of("a.txt"), Set.of("b.txt"), Set.of(), 1, 0, 1000);
                } catch (IOException failure) { throw new AssertionError(failure); }
            }, "Unrelated writable root was admitted");
            rejects(() -> {
                try {
                    IsolatedExecutionPolicyOwner.Scope.granted("task", session, 2, null, null,
                            Set.of("a.txt"), Set.of(), Set.of(), 1, 0, 1000);
                } catch (IOException failure) { throw new AssertionError(failure); }
            }, "File grant was admitted without an App workspace");
        } finally {
            Files.delete(inside);
            Files.delete(root);
            Files.delete(outside);
        }
    }

    private static void receiptBackedAdmissionIsSingleUse() throws Exception {
        Path root = Files.createTempDirectory("policy-receipt-");
        try {
            var receipts = new IsolatedScriptReceipt(root, directory -> {});
            String ownerId = "receipt.task";
            String sessionId = id();
            var policy = new IsolatedExecutionPolicyOwner(ownerId, sessionId,
                    (runId, scope) -> receipts.admit(runId), (before, after) -> {});
            String runId = id();
            var lease = policy.admit(runId);
            check(lease.active(1) && receipts.read(runId).state() == IsolatedScriptReceipt.State.ADMITTED,
                    "Policy lease was exposed before durable receipt admission");
            receipts.finish(new IsolatedScriptReceipt.Entry(
                    runId, IsolatedScriptReceipt.State.COMPLETED, "{}", null));
            policy.revoke(runId);
            check(!lease.active(1), "Completed policy lease retained authority");
            var restarted = new IsolatedExecutionPolicyOwner(ownerId, sessionId,
                    (nextId, scope) -> new IsolatedScriptReceipt(root, directory -> {}).admit(nextId),
                    (before, after) -> {});
            try { restarted.admit(runId); throw new AssertionError("Persisted run ID replayed after restart"); }
            catch (IOException expected) {
                check(receipts.read(runId).state() == IsolatedScriptReceipt.State.COMPLETED,
                        "Replay changed the completed receipt");
            }
        } finally {
            try (var paths = Files.walk(root)) {
                for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(path);
            }
        }
    }
}
