package com.minnnng.dsh_android;

import java.util.concurrent.TimeUnit;

/** Confirms that one fixed, single-process command is dead before publishing its output. */
final class IsolatedLinuxProcessRetirement {
    static boolean stopAndReap(Process child, long timeoutMillis) {
        if (child == null || timeoutMillis < 1) return false;
        try {
            child.destroyForcibly();
            return child.waitFor(timeoutMillis, TimeUnit.MILLISECONDS) && !child.isAlive();
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            return false;
        } catch (RuntimeException failed) {
            return false;
        }
    }

    private IsolatedLinuxProcessRetirement() { }
}
