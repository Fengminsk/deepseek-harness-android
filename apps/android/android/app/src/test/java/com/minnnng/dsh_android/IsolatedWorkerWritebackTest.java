package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

public final class IsolatedWorkerWritebackTest {
    public static void main(String[] args) throws Exception {
        Path fixture = Files.createTempDirectory(Path.of(System.getProperty("java.io.tmpdir")), "writeback-");
        try {
            Path privateRoot = Files.createDirectory(fixture.resolve("private"));
            Path workspace = Files.createDirectory(privateRoot.resolve("workspace"));
            AtomicInteger syncs = new AtomicInteger();
            var writer = new IsolatedWorkerWriteback(privateRoot, workspace, directory -> {
                check(directory.equals(workspace), "synced a different directory");
                syncs.incrementAndGet();
            });
            check(writer.version("笔记.txt").equals(IsolatedWorkerWriteback.MISSING), "missing revision");
            byte[] first = "第一版\n".getBytes(StandardCharsets.UTF_8);
            var created = writer.commit("笔记.txt", IsolatedWorkerWriteback.MISSING, first, () -> false);
            check(created.bytes() == first.length && created.previousSha256().equals(IsolatedWorkerWriteback.MISSING), "create receipt");
            check(writer.version("笔记.txt").equals(created.sha256()), "created revision");
            check(Files.readString(workspace.resolve("笔记.txt")).equals("第一版\n"), "created content");
            var snapshot = writer.snapshot("笔记.txt", () -> false);
            check(snapshot.sha256().equals(created.sha256())
                    && new String(snapshot.content(), StandardCharsets.UTF_8).equals("第一版\n"),
                "App-selected snapshot did not pair bytes with revision");
            snapshot.content()[0] = 0;
            check(new String(snapshot.content(), StandardCharsets.UTF_8).equals("第一版\n"),
                "snapshot exposed mutable granted bytes");
            byte[] second = "第二版\n".getBytes(StandardCharsets.UTF_8);
            var replaced = writer.commit("笔记.txt", created.sha256(), second, () -> false);
            check(replaced.previousSha256().equals(created.sha256()), "replacement revision");
            check(syncs.get() == 2, "directory sync count");
            var competingWriter = new IsolatedWorkerWriteback(privateRoot, workspace, directory -> {});
            var firstEntered = new CountDownLatch(1);
            var secondEntered = new CountDownLatch(1);
            var releaseFirst = new CountDownLatch(1);
            var pool = Executors.newFixedThreadPool(2);
            try {
                var firstCommit = pool.submit(() -> writer.commit("concurrent.txt", IsolatedWorkerWriteback.MISSING,
                    "first".getBytes(StandardCharsets.UTF_8), () -> {
                        firstEntered.countDown();
                        try { return !releaseFirst.await(3, TimeUnit.SECONDS); }
                        catch (InterruptedException interrupted) {
                            Thread.currentThread().interrupt();
                            return true;
                        }
                    }));
                check(firstEntered.await(3, TimeUnit.SECONDS), "first writer never entered commit");
                var secondWriter = pool.submit(() -> {
                    secondEntered.countDown();
                    try {
                        competingWriter.commit("concurrent.txt", IsolatedWorkerWriteback.MISSING,
                            "second".getBytes(StandardCharsets.UTF_8), () -> false);
                        return false;
                    } catch (IOException stale) { return true; }
                });
                check(secondEntered.await(3, TimeUnit.SECONDS), "second writer never attempted commit");
                Thread.sleep(100);
                check(!secondWriter.isDone(), "independent writer passed a pending revision check");
                releaseFirst.countDown();
                firstCommit.get(3, TimeUnit.SECONDS);
                check(secondWriter.get(3, TimeUnit.SECONDS), "competing writer silently overwrote the first");
                check(Files.readString(workspace.resolve("concurrent.txt")).equals("first"),
                    "concurrent winner changed");
            } finally {
                releaseFirst.countDown();
                pool.shutdownNow();
            }
            byte[] exactLimit = new byte[IsolatedWorkerInput.MAX_TEXT_BYTES];
            var exact = writer.commit("exact.txt", IsolatedWorkerWriteback.MISSING, exactLimit, () -> false);
            check(exact.bytes() == exactLimit.length && Files.size(workspace.resolve("exact.txt")) == exactLimit.length,
                "exact writeback limit");

            reject(() -> writer.commit("笔记.txt", created.sha256(), first, () -> false), "stale revision");
            reject(() -> writer.commit("../escape", replaced.sha256(), first, () -> false), "parent traversal");
            reject(() -> writer.commit("nested/file", replaced.sha256(), first, () -> false), "nested target");
            reject(() -> writer.commit("笔记.txt", "0".repeat(63), first, () -> false), "invalid revision");
            reject(() -> writer.commit("笔记.txt", replaced.sha256(), new byte[IsolatedWorkerInput.MAX_TEXT_BYTES + 1], () -> false), "oversize");
            reject(() -> writer.commit("笔记.txt", replaced.sha256(), new byte[] {(byte) 0xc3, 0x28}, () -> false), "malformed UTF-8");
            reject(() -> writer.commit("笔记.txt", replaced.sha256(), first, () -> true), "pre-cancelled");
            reject(() -> writer.snapshot("笔记.txt", () -> true), "cancelled snapshot");
            reject(() -> writer.snapshot("../escape", () -> false), "snapshot traversal");
            AtomicInteger checkpoints = new AtomicInteger();
            reject(() -> writer.commit("笔记.txt", replaced.sha256(), new byte[20000],
                () -> checkpoints.incrementAndGet() >= 3), "mid-write cancellation");
            check(Files.readString(workspace.resolve("笔记.txt")).equals("第二版\n"), "failure replaced target");
            try (var entries = Files.list(workspace)) {
                check(entries.noneMatch(path -> path.getFileName().toString().endsWith(".pending")), "staged file survived failure");
            }

            Files.createDirectory(workspace.resolve("folder"));
            reject(() -> writer.version("folder"), "directory target");
            Files.write(workspace.resolve("large.txt"), new byte[IsolatedWorkerInput.MAX_TEXT_BYTES + 1]);
            reject(() -> writer.version("large.txt"), "oversized existing target");
            reject(() -> writer.snapshot("large.txt", () -> false), "oversized snapshot");
            Files.write(workspace.resolve("invalid.txt"), new byte[] {(byte) 0xc3, 0x28});
            reject(() -> writer.snapshot("invalid.txt", () -> false), "malformed snapshot");
            boolean symlinkAvailable = false;
            try {
                Files.createSymbolicLink(workspace.resolve("alias.txt"), workspace.resolve("笔记.txt"));
                symlinkAvailable = true;
            } catch (java.nio.file.FileSystemException | UnsupportedOperationException | SecurityException unavailable) {
                // Some Windows hosts do not permit creating symlinks without developer mode.
            }
            if (symlinkAvailable) reject(() -> writer.snapshot("alias.txt", () -> false), "symbolic-link snapshot");
            reject(() -> new IsolatedWorkerWriteback(privateRoot, fixture, directory -> {}), "outside private root");
            var uncertain = new IsolatedWorkerWriteback(privateRoot, workspace, directory -> { throw new IOException("sync failed"); });
            try {
                uncertain.commit("笔记.txt", replaced.sha256(), first, () -> false);
                throw new AssertionError("post-rename sync failure looked successful");
            } catch (IsolatedWorkerWriteback.CommitUncertain failure) {
                check(failure.receipt.sha256().equals(created.sha256()), "uncertain receipt");
                check(Files.readString(workspace.resolve("笔记.txt")).equals("第一版\n"), "post-rename state hidden");
            }
            System.out.println("IsolatedWorkerWriteback: scope, revisions, limits, cancellation, atomic replacement and uncertain sync passed");
        } finally {
            try (var paths = Files.walk(fixture)) {
                for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(path);
            }
        }
    }

    private interface Checked { void run() throws Exception; }

    private static void reject(Checked action, String label) throws Exception {
        try { action.run(); }
        catch (IOException expected) { return; }
        throw new AssertionError("Accepted " + label);
    }

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
}
