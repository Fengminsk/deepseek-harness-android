package com.minnnng.dsh_android;

import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

/** Host contract for bounded image reads and cancellation across the native RPC boundary. */
public final class DocumentImageReadRequestsTest {
    private static int checks;

    public static void main(String[] args) {
        boundsConcurrentReadsAndReleasesSlots();
        catchesCancellationBeforeAdmission();
        revokesOnlyMatchingRoot();
        closeCancelsAllAndRejectsNewReads();
        System.out.println("DocumentImageReadRequests: " + checks + " checks passed");
    }

    private static void boundsConcurrentReadsAndReleasesSlots() {
        AtomicLong now = new AtomicLong(1000);
        DocumentImageReadRequests requests = new DocumentImageReadRequests(now::get);
        AtomicInteger cancelled = new AtomicInteger();
        requests.begin("a", "root", cancelled::incrementAndGet);
        requests.begin("b", "root", cancelled::incrementAndGet);
        check(requests.activeCount() == DocumentImageReadRequests.MAX_ACTIVE);
        rejected(() -> requests.begin("c", "root", cancelled::incrementAndGet), "已满");
        rejected(() -> requests.begin("a", "root", cancelled::incrementAndGet), "正在执行");
        requests.cancel("a");
        check(cancelled.get() == 1);
        rejected(() -> requests.begin("c", "root", cancelled::incrementAndGet), "已满");
        requests.finish("a");
        requests.begin("c", "root", cancelled::incrementAndGet);
        check(requests.activeCount() == 2);
        requests.finish("b");
        requests.finish("c");
        check(requests.activeCount() == 0);
    }

    private static void catchesCancellationBeforeAdmission() {
        AtomicLong now = new AtomicLong(1000);
        DocumentImageReadRequests requests = new DocumentImageReadRequests(now::get);
        requests.cancel("before");
        rejected(() -> requests.begin("before", "root", () -> {}), "已取消");
        check(requests.activeCount() == 0);
        requests.cancel("expired");
        now.addAndGet(60_001);
        requests.begin("expired", "root", () -> {});
        requests.finish("expired");
        for (int index = 0; index < 200; index++) requests.cancel("pending-" + index);
        requests.begin("pending-0", "root", () -> {});
        requests.finish("pending-0");
        rejected(() -> requests.begin("pending-199", "root", () -> {}), "已取消");
    }

    private static void revokesOnlyMatchingRoot() {
        DocumentImageReadRequests requests = new DocumentImageReadRequests(() -> 1000);
        AtomicInteger first = new AtomicInteger();
        AtomicInteger other = new AtomicInteger();
        requests.begin("a", "root-a", first::incrementAndGet);
        requests.begin("b", "root-b", other::incrementAndGet);
        requests.revokeRoot("root-a");
        check(first.get() == 1 && other.get() == 0);
        requests.finish("a");
        requests.finish("b");
    }

    private static void closeCancelsAllAndRejectsNewReads() {
        DocumentImageReadRequests requests = new DocumentImageReadRequests(() -> 1000);
        AtomicInteger cancelled = new AtomicInteger();
        requests.begin("a", "root", cancelled::incrementAndGet);
        requests.begin("b", "root", cancelled::incrementAndGet);
        requests.close();
        check(cancelled.get() == 2 && requests.activeCount() == 0);
        requests.close();
        check(cancelled.get() == 2);
        rejected(() -> requests.begin("c", "root", () -> {}), "已停止");
        requests.finish("a");
        check(requests.activeCount() == 0);
    }

    private static void rejected(Runnable action, String expected) {
        try { action.run(); throw new AssertionError("Accepted request expected to fail"); }
        catch (IllegalStateException failure) {
            check(failure.getMessage().contains(expected));
        }
    }

    private static void check(boolean condition) {
        if (!condition) throw new AssertionError("Image read request invariant failed");
        checks++;
    }
}
