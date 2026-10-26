package com.minnnng.dsh_android;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

/** Plain JVM checks for fixed executable resolution; actual exec requires Android instrumentation. */
public final class PackagedLinuxUtilityTest {
    public static void main(String[] args) throws Exception {
        IsolatedLinuxCommandPolicy.Request candidate = IsolatedLinuxCommandPolicy.Request.of(
            IsolatedLinuxCommandPolicy.Command.TEST_PACKAGED_COUNT_BYTES, null, new byte[] {1, 2});
        IsolatedLinuxCommandPolicy.Request ordinary = IsolatedLinuxCommandPolicy.Request.of(
            IsolatedLinuxCommandPolicy.Command.COUNT_BYTES, null, new byte[] {1, 2});
        IsolatedLinuxCommandPolicy.Request sha = IsolatedLinuxCommandPolicy.Request.of(
            IsolatedLinuxCommandPolicy.Command.SHA256, null, new byte[] {1, 2});
        IsolatedLinuxCommandPolicy.Request lines = IsolatedLinuxCommandPolicy.Request.of(
            IsolatedLinuxCommandPolicy.Command.COUNT_LINES, null, new byte[] {1, 2});
        IsolatedLinuxCommandPolicy.Request system = IsolatedLinuxCommandPolicy.Request.of(
            IsolatedLinuxCommandPolicy.Command.KERNEL, null, null);
        require(PackagedLinuxUtility.argv(system, null).equals(system.argv()));
        rejected(candidate, null);
        rejected(candidate, "relative/library/directory");
        rejected(ordinary, null);
        rejected(sha, null);
        rejected(lines, null);
        Path root = Files.createTempDirectory("pocket-linux-utility-test-");
        try {
            rejected(candidate, root.toString());
            Path binary = root.resolve(PackagedLinuxUtility.EXECUTABLE_NAME);
            Files.write(binary, new byte[] {1, 2, 3});
            String pinned = binary.toFile().getCanonicalPath();
            require(PackagedLinuxUtility.argv(candidate, root.toString()).equals(
                List.of(pinned, "count_bytes")));
            require(PackagedLinuxUtility.argv(ordinary, root.toString()).equals(
                List.of(pinned, "count_bytes")));
            require(PackagedLinuxUtility.argv(sha, root.toString()).equals(
                List.of(pinned, "sha256")));
            require(PackagedLinuxUtility.argv(lines, root.toString()).equals(
                List.of(pinned, "count_lines")));
            Path other = Files.createTempFile("pocket-linux-utility-other-", ".so");
            try {
                Files.delete(binary);
                Files.createSymbolicLink(binary, other);
                rejected(candidate, root.toString());
                rejected(ordinary, root.toString());
            } catch (UnsupportedOperationException | java.nio.file.FileSystemException unsupported) {
                // Windows symlink privilege is not required for the positive path.
            } finally {
                Files.deleteIfExists(other);
            }
        } finally {
            Path binary = root.resolve(PackagedLinuxUtility.EXECUTABLE_NAME);
            Files.deleteIfExists(binary);
            Files.delete(root);
        }
        System.out.println("PackagedLinuxUtilityTest passed");
    }

    private static void rejected(IsolatedLinuxCommandPolicy.Request request, String directory) {
        try {
            PackagedLinuxUtility.argv(request, directory);
            throw new AssertionError("Unsafe executable accepted");
        } catch (IOException expected) { /* Fail closed. */ }
    }

    private static void require(boolean condition) {
        if (!condition) throw new AssertionError("Packaged utility resolution failed");
    }
}
