package com.minnnng.dsh_android;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Process-owned ordering survives Activity replacement and client timeouts. */
public final class RecoveryModeQueue {
    private static final ExecutorService WORKER = Executors.newSingleThreadExecutor(task -> {
        Thread thread = new Thread(task, "pocket-recovery-mode");
        thread.setDaemon(true);
        return thread;
    });
    public static void execute(Runnable task) { WORKER.execute(task); }
    private RecoveryModeQueue() {}
}
