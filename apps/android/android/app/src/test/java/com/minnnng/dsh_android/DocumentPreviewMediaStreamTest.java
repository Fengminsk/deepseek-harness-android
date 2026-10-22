package com.minnnng.dsh_android;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.Arrays;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/** Host tests transfer ownership without Android, network, filesystem content, or a running Agent. */
public final class DocumentPreviewMediaStreamTest {
    private static void check(boolean value, String label) { if (!value) throw new AssertionError(label); }
    public static void main(String[] args) throws Exception {
        byte[] source = new byte[600_000];
        for (int i = 0; i < source.length; i++) source[i] = (byte) (i * 17);
        AtomicInteger chunks = new AtomicInteger();
        AtomicInteger released = new AtomicInteger();
        var stream = new DocumentPreviewMediaStream(source.length, (offset, count) -> {
            check(count <= 262_144, "bounded byte frame");
            chunks.incrementAndGet();
            return Arrays.copyOfRange(source, (int) offset, (int) offset + count);
        }, released::incrementAndGet);
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[19_999];
        int count;
        while ((count = stream.read(buffer)) != -1) output.write(buffer, 0, count);
        check(Arrays.equals(source, output.toByteArray()), "all bytes exact across consumer boundaries");
        check(chunks.get() == 3 && released.get() == 1, "three chunks and one EOF release");
        check(stream.read() == -1, "repeat EOF");
        stream.close(); stream.close();
        check(released.get() == 1, "close after EOF idempotent");
        try { stream.read(); throw new AssertionError("closed stream read"); } catch (IOException expected) { }

        AtomicInteger emptyRelease = new AtomicInteger();
        var empty = new DocumentPreviewMediaStream(0, (offset, length) -> { throw new AssertionError("empty file fetch"); }, emptyRelease::incrementAndGet);
        check(emptyRelease.get() == 1 && empty.read() == -1, "empty file releases without RPC");
        empty.close();
        check(emptyRelease.get() == 1, "empty close idempotent");

        AtomicInteger shortRelease = new AtomicInteger();
        var shortRead = new DocumentPreviewMediaStream(10, (offset, length) -> new byte[9], shortRelease::incrementAndGet);
        try { shortRead.read(); throw new AssertionError("short frame returned partial success"); } catch (IOException expected) { }
        check(shortRelease.get() == 1, "short frame releases");

        AtomicInteger failedRelease = new AtomicInteger();
        var failed = new DocumentPreviewMediaStream(10, (offset, length) -> { throw new IOException("runtime disconnected"); }, failedRelease::incrementAndGet);
        try { failed.read(); throw new AssertionError("read failure hidden"); } catch (IOException expected) { }
        check(failedRelease.get() == 1, "transport failure releases");

        CountDownLatch reading = new CountDownLatch(1);
        CountDownLatch complete = new CountDownLatch(1);
        AtomicInteger racingRelease = new AtomicInteger();
        var racing = new DocumentPreviewMediaStream(1, (offset, length) -> {
            reading.countDown();
            try { check(complete.await(3, TimeUnit.SECONDS), "test read barrier released"); }
            catch (InterruptedException failure) { Thread.currentThread().interrupt(); throw new IOException(failure); }
            return new byte[]{1};
        }, racingRelease::incrementAndGet);
        CompletableFuture<Boolean> read = CompletableFuture.supplyAsync(() -> {
            try { racing.read(); return false; } catch (IOException expected) { return true; }
        });
        check(reading.await(3, TimeUnit.SECONDS), "chunk read started");
        racing.close();
        check(racingRelease.get() == 1 && !read.isDone(), "close revokes while blocked without waiting");
        complete.countDown();
        check(read.get(3, TimeUnit.SECONDS), "late chunk is not delivered after close");
        check(racingRelease.get() == 1, "late completion cannot double release");
        System.out.println("Document media stream: bounded transfer, EOF, cancellation and release checks passed");
    }
}
