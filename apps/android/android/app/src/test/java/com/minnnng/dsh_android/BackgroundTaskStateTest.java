package com.minnnng.dsh_android;

/** Standalone JVM checks for ordering, uncertain recovery and CPU ownership decisions. */
public final class BackgroundTaskStateTest {
    public static void main(String[] args) {
        BackgroundTaskState state = new BackgroundTaskState(true);
        check(!state.accept("first", 1, 1, 0, 0, 0, 0), "pre-ready frame accepted");
        check(!state.shouldHoldWakeLock(), "startup acquired CPU");
        state.phase("ready");
        check(state.accept("first", 2, 1, 2, 0, 0, 0), "running frame rejected");
        check(state.shouldHoldWakeLock(), "running task did not acquire CPU");
        check(!state.accept("first", 1, 0, 0, 0, 0, 0), "stale revision replaced active state");
        check(!state.accept("other", 3, 0, 0, 0, 0, 0), "foreign runtime replaced state");
        state.accept("first", 3, 0, 0, 1, 0, 0);
        check(!state.shouldHoldWakeLock() && state.presentation().equals("waiting"), "approval held CPU");
        state.accept("first", 4, 0, 0, 1, 0, 1);
        check(state.shouldHoldWakeLock(), "independent background background job lost CPU");
        state.keepAwake(false);
        check(!state.shouldHoldWakeLock(), "user preference ignored");
        state.keepAwake(true);
        state.stale();
        check(!state.shouldHoldWakeLock() && state.presentation().equals("unconfirmed"), "stale feed held CPU");
        check(state.accept("first", 4, 0, 0, 1, 0, 1), "same-revision fresh observation rejected");
        check(state.shouldHoldWakeLock(), "verified reconnection did not recover CPU ownership");
        state.phase("failed");
        check(!state.shouldHoldWakeLock() && state.presentation().equals("failed"), "runtime failure remained running");
        state.phase("ready");
        state.accept("replacement", 0, 0, 0, 0, 0, null);
        check(state.presentation().equals("partial"), "unknown background job baseline presented as idle");
        state.accept("replacement", 1, 0, 0, 0, 1, 0);
        check(state.presentation().equals("attention"), "failure record hidden by idle");
        state.accept("replacement", 2, 0, 0, 0, 0, 0);
        check(state.presentation().equals("idle"), "confirmed empty state was not idle");
        state.phase("stopped");
        check(!state.shouldHoldWakeLock(), "closed service retained CPU");
        boolean rejected = false;
        try { state.accept("replacement", 3, -1, 0, 0, 0, 0); }
        catch (IllegalArgumentException expected) { rejected = true; }
        check(rejected, "malformed count accepted");
        System.out.println("Background task state: ordering, lifecycle and wake ownership passed");
    }

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
}
