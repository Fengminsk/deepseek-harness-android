package com.minnnng.dsh_android;

/**
 * Confirms a startup stall only after consecutive checks without recorded
 * progress, so one slow sample or a freeze that just ended cannot kill a
 * healthy process. Time is supplied by the caller; this class owns no clock.
 */
public final class StartupStallPolicy {
    private final int confirmations;
    private long lastProgressMillis;
    private int stalledChecks;

    /**
     * @param confirmations consecutive stalled checks required to declare a stall, at least one
     */
    public StartupStallPolicy(int confirmations) {
        if (confirmations < 1) throw new IllegalArgumentException("At least one confirmation is required");
        this.confirmations = confirmations;
    }

    /** Record forward progress and clear any pending stall confirmation. */
    public synchronized void recordProgress(long nowMillis) {
        lastProgressMillis = nowMillis;
        stalledChecks = 0;
    }

    /**
     * Evaluate one check against the current budget.
     * @param nowMillis current monotonic uptime
     * @param budgetMillis tolerated time without progress
     * @returns true only when the configured number of checks in a row found no progress
     */
    public synchronized boolean stalled(long nowMillis, long budgetMillis) {
        if (nowMillis - lastProgressMillis < budgetMillis) {
            stalledChecks = 0;
            return false;
        }
        stalledChecks += 1;
        return stalledChecks >= confirmations;
    }
}
