package com.minnnng.dsh_android;

import java.io.File;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

/** Uses real JVM/FileChannel locks, including a second process simulating an Activity save worker. */
public final class AttachmentCacheLeaseTest {
    public static void main(String[] args) throws Exception {
        if (args.length == 3 && args[0].equals("hold")) {
            try (var lease = AttachmentCacheLease.acquire(new File(args[1]), args[2])) {
                System.out.println("LOCKED");
                System.out.flush();
                System.in.read();
            }
            return;
        }
        Path root = Files.createTempDirectory("pocket-file-lease-test-");
        Path foreign = root.resolve("unowned-notes.txt");
        Files.writeString(foreign, "retain");
        try {
            var service = AttachmentCacheLease.create(root.toFile());
            Path instance = service.directory().toPath();
            Path source = instance.resolve(UUID.randomUUID() + ".file");
            Files.writeString(source, "verified");
            var sameJvmSave = AttachmentCacheLease.acquire(root.toFile(), service.instance());
            AttachmentCacheLease.collect(root.toFile());
            check(Files.exists(source), "collector touched active service");
            service.close();
            AttachmentCacheLease.collect(root.toFile());
            check(Files.exists(source), "collector touched refcounted same-JVM save");
            sameJvmSave.close();

            Process child = new ProcessBuilder(new File(System.getProperty("java.home"), "bin/java").getPath(),
                    "-cp", System.getProperty("java.class.path"), AttachmentCacheLeaseTest.class.getName(),
                    "hold", root.toString(), instance.getFileName().toString()).redirectErrorStream(true).start();
            try {
                var response = new BufferedReader(new InputStreamReader(child.getInputStream()));
                check("LOCKED".equals(response.readLine()), "native-save process failed to acquire its shared lock");
                try (var nextService = AttachmentCacheLease.create(root.toFile())) {
                    check(Files.exists(source), "new service removed an old native save source");
                    AttachmentCacheLease.collect(root.toFile());
                    check(Files.exists(source), "collector ignored actual cross-process shared lock");
                }
                child.getOutputStream().write(1);
                child.getOutputStream().flush();
                check(child.waitFor(5, TimeUnit.SECONDS) && child.exitValue() == 0, "native-save process did not close lease");
                AttachmentCacheLease.collect(root.toFile());
                check(!Files.exists(instance), "unowned instance was not collected after save completed");
            } finally {
                if (child.isAlive()) { child.destroyForcibly(); child.waitFor(5, TimeUnit.SECONDS); }
            }

            var abandoned = AttachmentCacheLease.create(root.toFile());
            Path abandonedDirectory = abandoned.directory().toPath();
            Path partial = abandonedDirectory.resolve(UUID.randomUUID() + ".partial");
            Path publish = abandonedDirectory.resolve(".pocket-publish-" + UUID.randomUUID());
            Path unknown = abandonedDirectory.resolve("user-content.txt");
            Path nested = abandonedDirectory.resolve(UUID.randomUUID() + ".file");
            Files.writeString(partial, "incomplete");
            Files.writeString(publish, "publishing");
            Files.writeString(unknown, "preserve unknown content");
            Files.createDirectory(nested);
            Path nestedContent = nested.resolve("keep.txt");
            Files.writeString(nestedContent, "no recursive deletion");
            abandoned.close();
            AttachmentCacheLease.collect(root.toFile());
            check(!Files.exists(partial) && !Files.exists(publish), "owned incomplete files were not collected");
            check(Files.exists(unknown) && Files.exists(nestedContent), "collector removed unknown/nested content");
            check(Files.exists(foreign), "collector touched unrelated root file");
            Files.delete(nestedContent);
            Files.delete(nested);
            Files.delete(unknown);
            AttachmentCacheLease.collect(root.toFile());
            check(!Files.exists(abandonedDirectory), "empty owned instance was not collected");
            System.out.println("AttachmentCacheLease: same-JVM refcount, actual cross-process save lease, abandoned partials and nonrecursive scoped cleanup passed");
        } finally {
            AttachmentCacheLease.collect(root.toFile());
            Files.deleteIfExists(foreign);
            Files.delete(root);
        }
    }
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
