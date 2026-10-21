package com.minnnng.dsh_android;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.function.Consumer;

/** Exercises Native/Node reply ordering without Android or a running package manager. */
public final class PackageOperationTransitionsTest {
    private record Call(String method, String token, String epoch, Consumer<PackageOperationTransitions.Reply> reply) {}
    private static final class Harness {
        final List<Call> calls = new ArrayList<>();
        final List<Runnable> deadlines = new ArrayList<>();
        final List<PackageOperationTransitions.Reply> replies = new ArrayList<>();
        final Object owner = new Object();
        final String token = UUID.randomUUID().toString();
        final PackageOperationTransitions gate = new PackageOperationTransitions(
                (method, token, epoch, reply) -> calls.add(new Call(method, token, epoch, reply)),
                new PackageOperationTransitions.Scheduler() {
                    public void schedule(Runnable callback, long milliseconds) {
                        check(milliseconds == 15_000, "reservation deadline changed");
                        deadlines.add(callback);
                    }
                    public void cancel(Runnable callback) { deadlines.remove(callback); }
                });
        void reserve() { gate.reserve(token, owner, PackageOperationTransitions.Availability.RUNNING, replies::add); }
        void accepted() { calls.get(0).reply.accept(ok("node-epoch", "reserved")); }
        void commit() { gate.commit(token, owner, replies::add); }
        long releases() { return calls.stream().filter(call -> call.method.equals("release")).count(); }
    }

    public static void main(String[] args) {
        Harness success = new Harness();
        success.reserve();
        check(success.gate.busy() && success.replies.isEmpty(), "Native accepted before Node reserve ACK");
        success.accepted();
        check(success.replies.size() == 1 && success.replies.get(0).accepted(), "Node reserve was not accepted");
        success.commit();
        check(success.replies.size() == 1, "Native stopped before Node commit ACK");
        check(success.calls.get(1).epoch.equals("node-epoch"), "commit lost its runtime epoch");
        success.calls.get(1).reply.accept(ok("node-epoch", "committed"));
        check(success.replies.size() == 2 && success.replies.get(1).accepted(), "confirmed commit rejected");
        check(success.deadlines.isEmpty(), "committed stop retains an expiry that can reopen admission");
        success.gate.release(success.token, success.owner);
        check(success.gate.busy() && success.releases() == 0, "late Activity abort reopened admission after commit ACK");
        success.gate.unavailable();
        success.gate.disconnect(success.owner);
        success.gate.close();
        check(success.releases() == 0, "shutdown released the committed gate before process exit");

        Harness busy = new Harness();
        busy.reserve();
        busy.calls.get(0).reply.accept(PackageOperationTransitions.denied("runtime/package-busy", "package busy"));
        check(!busy.replies.get(0).accepted() && !busy.gate.busy(), "active packages permitted maintenance");
        busy.commit();
        check(!busy.replies.get(1).accepted(), "rejected reservation permitted stop");

        Harness savedFailure = new Harness();
        savedFailure.reserve();
        savedFailure.accepted();
        savedFailure.gate.release(savedFailure.token, new Object());
        check(savedFailure.gate.busy(), "foreign Activity released the reservation");
        savedFailure.gate.release(savedFailure.token, savedFailure.owner);
        check(!savedFailure.gate.busy() && savedFailure.releases() == 1, "mode-save failure retained Node reservation");
        savedFailure.commit();
        check(!savedFailure.replies.get(1).accepted(), "released token permitted termination");

        Harness expired = new Harness();
        expired.reserve();
        expired.deadlines.get(0).run();
        check(!expired.gate.busy() && expired.releases() == 1 && !expired.replies.get(0).accepted(), "timeout did not release Node");
        expired.accepted();
        check(expired.replies.size() == 1 && expired.releases() == 2, "late reserve ACK reauthorized transition");

        Harness repeated = new Harness();
        repeated.reserve();
        Call oldReserve = repeated.calls.get(0);
        repeated.deadlines.get(0).run();
        repeated.reserve();
        Call newReserve = repeated.calls.get(2);
        check(!oldReserve.token.equals(newReserve.token), "reusing an Activity request ID reused the Node reservation");
        oldReserve.reply.accept(ok("node-epoch", "reserved"));
        check(repeated.calls.get(3).token.equals(oldReserve.token), "late ACK released the replacement Node reservation");
        newReserve.reply.accept(ok("node-epoch", "reserved"));
        repeated.commit();
        check(repeated.calls.get(4).token.equals(newReserve.token), "commit did not own its Node reservation");

        Harness lateCommit = new Harness();
        lateCommit.reserve();
        lateCommit.accepted();
        lateCommit.commit();
        lateCommit.deadlines.get(0).run();
        lateCommit.calls.get(1).reply.accept(ok("node-epoch", "committed"));
        check(lateCommit.replies.size() == 2 && !lateCommit.replies.get(1).accepted(), "late commit stopped Node");
        check(lateCommit.releases() == 2, "late committed latch was not released");

        Harness disconnected = new Harness();
        disconnected.reserve();
        disconnected.accepted();
        disconnected.gate.disconnect(disconnected.owner);
        check(disconnected.releases() == 1 && !disconnected.gate.busy(), "Activity death retained Node reservation");

        Harness failure = new Harness();
        failure.reserve();
        failure.gate.unavailable();
        check(!failure.replies.get(0).accepted() && failure.releases() == 1, "runtime failure left pending reservation accepted");

        Harness unknown = new Harness();
        unknown.gate.reserve(unknown.token, unknown.owner, PackageOperationTransitions.Availability.UNKNOWN, unknown.replies::add);
        check(!unknown.replies.get(0).accepted() && unknown.calls.isEmpty(), "unknown runtime admitted transition");
        unknown.commit();
        check(!unknown.replies.get(1).accepted(), "replacement process accepted an old token");

        Harness wrongEpoch = new Harness();
        wrongEpoch.reserve();
        wrongEpoch.accepted();
        wrongEpoch.commit();
        wrongEpoch.calls.get(1).reply.accept(ok("replacement", "committed"));
        check(!wrongEpoch.replies.get(1).accepted() && wrongEpoch.releases() == 1, "foreign runtime authorized termination");

        Harness stopped = new Harness();
        stopped.gate.reserve(stopped.token, stopped.owner, PackageOperationTransitions.Availability.STOPPED, stopped.replies::add);
        stopped.commit();
        check(stopped.replies.stream().allMatch(PackageOperationTransitions.Reply::accepted) && stopped.calls.isEmpty(),
                "verified maintenance process required nonexistent Node");
        System.out.println("Package transitions: Node ACK gating, release, expiry, disconnect and replacement passed");
    }

    private static PackageOperationTransitions.Reply ok(String epoch, String state) {
        return new PackageOperationTransitions.Reply(true, epoch, state, null, null);
    }
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
