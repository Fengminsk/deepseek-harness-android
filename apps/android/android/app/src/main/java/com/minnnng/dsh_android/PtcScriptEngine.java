package com.minnnng.dsh_android;

import java.nio.charset.StandardCharsets;
import java.util.Objects;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * V8-only execution in the Android isolated guest process. The script is a JavaScript function
 * expression taking one JSON value and returning one JSON value, synchronously or via already
 * settled microtasks. No Node Environment, direct file, network, subprocess, or timer API exists.
 * A caller may supply bounded host-call callbacks with App-issued grant handles;
 * the default overload exposes no host object. This is not DSH PTC or workflow tool parity.
 *
 * <p>The caller owns an instance for exactly one run, calls {@link #cancel()} on cancellation,
 * closes it after completion, and also enforces a Binder/service deadline. V8 heap exhaustion can
 * terminate the isolated process; the App must handle Binder death as an unsuccessful run.</p>
 */
public final class PtcScriptEngine implements AutoCloseable {
    public static final int MAX_PROGRAM_BYTES = 64 * 1024;
    public static final int MAX_INPUT_BYTES = 64 * 1024;
    public static final int MAX_OUTPUT_BYTES = 64 * 1024;
    public static final int MAX_LOG_BYTES = 16 * 1024;
    public static final int MAX_DEADLINE_MILLIS = 5000;
    /** Private workflow only; the App controller rejects this budget for ordinary scripts. */
    public static final int MAX_WORKFLOW_DEADLINE_MILLIS = 120_000;
    public static final int MAX_HOST_REQUEST_BYTES = 32 * 1024;
    // A 64 KiB UTF-8 read can expand to 6 ASCII bytes per control character in JSON.
    // Leave room for the fixed response envelope while staying below one Binder transaction.
    public static final int MAX_HOST_REPLY_BYTES = 448 * 1024;
    public static final int MAX_GRANTS_BYTES = 8192;
    public static final int MAX_PENDING_HOST_CALLS = 8;
    public static final int MAX_HOST_CALLS = 128;

    /** The guest callback must enforce its own remaining deadline and return one JSON value. */
    public interface HostCall {
        String call(String requestJson);
        /** Enqueue one request without blocking the V8 thread; return its wire sequence. */
        default int submit(String requestJson) {
            throw new UnsupportedOperationException("Asynchronous host calls unavailable");
        }
    }

    public enum Status {
        COMPLETED, INVALID_REQUEST, INVALID_EXECUTION, INVALID_INPUT, INVALID_PROGRAM,
        SCRIPT_ERROR, OUTPUT_INVALID, OUTPUT_TOO_LARGE, ASYNC_HOST_UNAVAILABLE,
        DEADLINE_EXCEEDED, CANCELLED, ENGINE_UNAVAILABLE
    }

    public static final class Result {
        public final Status status;
        public final String outputJson;
        public final String logsJson;

        private Result(Status status, String outputJson, String logsJson) {
            this.status = status;
            this.outputJson = outputJson;
            this.logsJson = logsJson;
        }
    }

    private static final class Native {
        static { System.loadLibrary("pocket_ptc_script"); }
        static void ensureLoaded() { }
    }

    private static native long nativeCreate();
    private static native String[] nativeRun(long id, String program, String inputJson,
                                             int deadlineMillis, HostCall hostCall, String grantsJson);
    private static native String[] nativeRunFunctionBody(long id, String body, String inputJson,
                                                         int deadlineMillis, HostCall hostCall,
                                                         String grantsJson);
    private static native void nativeCancel(long id);
    private static native boolean nativeDeliverReply(long id, int sequence, String replyJson);
    private static native void nativeClose(long id);

    private final long id;
    private final AtomicBoolean started = new AtomicBoolean();
    private final AtomicBoolean closed = new AtomicBoolean();

    public PtcScriptEngine() {
        Native.ensureLoaded();
        id = nativeCreate();
        if (id == 0) throw new IllegalStateException("An isolated script is already active");
    }

    /** Validates the wire request before native allocation or execution. */
    public static void validate(String program, String inputJson, int deadlineMillis) {
        validateBounded(program, inputJson, deadlineMillis, MAX_DEADLINE_MILLIS);
    }

    /** The private workflow path has a longer but still finite guest lifetime. */
    public static void validateWorkflow(String program, String inputJson, int deadlineMillis) {
        validateBounded(program, inputJson, deadlineMillis, MAX_WORKFLOW_DEADLINE_MILLIS);
    }

    private static void validateBounded(String program, String inputJson, int deadlineMillis,
                                        int maximumMillis) {
        Objects.requireNonNull(program, "program");
        Objects.requireNonNull(inputJson, "inputJson");
        if (program.trim().isEmpty() || program.length() > MAX_PROGRAM_BYTES
                || inputJson.length() > MAX_INPUT_BYTES
                || program.getBytes(StandardCharsets.UTF_8).length > MAX_PROGRAM_BYTES
                || inputJson.getBytes(StandardCharsets.UTF_8).length > MAX_INPUT_BYTES
                || deadlineMillis < 1 || deadlineMillis > maximumMillis) {
            throw new IllegalArgumentException("Script request exceeds execution limits");
        }
    }

    /** Blocking execution. A second invocation, including after failure, is rejected. */
    public Result run(String program, String inputJson, int deadlineMillis) {
        return run(program, inputJson, deadlineMillis, null, null);
    }

    /** The optional host callback exposes only App-selected grant handles, never paths. */
    public Result run(String program, String inputJson, int deadlineMillis,
                      HostCall hostCall, String grantsJson) {
        return runInternal(program, inputJson, deadlineMillis, hostCall, grantsJson, false);
    }

    /**
     * Run JavaScript statements as an async function body. A top-level await or return is
     * accepted. The body is passed to V8's native AsyncFunction constructor as a separate
     * string; it is never interpolated into an enclosing source expression. This entry does
     * not strip TypeScript or expose Node globals. Completed runs carry bounded console logs.
     */
    public Result runFunctionBody(String body, String inputJson, int deadlineMillis) {
        return runFunctionBody(body, inputJson, deadlineMillis, null, null);
    }

    /** A host callback is available only when the App supplies a matching grant list. */
    public Result runFunctionBody(String body, String inputJson, int deadlineMillis,
                                  HostCall hostCall, String grantsJson) {
        return runInternal(body, inputJson, deadlineMillis, hostCall, grantsJson, true);
    }

    private Result runInternal(String program, String inputJson, int deadlineMillis,
                               HostCall hostCall, String grantsJson, boolean functionBody) {
        // The App controller is the authority for choosing ordinary script or
        // private workflow. This worker sees only its bounded Binder request.
        validateWorkflow(program, inputJson, deadlineMillis);
        if ((hostCall == null) != (grantsJson == null)
                || (grantsJson != null && utf8Bytes(grantsJson) > MAX_GRANTS_BYTES)) {
            throw new IllegalArgumentException("Invalid host-call binding");
        }
        if (closed.get() || !started.compareAndSet(false, true)) {
            throw new IllegalStateException("Script execution is closed or already started");
        }
        String[] nativeResult = functionBody
                ? nativeRunFunctionBody(id, program, inputJson, deadlineMillis, hostCall, grantsJson)
                : nativeRun(id, program, inputJson, deadlineMillis, hostCall, grantsJson);
        if (nativeResult == null || nativeResult.length != 3) {
            return new Result(Status.ENGINE_UNAVAILABLE, null, null);
        }
        final Status status;
        try { status = Status.valueOf(nativeResult[0]); }
        catch (RuntimeException error) { return new Result(Status.ENGINE_UNAVAILABLE, null, null); }
        if (status != Status.COMPLETED) return new Result(status, null, null);
        String output = nativeResult[1];
        String logs = nativeResult[2];
        if (output == null || logs == null || !logs.startsWith("[") || !logs.endsWith("]")
                || utf8Bytes(logs) > MAX_LOG_BYTES
                || utf8Bytes(output) > MAX_OUTPUT_BYTES - utf8Bytes(logs)) {
            return new Result(Status.OUTPUT_INVALID, null, null);
        }
        return new Result(status, output, logs);
    }

    private static int utf8Bytes(String text) { return text.getBytes(StandardCharsets.UTF_8).length; }

    /** Terminates active V8 execution and rejects a run that has not started. */
    public void cancel() {
        if (!closed.get()) nativeCancel(id);
    }

    /** Called on Binder's receiving thread; V8 handles the reply on its execution thread. */
    public boolean deliverReply(int sequence, String replyJson) {
        if (closed.get() || sequence < 1 || sequence > MAX_HOST_CALLS
                || replyJson == null || utf8Bytes(replyJson) > MAX_HOST_REPLY_BYTES) return false;
        return nativeDeliverReply(id, sequence, replyJson);
    }

    @Override public void close() {
        if (closed.compareAndSet(false, true)) nativeClose(id);
    }
}
