package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;

public final class DurableWorkflowOwnerTest {
    public static void main(String[] args) throws Exception {
        if (args.length == 3 && args[0].equals("recover")) {
            DurableWorkflowOwner owner = new DurableWorkflowOwner(Path.of(args[1]), ignored -> {});
            List<DurableWorkflowOwner.Recovery> found = owner.recoverInterrupted();
            if (found.size() != 1 || !found.get(0).childIdsToCancel().equals(List.of(args[2])))
                throw new AssertionError("Recovery lost the owned child ID");
            return;
        }
        Path parent = Files.createTempDirectory("durable-workflow-owner-");
        DurableWorkflowOwner owner = new DurableWorkflowOwner(parent, ignored -> {});
        IsolatedScriptReceipt scripts = new IsolatedScriptReceipt(parent, ignored -> {});
        refuses(() -> owner.admit(UUID.randomUUID().toString()));
        owner.recoverInterrupted();

        String complete = UUID.randomUUID().toString();
        owner.admit(complete);
        scripts.admit(complete);
        String owned = owner.reserveChild(complete);
        if (!UUID.fromString(owned).toString().equals(owned)
                || !owner.read(complete).children().equals(List.of(
                        new DurableWorkflowOwner.Child(owned, DurableWorkflowOwner.ChildState.RESERVED))))
            throw new AssertionError("Child Session ID is not durably bound to run");
        refuses(() -> owner.markLaunching(UUID.randomUUID().toString(), owned));
        refuses(() -> owner.confirmChildRetired(complete, owned));
        owner.markLaunching(complete, owned);
        scripts.finish(new IsolatedScriptReceipt.Entry(
                complete, IsolatedScriptReceipt.State.COMPLETED, "{\"answer\":1}", null));
        refuses(() -> owner.complete(complete, scripts));
        owner.confirmChildRetired(complete, owned);
        DurableWorkflowOwner.Entry published = owner.complete(complete, scripts);
        if (published.state() != DurableWorkflowOwner.State.COMPLETED
                || !"{\"answer\":1}".equals(owner.read(complete).outputJson()))
            throw new AssertionError("Confirmed output was not persisted");
        refuses(() -> owner.admit(complete));
        refuses(() -> owner.complete(complete, scripts));
        refuses(() -> owner.reserveChild(complete));

        String restart = UUID.randomUUID().toString();
        owner.admit(restart);
        String stranded = owner.reserveChild(restart);
        owner.markLaunching(restart, stranded);
        Files.write(parent.resolve("workflow-runs").resolve("workflow-unpublished.tmp"),
                new byte[] { 1, 2, 3 });
        Process process = new ProcessBuilder(
                Path.of(System.getProperty("java.home"), "bin", isWindows() ? "java.exe" : "java").toString(),
                "-cp", System.getProperty("java.class.path"), DurableWorkflowOwnerTest.class.getName(),
                "recover", parent.toString(), stranded).inheritIO().start();
        if (process.waitFor() != 0) throw new AssertionError("Cross-process recovery failed");
        DurableWorkflowOwner afterRestart = new DurableWorkflowOwner(parent, ignored -> {});
        refuses(() -> afterRestart.confirmStoppedChild(restart, stranded));
        afterRestart.recoverInterrupted();
        if (afterRestart.read(restart).state() != DurableWorkflowOwner.State.INTERRUPTED_UNCONFIRMED
                || afterRestart.read(restart).outputJson() != null
                || !afterRestart.recoverInterrupted().equals(List.of(
                        new DurableWorkflowOwner.Recovery(restart, List.of(stranded)))))
            throw new AssertionError("Interrupted run was exposed as success or lost cancellation ID");
        refuses(() -> afterRestart.admit(restart));
        if (!Files.exists(parent.resolve("workflow-runs").resolve("workflow-unpublished.tmp")))
            throw new AssertionError("Recovery unexpectedly used an unpublished temp as a receipt");
        refuses(() -> afterRestart.markLaunching(restart, stranded));
        afterRestart.confirmStoppedChild(restart, stranded);
        if (!afterRestart.recoverInterrupted().isEmpty())
            throw new AssertionError("Retired child was still pending cancellation");

        String cancellation = UUID.randomUUID().toString();
        owner.admit(cancellation);
        scripts.admit(cancellation);
        String cancelledChild = owner.reserveChild(cancellation);
        owner.markLaunching(cancellation, cancelledChild);
        if (!owner.requestCancel(cancellation).equals(List.of(cancelledChild))
                || !owner.requestCancel(cancellation).equals(List.of(cancelledChild)))
            throw new AssertionError("Cancellation lost owned child");
        refuses(() -> owner.reserveChild(cancellation));
        scripts.finish(new IsolatedScriptReceipt.Entry(
                cancellation, IsolatedScriptReceipt.State.CANCELLED, null, null));
        refuses(() -> owner.complete(cancellation, scripts));
        refuses(() -> owner.confirmCancelled(cancellation, scripts));
        owner.confirmStoppedChild(cancellation, cancelledChild);
        if (owner.confirmCancelled(cancellation, scripts).state() != DurableWorkflowOwner.State.CANCELLED)
            throw new AssertionError("Confirmed cancellation did not settle");

        String failed = UUID.randomUUID().toString();
        owner.admit(failed);
        scripts.admit(failed);
        String failedChild = owner.reserveChild(failed);
        owner.markLaunching(failed, failedChild);
        scripts.finish(new IsolatedScriptReceipt.Entry(
                failed, IsolatedScriptReceipt.State.ERROR, null, "guest failed"));
        refuses(() -> owner.confirmFailed(failed, scripts));
        owner.requestCancel(failed);
        owner.confirmStoppedChild(failed, failedChild);
        if (owner.confirmFailed(failed, scripts).state() != DurableWorkflowOwner.State.FAILED)
            throw new AssertionError("Confirmed guest failure was not closed durably");
        refuses(() -> owner.confirmFailed(failed, scripts));
        if (!owner.recoverInterrupted().isEmpty())
            throw new AssertionError("Terminal failed workflow was replayed after recovery");

        String reportedError = UUID.randomUUID().toString();
        owner.admit(reportedError);
        scripts.admit(reportedError);
        scripts.finish(new IsolatedScriptReceipt.Entry(reportedError,
                IsolatedScriptReceipt.State.COMPLETED,
                "{\"value\":null,\"stopReason\":\"error\",\"agentsStarted\":0}", null));
        DurableWorkflowOwner.Entry failedDsl = owner.confirmGuestReportedFailure(reportedError, scripts);
        if (failedDsl.state() != DurableWorkflowOwner.State.FAILED
                || failedDsl.outputJson() != null || owner.read(reportedError).outputJson() != null)
            throw new AssertionError("Guest-reported failure exposed output as success");
        refuses(() -> owner.complete(reportedError, scripts));

        String uncertainLive = UUID.randomUUID().toString();
        owner.admit(uncertainLive);
        String uncertainChild = owner.reserveChild(uncertainLive);
        owner.markLaunching(uncertainLive, uncertainChild);
        if (owner.markUnconfirmed(uncertainLive).state() != DurableWorkflowOwner.State.INTERRUPTED_UNCONFIRMED
                || !owner.recoverInterrupted().equals(List.of(
                        new DurableWorkflowOwner.Recovery(uncertainLive, List.of(uncertainChild)))))
            throw new AssertionError("Unconfirmed child identity was not retained");

        String unconfirmed = UUID.randomUUID().toString();
        owner.admit(unconfirmed);
        scripts.admit(unconfirmed);
        refuses(() -> owner.complete(unconfirmed, scripts));
        afterRestart.recoverInterrupted();
        if (owner.read(unconfirmed).state() != DurableWorkflowOwner.State.INTERRUPTED_UNCONFIRMED)
            throw new AssertionError("Unconfirmed guest completion was published");

        Path uncertainParent = Files.createDirectory(parent.resolve("uncertain-replacement"));
        AtomicBoolean failNextSync = new AtomicBoolean();
        DurableWorkflowOwner uncertain = new DurableWorkflowOwner(uncertainParent, directory -> {
            if (directory.getFileName().toString().equals("workflow-runs")
                    && failNextSync.getAndSet(false))
                throw new IOException("injected replacement sync failure");
        });
        uncertain.recoverInterrupted();
        String uncertainRun = UUID.randomUUID().toString();
        uncertain.admit(uncertainRun);
        failNextSync.set(true);
        refuses(() -> uncertain.reserveChild(uncertainRun));
        String reservedButUnconfirmed = uncertain.read(uncertainRun).children().get(0).id();
        if (!UUID.fromString(reservedButUnconfirmed).toString().equals(reservedButUnconfirmed))
            throw new AssertionError("Unconfirmed reservation did not retain a child Session ID");
        refuses(() -> uncertain.markLaunching(uncertainRun, reservedButUnconfirmed));
        String refusedDuringUncertainty = UUID.randomUUID().toString();
        refuses(() -> uncertain.admit(refusedDuringUncertainty));
        if (Files.exists(uncertainParent.resolve("workflow-runs")
                .resolve("run-" + refusedDuringUncertainty + ".receipt")))
            throw new AssertionError("Uncertain owner admitted a second run before recovery");
        if (!uncertain.recoverInterrupted().equals(List.of(new DurableWorkflowOwner.Recovery(
                uncertainRun, List.of(reservedButUnconfirmed)))))
            throw new AssertionError("Uncertain replacement did not require recovery of the reserved child");
        refuses(() -> uncertain.markLaunching(uncertainRun, reservedButUnconfirmed));

        String damaged = UUID.randomUUID().toString();
        owner.admit(damaged);
        Files.write(parent.resolve("workflow-runs").resolve("run-" + damaged + ".receipt"),
                new byte[] { 1, 2, 3 });
        refuses(() -> owner.read(damaged));
        refuses(() -> owner.admit(damaged));
        refuses(owner::recoverInterrupted);

        Path failedParent = Files.createDirectory(parent.resolve("sync-failure"));
        String consumed = UUID.randomUUID().toString();
        DurableWorkflowOwner failedSync = new DurableWorkflowOwner(failedParent, directory -> {
            if (directory.getFileName().toString().equals("workflow-runs")
                    && Files.exists(directory.resolve("run-" + consumed + ".receipt")))
                throw new IOException("injected directory sync failure");
        });
        failedSync.recoverInterrupted();
        refuses(() -> failedSync.admit(consumed));
        String refusedAfterAdmission = UUID.randomUUID().toString();
        refuses(() -> failedSync.admit(refusedAfterAdmission));
        if (Files.exists(failedParent.resolve("workflow-runs")
                .resolve("run-" + refusedAfterAdmission + ".receipt")))
            throw new AssertionError("Admission sync failure did not revoke the current owner");
        DurableWorkflowOwner resumed = new DurableWorkflowOwner(failedParent, ignored -> {});
        resumed.recoverInterrupted();
        refuses(() -> resumed.admit(consumed));
        if (resumed.read(consumed).state() != DurableWorkflowOwner.State.INTERRUPTED_UNCONFIRMED)
            throw new AssertionError("Uncertain admission was replayable");
        System.out.println("Durable workflow owner host checks passed.");
    }

    private static boolean isWindows() {
        return System.getProperty("os.name").toLowerCase().contains("win");
    }

    private interface Checked { void run() throws Exception; }

    private static void refuses(Checked operation) throws Exception {
        try { operation.run(); }
        catch (IOException | IllegalArgumentException expected) { return; }
        throw new AssertionError("Expected a fail-closed workflow operation");
    }
}
