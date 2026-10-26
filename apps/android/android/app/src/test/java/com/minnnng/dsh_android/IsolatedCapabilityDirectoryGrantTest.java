package com.minnnng.dsh_android;

import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BooleanSupplier;

/** Pure broker contract; Android anchored files and hard-link checks require device evidence. */
public final class IsolatedCapabilityDirectoryGrantTest {
    public static void main(String[] args) throws Exception {
        String owner = UUID.randomUUID().toString();
        TrackingWorkspace workspace = new TrackingWorkspace();
        List<IsolatedCapabilityBroker.Event> audit = new ArrayList<>();
        var readRoot = new IsolatedCapabilityBroker.GrantSpec("notes/",
                Set.of(IsolatedCapabilityBroker.Action.READ, IsolatedCapabilityBroker.Action.SEARCH));
        var editRoot = new IsolatedCapabilityBroker.GrantSpec("notes/edits/",
                Set.of(IsolatedCapabilityBroker.Action.EDIT));
        var exact = new IsolatedCapabilityBroker.GrantSpec("single.txt",
                Set.of(IsolatedCapabilityBroker.Action.READ));
        var broker = new IsolatedCapabilityBroker(owner, workspace, audit::add,
                List.of(readRoot, editRoot, exact),
                new IsolatedCapabilityBroker.SandboxPolicy(
                        Set.of("notes/", "single.txt"), Set.of("notes/edits/")), 10_000);
        var handles = broker.handles();
        check(handles.get(0).directory() && handles.get(1).directory()
                && !handles.get(2).directory(), "Guest handle misreported root kind");
        check(!handles.toString().contains("notes/") && !handles.toString().contains("single.txt"),
                "Guest handle leaked App path");

        var read = broker.execute(IsolatedCapabilityBroker.Call.readChild(broker.runId(), id(),
                handles.get(0).id(), "edits/sub/file.txt"), () -> false);
        check(read.status() == IsolatedCapabilityBroker.Status.OK
                && workspace.lastTarget.equals("notes/edits/sub/file.txt"), "Child target not anchored to grant root");
        check(audit.stream().anyMatch(event -> event.phase() == IsolatedCapabilityBroker.Phase.CALL_STARTED
                && "notes/edits/sub/file.txt".equals(event.target())),
                "Audit omitted the resolved workspace-relative child");

        var edit = broker.execute(IsolatedCapabilityBroker.Call.editChild(broker.runId(), id(),
                handles.get(1).id(), "sub/file.txt", "0".repeat(64), "a", "b", 1), () -> false);
        check(edit.status() == IsolatedCapabilityBroker.Status.OK
                && workspace.lastTarget.equals("notes/edits/sub/file.txt"),
                "Writable subroot did not resolve its own child");
        int before = workspace.calls.get();
        denied(broker, IsolatedCapabilityBroker.Call.read(broker.runId(), id(), handles.get(0).id()));
        denied(broker, IsolatedCapabilityBroker.Call.readChild(broker.runId(), id(),
                handles.get(2).id(), "other.txt"));
        denied(broker, IsolatedCapabilityBroker.Call.editChild(broker.runId(), id(),
                handles.get(0).id(), "edits/sub/file.txt", "0".repeat(64), "a", "b", 1));
        denied(broker, IsolatedCapabilityBroker.Call.readChild(broker.runId(), id(),
                handles.get(0).id(), "x/x/x/x/x/x/x/x/x/x/x/x/x/x/x/x"));
        check(workspace.calls.get() == before, "Denied target reached workspace operations");

        for (String path : List.of("../secret", "/private", "a//b",
                "a\\b", "C:secret", "a/./b", "a/../b", "a\nsecret")) {
            try {
                IsolatedCapabilityBroker.Call.readChild(broker.runId(), id(), handles.get(0).id(), path);
                throw new AssertionError("Unsafe child path accepted: " + path);
            } catch (IllegalArgumentException expected) { /* No workspace call was issued. */ }
        }
        for (String root : List.of("/", "notes//", "notes/../", "notes-extra/../",
                "x".repeat(512) + "/")) {
            try {
                new IsolatedCapabilityBroker.GrantSpec(root, Set.of(IsolatedCapabilityBroker.Action.READ));
                throw new AssertionError("Unsafe root accepted: " + root);
            } catch (IllegalArgumentException expected) { /* Root cannot escape the workspace. */ }
        }
        try {
            new IsolatedCapabilityBroker(id(), workspace, audit::add,
                    List.of(new IsolatedCapabilityBroker.GrantSpec("notes-extra/",
                            Set.of(IsolatedCapabilityBroker.Action.READ))),
                    IsolatedCapabilityBroker.SandboxPolicy.readOnly(Set.of("notes/")), 10_000);
            throw new AssertionError("A similar-prefix directory escaped the selected root");
        } catch (IllegalArgumentException expected) { /* Directory prefix requires the slash boundary. */ }
        check(broker.cancel() == IsolatedCapabilityBroker.Terminal.CANCELLED, "Grant did not revoke");
        denied(broker, IsolatedCapabilityBroker.Call.readChild(broker.runId(), id(),
                handles.get(0).id(), "edits/sub/file.txt"));
        check(workspace.calls.get() == before, "Revoked root reached workspace operations");
        System.out.println("IsolatedCapabilityDirectoryGrantTest passed");
    }

    private static void denied(IsolatedCapabilityBroker broker, IsolatedCapabilityBroker.Call call) {
        check(broker.execute(call, () -> false).status() != IsolatedCapabilityBroker.Status.OK,
                "Unapproved target reached workspace");
    }
    private static String id() { return UUID.randomUUID().toString(); }
    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }

    private static final class TrackingWorkspace implements IsolatedCapabilityBroker.WorkspaceOps {
        final AtomicInteger calls = new AtomicInteger();
        volatile String lastTarget;
        public IsolatedCapabilityBroker.ReadData read(String filename, BooleanSupplier cancelled) {
            lastTarget = filename; calls.incrementAndGet();
            return new IsolatedCapabilityBroker.ReadData("0".repeat(64), "text");
        }
        public IsolatedCapabilityBroker.SearchData search(String filename, String query, int maxMatches,
                BooleanSupplier cancelled) {
            lastTarget = filename; calls.incrementAndGet();
            return new IsolatedCapabilityBroker.SearchData("0".repeat(64), List.of(), false);
        }
        public IsolatedCapabilityBroker.EditData edit(String filename, String revision,
                String needle, String replacement, int maxReplacements, BooleanSupplier cancelled) {
            lastTarget = filename; calls.incrementAndGet();
            return new IsolatedCapabilityBroker.EditData(revision, "1".repeat(64), 2);
        }
    }
}
