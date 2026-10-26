package com.minnnng.dsh_android;

import java.io.IOException;
import java.net.InetAddress;
import java.net.SocketTimeoutException;
import java.util.Arrays;
import java.util.Objects;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Future;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.BooleanSupplier;

/**
 * Deadline and callback arbitration for an asynchronous DNS implementation. A bounded executor
 * also bounds the query-start call: if Android's Binder submission stalls, later calls fail closed
 * instead of accumulating threads. Neither a late callback nor a late query start can be used.
 */
final class DeadlineDnsQuery {
    interface Callback {
        void answered(InetAddress[] addresses);
        void failed(IOException error);
    }

    interface Starter {
        void start(String host, Callback callback) throws IOException;
    }

    interface Cancellation {
        void cancel();
    }

    private DeadlineDnsQuery() {}

    /** Recheck after potentially blocking network-state reads, immediately before query submit. */
    static void requireLiveBeforeSubmit(long deadlineNanos, BooleanSupplier cancelled)
            throws SocketTimeoutException {
        if (cancelled.getAsBoolean() || deadlineNanos - System.nanoTime() <= 0)
            throw new SocketTimeoutException("DNS query expired before submission");
    }

    static InetAddress[] resolve(String host, long deadlineNanos, ExecutorService kickoff,
                                 Cancellation cancellation, Starter starter) throws IOException {
        return resolve(host, deadlineNanos, kickoff, cancellation, starter, () -> false);
    }

    static InetAddress[] resolve(String host, long deadlineNanos, ExecutorService kickoff,
                                 Cancellation cancellation, Starter starter,
                                 BooleanSupplier revoked) throws IOException {
        Objects.requireNonNull(host);
        Objects.requireNonNull(kickoff);
        Objects.requireNonNull(cancellation);
        Objects.requireNonNull(starter);
        Objects.requireNonNull(revoked);
        if (revoked.getAsBoolean()) throw new IOException("DNS capability revoked");
        if (deadlineNanos - System.nanoTime() <= 0)
            throw new SocketTimeoutException("DNS deadline expired before query");

        CountDownLatch completed = new CountDownLatch(1);
        AtomicBoolean terminal = new AtomicBoolean();
        AtomicReference<InetAddress[]> answer = new AtomicReference<>();
        AtomicReference<IOException> failure = new AtomicReference<>();
        Callback callback = new Callback() {
            @Override public void answered(InetAddress[] addresses) {
                if (terminal.compareAndSet(false, true)) {
                    if (addresses == null || addresses.length == 0 || addresses.length > 32
                            || Arrays.asList(addresses).contains(null))
                        failure.set(new IOException("Invalid or unbounded DNS answer"));
                    else answer.set(addresses.clone());
                    completed.countDown();
                }
            }

            @Override public void failed(IOException error) {
                if (terminal.compareAndSet(false, true)) {
                    failure.set(error == null ? new IOException("DNS failed") : error);
                    completed.countDown();
                }
            }
        };

        Future<?> submitted;
        try {
            submitted = kickoff.submit(() -> {
                if (terminal.get() || revoked.getAsBoolean()) return;
                try { starter.start(host, callback); }
                catch (IOException error) { callback.failed(error); }
                catch (RuntimeException error) {
                    callback.failed(new IOException("DNS query submission failed", error));
                }
            });
        } catch (RejectedExecutionException error) {
            cancellation.cancel();
            throw new IOException("DNS query capacity unavailable", error);
        }

        boolean accepted = false;
        try {
            while (true) {
                if (revoked.getAsBoolean()) throw new IOException("DNS capability revoked");
                long left = deadlineNanos - System.nanoTime();
                if (left <= 0) throw new SocketTimeoutException("DNS deadline exceeded");
                if (completed.await(Math.min(left, TimeUnit.MILLISECONDS.toNanos(50)),
                        TimeUnit.NANOSECONDS)) break;
            }
            if (revoked.getAsBoolean()) throw new IOException("DNS capability revoked");
            if (deadlineNanos - System.nanoTime() <= 0)
                throw new SocketTimeoutException("DNS answer arrived after deadline");
            if (failure.get() != null) throw failure.get();
            InetAddress[] addresses = answer.get();
            if (addresses == null) throw new IOException("DNS completed without an answer");
            accepted = true;
            return addresses.clone();
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new IOException("DNS wait interrupted", error);
        } finally {
            if (!accepted) {
                terminal.set(true);
                submitted.cancel(true);
                cancellation.cancel();
            }
        }
    }
}
