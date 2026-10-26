package com.minnnng.dsh_android;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/** Exercises the same persist-before-deliver and bounded shutdown handoff used by the Service. */
public final class TaskCompletionDeliveryTest {
    public static void main(String[] args) throws Exception {
        TaskCompletionDelivery delivery = new TaskCompletionDelivery();
        TaskCompletionState state = new TaskCompletionState();
        check(state.claim("session", 4, -1), "fresh completion was rejected");
        TaskCompletionDelivery.Ticket first = delivery.add("session", 4, "done", true);
        CountDownLatch releaseWriter = new CountDownLatch(1);
        ExecutorService writer = Executors.newSingleThreadExecutor();
        writer.execute(() -> {
            try { releaseWriter.await(); }
            catch (InterruptedException error) { Thread.currentThread().interrupt(); return; }
            first.finish(true);
        });
        writer.shutdown();
        check(!writer.awaitTermination(20, TimeUnit.MILLISECONDS), "blocked writer unexpectedly drained");
        check(delivery.unfinishedCount() == 1 && delivery.persistedAtShutdown().isEmpty(),
            "uncommitted completion became a shutdown notice");
        releaseWriter.countDown();
        check(writer.awaitTermination(2, TimeUnit.SECONDS), "released writer did not drain");
        check(first.isPersisted() && delivery.persistedAtShutdown().contains(first)
            && state.isCurrentClaim(first.sessionId, first.endSeq),
            "committed completion was lost during shutdown handoff");

        check(!TaskCompletionDelivery.shouldAcknowledge(false, true, true),
            "uncommitted receipt was acknowledged after a notification attempt");
        check(!TaskCompletionDelivery.shouldAcknowledge(true, true, false),
            "failed Android notification post discarded its recoverable receipt");
        check(TaskCompletionDelivery.shouldAcknowledge(true, true, true),
            "accepted Android notification retained a duplicate pending receipt");
        check(TaskCompletionDelivery.shouldAcknowledge(true, false, false),
            "a deliberately suppressed notice remained pending for cold recovery");

        check(state.claim("session", 5, 4), "next turn was rejected");
        check(!state.isCurrentClaim(first.sessionId, first.endSeq),
            "old committed notice could overtake a newer turn");
        TaskCompletionDelivery.Ticket failed = delivery.add("session", 5, null, true);
        failed.finish(false);
        check(!delivery.persistedAtShutdown().contains(failed),
            "failed watermark produced an unfenced notice");
        delivery.delivered(first);
        check(!delivery.persistedAtShutdown().contains(first), "already delivered notice could replay at shutdown");
        delivery.clear();
        check(delivery.persistedAtShutdown().isEmpty(), "closed delivery owner retained pending notices");
        System.out.println("Task completion delivery: delayed writes, shutdown drain and stale fences passed");
    }

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
}
