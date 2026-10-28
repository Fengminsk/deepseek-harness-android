package com.minnnng.dsh_android;

import java.util.concurrent.atomic.AtomicLong;

/** Deterministic suspension intervals for the process-freeze observation. */
public final class ProcessSuspensionWatchTest {
    private static int checks;
    private static void check(boolean value, String message) {
        checks++;
        if (!value) throw new AssertionError(message);
    }
    private static final class FakeClock implements ProcessSuspensionWatch.Clock {
        final AtomicLong monotonic = new AtomicLong(1_000_000_000L);
        final AtomicLong elapsed = new AtomicLong(10_000L);
        void advance(long millis) {
            monotonic.addAndGet(millis * 1_000_000L);
            elapsed.addAndGet(millis);
        }
        void advanceElapsedOnly(long millis) { elapsed.addAndGet(millis); }
        @Override public long monotonicNanos() { return monotonic.get(); }
        @Override public long elapsedRealtimeMillis() { return elapsed.get(); }
    }
    public static void main(String[] args) throws Exception {
        FakeClock clock = new FakeClock();
        int[] callbacks = { 0 };
        ProcessSuspensionWatch watch = new ProcessSuspensionWatch(clock, 1_000, 5_000,
                (kind, duration) -> callbacks[0]++);
        watch.start();
        watch.close();
        check(watch.snapshot().count() == 0, "a normal start recorded a suspension");

        clock.advance(1_000);
        watch.sample();
        check(watch.snapshot().count() == 0, "an expected tick recorded a suspension");

        clock.advance(11_000);
        watch.sample();
        ProcessSuspensionWatch.Snapshot unscheduled = watch.snapshot();
        check(unscheduled.count() == 1, "an unscheduled process interval was not recorded");
        check(ProcessSuspensionWatch.PROCESS_UNSCHEDULED.equals(unscheduled.lastKind()),
                "an unscheduled interval was classified as device suspension");
        check(unscheduled.lastMillis() == 10_000, "the unscheduled interval kept its sampling delay");
        check(unscheduled.maxMillis() == 10_000, "the longest interval is wrong");
        check(unscheduled.totalMillis() == 10_000, "the summed interval is wrong");
        check(callbacks[0] == 1, "the listener did not observe the interval");

        clock.advanceElapsedOnly(31_000);
        watch.sample();
        ProcessSuspensionWatch.Snapshot device = watch.snapshot();
        check(device.count() == 2, "a device suspension was not recorded");
        check(ProcessSuspensionWatch.DEVICE_SUSPENSION.equals(device.lastKind()),
                "a device suspension was classified as an unscheduled process");
        check(device.lastMillis() == 30_000, "the suspended interval includes the sampling delay");
        check(device.totalMillis() == 40_000, "summed missed time does not include both intervals");
        check(device.maxMillis() == 30_000, "the longest interval is stale");

        clock.advance(-5_000);
        watch.sample();
        check(watch.snapshot().count() == 2, "a reordered clock recorded a suspension");

        boolean invalidInterval = false;
        try { new ProcessSuspensionWatch(clock, 100, 5_000, null); }
        catch (IllegalArgumentException expected) { invalidInterval = true; }
        check(invalidInterval, "an unusable sample interval was accepted");
        boolean invalidThreshold = false;
        try { new ProcessSuspensionWatch(clock, 1_000, 1_500, null); }
        catch (IllegalArgumentException expected) { invalidThreshold = true; }
        check(invalidThreshold, "a threshold below two intervals was accepted");

        ProcessSuspensionWatch started = new ProcessSuspensionWatch(clock, 250, 5_000, null);
        started.start();
        boolean restarted = false;
        try { started.start(); }
        catch (IllegalStateException expected) { restarted = true; }
        check(restarted, "the sampler started twice");
        FakeClock threaded = new FakeClock();
        ProcessSuspensionWatch observing = new ProcessSuspensionWatch(threaded, 250, 5_000, null);
        observing.start();
        threaded.advance(20_000);
        long until = System.currentTimeMillis() + 5_000;
        while (observing.snapshot().count() == 0 && System.currentTimeMillis() < until) Thread.sleep(10);
        check(observing.snapshot().count() == 1, "the sampler thread did not observe a stalled process");
        observing.close();
        started.close();
        check(observing.snapshot().count() == 1, "closing the sampler discarded its counters");
        check(ProcessSuspensionWatch.PROCESS_UNSCHEDULED.equals(observing.snapshot().lastKind()),
                "the sampler thread misclassified its interval");
        System.out.println("ProcessSuspensionWatch: " + checks + " checks passed");
    }
}
