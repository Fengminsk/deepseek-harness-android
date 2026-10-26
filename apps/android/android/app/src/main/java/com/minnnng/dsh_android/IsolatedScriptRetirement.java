package com.minnnng.dsh_android;

/** Success needs the reported result, bound Binder death, and App-owned binding cleanup. */
public final class IsolatedScriptRetirement {
    private IsolatedScriptRetirement() {}

    public static IsolatedScriptReceipt.State classify(
            boolean bound, boolean binderSeen, boolean dead, boolean cleanupSucceeded,
            boolean cancelled, boolean rejected, PtcScriptEngine.Status reported) {
        if (bound && binderSeen && (!dead || !cleanupSucceeded))
            return IsolatedScriptReceipt.State.RETIRE_UNCONFIRMED;
        if (cancelled) return IsolatedScriptReceipt.State.CANCELLED;
        if (!bound || rejected) return IsolatedScriptReceipt.State.ERROR;
        if (!binderSeen) return IsolatedScriptReceipt.State.ERROR;
        if (reported == null) return IsolatedScriptReceipt.State.WORKER_DIED;
        return switch (reported) {
            case COMPLETED -> IsolatedScriptReceipt.State.COMPLETED;
            case CANCELLED -> IsolatedScriptReceipt.State.CANCELLED;
            case DEADLINE_EXCEEDED -> IsolatedScriptReceipt.State.TIMED_OUT;
            default -> IsolatedScriptReceipt.State.ERROR;
        };
    }
}
