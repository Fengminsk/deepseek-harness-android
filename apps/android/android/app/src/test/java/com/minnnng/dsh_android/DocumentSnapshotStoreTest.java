package com.minnnng.dsh_android;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

public final class DocumentSnapshotStoreTest {
    private static final String ID = "a".repeat(64);
    private static final String META = "b".repeat(64);

    public static void main(String[] args) throws Exception {
        Path temp = Files.createTempDirectory("dsh-saf-snapshot-");
        try {
            DocumentSnapshotStore store = new DocumentSnapshotStore(temp.toFile(), 32, 64, 1000, 0);
            byte[] first = "first page content".getBytes(StandardCharsets.UTF_8);
            byte[] edited = "second page edited".getBytes(StandardCharsets.UTF_8);
            assertTrue(first.length == edited.length, "fixture must retain provider-reported size");
            Mutable source = new Mutable(first);
            var original = store.create(ID, META, source);
            source.bytes = edited; // Same length and unchanged provider metadata.
            var continuation = store.get(ID, META, original.version);
            assertTrue(Arrays.equals(Files.readAllBytes(continuation.file.toPath()), first),
                    "continuation must retain the first immutable bytes");
            assertTrue(Arrays.equals(Files.readAllBytes(
                    new DocumentSnapshotStore(temp.toFile()).get(ID, META, original.version).file.toPath()), first),
                    "a new process-facing store instance must reopen the same snapshot");
            var fresh = store.create(ID, META, source);
            assertTrue(!fresh.version.equals(original.version), "new first page must reveal content replacement");
            expect(IOException.class, () -> store.get("c".repeat(64), META, original.version), "changed root/path/URI");
            expect(IOException.class, () -> store.get(ID, "d".repeat(64), original.version), "changed provider metadata");

            source.bytes = "before".getBytes(StandardCharsets.UTF_8);
            source.afterFirstOpen = "after!".getBytes(StandardCharsets.UTF_8);
            expect(IOException.class, () -> store.create(ID, META, source), "during capture");
            source.afterFirstOpen = null;
            source.bytes = new byte[33];
            expect(IOException.class, () -> store.create(ID, META, source), "bounded maximum");
            try (var entries = Files.list(temp.resolve("document-read-snapshots"))) {
                assertTrue(entries.noneMatch(path -> path.getFileName().toString().startsWith(".part-")),
                        "failed capture must not publish temporary bytes");
            }
            source.bytes = first;
            source.revoked = true;
            expect(SecurityException.class, () -> store.create(ID, META, source), "revoked grant");
            source.revoked = false;

            Path orphan = temp.resolve("document-read-snapshots").resolve("e".repeat(64) + ".bin");
            Files.write(orphan, new byte[] {1, 2, 3});
            store.get(ID, META, fresh.version);
            assertTrue(!Files.exists(orphan), "interrupted publish must not retain an orphaned snapshot");

            original.file.setLastModified(System.currentTimeMillis() - 2000);
            new java.io.File(original.file.getParentFile(), original.version + ".meta")
                    .setLastModified(System.currentTimeMillis() - 2000);
            expect(IOException.class, () -> store.get(ID, META, original.version), "expired snapshot");

            DocumentSnapshotStore compact = new DocumentSnapshotStore(temp.toFile(), 32, 24, 1000, 0);
            var newest = compact.create(ID, META, new Mutable("new cache item".getBytes(StandardCharsets.UTF_8)));
            assertTrue(Files.isRegularFile(newest.file.toPath()), "newest entry must be retained");
            expect(IOException.class, () -> compact.get(ID, META, fresh.version), "cache budget eviction");

            Path parallel = Files.createDirectory(temp.resolve("parallel"));
            DocumentSnapshotStore parallelStore = new DocumentSnapshotStore(parallel.toFile(), 32, 20, 1000, 0);
            var held = parallelStore.create(ID, META, new Mutable("first content".getBytes(StandardCharsets.UTF_8)));
            CountDownLatch pinned = new CountDownLatch(1), release = new CountDownLatch(1), evictionStarted = new CountDownLatch(1);
            var pool = Executors.newFixedThreadPool(2);
            try {
                var reading = pool.submit(() -> parallelStore.withPinnedSnapshot(held, () -> {
                    pinned.countDown();
                    try {
                        if (!release.await(2, TimeUnit.SECONDS)) throw new IOException("reader timed out");
                    } catch (InterruptedException failure) {
                        Thread.currentThread().interrupt();
                        throw new IOException("reader interrupted", failure);
                    }
                    return Files.readAllBytes(held.file.toPath());
                }));
                assertTrue(pinned.await(2, TimeUnit.SECONDS), "reader must pin snapshot");
                var evicting = pool.submit(() -> {
                    evictionStarted.countDown();
                    return parallelStore.create(ID, META, new Mutable("other content".getBytes(StandardCharsets.UTF_8)));
                });
                assertTrue(evictionStarted.await(2, TimeUnit.SECONDS), "eviction must be scheduled");
                Thread.sleep(75);
                assertTrue(!evicting.isDone(), "eviction must wait for the active page read");
                release.countDown();
                assertTrue(Arrays.equals(reading.get(2, TimeUnit.SECONDS), "first content".getBytes(StandardCharsets.UTF_8)),
                        "pinned page must finish before eviction");
                evicting.get(2, TimeUnit.SECONDS);
                expect(IOException.class, () -> parallelStore.get(ID, META, held.version), "evicted continuation");
            } finally {
                release.countDown();
                pool.shutdownNow();
            }
            System.out.println("DocumentSnapshotStoreTest passed");
        } finally {
            try (var walk = Files.walk(temp)) {
                walk.sorted(java.util.Comparator.reverseOrder()).forEach(path -> {
                    try { Files.deleteIfExists(path); } catch (IOException failure) { throw new RuntimeException(failure); }
                });
            }
        }
    }

    private static final class Mutable implements DocumentSnapshotStore.Source {
        byte[] bytes;
        byte[] afterFirstOpen;
        int opens;
        boolean revoked;
        Mutable(byte[] bytes) { this.bytes = bytes; }
        public void check() { if (revoked) throw new SecurityException("grant revoked"); }
        public InputStream open() {
            opens++;
            return new ByteArrayInputStream(afterFirstOpen != null && opens % 2 == 0 ? afterFirstOpen : bytes);
        }
    }
    private interface Throwing { void run() throws Exception; }
    private static void expect(Class<? extends Throwable> type, Throwing action, String label) throws Exception {
        try { action.run(); } catch (Throwable failure) {
            if (type.isInstance(failure)) return;
            throw new AssertionError(label + " returned " + failure, failure);
        }
        throw new AssertionError(label + " unexpectedly succeeded");
    }
    private static void assertTrue(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
