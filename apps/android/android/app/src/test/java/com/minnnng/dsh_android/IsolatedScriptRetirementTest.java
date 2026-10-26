package com.minnnng.dsh_android;

public final class IsolatedScriptRetirementTest {
    public static void main(String[] args) {
        check(IsolatedScriptReceipt.State.COMPLETED,
                true, true, true, true, false, false, PtcScriptEngine.Status.COMPLETED);
        check(IsolatedScriptReceipt.State.RETIRE_UNCONFIRMED,
                true, true, false, true, false, false, PtcScriptEngine.Status.COMPLETED);
        check(IsolatedScriptReceipt.State.RETIRE_UNCONFIRMED,
                true, true, true, false, false, false, PtcScriptEngine.Status.COMPLETED);
        check(IsolatedScriptReceipt.State.CANCELLED,
                true, true, true, true, true, false, PtcScriptEngine.Status.COMPLETED);
        check(IsolatedScriptReceipt.State.ERROR,
                true, true, true, true, false, true, PtcScriptEngine.Status.COMPLETED);
        check(IsolatedScriptReceipt.State.WORKER_DIED,
                true, true, true, true, false, false, null);
        check(IsolatedScriptReceipt.State.ERROR,
                true, false, false, true, false, true, null);
        check(IsolatedScriptReceipt.State.ERROR,
                false, false, false, true, false, true, null);
        check(IsolatedScriptReceipt.State.TIMED_OUT,
                true, true, true, true, false, false, PtcScriptEngine.Status.DEADLINE_EXCEEDED);
    }

    private static void check(IsolatedScriptReceipt.State expected, boolean bound,
                              boolean binderSeen, boolean dead, boolean cleanup, boolean cancelled,
                              boolean rejected, PtcScriptEngine.Status reported) {
        var actual = IsolatedScriptRetirement.classify(bound, binderSeen, dead, cleanup,
                cancelled, rejected, reported);
        if (actual != expected) throw new AssertionError("Expected " + expected + ", got " + actual);
    }
}
