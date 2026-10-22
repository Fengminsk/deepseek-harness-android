package com.minnnng.dsh_android;

/** Main-thread state for foreground presentation. Stale data never justifies a wake lock. */
public final class BackgroundTaskState {
    private String phase = "starting";
    private String epoch;
    private long revision = -1;
    private boolean fresh;
    private boolean keepAwake;
    private int running, queued, waiting, failed;
    private Integer backgroundJobs;
    private Integer packageOperations;

    public BackgroundTaskState(boolean keepAwake) {
        this.keepAwake = keepAwake;
    }

    /** Returns whether a new phase invalidated the current observation. */
    public boolean phase(String value) {
        if (!value.equals(phase)) {
            phase = value;
            fresh = false;
            epoch = null;
            revision = -1;
            return true;
        }
        return false;
    }

    public boolean accept(String sourceEpoch, long sourceRevision, int running, int queued,
            int waiting, int failed, Integer backgroundJobs, Integer packageOperations) {
        if (sourceEpoch == null || sourceEpoch.trim().isEmpty() || sourceEpoch.length() > 128
                || sourceRevision < 0 || running < 0 || queued < 0 || waiting < 0 || failed < 0
                || (backgroundJobs != null && backgroundJobs < 0)
                || (packageOperations != null && packageOperations < 0)) {
            throw new IllegalArgumentException("Invalid task summary");
        }
        if (!phase.equals("ready") || (epoch != null && !epoch.equals(sourceEpoch))
                || sourceRevision < revision) return false;
        if (sourceRevision == revision && (running != this.running || queued != this.queued
                || waiting != this.waiting || failed != this.failed
                || !java.util.Objects.equals(backgroundJobs, this.backgroundJobs)
                || !java.util.Objects.equals(packageOperations, this.packageOperations))) {
            throw new IllegalArgumentException("Conflicting task summary revision");
        }
        epoch = sourceEpoch;
        revision = sourceRevision;
        this.running = running;
        this.queued = queued;
        this.waiting = waiting;
        this.failed = failed;
        this.backgroundJobs = backgroundJobs;
        this.packageOperations = packageOperations;
        fresh = true;
        return true;
    }

    public void stale() { fresh = false; }
    public void keepAwake(boolean enabled) { keepAwake = enabled; }
    public boolean keepAwake() { return keepAwake; }
    public boolean fresh() { return phase.equals("ready") && fresh; }
    public int running() { return running; }
    public int queued() { return queued; }
    public int waiting() { return waiting; }
    public int failed() { return failed; }
    public Integer backgroundJobs() { return backgroundJobs; }
    public Integer packageOperations() { return packageOperations; }
    public boolean hasActiveWork() {
        return fresh() && (running > 0 || (backgroundJobs != null && backgroundJobs > 0)
                || (packageOperations != null && packageOperations > 0));
    }
    public boolean shouldHoldWakeLock() {
        return keepAwake && hasActiveWork();
    }
    public String presentation() {
        if (!phase.equals("ready")) return phase;
        if (!fresh) return "unconfirmed";
        if (running > 0 || (backgroundJobs != null && backgroundJobs > 0)) return "running";
        if (packageOperations != null && packageOperations > 0) return "packages";
        if (waiting > 0) return "waiting";
        if (queued > 0) return "queued";
        if (backgroundJobs == null || packageOperations == null) return "partial";
        if (failed > 0) return "attention";
        return "idle";
    }
}
