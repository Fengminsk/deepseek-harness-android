package com.minnnng.dsh_android;

/** Standalone JVM checks for ordering, uncertain recovery and CPU ownership decisions. */
public final class BackgroundTaskStateTest {
    public static void main(String[] args) {
        BackgroundTaskState state = new BackgroundTaskState(true);
        check(!state.accept("first", 1, 1, 0, 0, 0, 0, 1), "pre-ready frame accepted");
        check(!state.shouldHoldWakeLock(), "startup acquired CPU");
        state.phase("ready");
        check(state.accept("first", 2, 1, 2, 0, 0, 0, 0), "running frame rejected");
        check(state.shouldHoldWakeLock(), "running task did not acquire CPU");
        check(!state.phase("ready") && state.fresh(), "duplicate ready phase revoked the observation lease");
        check(!state.accept("first", 1, 0, 0, 0, 0, 0, 1), "stale revision replaced active state");
        check(!state.accept("other", 3, 0, 0, 0, 0, 0, 1), "foreign runtime replaced state");
        boolean conflictingRevision = false;
        try { state.accept("first", 2, 0, 0, 0, 0, 0, 0); }
        catch (IllegalArgumentException expected) { conflictingRevision = true; }
        check(conflictingRevision && state.shouldHoldWakeLock(), "conflicting same-revision frame replaced running work");
        state.accept("first", 3, 0, 0, 1, 0, 0, 0);
        check(!state.shouldHoldWakeLock() && state.presentation().equals("waiting"), "approval held CPU");
        state.accept("first", 4, 0, 0, 1, 0, 1, 0);
        check(state.shouldHoldWakeLock(), "independent background background job lost CPU");
        state.keepAwake(false);
        check(!state.shouldHoldWakeLock(), "user preference ignored");
        state.keepAwake(true);
        state.stale();
        check(!state.shouldHoldWakeLock() && state.presentation().equals("unconfirmed"), "stale feed held CPU");
        check(state.accept("first", 4, 0, 0, 1, 0, 1, 0), "same-revision fresh observation rejected");
        check(state.shouldHoldWakeLock(), "verified reconnection did not recover CPU ownership");
        check(state.phase("failed"), "failure phase did not invalidate the running observation");
        check(!state.shouldHoldWakeLock() && state.presentation().equals("failed"), "runtime failure remained running");
        state.phase("ready");
        state.accept("replacement", 0, 0, 0, 0, 0, null, 0);
        check(state.presentation().equals("partial"), "unknown background job baseline presented as idle");
        state.accept("replacement", 1, 0, 0, 0, 1, 0, 0);
        check(state.presentation().equals("attention"), "failure record hidden by idle");
        state.accept("replacement", 2, 0, 0, 0, 0, 0, null);
        check(state.presentation().equals("partial") && !state.shouldHoldWakeLock(), "unknown package operations presented as idle");
        state.accept("replacement", 3, 0, 0, 1, 0, 0, 2);
        check(state.presentation().equals("packages") && state.shouldHoldWakeLock(), "package operations without an Agent lost CPU");
        check(state.running() == 0 && state.backgroundJobs() == 0 && state.waiting() == 1 && state.packageOperations() == 2,
                "package operations changed Agent or job semantics");
        state.keepAwake(false);
        check(!state.shouldHoldWakeLock(), "package operations ignored disabled background setting");
        state.keepAwake(true);
        state.stale();
        check(!state.shouldHoldWakeLock(), "stale package operations held CPU");
        state.accept("replacement", 3, 0, 0, 1, 0, 0, 2);
        check(state.shouldHoldWakeLock(), "fresh package observation did not restore CPU");
        state.accept("replacement", 4, 0, 0, 0, 0, 0, 0);
        check(state.presentation().equals("idle"), "confirmed empty state was not idle");
        state.phase("stopped");
        check(!state.shouldHoldWakeLock(), "closed service retained CPU");
        boolean rejected = false;
        try { state.accept("replacement", 5, -1, 0, 0, 0, 0, 0); }
        catch (IllegalArgumentException expected) { rejected = true; }
        check(rejected, "malformed count accepted");
        rejected = false;
        try { state.accept("replacement", 5, 0, 0, 0, 0, 0, -1); }
        catch (IllegalArgumentException expected) { rejected = true; }
        check(rejected, "malformed package count accepted");
        System.out.println("Background task state: ordering, lifecycle and wake ownership passed");
    }

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
}
