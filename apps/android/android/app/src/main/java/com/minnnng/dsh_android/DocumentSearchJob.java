package com.minnnng.dsh_android;

import java.io.Closeable;
import java.io.IOException;
import java.util.concurrent.CancellationException;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.Executor;

/** One prepared native request; cancellation completion is distinct from requesting cancellation. */
public final class DocumentSearchJob {
    private final Runnable cancelProvider;
    private final CountDownLatch stopped = new CountDownLatch(1);
    private boolean cancelled, started;
    private Closeable stream;

    public DocumentSearchJob(Runnable cancelProvider) { this.cancelProvider = cancelProvider; }
    public synchronized boolean start() {
        if (started) throw new IllegalStateException("Search already started");
        if (cancelled) return false;
        started = true;
        return true;
    }
    public synchronized void check() {
        if (cancelled || Thread.currentThread().isInterrupted()) throw new CancellationException("Search cancelled");
    }
    public void attach(Closeable value) throws IOException {
        synchronized (this) {
            if (!cancelled) { stream = value; return; }
        }
        value.close();
        throw new CancellationException("Search cancelled");
    }
    public synchronized void detach() { stream = null; }
    public void requestCancel() {
        requestCancel(Runnable::run);
    }
    /** Independent cleanup tasks keep a blocked pipe close from delaying provider cancellation. */
    public void requestCancel(Executor cleanup) {
        Closeable active;
        synchronized (this) {
            if (cancelled) return;
            cancelled = true;
            active = stream;
            if (!started) stopped.countDown();
        }
        cleanup.execute(cancelProvider);
        if (active != null) cleanup.execute(() -> {
            try { active.close(); }
            catch (IOException closeFailure) {
                // The scanning owner still closes it in finally; completion remains unconfirmed.
            }
        });
    }
    public void finish() { stopped.countDown(); }
    public boolean awaitStopped(long timeoutMs) throws InterruptedException {
        return stopped.await(timeoutMs, TimeUnit.MILLISECONDS);
    }
}
