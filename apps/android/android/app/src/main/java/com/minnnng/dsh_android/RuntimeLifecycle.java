package com.minnnng.dsh_android;

import java.util.concurrent.atomic.AtomicReference;

/** One service generation's transport lifetime, shared by the Node, IPC and main threads. */
public final class RuntimeLifecycle {
    private enum State { ACTIVE, FAILED, CLOSED }
    private final AtomicReference<State> state = new AtomicReference<>(State.ACTIVE);

    /** A terminal transport cannot admit buffered ready events or further native work. */
    public boolean acceptsFrames() { return state.get() == State.ACTIVE; }

    /** Latches the first failure before its main-thread notification is queued. */
    public boolean fail() { return state.compareAndSet(State.ACTIVE, State.FAILED); }

    /** Teardown supersedes a failure whose notification has not yet run. */
    public boolean failed() { return state.get() == State.FAILED; }

    /** Each replacement service owns a new instance; this instance is never reset. */
    public void close() { state.set(State.CLOSED); }
}
