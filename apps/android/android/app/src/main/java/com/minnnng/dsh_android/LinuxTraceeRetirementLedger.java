package com.minnnng.dsh_android;

import java.util.HashSet;
import java.util.Set;

/**
 * Tracks a complete, ordered tracer event stream before a guest result can be published.
 * This records evidence; it neither traces nor kills OS processes by itself.
 */
final class LinuxTraceeRetirementLedger {
    static final int TRACE_FORK = 0x00000002;
    static final int TRACE_VFORK = 0x00000004;
    static final int TRACE_CLONE = 0x00000008;
    static final int TRACE_EXIT = 0x00000040;
    static final int REQUIRED_OPTIONS = TRACE_FORK | TRACE_VFORK | TRACE_CLONE | TRACE_EXIT;
    static final int MAX_LIFETIMES = 128;

    private final Set<Integer> live = new HashSet<>();
    private final Set<Integer> seen = new HashSet<>();
    private long nextSequence = 1;
    private boolean armed;
    private boolean closed;
    private boolean cancellationRequested;
    private String failure;

    LinuxTraceeRetirementLedger(int rootPid) {
        if (rootPid <= 0) throw new IllegalArgumentException("Invalid root tracee PID");
        live.add(rootPid);
        seen.add(rootPid);
    }

    boolean arm(int confirmedPtraceOptions) {
        if (armed || closed || failure != null ||
                (confirmedPtraceOptions & REQUIRED_OPTIONS) != REQUIRED_OPTIONS) {
            return reject("Tracer fork and final-exit options unconfirmed");
        }
        armed = true;
        return true;
    }

    boolean spawned(long sequence, int parentPid, int childPid) {
        if (!acceptSequence(sequence) || !live.contains(parentPid) || childPid <= 0 ||
                seen.contains(childPid) || seen.size() >= MAX_LIFETIMES) {
            return reject("Tracee spawn event missing or ambiguous");
        }
        seen.add(childPid);
        live.add(childPid);
        nextSequence++;
        return true;
    }

    /** Call only after waitpid reports WIFEXITED or WIFSIGNALED, not PTRACE_EVENT_EXIT. */
    boolean reaped(long sequence, int pid) {
        if (!acceptSequence(sequence) || !live.remove(pid)) {
            return reject("Tracee final reap event missing or ambiguous");
        }
        nextSequence++;
        return true;
    }

    void requestCancellation() { cancellationRequested = true; }

    /** A normal tracer exit must follow a drained stream and final wait for every tracee. */
    boolean close(long sequence, boolean tracerExitedNormally, boolean streamDrained) {
        if (!acceptSequence(sequence) || !tracerExitedNormally || !streamDrained || !live.isEmpty()) {
            return reject("Tracer termination or process retirement unconfirmed");
        }
        nextSequence++;
        closed = true;
        return true;
    }

    boolean retirementConfirmed() { return closed && failure == null && live.isEmpty(); }

    boolean mayPublishSuccess() { return retirementConfirmed() && !cancellationRequested; }

    String failure() { return failure; }

    private boolean acceptSequence(long sequence) {
        return armed && !closed && failure == null && sequence == nextSequence;
    }

    private boolean reject(String reason) {
        if (failure == null) failure = reason;
        return false;
    }
}
