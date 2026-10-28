package com.minnnng.dsh_android;

import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Records intervals in which this process did not run while monotonic time advanced.
 *
 * <p>A sampler thread compares {@link Clock#monotonicNanos()} with
 * {@link Clock#elapsedRealtimeMillis()} between ticks. A gap in both clocks means the
 * process was not scheduled (a platform freezer, an OEM freeze service, or long scheduler
 * starvation); a gap only in the elapsed-realtime clock means the device suspended.
 * Android timers are cooperative, so every in-process deadline is delivered late by the
 * same interval; this observation is what distinguishes that late delivery from a slow
 * operation. Counters are in memory only: a process killed while suspended loses them.
 */
public final class ProcessSuspensionWatch implements AutoCloseable {
    /** The device slept while this process could not run. */
    public static final String DEVICE_SUSPENSION = "device-suspension";
    /** The process was not scheduled while monotonic time kept advancing. */
    public static final String PROCESS_UNSCHEDULED = "process-unscheduled";

    /** Monotonic sources only; wall time is never used because it moves backwards. */
    public interface Clock {
        /** @return nanoseconds that stop advancing while the device is suspended */
        long monotonicNanos();

        /** @return milliseconds that include device suspension */
        long elapsedRealtimeMillis();
    }

    /** Receives one observation per detected interval, on the sampler thread. */
    public interface Listener {
        /**
         * @param kind one of {@link #DEVICE_SUSPENSION} or {@link #PROCESS_UNSCHEDULED}
         * @param durationMillis time beyond the expected tick that the process missed
         */
        void onSuspension(String kind, long durationMillis);
    }

    /** Immutable counters for one watcher. */
    public static final class Snapshot {
        private final long count;
        private final long totalMillis;
        private final long maxMillis;
        private final long lastMillis;
        private final String lastKind;

        private Snapshot(long count, long totalMillis, long maxMillis, long lastMillis, String lastKind) {
            this.count = count;
            this.totalMillis = totalMillis;
            this.maxMillis = maxMillis;
            this.lastMillis = lastMillis;
            this.lastKind = lastKind;
        }

        /** @return detected interval count */
        public long count() { return count; }

        /** @return summed missed milliseconds of every interval */
        public long totalMillis() { return totalMillis; }

        /** @return longest missed interval in milliseconds */
        public long maxMillis() { return maxMillis; }

        /** @return missed milliseconds of the latest interval */
        public long lastMillis() { return lastMillis; }

        /** @return kind of the latest interval, or null before the first one */
        public String lastKind() { return lastKind; }
    }

    private final Clock clock;
    private final long sampleIntervalMillis;
    private final long thresholdMillis;
    private final Listener listener;
    private final AtomicBoolean started = new AtomicBoolean();
    private volatile boolean closed;
    private Thread thread;
    private long previousMonotonicNanos;
    private long previousElapsedRealtimeMillis;
    private long count;
    private long totalMillis;
    private long maxMillis;
    private long lastMillis;
    private String lastKind;

    /**
     * @param clock monotonic clock sources supplied by the owner
     * @param sampleIntervalMillis expected delay between samples, 250 to 5000
     * @param thresholdMillis missed time that counts as suspension, at least twice the sample interval
     * @param listener optional observer invoked on the sampler thread
     */
    public ProcessSuspensionWatch(Clock clock, long sampleIntervalMillis, long thresholdMillis, Listener listener) {
        if (clock == null) throw new IllegalArgumentException("A suspension clock is required");
        if (sampleIntervalMillis < 250 || sampleIntervalMillis > 5_000)
            throw new IllegalArgumentException("Invalid suspension sample interval");
        if (thresholdMillis < sampleIntervalMillis * 2 || thresholdMillis > 600_000)
            throw new IllegalArgumentException("Invalid suspension threshold");
        this.clock = clock;
        this.sampleIntervalMillis = sampleIntervalMillis;
        this.thresholdMillis = thresholdMillis;
        this.listener = listener;
    }

    /** Starts the daemon sampler once; the first baseline is taken before it returns. */
    public void start() {
        if (!started.compareAndSet(false, true)) throw new IllegalStateException("Suspension watch already started");
        synchronized (this) {
            previousMonotonicNanos = clock.monotonicNanos();
            previousElapsedRealtimeMillis = clock.elapsedRealtimeMillis();
        }
        thread = new Thread(this::loop, "dsh-process-suspension");
        thread.setDaemon(true);
        thread.start();
    }

    private void loop() {
        while (!closed) {
            try { Thread.sleep(sampleIntervalMillis); }
            catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return;
            }
            if (!closed) sample();
        }
    }

    /** Compares the current tick with the previous one; a stale or reordered clock reports nothing. */
    synchronized void sample() {
        long nowMonotonic = clock.monotonicNanos();
        long nowElapsed = clock.elapsedRealtimeMillis();
        long monotonicGapMillis = (nowMonotonic - previousMonotonicNanos) / 1_000_000L;
        long elapsedGapMillis = nowElapsed - previousElapsedRealtimeMillis;
        previousMonotonicNanos = nowMonotonic;
        previousElapsedRealtimeMillis = nowElapsed;
        if (monotonicGapMillis < 0 || elapsedGapMillis < 0) return;
        String kind;
        long observedMillis;
        if (elapsedGapMillis - monotonicGapMillis >= thresholdMillis) {
            kind = DEVICE_SUSPENSION;
            observedMillis = elapsedGapMillis;
        } else if (monotonicGapMillis - sampleIntervalMillis >= thresholdMillis) {
            kind = PROCESS_UNSCHEDULED;
            observedMillis = monotonicGapMillis;
        } else return;
        long missedMillis = Math.max(observedMillis - sampleIntervalMillis, 0);
        count += 1;
        totalMillis += missedMillis;
        maxMillis = Math.max(maxMillis, missedMillis);
        lastMillis = missedMillis;
        lastKind = kind;
        if (listener != null) listener.onSuspension(kind, missedMillis);
    }

    /** @return counters observed so far; the sampler keeps running */
    public synchronized Snapshot snapshot() {
        return new Snapshot(count, totalMillis, maxMillis, lastMillis, lastKind);
    }

    /** Stops the sampler; the counters remain readable. */
    @Override
    public void close() {
        closed = true;
        Thread running = thread;
        if (running == null) return;
        running.interrupt();
        try { running.join(1_000); }
        catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
    }
}
