package com.minnnng.dsh_android;

/** Wire limits are checked without loading Android's native library on the JVM host. */
public final class PtcScriptEngineTest {
    public static void main(String[] args) {
        PtcScriptEngine.validate("(input) => ({answer: input.value + 1})",
                "{\"value\":2}", 1000);
        String oversized = "中".repeat(PtcScriptEngine.MAX_PROGRAM_BYTES / 3 + 1);
        rejects(() -> PtcScriptEngine.validate(oversized, "{}", 1000));
        rejects(() -> PtcScriptEngine.validate("(x) => x", oversized, 1000));
        rejects(() -> PtcScriptEngine.validate("(x) => x", "{}", 0));
        rejects(() -> PtcScriptEngine.validate("(x) => x", "{}",
                PtcScriptEngine.MAX_DEADLINE_MILLIS + 1));
        PtcScriptEngine.validateWorkflow("(x) => x", "{}",
                PtcScriptEngine.MAX_WORKFLOW_DEADLINE_MILLIS);
        rejects(() -> PtcScriptEngine.validateWorkflow("(x) => x", "{}",
                PtcScriptEngine.MAX_WORKFLOW_DEADLINE_MILLIS + 1));
        PtcScriptEngine.validatePtc("(x) => x", "{}", 120_000);
        rejects(() -> PtcScriptEngine.validatePtc("(x) => x", "{}", 120_001));
        rejects(() -> PtcScriptEngine.validatePtc("(x) => x", "{}", 0));
        rejects(() -> PtcScriptEngine.validate("  ", "{}", 1000));
        if (PtcScriptEngine.MAX_PENDING_HOST_CALLS != 8 || PtcScriptEngine.MAX_HOST_CALLS != 128) {
            throw new AssertionError("Host queue bounds changed without protocol review");
        }
        PtcScriptEngine.HostCall synchronousOnly = request -> "{}";
        rejectsUnsupported(() -> synchronousOnly.submit("{}"));
    }

    private static void rejects(Runnable action) {
        try { action.run(); }
        catch (IllegalArgumentException expected) { return; }
        throw new AssertionError("Invalid script request was accepted");
    }

    private static void rejectsUnsupported(Runnable action) {
        try { action.run(); }
        catch (UnsupportedOperationException expected) { return; }
        throw new AssertionError("A synchronous host callback silently accepted async submission");
    }
}
