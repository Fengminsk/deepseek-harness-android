package com.minnnng.dsh_android;

import java.io.IOException;
import java.io.StringWriter;
import java.io.Writer;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/** Exercises the production writer with requests waiting behind an in-flight frame. */
public final class RuntimeTransportTest {
    private static int checks;
    private static void check(boolean value, String message) {
        checks++;
        if (!value) throw new AssertionError(message);
    }
    private static void rejected(RuntimeTransport transport, String label) throws IOException {
        boolean rejected = false;
        try { transport.write(label); }
        catch (IOException expected) { rejected = true; }
        check(rejected, label + " reached a terminal runtime");
    }
    private static boolean waitingForWriter(Thread thread) throws InterruptedException {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        while (thread.getState() != Thread.State.BLOCKED && thread.isAlive() && System.nanoTime() < deadline) {
            Thread.sleep(1);
        }
        return thread.getState() == Thread.State.BLOCKED;
    }
    private static final class HeldWriter extends Writer {
        final StringWriter received = new StringWriter();
        final CountDownLatch entered = new CountDownLatch(1);
        final CountDownLatch release = new CountDownLatch(1);
        @Override public void write(char[] chars, int offset, int length) throws IOException {
            entered.countDown();
            try {
                if (!release.await(5, TimeUnit.SECONDS)) throw new IOException("Test did not release in-flight write");
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new IOException(error);
            }
            received.write(chars, offset, length);
        }
        @Override public void flush() {}
        @Override public void close() {}
    }
    public static void main(String[] args) throws Exception {
        RuntimeLifecycle failed = new RuntimeLifecycle();
        StringWriter failedOutput = new StringWriter();
        RuntimeTransport failedTransport = new RuntimeTransport(failed, failedOutput);
        failed.fail();
        rejected(failedTransport, "session.send after failure before main-thread status");
        check(failedOutput.toString().isEmpty(), "failed generation received request bytes");

        RuntimeLifecycle closed = new RuntimeLifecycle();
        StringWriter closedOutput = new StringWriter();
        RuntimeTransport closedTransport = new RuntimeTransport(closed, closedOutput);
        closed.close();
        rejected(closedTransport, "approval reply after shutdown");
        check(closedOutput.toString().isEmpty(), "closed generation received approval bytes");

        StringWriter disconnectedOutput = new StringWriter();
        RuntimeTransport disconnected = new RuntimeTransport(new RuntimeLifecycle(), disconnectedOutput);
        disconnected.close();
        rejected(disconnected, "request after output close");
        check(disconnectedOutput.toString().isEmpty(), "closed output received request bytes");

        RuntimeLifecycle lifetime = new RuntimeLifecycle();
        HeldWriter sink = new HeldWriter();
        RuntimeTransport transport = new RuntimeTransport(lifetime, sink);
        AtomicReference<Throwable> firstFailure = new AtomicReference<>();
        AtomicReference<Throwable> queuedOutcome = new AtomicReference<>();
        CountDownLatch queuedStarted = new CountDownLatch(1);
        Thread first = new Thread(() -> {
            try { transport.write("already-in-flight"); }
            catch (Throwable error) { firstFailure.set(error); }
        });
        Thread queued = new Thread(() -> {
            queuedStarted.countDown();
            try { transport.write("queued-session-send"); }
            catch (Throwable error) { queuedOutcome.set(error); }
        });
        first.start();
        try {
            check(sink.entered.await(5, TimeUnit.SECONDS), "first frame never reached writer");
            queued.start();
            check(queuedStarted.await(5, TimeUnit.SECONDS), "queued request never started");
            check(waitingForWriter(queued), "second request never waited for the in-flight writer");
            lifetime.fail();
        } finally {
            sink.release.countDown();
            first.join(5000);
            queued.join(5000);
        }
        check(!first.isAlive() && !queued.isAlive(), "transport workers did not settle");
        check(firstFailure.get() == null, "in-flight write failed for an unrelated reason");
        check(queuedOutcome.get() instanceof IOException, "waiting request bypassed the terminal lifetime");
        check(sink.received.toString().equals("already-in-flight\n"),
                "a request waiting for the writer was delivered after failure");

        RuntimeLifecycle replacement = new RuntimeLifecycle();
        StringWriter replacementOutput = new StringWriter();
        RuntimeTransport replacementTransport = new RuntimeTransport(replacement, replacementOutput);
        replacementTransport.write("new-generation-status");
        check(replacementOutput.toString().equals("new-generation-status\n"),
                "replacement inherited the old generation's terminal state");
        check(!replacementOutput.toString().contains("queued-session-send"), "transport replayed an old request");
        System.out.println("RuntimeTransport: " + checks + " checks passed (failed, closed, queued, in-flight, replacement)");
    }
}
