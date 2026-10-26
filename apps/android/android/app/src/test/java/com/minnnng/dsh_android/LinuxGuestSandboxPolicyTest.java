package com.minnnng.dsh_android;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Set;
import java.util.UUID;

public final class LinuxGuestSandboxPolicyTest {
    private static String id() { return UUID.randomUUID().toString(); }
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    public static void main(String[] ignored) throws Exception {
        deniesByDefaultAndAfterRevocation();
        grantsOnlyBrokeredVirtualPathsAndExactHosts();
        narrowsChildrenAndRejectsExpiredLeases();
        System.out.println("LinuxGuestSandboxPolicyTest passed");
    }

    private static void deniesByDefaultAndAfterRevocation() throws Exception {
        var owner = new IsolatedExecutionPolicyOwner("guest.default", id(),
                (run, scope) -> {}, (previous, next) -> {});
        var lease = owner.admit(id());
        var policy = LinuxGuestSandboxPolicy.fromLease(lease);
        check(policy.fileCallLimit() == 0 && policy.networkCallLimit() == 0,
                "Default policy exposed a broker-call budget");
        check(!policy.permitsBrokeredFile("/workspace/readme.txt",
                IsolatedCapabilityBroker.Action.READ), "Default policy granted a file");
        check(!policy.permitsBrokeredHttpsHost("example.com"), "Default policy granted network");
        owner.revoke(lease.runId());
        check(!policy.active(), "Revoked guest policy remained active");
        try {
            LinuxGuestSandboxPolicy.fromLease(lease);
            throw new AssertionError("Revoked lease was re-projected");
        } catch (IllegalStateException expected) { /* Revoked leases cannot regain authority. */ }
    }

    private static void grantsOnlyBrokeredVirtualPathsAndExactHosts() throws Exception {
        Path root = Files.createTempDirectory("linux-guest-policy-");
        Path workspace = Files.createDirectory(root.resolve("workspace"));
        try {
            var owner = new IsolatedExecutionPolicyOwner("guest.scope", id(),
                    (run, scope) -> {}, (previous, next) -> {});
            owner.replace(IsolatedExecutionPolicyOwner.Scope.granted(
                    "guest.scope", owner.current().sessionId(), 2, root, workspace,
                    Set.of("docs/", "notes.txt"), Set.of("docs/"),
                    Set.of("example.com"), 8, 2, 10_000));
            var lease = owner.admit(id());
            var policy = LinuxGuestSandboxPolicy.fromLease(lease);
            check(policy.fileCallLimit() == 8 && policy.networkCallLimit() == 2,
                    "Guest broker-call ceilings differ from the approved lease");
            check(policy.permitsBrokeredFile("/workspace/docs/a.txt",
                    IsolatedCapabilityBroker.Action.READ), "Approved workspace read denied");
            check(policy.permitsBrokeredFile("/workspace/docs/a.txt",
                    IsolatedCapabilityBroker.Action.EDIT), "Approved workspace write denied");
            check(policy.permitsBrokeredFile("/workspace/notes.txt",
                    IsolatedCapabilityBroker.Action.SEARCH), "Approved exact-file search denied");
            check(!policy.permitsBrokeredFile("/workspace/notes.txt",
                    IsolatedCapabilityBroker.Action.EDIT), "Read-only file became writable");
            for (String path : new String[]{
                    "/workspace/docs/.git/config", "/workspace/docs/.agents/config",
                    "/workspace/docs/.codex/keys", "/workspace/docs/.aws/credentials",
                    "/workspace/docs/../secret", "/workspace/docs//a", "/workspace/docs\\a",
                    "/workspace/docs/C:secret", "/workspace/docs/a\u0000b",
                    "/workspace2/docs/a", "C:/workspace/docs/a", "/docs/a", "/workspace/docs/"
            }) {
                check(!policy.permitsBrokeredFile(path, IsolatedCapabilityBroker.Action.EDIT),
                        "Unsafe guest path became writable: " + path);
            }
            check(policy.permitsBrokeredHttpsHost("example.com"), "Exact approved host denied");
            check(!policy.permitsBrokeredHttpsHost("EXAMPLE.COM")
                    && !policy.permitsBrokeredHttpsHost("api.example.com")
                    && !policy.permitsBrokeredHttpsHost("example.com:443"),
                    "Host allow-list widened");
            owner.replace(IsolatedExecutionPolicyOwner.Scope.denied(
                    "guest.scope", owner.current().sessionId(), 3));
            check(!policy.permitsBrokeredFile("/workspace/docs/a.txt",
                    IsolatedCapabilityBroker.Action.READ)
                    && !policy.permitsBrokeredHttpsHost("example.com"),
                    "Policy replacement retained guest authority");
        } finally {
            Files.delete(workspace);
            Files.delete(root);
        }
    }

    private static void narrowsChildrenAndRejectsExpiredLeases() throws Exception {
        Path root = Files.createTempDirectory("linux-guest-child-");
        Path workspace = Files.createDirectory(root.resolve("workspace"));
        try {
            var owner = new IsolatedExecutionPolicyOwner("guest.child", id(),
                    (run, scope) -> {}, (previous, next) -> {});
            owner.replace(IsolatedExecutionPolicyOwner.Scope.granted(
                    "guest.child", owner.current().sessionId(), 2, root, workspace,
                    Set.of("docs/"), Set.of("docs/"), Set.of("example.com"), 8, 2, 10_000));
            var parent = owner.admit(id());
            var child = owner.admitChild(parent.runId(), id(),
                    IsolatedExecutionPolicyOwner.Scope.granted(
                            "guest.child", owner.current().sessionId(), 2, root, workspace,
                            Set.of("docs/a.txt"), Set.of(), Set.of(), 2, 0, 1_000));
            var policy = LinuxGuestSandboxPolicy.fromLease(child);
            check(policy.permitsBrokeredFile("/workspace/docs/a.txt",
                    IsolatedCapabilityBroker.Action.READ), "Narrow child read denied");
            check(!policy.permitsBrokeredFile("/workspace/docs/b.txt",
                    IsolatedCapabilityBroker.Action.READ)
                    && !policy.permitsBrokeredFile("/workspace/docs/a.txt",
                            IsolatedCapabilityBroker.Action.EDIT)
                    && !policy.permitsBrokeredHttpsHost("example.com"),
                    "Child inherited authority it did not request");
            owner.revoke(parent.runId());
            check(!policy.active(), "Revoking parent left child guest scope active");
        } finally {
            Files.delete(workspace);
            Files.delete(root);
        }
    }
}
