package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.EnumSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.BooleanSupplier;

/** Host contract checks; Android Binder identity and filesystem provider still need device tests. */
public final class IsolatedCapabilityBrokerTest {
    private static final String PATH = "nested/笔记.txt";
    private static final String OWNER_TEXT = "first line\nsecond line";

    public static void main(String[] args) throws Exception {
        sandboxPathPolicy();
        admissionAndBoundedOperations();
        fullWriteIsExactAuditedAndVersioned();
        staleAndReplay();
        cancellationAndWorkerDeath();
        interruptedAndObservedCancellation();
        cancellationProbeFailureStillSettles();
        unknownWriteOutcomeRequiresInspection();
        deadlineAndAuditFailure();
        terminalRaceAndInFlightEdit();
        journalDurabilityFrame();
    }

    private static void sandboxPathPolicy() throws Exception {
        MemoryWorkspace workspace = new MemoryWorkspace();
        workspace.text = OWNER_TEXT;
        List<IsolatedCapabilityBroker.Event> events = new ArrayList<>();
        var edit = new IsolatedCapabilityBroker.GrantSpec(PATH,
                Set.of(IsolatedCapabilityBroker.Action.EDIT));
        try {
            new IsolatedCapabilityBroker(id(), workspace, events::add, List.of(edit), 10_000);
            throw new AssertionError("Default read-only broker issued an edit grant");
        } catch (IllegalArgumentException expected) { /* No run or grant was admitted. */ }
        check(events.isEmpty(), "Rejected path policy opened an auditable run");

        var policy = new IsolatedCapabilityBroker.SandboxPolicy(
                Set.of("nested/"), Set.of(PATH));
        var broker = new IsolatedCapabilityBroker(id(), workspace, events::add,
                List.of(edit), policy, 10_000);
        check(broker.handles().size() == 1, "Explicit writable file was not granted");
        broker.cancel();

        for (String outside : List.of("nested-extra/笔记.txt", "other/笔记.txt")) {
            try {
                new IsolatedCapabilityBroker(id(), workspace, events::add,
                        List.of(new IsolatedCapabilityBroker.GrantSpec(outside,
                                Set.of(IsolatedCapabilityBroker.Action.READ))), policy, 10_000);
                throw new AssertionError("Path prefix escaped readable root: " + outside);
            } catch (IllegalArgumentException expected) { /* Prefix requires a segment boundary. */ }
        }
        try {
            new IsolatedCapabilityBroker(id(), workspace, events::add,
                    List.of(new IsolatedCapabilityBroker.GrantSpec("nested/other.txt",
                            Set.of(IsolatedCapabilityBroker.Action.EDIT))), policy, 10_000);
            throw new AssertionError("Edit escaped writable file");
        } catch (IllegalArgumentException expected) { /* Readable is not writable. */ }
        try {
            new IsolatedCapabilityBroker.SandboxPolicy(Set.of("nested/"), Set.of("other"));
            throw new AssertionError("Writable root escaped readable scope");
        } catch (IllegalArgumentException expected) { /* Invalid policy rejected. */ }
        try {
            new IsolatedCapabilityBroker(id(), workspace, events::add,
                    List.of(new IsolatedCapabilityBroker.GrantSpec(PATH + "/child",
                            Set.of(IsolatedCapabilityBroker.Action.READ))),
                    IsolatedCapabilityBroker.SandboxPolicy.readOnly(Set.of(PATH)), 10_000);
            throw new AssertionError("Exact-file grant silently became a directory grant");
        } catch (IllegalArgumentException expected) { /* Exact paths do not admit descendants. */ }
        check(!policy.writablePaths().contains("nested/other.txt"), "Writable policy expanded");
        for (String protectedName : List.of(".git/config", "nested/.agents/instructions.md",
                "nested/.codex/state", ".aws/credentials")) {
            try {
                new IsolatedCapabilityBroker.SandboxPolicy(
                        Set.of(protectedName), Set.of(protectedName));
                throw new AssertionError("Protected workspace metadata became writable: " + protectedName);
            } catch (IllegalArgumentException expected) { /* Explicit protected write rejected. */ }
        }
        var directory = new IsolatedCapabilityBroker.SandboxPolicy(
                Set.of("nested/"), Set.of("nested/"));
        var directoryBroker = new IsolatedCapabilityBroker(id(), workspace, events::add,
                List.of(new IsolatedCapabilityBroker.GrantSpec("nested/",
                        Set.of(IsolatedCapabilityBroker.Action.EDIT))), directory, 10_000);
        var protectedCall = IsolatedCapabilityBroker.Call.editChild(directoryBroker.runId(), id(),
                directoryBroker.handles().get(0).id(), ".git/config", "0".repeat(64),
                "before", "after", 1);
        check(directoryBroker.execute(protectedCall, () -> false).status()
                == IsolatedCapabilityBroker.Status.DENIED,
                "A directory grant edited protected workspace metadata");
        var writeDirectoryBroker = new IsolatedCapabilityBroker(id(), workspace, events::add,
                List.of(new IsolatedCapabilityBroker.GrantSpec("nested/",
                        Set.of(IsolatedCapabilityBroker.Action.WRITE))), directory, 10_000);
        var protectedWrite = IsolatedCapabilityBroker.Call.writeChild(writeDirectoryBroker.runId(), id(),
                writeDirectoryBroker.handles().get(0).id(), ".codex/config.json",
                IsolatedWorkerWriteback.MISSING, "{} ");
        check(writeDirectoryBroker.execute(protectedWrite, () -> false).status()
                == IsolatedCapabilityBroker.Status.DENIED,
                "A directory grant wrote protected workspace metadata");
        writeDirectoryBroker.cancel();
        directoryBroker.cancel();
        for (String unsafe : List.of("nested/line\nname", "nested/" + "x".repeat(181),
                "x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x")) {
            try {
                new IsolatedCapabilityBroker.GrantSpec(unsafe, Set.of(IsolatedCapabilityBroker.Action.READ));
                throw new AssertionError("Writer-invalid target entered broker: " + unsafe);
            } catch (IllegalArgumentException expected) { /* Same path grammar as anchored writeback. */ }
        }
    }

    private static void admissionAndBoundedOperations() throws Exception {
        MemoryWorkspace workspace = new MemoryWorkspace();
        workspace.text = OWNER_TEXT;
        List<IsolatedCapabilityBroker.Event> events = new ArrayList<>();
        var broker = broker(workspace, events::add, EnumSet.allOf(IsolatedCapabilityBroker.Action.class));
        var handle = broker.handles().get(0);
        check(!handle.toString().contains(PATH), "Guest handle revealed workspace target");
        var read = broker.execute(IsolatedCapabilityBroker.Call.read(broker.runId(), id(), handle.id()), () -> false);
        check(read.status() == IsolatedCapabilityBroker.Status.OK
                && read.read().text().equals(OWNER_TEXT), "READ failed");
        var search = broker.execute(IsolatedCapabilityBroker.Call.search(
                broker.runId(), id(), handle.id(), "second", 4), () -> false);
        check(search.status() == IsolatedCapabilityBroker.Status.OK
                && search.search().hits().get(0).line() == 2, "SEARCH failed");
        var edit = broker.execute(IsolatedCapabilityBroker.Call.edit(broker.runId(), id(), handle.id(),
                read.read().revision(), "second", "updated", 1), () -> false);
        check(edit.status() == IsolatedCapabilityBroker.Status.OK
                && workspace.text.contains("updated") && workspace.edits.get() == 1, "EDIT failed");
        check(events.stream().filter(e -> e.phase() == IsolatedCapabilityBroker.Phase.CALL_STARTED).count() == 3,
                "Every granted call needs an audit start");
        check(events.stream().filter(e -> e.phase() == IsolatedCapabilityBroker.Phase.CALL_SETTLED).count() == 3,
                "Every granted call needs an audit settlement");
        check(events.stream().anyMatch(e -> e.phase() == IsolatedCapabilityBroker.Phase.CALL_STARTED
                && e.action() == IsolatedCapabilityBroker.Action.EDIT
                && e.expectedRevision().equals(read.read().revision()))
                && events.stream().anyMatch(e -> e.phase() == IsolatedCapabilityBroker.Phase.CALL_SETTLED
                && e.action() == IsolatedCapabilityBroker.Action.EDIT
                && e.resultRevision().equals(edit.edit().revision())),
                "Edit audit omitted expected or result revision");
        check(events.stream().anyMatch(e -> e.phase() == IsolatedCapabilityBroker.Phase.GRANT_ISSUED
                && PATH.equals(e.target())
                && e.grantActions().equals(EnumSet.allOf(IsolatedCapabilityBroker.Action.class))),
                "Private audit did not record complete grant rights");
        check(broker.complete() == IsolatedCapabilityBroker.Terminal.COMPLETED
                && broker.cancel() == IsolatedCapabilityBroker.Terminal.COMPLETED,
                "First terminal outcome did not win");
        check(broker.execute(IsolatedCapabilityBroker.Call.read(broker.runId(), id(), handle.id()), () -> false)
                .status() == IsolatedCapabilityBroker.Status.DENIED, "Closed run still grants reads");
    }

    private static void fullWriteIsExactAuditedAndVersioned() throws Exception {
        MemoryWorkspace workspace = new MemoryWorkspace();
        List<IsolatedCapabilityBroker.Event> events = new ArrayList<>();
        var broker = broker(workspace, events::add, Set.of(IsolatedCapabilityBroker.Action.WRITE));
        String handle = broker.handles().get(0).id();
        var create = broker.execute(IsolatedCapabilityBroker.Call.write(broker.runId(), id(), handle,
                IsolatedWorkerWriteback.MISSING, "created"), () -> false);
        check(create.status() == IsolatedCapabilityBroker.Status.OK
                && create.edit().previousRevision().equals(IsolatedWorkerWriteback.MISSING)
                && workspace.text.equals("created"), "Exact-file create did not publish");
        var stale = broker.execute(IsolatedCapabilityBroker.Call.write(broker.runId(), id(), handle,
                IsolatedWorkerWriteback.MISSING, "overwrite"), () -> false);
        check(stale.status() == IsolatedCapabilityBroker.Status.STALE
                && workspace.text.equals("created"), "Missing precondition overwrote a file");
        var replace = broker.execute(IsolatedCapabilityBroker.Call.write(broker.runId(), id(), handle,
                create.edit().revision(), "replaced"), () -> false);
        check(replace.status() == IsolatedCapabilityBroker.Status.OK && workspace.text.equals("replaced"),
                "Revision-checked replacement failed");
        check(events.stream().filter(e -> e.action() == IsolatedCapabilityBroker.Action.WRITE
                && e.phase() == IsolatedCapabilityBroker.Phase.CALL_SETTLED).count() == 3,
                "WRITE settlements were not audited");
        check(events.stream().anyMatch(e -> e.action() == IsolatedCapabilityBroker.Action.WRITE
                && e.phase() == IsolatedCapabilityBroker.Phase.CALL_SETTLED
                && create.edit().revision().equals(e.resultRevision())), "WRITE receipt revision was not audited");
        var cancelled = broker.execute(IsolatedCapabilityBroker.Call.write(broker.runId(), id(), handle,
                replace.edit().revision(), "cancelled"), () -> true);
        check(cancelled.status() == IsolatedCapabilityBroker.Status.CANCELLED
                && workspace.text.equals("replaced"), "Cancelled WRITE changed content");
        try {
            IsolatedCapabilityBroker.Call.write(broker.runId(), id(), handle,
                    replace.edit().revision(), "x".repeat(IsolatedWorkerInput.MAX_TEXT_BYTES + 1));
            throw new AssertionError("Oversized WRITE admitted");
        } catch (IllegalArgumentException expected) { /* bounded before dispatch */ }
        try {
            new IsolatedCapabilityBroker(id(), workspace, events::add,
                    List.of(new IsolatedCapabilityBroker.GrantSpec("other.txt",
                            Set.of(IsolatedCapabilityBroker.Action.WRITE))),
                    new IsolatedCapabilityBroker.SandboxPolicy(Set.of(PATH), Set.of(PATH)), 10_000);
            throw new AssertionError("WRITE escaped the exact file");
        } catch (IllegalArgumentException expected) { /* exact grant cannot widen policy */ }
    }

    private static void staleAndReplay() throws Exception {
        MemoryWorkspace workspace = new MemoryWorkspace();
        workspace.text = OWNER_TEXT;
        var broker = broker(workspace, event -> {}, Set.of(IsolatedCapabilityBroker.Action.READ,
                IsolatedCapabilityBroker.Action.EDIT));
        String handle = broker.handles().get(0).id();
        String callId = id();
        check(broker.execute(IsolatedCapabilityBroker.Call.read("wrong", callId, handle), () -> false)
                .status() == IsolatedCapabilityBroker.Status.DENIED, "Wrong run accepted");
        check(broker.execute(IsolatedCapabilityBroker.Call.read(broker.runId(), callId, handle), () -> false)
                .status() == IsolatedCapabilityBroker.Status.OK, "Wrong-run request consumed call ID");
        check(broker.execute(IsolatedCapabilityBroker.Call.read(broker.runId(), callId, handle), () -> false)
                .status() == IsolatedCapabilityBroker.Status.DENIED, "Replayed call accepted");
        check(broker.execute(IsolatedCapabilityBroker.Call.search(broker.runId(), id(), handle, "line", 1), () -> false)
                .status() == IsolatedCapabilityBroker.Status.DENIED, "Unissued SEARCH accepted");
        check(broker.execute(IsolatedCapabilityBroker.Call.read(broker.runId(), id(), id()), () -> false)
                .status() == IsolatedCapabilityBroker.Status.DENIED, "Unknown grant accepted");
        var stale = broker.execute(IsolatedCapabilityBroker.Call.edit(broker.runId(), id(), handle,
                "0".repeat(64), "first", "other", 1), () -> false);
        check(stale.status() == IsolatedCapabilityBroker.Status.STALE && workspace.edits.get() == 0,
                "Stale edit was not distinguished or changed content");
        for (String unsafe : List.of("../secret", "/private", "nested//file", "a\\b", "C:drive")) {
            try { new IsolatedCapabilityBroker.GrantSpec(unsafe, Set.of(IsolatedCapabilityBroker.Action.READ));
                throw new AssertionError("Unsafe target accepted: " + unsafe);
            } catch (IllegalArgumentException expected) { /* Denied before grant issue. */ }
        }
    }

    private static void cancellationAndWorkerDeath() throws Exception {
        MemoryWorkspace workspace = new MemoryWorkspace();
        workspace.text = OWNER_TEXT;
        var cancelled = broker(workspace, event -> {}, Set.of(IsolatedCapabilityBroker.Action.READ));
        String handle = cancelled.handles().get(0).id();
        check(cancelled.execute(IsolatedCapabilityBroker.Call.read(cancelled.runId(), id(), handle), () -> true)
                .status() == IsolatedCapabilityBroker.Status.CANCELLED, "Caller cancellation accepted call");
        check(cancelled.terminal() == IsolatedCapabilityBroker.Terminal.CANCELLED, "Cancellation not terminal");
        var dead = broker(workspace, event -> {}, Set.of(IsolatedCapabilityBroker.Action.READ));
        dead.workerDied();
        check(dead.execute(IsolatedCapabilityBroker.Call.read(dead.runId(), id(), dead.handles().get(0).id()),
                () -> false).status() == IsolatedCapabilityBroker.Status.WORKER_DIED,
                "Dead guest retained its grant");
    }

    private static void interruptedAndObservedCancellation() throws Exception {
        CountDownLatch entered = new CountDownLatch(1);
        IsolatedCapabilityBroker.WorkspaceOps interruptedOps = new IsolatedCapabilityBroker.WorkspaceOps() {
            public IsolatedCapabilityBroker.ReadData read(String filename, BooleanSupplier cancelled)
                    throws Exception {
                entered.countDown();
                new CountDownLatch(1).await(); // Interrupt clears the flag before reaching the broker catch.
                throw new AssertionError("Interrupted read continued");
            }
            public IsolatedCapabilityBroker.SearchData search(String filename, String query, int maxMatches,
                    BooleanSupplier cancelled) { throw new AssertionError("Unexpected search"); }
            public IsolatedCapabilityBroker.EditData edit(String filename, String expectedRevision,
                    String needle, String replacement, int maxReplacements, BooleanSupplier cancelled) {
                throw new AssertionError("Unexpected edit");
            }
        };
        var interrupted = new IsolatedCapabilityBroker(id(), interruptedOps, event -> {},
                List.of(new IsolatedCapabilityBroker.GrantSpec(PATH,
                        Set.of(IsolatedCapabilityBroker.Action.READ))), 10_000);
        var outcome = new java.util.concurrent.atomic.AtomicReference<IsolatedCapabilityBroker.CallResult>();
        Thread reader = new Thread(() -> outcome.set(interrupted.execute(
                IsolatedCapabilityBroker.Call.read(interrupted.runId(), id(), interrupted.handles().get(0).id()),
                () -> false)));
        reader.start();
        check(entered.await(3, TimeUnit.SECONDS), "Interrupted read did not enter");
        reader.interrupt();
        reader.join(3000);
        check(!reader.isAlive() && outcome.get().status() == IsolatedCapabilityBroker.Status.CANCELLED
                && interrupted.terminal() == IsolatedCapabilityBroker.Terminal.CANCELLED,
                "Interrupted call left a live lease or returned FAILED");
        check(interrupted.execute(IsolatedCapabilityBroker.Call.read(interrupted.runId(), id(),
                interrupted.handles().get(0).id()), () -> false).status()
                == IsolatedCapabilityBroker.Status.CANCELLED,
                "Interrupted run accepted a later request");

        AtomicBoolean callerCancel = new AtomicBoolean();
        IsolatedCapabilityBroker.WorkspaceOps observedOps = new IsolatedCapabilityBroker.WorkspaceOps() {
            public IsolatedCapabilityBroker.ReadData read(String filename, BooleanSupplier cancelled)
                    throws IOException {
                callerCancel.set(true);
                check(cancelled.getAsBoolean(), "Cancellation supplier missed caller signal");
                throw new IOException("provider stopped after cancellation");
            }
            public IsolatedCapabilityBroker.SearchData search(String filename, String query, int maxMatches,
                    BooleanSupplier cancelled) { throw new AssertionError("Unexpected search"); }
            public IsolatedCapabilityBroker.EditData edit(String filename, String expectedRevision,
                    String needle, String replacement, int maxReplacements, BooleanSupplier cancelled) {
                throw new AssertionError("Unexpected edit");
            }
        };
        var observed = new IsolatedCapabilityBroker(id(), observedOps, event -> {},
                List.of(new IsolatedCapabilityBroker.GrantSpec(PATH,
                        Set.of(IsolatedCapabilityBroker.Action.READ))), 10_000);
        check(observed.execute(IsolatedCapabilityBroker.Call.read(observed.runId(), id(),
                observed.handles().get(0).id()), callerCancel::get).status()
                == IsolatedCapabilityBroker.Status.CANCELLED,
                "Provider error after cancellation was reported as ordinary FAILED");
        check(observed.terminal() == IsolatedCapabilityBroker.Terminal.CANCELLED,
                "Observed cancellation left a live lease");
    }

    private static void cancellationProbeFailureStillSettles() throws Exception {
        for (var action : List.of(IsolatedCapabilityBroker.Action.READ, IsolatedCapabilityBroker.Action.EDIT)) {
            MemoryWorkspace workspace = new MemoryWorkspace();
            workspace.text = OWNER_TEXT;
            List<IsolatedCapabilityBroker.Event> events = new ArrayList<>();
            var broker = broker(workspace, events::add, Set.of(action));
            String handle = broker.handles().get(0).id();
            AtomicInteger checks = new AtomicInteger();
            BooleanSupplier brokenAfterExecution = () -> {
                if (checks.incrementAndGet() == 3) throw new IllegalStateException("caller vanished");
                return false;
            };
            var call = action == IsolatedCapabilityBroker.Action.READ
                    ? IsolatedCapabilityBroker.Call.read(broker.runId(), id(), handle)
                    : IsolatedCapabilityBroker.Call.edit(broker.runId(), id(), handle,
                            sha(OWNER_TEXT), "first", "changed", 1);
            var result = broker.execute(call, brokenAfterExecution);
            check(result.status() == (action == IsolatedCapabilityBroker.Action.EDIT
                    ? IsolatedCapabilityBroker.Status.COMMIT_UNCERTAIN : IsolatedCapabilityBroker.Status.FAILED),
                    "Exception in final cancellation check returned a clean result");
            check(broker.terminal() == IsolatedCapabilityBroker.Terminal.FAILED
                    && broker.complete() == IsolatedCapabilityBroker.Terminal.FAILED,
                    "Cancellation callback failure left a completable run");
            check(events.stream().filter(e -> e.phase() == IsolatedCapabilityBroker.Phase.CALL_STARTED).count() == 1
                    && events.stream().filter(e -> e.phase() == IsolatedCapabilityBroker.Phase.CALL_SETTLED
                    && e.status() == result.status()).count() == 1,
                    "Cancellation callback failure left an unsettled call");
            if (action == IsolatedCapabilityBroker.Action.EDIT)
                check(events.stream().anyMatch(e -> e.phase() == IsolatedCapabilityBroker.Phase.CALL_SETTLED
                        && sha(workspace.text).equals(e.resultRevision())),
                        "Uncertain edit audit lost the observed output revision");
        }
    }

    private static void unknownWriteOutcomeRequiresInspection() throws Exception {
        MemoryWorkspace workspace = new MemoryWorkspace();
        workspace.text = OWNER_TEXT;
        IsolatedCapabilityBroker.WorkspaceOps uncertainWorkspace = new IsolatedCapabilityBroker.WorkspaceOps() {
            public IsolatedCapabilityBroker.ReadData read(String filename, BooleanSupplier cancelled) {
                throw new AssertionError("Unexpected read");
            }
            public IsolatedCapabilityBroker.SearchData search(String filename, String query, int maxMatches,
                    BooleanSupplier cancelled) { throw new AssertionError("Unexpected search"); }
            public IsolatedCapabilityBroker.EditData edit(String filename, String expectedRevision,
                    String needle, String replacement, int maxReplacements, BooleanSupplier cancelled)
                    throws IOException {
                workspace.text = "replacement may be visible";
                throw new IsolatedCapabilityBroker.CommitOutcomeUnknown(new IOException("close failed"));
            }
        };
        List<IsolatedCapabilityBroker.Event> events = new ArrayList<>();
        var broker = new IsolatedCapabilityBroker(id(), uncertainWorkspace, events::add,
                List.of(new IsolatedCapabilityBroker.GrantSpec(PATH,
                        Set.of(IsolatedCapabilityBroker.Action.EDIT))),
                new IsolatedCapabilityBroker.SandboxPolicy(Set.of(PATH), Set.of(PATH)), 10_000);
        String expected = sha(OWNER_TEXT);
        var result = broker.execute(IsolatedCapabilityBroker.Call.edit(broker.runId(), id(),
                broker.handles().get(0).id(), expected, "first", "changed", 1), () -> false);
        check(result.status() == IsolatedCapabilityBroker.Status.COMMIT_UNCERTAIN,
                "Possibly committed write was misclassified as stale or a clean failure");
        check(events.stream().anyMatch(e -> e.phase() == IsolatedCapabilityBroker.Phase.CALL_SETTLED
                && e.status() == IsolatedCapabilityBroker.Status.COMMIT_UNCERTAIN
                && expected.equals(e.expectedRevision()) && e.resultRevision() == null),
                "Uncertain write settlement omitted the expected revision");

        IsolatedCapabilityBroker.WorkspaceOps genericFailure = new IsolatedCapabilityBroker.WorkspaceOps() {
            public IsolatedCapabilityBroker.ReadData read(String filename, BooleanSupplier cancelled) {
                throw new AssertionError("Unexpected read");
            }
            public IsolatedCapabilityBroker.SearchData search(String filename, String query, int maxMatches,
                    BooleanSupplier cancelled) { throw new AssertionError("Unexpected search"); }
            public IsolatedCapabilityBroker.EditData edit(String filename, String expectedRevision,
                    String needle, String replacement, int maxReplacements, BooleanSupplier cancelled)
                    throws IOException {
                workspace.text = "second replacement may be visible";
                throw new IOException("provider failed after writing");
            }
        };
        var genericBroker = new IsolatedCapabilityBroker(id(), genericFailure, event -> {},
                List.of(new IsolatedCapabilityBroker.GrantSpec(PATH,
                        Set.of(IsolatedCapabilityBroker.Action.EDIT))),
                new IsolatedCapabilityBroker.SandboxPolicy(Set.of(PATH), Set.of(PATH)), 10_000);
        check(genericBroker.execute(IsolatedCapabilityBroker.Call.edit(genericBroker.runId(), id(),
                genericBroker.handles().get(0).id(), sha(workspace.text), "first", "changed", 1),
                () -> false).status() == IsolatedCapabilityBroker.Status.COMMIT_UNCERTAIN,
                "Generic workspace failure after edit falsely claimed no commit");
    }

    private static void deadlineAndAuditFailure() throws Exception {
        AtomicLong clock = new AtomicLong(1_000_000L);
        MemoryWorkspace workspace = new MemoryWorkspace();
        workspace.text = OWNER_TEXT;
        var expired = new IsolatedCapabilityBroker(id(), workspace, event -> {},
                List.of(new IsolatedCapabilityBroker.GrantSpec(PATH, Set.of(IsolatedCapabilityBroker.Action.READ))),
                1000, clock::get);
        clock.addAndGet(TimeUnit.SECONDS.toNanos(2));
        check(expired.execute(IsolatedCapabilityBroker.Call.read(expired.runId(), id(), expired.handles().get(0).id()),
                () -> false).status() == IsolatedCapabilityBroker.Status.EXPIRED,
                "Expired grant was accepted");
        check(expired.terminal() == IsolatedCapabilityBroker.Terminal.EXPIRED, "Lease did not terminalize");

        var failedStart = broker(workspace, event -> {
            if (event.phase() == IsolatedCapabilityBroker.Phase.CALL_STARTED) throw new IOException("disk full");
        }, Set.of(IsolatedCapabilityBroker.Action.READ));
        check(failedStart.execute(IsolatedCapabilityBroker.Call.read(
                failedStart.runId(), id(), failedStart.handles().get(0).id()), () -> false)
                .status() == IsolatedCapabilityBroker.Status.AUDIT_UNCERTAIN,
                "Unaudited call was executed");
        check(workspace.reads.get() == 0, "Operation ran without admission journal");

        var failedSettlement = broker(workspace, event -> {
            if (event.phase() == IsolatedCapabilityBroker.Phase.CALL_SETTLED) throw new IOException("disk full");
        }, Set.of(IsolatedCapabilityBroker.Action.EDIT));
        var result = failedSettlement.execute(IsolatedCapabilityBroker.Call.edit(failedSettlement.runId(), id(),
                failedSettlement.handles().get(0).id(), sha(OWNER_TEXT), "first", "other", 1), () -> false);
        check(result.status() == IsolatedCapabilityBroker.Status.AUDIT_UNCERTAIN
                && failedSettlement.terminal() == IsolatedCapabilityBroker.Terminal.AUDIT_UNCERTAIN,
                "Lost edit settlement falsely returned clean success");

        var uncheckedSettlement = broker(workspace, event -> {
            if (event.phase() == IsolatedCapabilityBroker.Phase.CALL_SETTLED)
                throw new IllegalStateException("journal provider failed");
        }, Set.of(IsolatedCapabilityBroker.Action.READ));
        check(uncheckedSettlement.execute(IsolatedCapabilityBroker.Call.read(uncheckedSettlement.runId(), id(),
                uncheckedSettlement.handles().get(0).id()), () -> false).status()
                == IsolatedCapabilityBroker.Status.AUDIT_UNCERTAIN
                && uncheckedSettlement.terminal() == IsolatedCapabilityBroker.Terminal.AUDIT_UNCERTAIN,
                "Unchecked journal failure returned clean success");
    }

    private static void terminalRaceAndInFlightEdit() throws Exception {
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        MemoryWorkspace workspace = new MemoryWorkspace();
        workspace.text = OWNER_TEXT;
        workspace.beforeEdit = () -> {
            entered.countDown();
            try { if (!release.await(3, TimeUnit.SECONDS)) throw new AssertionError("Edit race timeout"); }
            catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new AssertionError(error); }
        };
        var broker = broker(workspace, event -> {}, Set.of(IsolatedCapabilityBroker.Action.EDIT));
        var holder = new java.util.concurrent.atomic.AtomicReference<IsolatedCapabilityBroker.CallResult>();
        Thread editing = new Thread(() -> holder.set(broker.execute(IsolatedCapabilityBroker.Call.edit(
                broker.runId(), id(), broker.handles().get(0).id(), sha(OWNER_TEXT), "first", "late", 1),
                () -> false)));
        editing.start();
        check(entered.await(3, TimeUnit.SECONDS), "Edit did not enter");
        try {
            broker.complete();
            throw new AssertionError("Run completed with an unsettled edit");
        } catch (IllegalStateException expected) { /* Completion waits for binding settlement. */ }
        check(broker.workerDied() == IsolatedCapabilityBroker.Terminal.WORKER_DIED,
                "Worker death did not terminalize");
        release.countDown();
        editing.join(3000);
        check(!editing.isAlive(), "Edit did not settle");
        check(holder.get().status() == IsolatedCapabilityBroker.Status.COMMIT_UNCERTAIN,
                "In-flight edit after worker death falsely returned clean success");
        check(broker.cancel() == IsolatedCapabilityBroker.Terminal.WORKER_DIED,
                "Late cancellation replaced terminal result");
    }

    private static void journalDurabilityFrame() throws Exception {
        Path root = Files.createTempDirectory("capability-journal-");
        try {
            AtomicInteger syncs = new AtomicInteger();
            var journal = new IsolatedCapabilityJournal(root, path -> {
                check(path.equals(root), "Journal synced outside App-private root");
                syncs.incrementAndGet();
            });
            var broker = broker(new MemoryWorkspace(), journal,
                    Set.of(IsolatedCapabilityBroker.Action.READ, IsolatedCapabilityBroker.Action.EDIT));
            broker.cancel();
            String log = new String(Files.readAllBytes(root.resolve("isolated-capabilities.jsonl")),
                    StandardCharsets.UTF_8);
            check(log.contains("\"phase\":\"GRANT_ISSUED\"")
                    && log.contains("nested/笔记.txt")
                    && log.contains("\"grantActions\":[\"READ\",\"EDIT\"]")
                    && log.contains("\"terminal\":\"CANCELLED\"")
                    && syncs.get() >= 3, "Audit journal omitted issuance or settlement");
        } finally {
            Files.deleteIfExists(root.resolve("isolated-capabilities.jsonl"));
            Files.delete(root);
        }
    }

    private static IsolatedCapabilityBroker broker(MemoryWorkspace workspace,
            IsolatedCapabilityBroker.AuditSink audit, Set<IsolatedCapabilityBroker.Action> actions) throws IOException {
        return new IsolatedCapabilityBroker(id(), workspace, audit,
                List.of(new IsolatedCapabilityBroker.GrantSpec(PATH, actions)),
                new IsolatedCapabilityBroker.SandboxPolicy(Set.of(PATH),
                        actions.contains(IsolatedCapabilityBroker.Action.EDIT)
                                || actions.contains(IsolatedCapabilityBroker.Action.WRITE) ? Set.of(PATH) : Set.of()),
                10_000);
    }
    private static String id() { return UUID.randomUUID().toString(); }
    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
    private static String sha(String text) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8));
            StringBuilder result = new StringBuilder();
            for (byte b : digest) result.append(String.format("%02x", b & 255));
            return result.toString();
        } catch (Exception error) { throw new AssertionError(error); }
    }
    private static final class MemoryWorkspace implements IsolatedCapabilityBroker.WorkspaceOps {
        volatile String text;
        final AtomicInteger reads = new AtomicInteger();
        final AtomicInteger edits = new AtomicInteger();
        Runnable beforeEdit = () -> {};
        public IsolatedCapabilityBroker.ReadData read(String filename, BooleanSupplier cancelled) {
            reads.incrementAndGet();
            return new IsolatedCapabilityBroker.ReadData(sha(text), text);
        }
        public IsolatedCapabilityBroker.SearchData search(String filename, String query, int maxMatches,
                BooleanSupplier cancelled) throws IOException {
            var result = IsolatedWorkerTextSearch.search(text, new IsolatedWorkerTextSearch.Spec(query, maxMatches));
            return new IsolatedCapabilityBroker.SearchData(sha(text),
                    result.hits().stream().map(hit -> new IsolatedCapabilityBroker.Hit(
                            hit.line(), hit.column(), hit.preview())).toList(), result.truncated());
        }
        public IsolatedCapabilityBroker.EditData edit(String filename, String expectedRevision,
                String needle, String replacement, int maxReplacements, BooleanSupplier cancelled) throws Exception {
            beforeEdit.run();
            if (!sha(text).equals(expectedRevision)) throw new IsolatedCapabilityBroker.StaleRevision();
            edits.incrementAndGet();
            String next = IsolatedWorkerTextEdit.replace(text,
                    new IsolatedWorkerTextEdit.Spec(needle, replacement, maxReplacements));
            text = next;
            return new IsolatedCapabilityBroker.EditData(expectedRevision, sha(next), next.getBytes(StandardCharsets.UTF_8).length);
        }
        public IsolatedCapabilityBroker.EditData write(String filename, String expectedRevision,
                String next, BooleanSupplier cancelled) throws Exception {
            String before = text == null ? IsolatedWorkerWriteback.MISSING : sha(text);
            if (!before.equals(expectedRevision)) throw new IsolatedCapabilityBroker.StaleRevision();
            if (cancelled.getAsBoolean()) throw new IOException("Cancelled");
            text = next;
            return new IsolatedCapabilityBroker.EditData(before, sha(next),
                    next.getBytes(StandardCharsets.UTF_8).length);
        }
    }
}
