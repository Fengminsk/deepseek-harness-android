package com.minnnng.dsh_android;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.FileSystemException;
import java.nio.file.Path;

public final class ExternalStageCacheTest {
    private static int assertions;
    private static void check(boolean condition) {
        assertions++;
        if (!condition) throw new AssertionError("Stage-cache assertion failed");
    }
    private static void write(File stage, int bytes) throws IOException {
        Files.write(stage.toPath(), new byte[bytes]);
    }

    public static void main(String[] args) throws Exception {
        Path temporary = Files.createTempDirectory("pocket-stage-test-");
        try {
            File root = ExternalStageCache.root(temporary.toFile());
            File recent = ExternalStageCache.create(root, "recent.pdf");
            write(recent, 8);
            File old = ExternalStageCache.create(root, "old.pdf");
            write(old, 8);
            check(old.getParentFile().setLastModified(System.currentTimeMillis() - ExternalStageCache.MAX_AGE_MS - 1000));
            ExternalStageCache.prune(root, System.currentTimeMillis(), null, 12);
            check(recent.isFile());
            check(!old.exists());
            check(!old.getParentFile().exists());

            File next = ExternalStageCache.create(root, "next.pdf");
            write(next, 8);
            ExternalStageCache.prune(root, System.currentTimeMillis(), next, 12);
            check(!recent.exists());
            check(next.exists());
            ExternalStageCache.delete(root, next);
            check(!next.exists());
            check(!next.getParentFile().exists());

            File outside = temporary.resolve("outside.txt").toFile();
            write(outside, 3);
            try { ExternalStageCache.delete(root, outside); throw new AssertionError("Outside path was accepted"); }
            catch (IOException expected) { assertions++; }
            check(outside.isFile());

            File linked = ExternalStageCache.create(root, "linked.txt");
            boolean symlinkCreated = false;
            try {
                Files.createSymbolicLink(linked.toPath(), outside.toPath());
                symlinkCreated = true;
            } catch (FileSystemException failure) {
                if (!System.getProperty("os.name").startsWith("Windows")) throw failure;
                System.out.println("ExternalStageCache: symlink attack skipped (Windows privilege unavailable)");
            }
            if (symlinkCreated) {
                try { ExternalStageCache.delete(root, linked); throw new AssertionError("Linked file was accepted"); }
                catch (IOException expected) { assertions++; }
                ExternalStageCache.prune(root, System.currentTimeMillis(), null, 12);
                check(outside.isFile());
                check(Files.isSymbolicLink(linked.toPath()));
                Files.delete(linked.toPath());
            }
            Files.delete(linked.getParentFile().toPath());

            File partial = ExternalStageCache.create(root, "partial.pdf");
            check(partial.getParentFile().setLastModified(System.currentTimeMillis() - ExternalStageCache.MAX_AGE_MS - 1000));
            ExternalStageCache.prune(root, System.currentTimeMillis(), null, 12);
            check(!partial.getParentFile().exists());
            System.out.println("ExternalStageCache: " + assertions + " assertions passed");
        } finally {
            Path verified = temporary.toRealPath();
            Path tempRoot = Path.of(System.getProperty("java.io.tmpdir")).toRealPath();
            if (!verified.getParent().equals(tempRoot) ||
                    !verified.getFileName().toString().startsWith("pocket-stage-test-"))
                throw new IOException("Refusing to remove an unexpected test directory");
            try (var paths = Files.walk(verified)) {
                paths.sorted((left, right) -> right.compareTo(left)).forEach(path -> {
                    try { Files.deleteIfExists(path); } catch (IOException failure) { throw new RuntimeException(failure); }
                });
            }
        }
    }
}
