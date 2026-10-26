package com.minnnng.dsh_android;

import java.io.IOException;
import java.net.InetAddress;
import java.net.SocketTimeoutException;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.SynchronousQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.atomic.AtomicBoolean;

/** Host-only deadline/cancellation races; no Android service or external DNS is contacted. */
public final class DeadlineDnsQueryTest {
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static ThreadPoolExecutor executor() {
        return new ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS,
                new SynchronousQueue<>(), task -> {
                    Thread thread = new Thread(task, "dns-test");
                    thread.setDaemon(true);
                    return thread;
                }, new ThreadPoolExecutor.AbortPolicy());
    }

    private static long later(long millis) {
        return System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(millis);
    }

    private static void awaitIdle(ThreadPoolExecutor pool) throws InterruptedException {
        long limit = later(1_000);
        while (pool.getActiveCount() != 0 && System.nanoTime() - limit < 0)
            Thread.sleep(1);
        check(pool.getActiveCount() == 0, "Previous DNS starter remained active");
    }

    private static void successCopiesAnswerAndIgnoresSecondCallback() throws Exception {
        ThreadPoolExecutor pool = executor();
        try {
            InetAddress first = InetAddress.getByName("8.8.8.8");
            InetAddress second = InetAddress.getByName("1.1.1.1");
            InetAddress[] mutable = {first};
            InetAddress[] answer = DeadlineDnsQuery.resolve("api.example.org", later(1_000),
                    pool, () -> { throw new AssertionError("Successful DNS was cancelled"); },
                    (host, callback) -> {
                        check(host.equals("api.example.org"), "Wrong DNS name");
                        callback.answered(mutable);
                        mutable[0] = second;
                        callback.answered(new InetAddress[]{second});
                    });
            check(answer.length == 1 && answer[0].equals(first),
                    "First DNS callback did not produce an immutable snapshot");
        } finally { pool.shutdownNow(); }
    }

    private static void timeoutCancelsAndLateCallbackCannotResurrectAnswer() throws Exception {
        ThreadPoolExecutor pool = executor();
        try {
            AtomicReference<DeadlineDnsQuery.Callback> callback = new AtomicReference<>();
            AtomicInteger cancellations = new AtomicInteger();
            CountDownLatch started = new CountDownLatch(1);
            try {
                DeadlineDnsQuery.resolve("api.example.org", later(40), pool,
                        cancellations::incrementAndGet, (host, received) -> {
                            callback.set(received);
                            started.countDown();
                        });
                throw new AssertionError("Missing DNS callback exceeded deadline");
            } catch (SocketTimeoutException expected) { /* bounded wait */ }
            check(started.await(1, TimeUnit.SECONDS), "Query never started");
            check(cancellations.get() == 1, "Timeout did not cancel Android DNS");
            callback.get().answered(new InetAddress[]{InetAddress.getByName("8.8.8.8")});
            callback.get().failed(new IOException("late error"));
            check(cancellations.get() == 1, "Late callback changed terminal state");
        } finally { pool.shutdownNow(); }
    }

    private static void deadlineAlsoBoundsStalledSubmission() throws Exception {
        ThreadPoolExecutor pool = executor();
        try {
            CountDownLatch starting = new CountDownLatch(1);
            CountDownLatch release = new CountDownLatch(1);
            AtomicInteger cancellations = new AtomicInteger();
            try {
                DeadlineDnsQuery.resolve("api.example.org", later(40), pool,
                        cancellations::incrementAndGet, (host, callback) -> {
                            starting.countDown();
                            while (true) {
                                try { release.await(); break; }
                                catch (InterruptedException ignored) { /* simulated stuck Binder call */ }
                            }
                            callback.answered(new InetAddress[]{InetAddress.getByName("8.8.8.8")});
                        });
                throw new AssertionError("Stalled query submission exceeded deadline");
            } catch (SocketTimeoutException expected) { /* bounded caller */ }
            check(starting.await(1, TimeUnit.SECONDS), "Stalled submission never started");
            check(cancellations.get() == 1, "Stalled query did not cancel signal");
            try {
                DeadlineDnsQuery.resolve("api.example.org", later(200), pool,
                        cancellations::incrementAndGet,
                        (host, callback) -> callback.answered(new InetAddress[0]));
                throw new AssertionError("Unbounded DNS submission queue was admitted");
            } catch (IOException expected) {
                check(expected.getMessage().contains("capacity"),
                        "Saturated DNS starter did not fail closed");
            } finally { release.countDown(); }
        } finally { pool.shutdownNow(); }
    }

    private static void invalidAndFailedAnswers() throws Exception {
        ThreadPoolExecutor pool = executor();
        try {
            AtomicInteger cancellations = new AtomicInteger();
            for (InetAddress[] invalid : new InetAddress[][]{null, new InetAddress[0],
                    new InetAddress[33], new InetAddress[]{null}}) {
                try {
                    DeadlineDnsQuery.resolve("api.example.org", later(1_000), pool,
                            cancellations::incrementAndGet,
                            (host, callback) -> callback.answered(invalid));
                    throw new AssertionError("Invalid DNS answer accepted");
                } catch (IOException expected) {
                    check(expected.getMessage().contains("Invalid"), "Wrong invalid answer result");
                }
                awaitIdle(pool);
            }
            check(cancellations.get() == 4, "Invalid answer did not cancel query");
            try {
                DeadlineDnsQuery.resolve("api.example.org", later(1_000), pool,
                        cancellations::incrementAndGet,
                        (host, callback) -> callback.failed(new IOException("server failure")));
                throw new AssertionError("DNS error accepted");
            } catch (IOException expected) {
                check(expected.getMessage().equals("server failure"), "DNS failure was lost");
            }
            awaitIdle(pool);
            check(cancellations.get() == 5, "DNS failure did not cancel query");
            AtomicInteger launches = new AtomicInteger();
            try {
                DeadlineDnsQuery.resolve("api.example.org", System.nanoTime() - 1, pool,
                        cancellations::incrementAndGet, (host, callback) -> launches.incrementAndGet());
                throw new AssertionError("Expired deadline launched DNS");
            } catch (SocketTimeoutException expected) { /* no launch */ }
            check(launches.get() == 0, "Expired deadline launched a query");
        } finally { pool.shutdownNow(); }
    }

    private static void selectedNetworkMustRemainEligible() {
        Object original = "network-a";
        Object replacement = "network-b";
        check(!DeadlineNetworkGate.permits(null, null, null, true, true),
                "Missing default network admitted DNS");
        check(!DeadlineNetworkGate.permits(original, null, null, true, true),
                "Lost default network admitted DNS");
        check(!DeadlineNetworkGate.permits(original, replacement, null, true, true),
                "Default network replacement admitted an old answer");
        check(!DeadlineNetworkGate.permits(original, original, replacement, true, true),
                "Different process-bound network admitted DNS");
        check(!DeadlineNetworkGate.permits(original, original, null, false, true),
                "Network without Internet capability admitted DNS");
        check(!DeadlineNetworkGate.permits(original, original, null, true, false),
                "Unvalidated network admitted DNS");
        check(DeadlineNetworkGate.permits(original, original, original, true, true),
                "Stable validated network rejected");
    }

    private static void stalledNetworkReadCannotStartLateQuery() throws Exception {
        ThreadPoolExecutor pool = executor();
        try {
            CountDownLatch enteredNetworkRead = new CountDownLatch(1);
            CountDownLatch releaseNetworkRead = new CountDownLatch(1);
            CountDownLatch checkedGate = new CountDownLatch(1);
            AtomicBoolean cancelled = new AtomicBoolean();
            AtomicInteger launched = new AtomicInteger();
            long deadline = later(250);
            try {
                DeadlineDnsQuery.resolve("api.example.org", deadline, pool,
                        () -> cancelled.set(true), (host, callback) -> {
                            enteredNetworkRead.countDown();
                            while (true) {
                                try { releaseNetworkRead.await(); break; }
                                catch (InterruptedException ignored) { /* simulated stuck network-state Binder */ }
                            }
                            try {
                                DeadlineDnsQuery.requireLiveBeforeSubmit(deadline, cancelled::get);
                                launched.incrementAndGet();
                            } finally { checkedGate.countDown(); }
                        });
                throw new AssertionError("Stalled network-state read returned a DNS answer");
            } catch (SocketTimeoutException expected) { /* caller returned at deadline */ }
            check(enteredNetworkRead.await(1, TimeUnit.SECONDS), "Network read did not start");
            check(cancelled.get(), "Deadline did not signal cancellation");
            releaseNetworkRead.countDown();
            check(checkedGate.await(1, TimeUnit.SECONDS), "Late network read did not reach gate");
            check(launched.get() == 0, "DNS query launched after the deadline");
        } finally { pool.shutdownNow(); }
    }

    private static void revocationCancelsInflightQuery() throws Exception {
        ThreadPoolExecutor pool = executor();
        try {
            AtomicBoolean revoked = new AtomicBoolean();
            AtomicInteger cancellations = new AtomicInteger();
            AtomicReference<DeadlineDnsQuery.Callback> callback = new AtomicReference<>();
            AtomicReference<Throwable> outcome = new AtomicReference<>();
            CountDownLatch entered = new CountDownLatch(1);
            Thread caller = new Thread(() -> {
                try {
                    DeadlineDnsQuery.resolve("api.example.org", later(3_000), pool,
                            cancellations::incrementAndGet,
                            (host, result) -> { callback.set(result); entered.countDown(); },
                            revoked::get);
                    outcome.set(new AssertionError("Revoked DNS returned an answer"));
                } catch (Throwable expected) { outcome.set(expected); }
            }, "dns-revoke-test");
            caller.setDaemon(true);
            caller.start();
            check(entered.await(1, TimeUnit.SECONDS), "DNS query never entered wait");
            revoked.set(true);
            caller.join(500);
            check(!caller.isAlive() && outcome.get() instanceof IOException,
                    "Revoked DNS did not return before its deadline");
            check(cancellations.get() == 1, "Revocation did not cancel Android query signal");
            callback.get().answered(new InetAddress[]{InetAddress.getByName("8.8.8.8")});
            check(outcome.get() instanceof IOException, "Late DNS answer replaced cancellation");
        } finally { pool.shutdownNow(); }
    }

    public static void main(String[] args) throws Exception {
        successCopiesAnswerAndIgnoresSecondCallback();
        timeoutCancelsAndLateCallbackCannotResurrectAnswer();
        deadlineAlsoBoundsStalledSubmission();
        invalidAndFailedAnswers();
        selectedNetworkMustRemainEligible();
        stalledNetworkReadCannotStartLateQuery();
        revocationCancelsInflightQuery();
        System.out.println("DeadlineDnsQueryTest PASS");
    }
}
