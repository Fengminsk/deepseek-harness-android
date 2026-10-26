package com.minnnng.dsh_android;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Set;
import java.util.UUID;

public final class IsolatedApprovedRunScopeTest {
    private interface Checked { void run() throws Exception; }
    private static void reject(Checked action, String reason) throws Exception {
        try { action.run(); throw new AssertionError(reason); }
        catch (IllegalArgumentException expected) { /* Fail closed. */ }
    }

    public static void main(String[] args) throws Exception {
        Path privateRoot = Files.createTempDirectory("approved-run-");
        try {
            Path workspace = Files.createDirectory(privateRoot.resolve("workspace"));
            String session = UUID.randomUUID().toString();
            String workspaceId = UUID.randomUUID().toString();
            var approved = IsolatedExecutionPolicyOwner.Scope.granted("app.session", session, 2,
                    privateRoot, workspace, Set.of("notes/a.txt", "notes/b.txt"),
                    Set.of("notes/a.txt"), Set.of("api.example.org", "data.example.org"),
                    8, 4, 10_000);
            Checked validSubset = () -> IsolatedApprovedRunScope.verify(approved,
                    session, workspaceId, session, workspaceId, "app.session", 2,
                    Set.of("notes/a.txt"), Set.of("notes/a.txt"), Set.of("api.example.org"),
                    8, 4, 10_000);
            validSubset.run();
            IsolatedApprovedRunScope.verify(approved,
                    session, workspaceId, session, workspaceId, "app.session", 2,
                    Set.of("notes/a.txt"), Set.of(), Set.of(), 8, 0, 10_000);
            IsolatedApprovedRunScope.verify(approved,
                    session, workspaceId, session, workspaceId, "app.session", 2,
                    Set.of(), Set.of(), Set.of("api.example.org"), 0, 4, 10_000);
            reject(() -> IsolatedApprovedRunScope.verify(approved,
                    session, workspaceId, session, workspaceId,
                    "app.session", 2, Set.of(), Set.of(), Set.of("api.example.org"),
                    8, 4, 10_000), "Dropped file category retained a call budget");
            reject(() -> IsolatedApprovedRunScope.verify(approved,
                    session, workspaceId, session, workspaceId,
                    "app.session", 2, Set.of("notes/a.txt"), Set.of(), Set.of(),
                    8, 4, 10_000), "Dropped network category retained a call budget");
            reject(() -> IsolatedApprovedRunScope.verify(approved,
                    session, workspaceId, UUID.randomUUID().toString(), workspaceId,
                    "app.session", 2, Set.of("notes/a.txt"), Set.of(), Set.of("api.example.org"), 8, 4, 10_000),
                    "Foreign session accepted");
            reject(() -> IsolatedApprovedRunScope.verify(approved,
                    session, workspaceId, session, UUID.randomUUID().toString(),
                    "app.session", 2, Set.of("notes/a.txt"), Set.of(), Set.of("api.example.org"), 8, 4, 10_000),
                    "Foreign workspace accepted");
            reject(() -> IsolatedApprovedRunScope.verify(approved,
                    session, workspaceId, session, workspaceId,
                    "app.session", 3, Set.of("notes/a.txt"), Set.of(), Set.of("api.example.org"), 8, 4, 10_000),
                    "Stale policy version accepted");
            reject(() -> IsolatedApprovedRunScope.verify(approved,
                    session, workspaceId, session, workspaceId,
                    "app.session", 2, Set.of("notes/a.txt", "notes/c.txt"), Set.of(),
                    Set.of("api.example.org"), 8, 4, 10_000), "Unapproved file accepted");
            reject(() -> IsolatedApprovedRunScope.verify(approved,
                    session, workspaceId, session, workspaceId,
                    "app.session", 2, Set.of("notes/b.txt"), Set.of("notes/b.txt"),
                    Set.of("api.example.org"), 8, 4, 10_000), "Read-only file became writable");
            reject(() -> IsolatedApprovedRunScope.verify(approved,
                    session, workspaceId, session, workspaceId,
                    "app.session", 2, Set.of("notes/a.txt"), Set.of(), Set.of("sub.api.example.org"),
                    8, 4, 10_000), "Subdomain extended HTTPS authority");
            reject(() -> IsolatedApprovedRunScope.verify(approved,
                    session, workspaceId, session, workspaceId,
                    "app.session", 2, Set.of("notes/a.txt"), Set.of(), Set.of("api.example.org"),
                    8, 5, 10_000), "Network budget increased");
            reject(() -> IsolatedApprovedRunScope.verify(approved,
                    session, workspaceId, session, workspaceId,
                    "app.session", 2, Set.of("notes/a.txt"), Set.of(), Set.of("api.example.org"),
                    8, 1, 10_000), "Smaller network budget was accepted but would not be enforced");
            reject(() -> IsolatedApprovedRunScope.verify(approved,
                    session, workspaceId, session, workspaceId,
                    "app.session", 2, Set.of("notes/a.txt"), Set.of(), Set.of("api.example.org"),
                    9, 4, 10_000), "File budget increased");
            reject(() -> IsolatedApprovedRunScope.verify(approved,
                    session, workspaceId, session, workspaceId,
                    "app.session", 2, Set.of("notes/a.txt"), Set.of(), Set.of("api.example.org"),
                    1, 4, 10_000), "Smaller file budget was accepted but would not be enforced");
            reject(() -> IsolatedApprovedRunScope.verify(approved,
                    session, workspaceId, session, workspaceId,
                    "app.session", 2, Set.of("notes/a.txt"), Set.of(), Set.of("api.example.org"),
                    8, 4, 11_000), "Lease increased");
            reject(() -> IsolatedApprovedRunScope.verify(approved,
                    session, workspaceId, session, workspaceId,
                    "app.session", 2, Set.of("notes/a.txt"), Set.of(), Set.of("api.example.org"),
                    8, 4, 5_000), "Smaller lease was accepted but would not be enforced");
            var approvedDirectory = IsolatedExecutionPolicyOwner.Scope.granted("app.session", session, 2,
                    privateRoot, workspace, Set.of("notes/"), Set.of(), Set.of(),
                    8, 0, 10_000);
            reject(() -> IsolatedApprovedRunScope.verify(approvedDirectory,
                    session, workspaceId, session, workspaceId,
                    "app.session", 2, Set.of("notes/"), Set.of(), Set.of(),
                    8, 0, 10_000), "Directory grant was admitted as an exact-file grant");
            reject(() -> IsolatedApprovedRunScope.verify(approved,
                    session, workspaceId, session, workspaceId,
                    "app.session", 2, Set.of(), Set.of(), Set.of(),
                    0, 0, 5_000), "Empty grant consumed an approved plan");
            System.out.println("IsolatedApprovedRunScopeTest passed");
        } finally {
            try (var paths = Files.walk(privateRoot)) {
                paths.sorted(java.util.Comparator.reverseOrder()).forEach(path -> {
                    try { Files.deleteIfExists(path); }
                    catch (Exception failure) { throw new RuntimeException(failure); }
                });
            }
        }
    }
}
