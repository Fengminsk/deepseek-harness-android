package com.minnnng.dsh_android;

import java.util.concurrent.atomic.AtomicReference;

/** One service generation's transport lifetime, shared by the Node, IPC and main threads. */
public final class RuntimeLifecycle {
    private enum State { ACTIVE, FAILED, CLOSED, PROCESS_EXIT_REQUIRED }
    private final AtomicReference<State> state = new AtomicReference<>(State.ACTIVE);

    /** A terminal transport cannot admit buffered ready events or further native work. */
    public boolean acceptsFrames() { return state.get() == State.ACTIVE; }

    /** Latches the first failure before its main-thread notification is queued. */
    public boolean fail() { return state.compareAndSet(State.ACTIVE, State.FAILED); }

    /** Teardown supersedes a failure whose notification has not yet run. */
    public boolean failed() { return state.get() == State.FAILED; }

    /** A failed IPC generation cannot retain an unobserved Node process. Teardown wins races with replacement. */
    public boolean stopFailedProcess(Runnable report, Runnable stopForeground, Runnable stopService,
            Runnable killProcess) {
        if (!state.compareAndSet(State.FAILED, State.PROCESS_EXIT_REQUIRED)) return false;
        try { report.run(); }
        finally {
            try { stopForeground.run(); }
            finally {
                try { stopService.run(); }
                finally { killProcess.run(); }
            }
        }
        return true;
    }

    /** A platform timeout must stop the foreground service before doing any disk or IPC work. */
    public boolean stopTimedOutProcess(Runnable stopForeground, Runnable stopService,
            Runnable report, Runnable killProcess) {
        State previous = state.getAndUpdate(current ->
                current == State.CLOSED || current == State.PROCESS_EXIT_REQUIRED
                        ? current : State.PROCESS_EXIT_REQUIRED);
        if (previous == State.CLOSED || previous == State.PROCESS_EXIT_REQUIRED) return false;
        try { stopForeground.run(); }
        finally {
            try { stopService.run(); }
            finally {
                try { report.run(); }
                finally { killProcess.run(); }
            }
        }
        return true;
    }

    /** Each replacement service owns a new instance; this instance is never reset. */
    public void close() { state.updateAndGet(current ->
            current == State.PROCESS_EXIT_REQUIRED ? current : State.CLOSED); }

    /** A planned exit may clear the lease marker only while this transport is still active. */
    public boolean closeForProcessExit() {
        return state.compareAndSet(State.ACTIVE, State.PROCESS_EXIT_REQUIRED);
    }

    /** Service destruction must not release the lease before a required process exit. */
    public boolean processExitRequired() { return state.get() == State.PROCESS_EXIT_REQUIRED; }

    /** Claims an unscheduled Service teardown, including a failure still queued on the main thread. */
    public boolean closeUnexpected() {
        State previous = state.getAndUpdate(current ->
                current == State.PROCESS_EXIT_REQUIRED ? current : State.CLOSED);
        return previous != State.CLOSED && previous != State.PROCESS_EXIT_REQUIRED;
    }
}
