package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

/** Exercises process death against the same durable receipt and approval files. */
public final class IsolatedExecutionColdRecoveryTest {
    private static final String CHILD = "admit-and-die";
    private static final int INTENTIONAL_EXIT = 37;

    public static void main(String[] args) throws Exception {
        if (args.length == 5 && CHILD.equals(args[0])) {
            admitAndDie(Path.of(args[1]), args[2], args[3], args[4]);
            throw new AssertionError("Child returned instead of terminating");
        }
        if (args.length != 0) throw new IllegalArgumentException("Unexpected test arguments");
        Path privateRoot = Files.createTempDirectory("isolated-cold-recovery-");
        try {
            for (boolean approvedLease : new boolean[] { false, true }) {
                coldRecovery(privateRoot, approvedLease);
            }
            System.out.println("IsolatedExecutionColdRecoveryTest passed");
        } finally { delete(privateRoot); }
    }

    private static void coldRecovery(Path privateRoot, boolean approvedLease) throws Exception {
        Path scenario = Files.createDirectory(privateRoot.resolve(approvedLease ? "leased" : "admitted"));
        Path policy = Files.createDirectory(scenario.resolve("policy"));
        Path workspace = Files.createDirectory(scenario.resolve("workspace"));
        Files.write(workspace.resolve("note.txt"), "private".getBytes(java.nio.charset.StandardCharsets.UTF_8));
        String runId = UUID.randomUUID().toString();
        String sessionId = UUID.randomUUID().toString();
        String approvalId = UUID.randomUUID().toString();
        String javaBinary = Path.of(System.getProperty("java.home"), "bin",
                System.getProperty("os.name").startsWith("Windows") ? "java.exe" : "java").toString();
        Process child = new ProcessBuilder(javaBinary, "-cp", System.getProperty("java.class.path"),
                getClassName(), CHILD, scenario.toString(), runId, sessionId,
                approvedLease ? approvalId : "none").inheritIO().start();
        if (!child.waitFor(10, TimeUnit.SECONDS)) {
            child.destroyForcibly();
            throw new AssertionError("Admission process did not terminate");
        }
        check(child.exitValue() == INTENTIONAL_EXIT, "Admission process failed before its crash point");

        IsolatedScriptReceipt receipts = new IsolatedScriptReceipt(scenario, ignored -> {});
        check(receipts.read(runId).state() == IsolatedScriptReceipt.State.ADMITTED,
                "The child did not durably admit its run");
        try (var recovered = new IsolatedExecutionApprovalStore(scenario, policy,
                "cold.task", sessionId, ignored -> {})) {
            var denied = recovered.recoveredDenied();
            check(denied.readablePaths().isEmpty() && denied.writablePaths().isEmpty()
                    && denied.exactHosts().isEmpty(), "Cold start restored a capability");
            check(denied.version() == (approvedLease ? 3 : 1),
                    "Cold start policy version did not revoke the grant");
            if (approvedLease) {
                var reissued = grant(scenario, workspace, sessionId, denied.version() + 1);
                try {
                    recovered.prepareTrustedUiApproval(reissued, approvalId);
                    throw new AssertionError("A pre-crash approval was reusable");
                } catch (IllegalArgumentException expected) { /* A new UI decision is required. */ }
            }
        }

        var interrupted = receipts.recoverInterrupted();
        check(interrupted.size() == 1 && interrupted.get(0).runId().equals(runId)
                && interrupted.get(0).state() == IsolatedScriptReceipt.State.INTERRUPTED_UNCONFIRMED,
                "Cold start did not retire the interrupted run without output");
        check(interrupted.get(0).outputJson() == null && receipts.recoverInterrupted().isEmpty(),
                "Recovered output or repeated the interruption transition");
        try {
            receipts.finish(new IsolatedScriptReceipt.Entry(runId,
                    IsolatedScriptReceipt.State.COMPLETED, "{\"late\":true}", null));
            throw new AssertionError("A stale guest response published output after recovery");
        } catch (IOException expected) { /* The terminal receipt cannot be replaced. */ }
        try {
            receipts.admit(runId);
            throw new AssertionError("The interrupted run ID was replayed");
        } catch (IOException expected) { /* The durable ID ledger survives process death. */ }
        check(receipts.read(runId).state() == IsolatedScriptReceipt.State.INTERRUPTED_UNCONFIRMED,
                "A rejected stale response changed the terminal receipt");
    }

    private static void admitAndDie(Path scenario, String runId, String sessionId,
                                    String approvalId) throws Exception {
        IsolatedScriptReceipt receipts = new IsolatedScriptReceipt(scenario, ignored -> {});
        Path policy = scenario.resolve("policy");
        try (var store = new IsolatedExecutionApprovalStore(scenario, policy,
                "cold.task", sessionId, ignored -> {})) {
            var owner = store.newOwner((id, ignored) -> receipts.admit(id));
            if (!"none".equals(approvalId)) {
                var grant = grant(scenario, scenario.resolve("workspace"), sessionId, 2);
                store.prepareTrustedUiApproval(grant, approvalId);
                owner.replace(grant);
            }
            var lease = owner.admit(runId);
            check(lease.active(owner.current().version()), "Admission did not create a live lease");
            // The process dies while its policy writer and lease are live, without close or finish.
            Runtime.getRuntime().halt(INTENTIONAL_EXIT);
        }
    }

    private static IsolatedExecutionPolicyOwner.Scope grant(Path privateRoot, Path workspace,
            String sessionId, long version) throws IOException {
        return IsolatedExecutionPolicyOwner.Scope.granted("cold.task", sessionId, version,
                privateRoot, workspace, Set.of("note.txt"), Set.of(), Set.of(), 1, 0, 5_000);
    }

    private static String getClassName() { return IsolatedExecutionColdRecoveryTest.class.getName(); }
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    private static void delete(Path root) throws IOException {
        try (var paths = Files.walk(root)) {
            for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(path);
        }
    }
}
