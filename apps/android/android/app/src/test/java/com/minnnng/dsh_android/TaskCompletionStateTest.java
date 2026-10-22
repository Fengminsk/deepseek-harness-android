package com.minnnng.dsh_android;

/** Standalone JVM coverage for repeat delivery, process replacement and independent Activity views. */
public final class TaskCompletionStateTest {
    public static void main(String[] args) {
        TaskCompletionState state = new TaskCompletionState();
        check(state.claim("first", 10, -1), "new completion was lost");
        check(state.isCurrentClaim("first", 10), "fresh completion was not deliverable");
        check(!state.claim("first", 10, -1), "duplicate completion was replayed");
        check(!state.claim("first", 9, -1), "older completion was replayed");
        check(state.claim("other", 10, -1), "separate session shared a watermark");
        check(state.claim("first", 20, 10), "next completion was suppressed");
        check(!state.isCurrentClaim("first", 10), "queued older completion could alert after a newer turn");
        check(state.isCurrentClaim("first", 20), "newer completion was not deliverable");
        check(!new TaskCompletionState().claim("first", 20, 20), "cold replay ignored durable watermark");
        check(state.shouldAlert("first"), "background completion was suppressed");
        state.viewing("activity-1", "first", true);
        check(!state.shouldAlert("first") && state.shouldAlert("other"), "visible-session suppression crossed sessions");
        state.viewing("activity-2", "other", true);
        state.viewing("activity-1", null, true);
        check(state.shouldAlert("first") && !state.shouldAlert("other"), "one Activity erased another view");
        state.viewing("activity-1", "first", false);
        check(state.shouldAlert("first"), "paused Activity kept suppressing notices");
        state.disconnected("activity-2");
        check(state.shouldAlert("other"), "dead client kept suppressing notices");
        state.viewing("activity-1", "first", true);
        state.viewing("activity-1", "other", true);
        check(state.shouldAlert("first") && !state.shouldAlert("other"), "navigation retained old suppression");
        state.close();
        check(!state.isCurrentClaim("first", 20), "closed owner retained a queued notice");
        check(!state.claim("first", 30, 20) && !state.shouldAlert("first"), "closed owner delivered a late notice");
        for (String invalid : new String[] {"", " ", "x".repeat(513)}) {
            boolean rejected = false;
            try { new TaskCompletionState().claim(invalid, 0, -1); }
            catch (IllegalArgumentException expected) { rejected = true; }
            check(rejected, "invalid session accepted");
        }
        System.out.println("Task completion state: deduplication, recovery and visible-session suppression passed");
    }
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
}
