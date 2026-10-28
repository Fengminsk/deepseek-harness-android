package com.minnnng.dsh_android;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/** The runner inserts only a scheduling barrier into its private compiled source copy. */
public final class DocumentSnapshotCommitRace {
    public static void main(String[] args) throws Exception {
        Path directory = Files.createDirectory(Path.of(args[0]));
        DocumentSnapshotStore store = new DocumentSnapshotStore(directory.toFile(), 32, 64, 60000, 0);
        byte[] bytesA = new byte[32];
        Arrays.fill(bytesA, (byte) 'A');
        CountDownLatch bReserved = new CountDownLatch(1), releaseB = new CountDownLatch(1);
        var workers = Executors.newFixedThreadPool(2);
        try {
            var b = workers.submit(() -> store.create("c".repeat(64), "d".repeat(64), new DocumentSnapshotStore.Source() {
                public void check() {}
                public InputStream open() throws IOException {
                    bReserved.countDown();
                    SnapshotCommitProbe.await(releaseB);
                    return new ByteArrayInputStream(new byte[] {'B'});
                }
            }));
            SnapshotCommitProbe.await(bReserved);
            var a = workers.submit(() -> {
                Thread.currentThread().setName("snapshot-commit-A");
                return store.create("a".repeat(64), "b".repeat(64), new DocumentSnapshotStore.Source() {
                    public void check() {}
                    public InputStream open() { return new ByteArrayInputStream(bytesA); }
                });
            });
            SnapshotCommitProbe.await(SnapshotCommitProbe.published);
            String digest = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytesA));
            String version = DocumentRevision.token("a".repeat(64), "b".repeat(64), digest, 32L, null);
            Path aFile = directory.resolve("document-read-snapshots").resolve(version + ".bin");
            if (!Files.isRegularFile(aFile)) throw new AssertionError("A did not publish before the commit barrier");
            releaseB.countDown();
            var snapshotB = b.get(5, TimeUnit.SECONDS);
            if (!Files.readString(snapshotB.file.toPath()).equals("B")) throw new AssertionError("B did not commit its page");
            boolean retained = Files.isRegularFile(aFile);
            SnapshotCommitProbe.release.countDown();
            var snapshotA = a.get(5, TimeUnit.SECONDS);
            if (!retained) throw new AssertionError("Committed snapshot A was evicted by double-counted reservation");
            byte[] page = store.withPinnedSnapshot(snapshotA, () -> Files.readAllBytes(snapshotA.file.toPath()));
            if (!Arrays.equals(page, bytesA)) throw new AssertionError("A page changed across the concurrent commit");
            System.out.println("Both committed pages retained with A paused after publication");
        } finally {
            releaseB.countDown();
            SnapshotCommitProbe.release.countDown();
            workers.shutdownNow();
            if (!workers.awaitTermination(5, TimeUnit.SECONDS)) throw new AssertionError("Commit fixture workers did not retire");
        }
    }
}

final class SnapshotCommitProbe {
    static final CountDownLatch published = new CountDownLatch(1), release = new CountDownLatch(1);
    static void afterPublication() throws IOException {
        if (!Thread.currentThread().getName().equals("snapshot-commit-A")) return;
        published.countDown();
        await(release);
    }
    static void await(CountDownLatch latch) throws IOException {
        try { if (!latch.await(20, TimeUnit.SECONDS)) throw new IOException("Commit fixture barrier timed out"); }
        catch (InterruptedException failure) { Thread.currentThread().interrupt(); throw new IOException(failure); }
    }
}
