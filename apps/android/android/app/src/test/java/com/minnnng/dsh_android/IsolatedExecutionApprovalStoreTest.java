package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;

public final class IsolatedExecutionApprovalStoreTest {
    private static String id() { return UUID.randomUUID().toString(); }
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    private static void denied(IsolatedExecutionPolicyOwner.Scope scope) {
        check(scope.readablePaths().isEmpty() && scope.writablePaths().isEmpty()
                && scope.exactHosts().isEmpty(), "Recovered policy retained a grant");
    }

    public static void main(String[] args) throws Exception {
        grantRequiresFreshAppDecisionAndRestartRevokes();
        uncertainWriteNeverRestoresAuthority();
        damagedLogAndConcurrentWriterFailClosed();
        boundedHistoryRefusesFurtherTransitions();
        System.out.println("IsolatedExecutionApprovalStoreTest passed");
    }

    private static void grantRequiresFreshAppDecisionAndRestartRevokes() throws Exception {
        Path privateRoot = Files.createTempDirectory("approval-store-");
        Path directory = Files.createDirectory(privateRoot.resolve("policies"));
        Path workspace = Files.createDirectory(privateRoot.resolve("workspace"));
        String ownerId = "session.task";
        String sessionId = "android-1793060921975320-627842147";
        String approvalId = id();
        try {
            try (var store = new IsolatedExecutionApprovalStore(privateRoot, directory,
                    ownerId, sessionId, ignored -> {})) {
                var owner = store.newOwner((runId, scope) -> {});
                check(owner.current().sessionId().equals(sessionId), "Actual Android Session identity changed");
                denied(owner.current());
                check(owner.current().version() == 1, "Fresh version changed");
                var grant = grant(ownerId, sessionId, 2, privateRoot, workspace);
                try {
                    owner.replace(grant);
                    throw new AssertionError("Grant without a UI approval was accepted");
                } catch (IllegalArgumentException expected) {
                    denied(owner.current());
                }
                try {
                    store.newOwner((runId, scope) -> {});
                    throw new AssertionError("One store issued concurrent policy owners");
                } catch (IOException expected) { /* Closed owner needs a reopened store. */ }
            }
            try (var store = new IsolatedExecutionApprovalStore(privateRoot, directory,
                    ownerId, sessionId, ignored -> {})) {
                var owner = store.newOwner((runId, scope) -> {});
                var grant = grant(ownerId, sessionId, 2, privateRoot, workspace);
                store.prepareTrustedUiApproval(grant, approvalId);
                owner.replace(grant);
                check(owner.current().version() == 2 && store.transitionCount() == 1,
                        "Approved transition was not stored");
            }
            Files.write(directory.resolve("approval-abandoned.tmp"), "unpublished".getBytes(java.nio.charset.StandardCharsets.UTF_8));
            try (var restarted = new IsolatedExecutionApprovalStore(privateRoot, directory,
                    ownerId, sessionId, ignored -> {})) {
                check(!Files.exists(directory.resolve("approval-abandoned.tmp")),
                        "Unpublished temp survived recovery");
                var scope = restarted.recoveredDenied();
                denied(scope);
                check(scope.version() == 3 && restarted.transitionCount() == 2,
                        "Restart did not persist a new revoked version");
                var owner = restarted.newOwner((runId, admitted) -> {});
                denied(owner.current());
                var next = grant(ownerId, sessionId, 4, privateRoot, workspace);
                try {
                    restarted.prepareTrustedUiApproval(next, approvalId);
                    throw new AssertionError("Approval ID was reusable");
                } catch (IllegalArgumentException expected) { /* One-use decision. */ }
                restarted.prepareTrustedUiApproval(next, id());
                owner.replace(next);
                check(owner.current().version() == 4, "Fresh approval was rejected");
            }
        } finally { delete(privateRoot); }
    }

    private static void uncertainWriteNeverRestoresAuthority() throws Exception {
        Path privateRoot = Files.createTempDirectory("approval-uncertain-");
        Path directory = Files.createDirectory(privateRoot.resolve("policies"));
        Path workspace = Files.createDirectory(privateRoot.resolve("workspace"));
        String ownerId = "uncertain.task";
        String sessionId = id();
        AtomicBoolean failSync = new AtomicBoolean();
        try {
            try (var store = new IsolatedExecutionApprovalStore(privateRoot, directory,
                    ownerId, sessionId, ignored -> {
                        if (failSync.get()) throw new IOException("Directory fsync uncertain");
                    })) {
                var owner = store.newOwner((runId, scope) -> {});
                var grant = grant(ownerId, sessionId, 2, privateRoot, workspace);
                store.prepareTrustedUiApproval(grant, id());
                failSync.set(true);
                try {
                    owner.replace(grant);
                    throw new AssertionError("Uncertain transition became active");
                } catch (IOException expected) {
                    denied(owner.current());
                }
                try {
                    store.recoveredDenied();
                    throw new AssertionError("Uncertain writer remained open");
                } catch (IOException expected) { /* A new process must inspect the log. */ }
            }
            try (var restarted = new IsolatedExecutionApprovalStore(privateRoot, directory,
                    ownerId, sessionId, ignored -> {})) {
                denied(restarted.recoveredDenied());
                check(restarted.recoveredDenied().version() == 3,
                        "Visible uncertain grant was not durably revoked");
            }
        } finally { delete(privateRoot); }
    }

    private static void damagedLogAndConcurrentWriterFailClosed() throws Exception {
        Path privateRoot = Files.createTempDirectory("approval-damaged-");
        Path directory = Files.createDirectory(privateRoot.resolve("policies"));
        String ownerId = "damaged.task";
        String sessionId = id();
        try {
            try (var writer = new IsolatedExecutionApprovalStore(privateRoot, directory,
                    ownerId, sessionId, ignored -> {})) {
                try (var ignored = new IsolatedExecutionApprovalStore(privateRoot, directory,
                        ownerId, sessionId, path -> {})) {
                    throw new AssertionError("Second writer acquired the policy lock");
                } catch (IOException expected) { /* Only one process may replace history. */ }
                var owner = writer.newOwner((runId, scope) -> {});
                owner.replace(IsolatedExecutionPolicyOwner.Scope.denied(ownerId, sessionId, 2));
            }
            Path log = directory.resolve("policy-transitions.log");
            byte[] bytes = Files.readAllBytes(log);
            bytes[bytes.length - 1] ^= 1;
            Files.write(log, bytes);
            try (var ignored = new IsolatedExecutionApprovalStore(privateRoot, directory,
                    ownerId, sessionId, path -> {})) {
                throw new AssertionError("Damaged policy log was accepted");
            } catch (IOException expected) { /* Preserve evidence and deny admission. */ }
            check(Files.readAllBytes(log)[bytes.length - 1] == bytes[bytes.length - 1],
                    "Damaged history was silently replaced");
        } finally { delete(privateRoot); }
    }

    private static void boundedHistoryRefusesFurtherTransitions() throws Exception {
        Path privateRoot = Files.createTempDirectory("approval-capacity-");
        Path directory = Files.createDirectory(privateRoot.resolve("policies"));
        String ownerId = "capacity.task";
        String sessionId = id();
        try {
            try (var store = new IsolatedExecutionApprovalStore(privateRoot, directory,
                    ownerId, sessionId, ignored -> {})) {
                var owner = store.newOwner((runId, scope) -> {});
                for (int index = 0; index < IsolatedExecutionApprovalStore.MAX_TRANSITIONS; index++) {
                    owner.replace(IsolatedExecutionPolicyOwner.Scope.denied(
                            ownerId, sessionId, index + 2L));
                }
                try {
                    owner.replace(IsolatedExecutionPolicyOwner.Scope.denied(
                            ownerId, sessionId, IsolatedExecutionApprovalStore.MAX_TRANSITIONS + 2L));
                    throw new AssertionError("Full policy history admitted a new version");
                } catch (IOException expected) { /* Failed writer closes until restart inspection. */ }
            }
            try (var restarted = new IsolatedExecutionApprovalStore(privateRoot, directory,
                    ownerId, sessionId, ignored -> {})) {
                denied(restarted.recoveredDenied());
                check(restarted.transitionCount() == IsolatedExecutionApprovalStore.MAX_TRANSITIONS,
                        "Capacity failure changed the durable transition count");
                check(restarted.recoveredDenied().version()
                        == IsolatedExecutionApprovalStore.MAX_TRANSITIONS + 1L,
                        "Denied version changed across restart");
            }
        } finally { delete(privateRoot); }
    }

    private static IsolatedExecutionPolicyOwner.Scope grant(String ownerId, String sessionId,
            long version, Path privateRoot, Path workspace) throws IOException {
        return IsolatedExecutionPolicyOwner.Scope.granted(ownerId, sessionId, version,
                privateRoot, workspace, Set.of("note.txt"), Set.of("note.txt"),
                Set.of(), 2, 0, 5_000);
    }

    private static void delete(Path root) throws IOException {
        try (var paths = Files.walk(root)) {
            for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(path);
        }
    }
}
