package com.minnnng.dsh_android;

import java.util.ArrayDeque;
import java.util.Queue;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.atomic.AtomicInteger;

/** Controlled callback/worker ordering, including a rejected post-shutdown submission. */
public final class NetworkChangeDispatchTest {
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    public static void main(String[] args) {
        RuntimeLifecycle lifecycle = new RuntimeLifecycle();
        Queue<Runnable> queued = new ArrayDeque<>();
        AtomicInteger delivered = new AtomicInteger();
        NetworkChangeDispatch dispatch = new NetworkChangeDispatch(lifecycle, queued::add);
        for (int index = 0; index < 100; index++) dispatch.changed(delivered::incrementAndGet);
        check(queued.size() == 1, "network burst scheduled unbounded work");
        queued.remove().run();
        check(delivered.get() == 1, "coalesced current-network hint was not delivered");
        AtomicInteger reentrant = new AtomicInteger();
        dispatch.changed(() -> {
            delivered.incrementAndGet();
            if (reentrant.getAndIncrement() == 0) dispatch.changed(delivered::incrementAndGet);
        });
        check(queued.size() == 1, "a later network change was permanently suppressed");
        queued.remove().run();
        check(queued.size() == 1, "a change during delivery did not schedule a final hint");
        queued.remove().run();
        check(delivered.get() == 3, "a change during delivery was lost");
        dispatch.changed(delivered::incrementAndGet);
        check(queued.size() == 1, "teardown fixture did not queue a late callback");
        lifecycle.close();
        queued.remove().run();
        dispatch.changed(delivered::incrementAndGet);
        check(delivered.get() == 3 && queued.isEmpty(), "closed runtime accepted a late network callback");

        RuntimeLifecycle shutdown = new RuntimeLifecycle();
        AtomicInteger attempts = new AtomicInteger();
        NetworkChangeDispatch rejected = new NetworkChangeDispatch(shutdown, callback -> {
            attempts.incrementAndGet();
            throw new RejectedExecutionException("executor already closed");
        });
        rejected.changed(delivered::incrementAndGet);
        rejected.changed(delivered::incrementAndGet);
        check(attempts.get() == 2 && delivered.get() == 3,
                "executor rejection crashed or left network notification permanently latched");

        // Negative control: absent teardown, the same queued hint must run.
        RuntimeLifecycle live = new RuntimeLifecycle();
        Queue<Runnable> liveQueue = new ArrayDeque<>();
        new NetworkChangeDispatch(live, liveQueue::add).changed(delivered::incrementAndGet);
        liveQueue.remove().run();
        check(delivered.get() == 4, "negative control did not exercise an admitted callback");
        System.out.println("Network change dispatch: burst, teardown, rejection and negative control passed");
    }
}
