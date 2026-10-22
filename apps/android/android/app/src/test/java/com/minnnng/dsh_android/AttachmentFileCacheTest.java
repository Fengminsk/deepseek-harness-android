package com.minnnng.dsh_android;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.UUID;
import java.util.HexFormat;
import java.security.MessageDigest;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/** Cache identity and provider-copy cancellation tests without depending on a phone or provider app. */
public final class AttachmentFileCacheTest {
    public static void main(String[] args) throws Exception {
        Path root = Files.createTempDirectory("pocket-file-cache-test-");
        String id = UUID.randomUUID().toString();
        Path source = root.resolve(id + ".file");
        byte[] data = new byte[3 * 1024 * 1024 + 19];
        for (int i = 0; i < data.length; i++) data[i] = (byte) i;
        Files.write(source, data);
        String digest = "sha256:" + HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(data));
        try {
            var output = new ByteArrayOutputStream();
            long copied = AttachmentFileCache.copy(AttachmentFileCache.source(root.toFile(), id, data.length),
                    data.length, digest, output, () -> false);
            check(copied == data.length && Arrays.equals(data, output.toByteArray()), "full copy changed bytes");
            rejects(() -> AttachmentFileCache.source(root.toFile(), "../source", data.length));
            rejects(() -> AttachmentFileCache.source(root.toFile(), UUID.randomUUID().toString(), data.length));
            rejects(() -> AttachmentFileCache.source(root.toFile(), id, data.length + 1));
            rejects(() -> AttachmentFileCache.source(root.toFile(), id, -1));
            for (String bad : new String[] { "", ".", "..", "a/b.txt", "a\\b.txt", "a\0.txt", "x".repeat(256) }) {
                rejects(() -> AttachmentFileCache.validateFilename(bad));
            }
            AttachmentFileCache.validateFilename("名".repeat(80) + ".txt");
            AttachmentFileCache.validateFilename("x".repeat(255));

            AtomicBoolean cancelled = new AtomicBoolean();
            OutputStream cancelAfterChunk = new OutputStream() {
                @Override public void write(int value) { cancelled.set(true); }
                @Override public void write(byte[] bytes, int offset, int length) { cancelled.set(true); }
            };
            rejects(() -> AttachmentFileCache.copy(source.toFile(), data.length, digest, cancelAfterChunk, cancelled::get));
            OutputStream failing = new OutputStream() {
                @Override public void write(int value) throws IOException { throw new IOException("provider failure"); }
            };
            rejects(() -> AttachmentFileCache.copy(source.toFile(), data.length, digest, failing, () -> false));
            check(Arrays.equals(data, Files.readAllBytes(source)), "failed save destroyed retry source");
            testCancellation(source, data.length, digest);
            testLateProvider();
            byte[] changed = data.clone();
            changed[changed.length - 1] ^= 1;
            Files.write(source, changed);
            rejects(() -> AttachmentFileCache.copy(source.toFile(), data.length, digest, new ByteArrayOutputStream(), () -> false));
            Files.delete(source);
            Files.write(source, changed);
            rejects(() -> AttachmentFileCache.copy(source.toFile(), data.length, digest, new ByteArrayOutputStream(), () -> false));
            check(Arrays.equals(changed, Files.readAllBytes(source)), "failed save must not delete cache it did not own");
            System.out.println("AttachmentFileCache: opaque identity, exact bytes/hash, same-size corruption/replacement, provider errors, cancellation and late-provider closure passed");
        } finally {
            Files.deleteIfExists(source);
            Files.delete(root);
        }
    }

    private static void testLateProvider() throws Exception {
        var lifecycle = new AttachmentSaveLifecycle();
        lifecycle.requestCancel(command -> { throw new AssertionError("no stream to close"); });
        AtomicBoolean closed = new AtomicBoolean();
        var late = new ByteArrayOutputStream() {
            @Override public void close() { closed.set(true); }
        };
        rejects(() -> lifecycle.attach(late));
        check(closed.get() && lifecycle.isCancelled() && late.size() == 0, "late provider was not closed before copy");
        // Repeated cancellation must not schedule on an already shut-down executor.
        lifecycle.requestCancel(command -> { throw new AssertionError("duplicate cancellation scheduled"); });
    }

    private static void testCancellation(Path source, long bytes, String digest) throws Exception {
        var lifecycle = new AttachmentSaveLifecycle();
        var copying = Executors.newSingleThreadExecutor();
        var closer = Executors.newSingleThreadExecutor();
        CountDownLatch writing = new CountDownLatch(1), closeStarted = new CountDownLatch(1);
        CountDownLatch allowClose = new CountDownLatch(1), closed = new CountDownLatch(1), workerDone = new CountDownLatch(1);
        AtomicBoolean finished = new AtomicBoolean();
        AtomicReference<Throwable> unexpected = new AtomicReference<>();
        OutputStream blocked = new OutputStream() {
            @Override public void write(int value) throws IOException { write(new byte[] {(byte) value}, 0, 1); }
            @Override public void write(byte[] value, int offset, int length) throws IOException {
                writing.countDown();
                await(closed);
                throw new IOException("closed provider");
            }
            @Override public void close() throws IOException {
                closeStarted.countDown();
                await(allowClose);
                closed.countDown();
            }
        };
        copying.execute(() -> {
            try (blocked) {
                lifecycle.attach(blocked);
                AttachmentFileCache.copy(source.toFile(), bytes, digest, blocked, lifecycle::isCancelled);
                unexpected.set(new AssertionError("cancelled copy reported success"));
            } catch (IOException expected) {
                if (!lifecycle.isCancelled()) unexpected.set(expected);
            } finally {
                lifecycle.detach(blocked);
                finished.set(true);
                workerDone.countDown();
            }
        });
        try {
            await(writing);
            lifecycle.requestCancel(closer);
            await(closeStarted);
            check(lifecycle.isCancelled(), "cancel flag must be immediate");
            check(!finished.get(), "cancel request cannot claim the copy has quiesced");
            lifecycle.requestCancel(command -> { throw new AssertionError("duplicate close"); });
            allowClose.countDown();
            await(workerDone);
            check(unexpected.get() == null, "worker completion failure: " + unexpected.get());
            check(Files.size(source) == bytes, "cancellation removed verified source");
        } finally {
            allowClose.countDown();
            closer.shutdown();
            copying.shutdown();
            check(closer.awaitTermination(5, TimeUnit.SECONDS), "closer did not stop");
            check(copying.awaitTermination(5, TimeUnit.SECONDS), "copy worker did not stop");
        }
    }

    private static void await(CountDownLatch latch) throws IOException {
        try { if (!latch.await(5, TimeUnit.SECONDS)) throw new IOException("fixture did not reach its barrier"); }
        catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new IOException(error); }
    }
    private interface Checked { void run() throws Exception; }
    private static void rejects(Checked action) throws Exception {
        try { action.run(); } catch (IOException | IllegalArgumentException expected) { return; }
        throw new AssertionError("Expected source or copy failure");
    }
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
