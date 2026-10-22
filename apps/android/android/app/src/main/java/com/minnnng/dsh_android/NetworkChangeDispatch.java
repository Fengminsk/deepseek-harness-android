package com.minnnng.dsh_android;

import java.util.concurrent.Executor;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.atomic.AtomicBoolean;

/** Coalesces network hints and fences late callbacks against service teardown. */
public final class NetworkChangeDispatch {
    private final RuntimeLifecycle lifecycle;
    private final Executor executor;
    private final AtomicBoolean pending = new AtomicBoolean();
    private final AtomicBoolean dirty = new AtomicBoolean();

    public NetworkChangeDispatch(RuntimeLifecycle lifecycle, Executor executor) {
        this.lifecycle = lifecycle;
        this.executor = executor;
    }

    /** The runtime reads current network state; multiple queued hints need one delivery. */
    public void changed(Runnable signal) {
        dirty.set(true);
        schedule(signal);
    }

    private void schedule(Runnable signal) {
        if (!lifecycle.acceptsFrames() || !pending.compareAndSet(false, true)) return;
        try {
            executor.execute(() -> {
                try {
                    dirty.set(false);
                    if (lifecycle.acceptsFrames()) signal.run();
                } finally {
                    pending.set(false);
                    // A change in the final check-to-release gap still gets a fresh hint.
                    if (dirty.get() && lifecycle.acceptsFrames()) schedule(signal);
                }
            });
        } catch (RejectedExecutionException ignored) {
            // Android can deliver an already registered callback while onDestroy closes the pool.
            pending.set(false);
            dirty.set(false);
        }
    }
}
