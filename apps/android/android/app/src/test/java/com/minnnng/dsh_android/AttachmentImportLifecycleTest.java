package com.minnnng.dsh_android;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/** Exercises the lifecycle used by AttachmentTransfers with provider-controlled close and read calls. */
public final class AttachmentImportLifecycleTest {
    public static void main(String[] args) throws Exception {
        blockedCloseDoesNotBlockCaller();
        cancelledLateOpenClosesWithoutCopying();
        cancellationClosesAnAttachedStreamOnce();
        cancellationUnblocksCopyAndRejectsItsResult();
        closeFailureDoesNotUndoCancellation();
        System.out.println("AttachmentImportLifecycle: blocked close, late open, repeated cancellation, active copy and close failure passed");
    }

    private static void blockedCloseDoesNotBlockCaller() throws Exception {
        var lifecycle = new AttachmentImportLifecycle();
        var closeEntered = new CountDownLatch(1);
        var releaseClose = new CountDownLatch(1);
        var cleanup = Executors.newSingleThreadExecutor();
        var caller = Executors.newSingleThreadExecutor();
        InputStream stream = new ByteArrayInputStream(new byte[0]) {
            @Override public void close() throws IOException {
                closeEntered.countDown();
                awaitProvider(releaseClose);
            }
        };
        lifecycle.attach(stream);
        try {
            var requested = caller.submit(() -> lifecycle.requestCancel(cleanup));
            check(closeEntered.await(5, TimeUnit.SECONDS), "Provider close was never requested");
            requested.get(5, TimeUnit.SECONDS);
            check(lifecycle.isCancelled(), "Caller returned before cancellation was recorded");
            check(releaseClose.getCount() == 1, "Test did not keep provider close blocked");
        } finally {
            releaseClose.countDown();
            lifecycle.detach(stream);
            stop(caller);
            stop(cleanup);
        }
    }

    private static void cancelledLateOpenClosesWithoutCopying() throws Exception {
        var lifecycle = new AttachmentImportLifecycle();
        List<Runnable> cleanup = new ArrayList<>();
        lifecycle.requestCancel(cleanup::add);
        var closes = new AtomicInteger();
        InputStream late = new ByteArrayInputStream(new byte[] {1}) {
            @Override public void close() { closes.incrementAndGet(); }
        };
        try {
            lifecycle.attach(late);
            throw new AssertionError("An import cancelled during provider open accepted its stream");
        } catch (IOException expected) {
            check(closes.get() == 1 && cleanup.isEmpty(), "Late-open stream cleanup was lost or queued twice");
        }
    }

    private static void cancellationClosesAnAttachedStreamOnce() throws Exception {
        var lifecycle = new AttachmentImportLifecycle();
        var closes = new AtomicInteger();
        InputStream stream = new ByteArrayInputStream(new byte[0]) {
            @Override public void close() { closes.incrementAndGet(); }
        };
        List<Runnable> cleanup = new ArrayList<>();
        lifecycle.attach(stream);
        lifecycle.requestCancel(cleanup::add);
        lifecycle.requestCancel(cleanup::add);
        check(closes.get() == 0 && cleanup.size() == 1, "Caller closed the provider or repeated cleanup");
        cleanup.get(0).run();
        check(closes.get() == 1, "Captured stream was not closed");
        lifecycle.detach(stream);

        var finished = new AttachmentImportLifecycle();
        finished.attach(stream);
        finished.detach(stream);
        finished.requestCancel(cleanup::add);
        check(cleanup.size() == 1, "Cancellation reused a worker's detached stream");
    }

    private static void cancellationUnblocksCopyAndRejectsItsResult() throws Exception {
        var lifecycle = new AttachmentImportLifecycle();
        var readEntered = new CountDownLatch(1);
        var releaseRead = new CountDownLatch(1);
        var cleanup = Executors.newSingleThreadExecutor();
        var copying = Executors.newSingleThreadExecutor();
        InputStream stream = new InputStream() {
            @Override public int read() throws IOException {
                readEntered.countDown();
                awaitProvider(releaseRead);
                return -1;
            }
            @Override public void close() { releaseRead.countDown(); }
        };
        try {
            var copy = copying.submit(() -> {
                lifecycle.attach(stream);
                try (stream) {
                    try {
                        AttachmentCopy.copy(stream, new ByteArrayOutputStream(), lifecycle::isCancelled);
                        throw new AssertionError("Cancelled import reported copied content as successful");
                    } catch (IOException expected) {
                        check(lifecycle.isCancelled(), "Read failed before cancellation");
                    }
                } finally {
                    lifecycle.detach(stream);
                }
                return true;
            });
            check(readEntered.await(5, TimeUnit.SECONDS), "Copy never reached the provider");
            lifecycle.requestCancel(cleanup);
            check(copy.get(5, TimeUnit.SECONDS), "Copy did not finish after provider closed");
        } finally {
            releaseRead.countDown();
            stop(copying);
            stop(cleanup);
        }
    }

    private static void closeFailureDoesNotUndoCancellation() throws Exception {
        var lifecycle = new AttachmentImportLifecycle();
        InputStream stream = new ByteArrayInputStream(new byte[0]) {
            @Override public void close() throws IOException { throw new IOException("Provider refused close"); }
        };
        lifecycle.attach(stream);
        List<Runnable> cleanup = new ArrayList<>();
        lifecycle.requestCancel(cleanup::add);
        cleanup.get(0).run();
        check(lifecycle.isCancelled(), "Provider close failure restored cancelled work");
        lifecycle.detach(stream);
    }

    private static void awaitProvider(CountDownLatch latch) throws IOException {
        try { latch.await(); }
        catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new IOException(interrupted);
        }
    }

    private static void stop(ExecutorService executor) throws InterruptedException {
        executor.shutdownNow();
        check(executor.awaitTermination(5, TimeUnit.SECONDS), "Test executor did not terminate");
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
