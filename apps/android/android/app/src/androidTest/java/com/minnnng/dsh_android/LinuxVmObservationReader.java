package com.minnnng.dsh_android;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/** Acceptance-only owner for shell dispatch, pipe reading, late descriptors and reader retirement. */
public final class LinuxVmObservationReader {
    public interface Opener { InputStream open() throws Exception; }
    private static final int MAX_BYTES = 2 * 1024 * 1024;
    private LinuxVmObservationReader() {}

    private static final class State {
        boolean stopping;
        InputStream stream;
        final AtomicReference<Throwable> closeFailure = new AtomicReference<>();
        void close(InputStream input) {
            if (input == null) return;
            try { input.close(); }
            catch (Throwable failure) { closeFailure.compareAndSet(null, failure); }
        }
    }

    public static String read(Opener opener, long timeoutMillis, long retirementMillis) throws Exception {
        if (timeoutMillis < 1 || timeoutMillis > 8000 || retirementMillis < 1 || retirementMillis > 1000)
            throw new IllegalArgumentException("Invalid observation deadline");
        State state = new State();
        CompletableFuture<String> result = new CompletableFuture<>();
        Thread reader = new Thread(() -> {
            try {
                InputStream opened = java.util.Objects.requireNonNull(opener.open());
                boolean stopped;
                synchronized (state) {
                    stopped = state.stopping;
                    if (!stopped) state.stream = opened;
                }
                if (stopped) {
                    state.close(opened);
                    throw new IOException("Linux observation descriptor arrived after timeout");
                }
                String text;
                try {
                    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                    byte[] buffer = new byte[8192];
                    while (true) {
                        int count = opened.read(buffer);
                        if (count < 0) break;
                        if (count > MAX_BYTES - bytes.size()) throw new IOException("Linux process observation exceeds limit");
                        bytes.write(buffer, 0, count);
                    }
                    text = new String(bytes.toByteArray(), StandardCharsets.UTF_8);
                } finally {
                    InputStream owned;
                    synchronized (state) { owned = state.stream; state.stream = null; }
                    state.close(owned);
                }
                Throwable closing = state.closeFailure.get();
                if (closing != null) throw new IOException("Linux observation descriptor close failed", closing);
                result.complete(text);
            } catch (Throwable failure) { result.completeExceptionally(failure); }
        }, "linux-acceptance-observation");
        reader.setDaemon(true);
        reader.start();
        String text = null;
        Throwable failure = null;
        try { text = result.get(timeoutMillis, TimeUnit.MILLISECONDS); }
        catch (Throwable error) { failure = error; }

        InputStream owned;
        synchronized (state) { state.stopping = true; owned = state.stream; state.stream = null; }
        Thread closer = null;
        if (owned != null) {
            closer = new Thread(() -> state.close(owned), "linux-acceptance-observation-close");
            closer.setDaemon(true);
            closer.start();
        }
        if (failure != null) reader.interrupt();
        long end = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(retirementMillis);
        try {
            join(reader, end);
            if (closer != null) join(closer, end);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new IOException("Linux observation retirement is unconfirmed: caller interrupted", interrupted);
        }
        if (reader.isAlive() || (closer != null && closer.isAlive()))
            throw new IOException("Linux observation retirement is unconfirmed: reader or descriptor closer still active", failure);
        if (state.closeFailure.get() != null)
            throw new IOException("Linux observation descriptor close is unconfirmed", state.closeFailure.get());
        if (failure != null) {
            if (failure instanceof InterruptedException) Thread.currentThread().interrupt();
            throw new IOException("Linux observation failed; reader and descriptor cleanup confirmed", failure);
        }
        return text;
    }

    private static void join(Thread thread, long deadline) throws InterruptedException {
        long remaining = deadline - System.nanoTime();
        if (remaining > 0) thread.join(Math.max(1, TimeUnit.NANOSECONDS.toMillis(remaining)));
    }
}
