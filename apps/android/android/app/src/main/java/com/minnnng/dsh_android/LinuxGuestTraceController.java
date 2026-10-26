package com.minnnng.dsh_android;

import java.io.IOException;
import java.io.InputStream;
import java.util.Objects;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * App-side observer for one already started, pinned native supervisor. This class never launches
 * PRoot, accepts model supplied process handles, or grants a Shell. The source must be created by
 * a trusted launcher from the supervisor's OS-owned stdout/stderr and process handle. Supervisor
 * exit zero attests to its own event-pipe EOF, tracer exit, DRAIN and empty descendant ledger.
 */
final class LinuxGuestTraceController {
    interface SupervisorSource {
        InputStream stdout();
        InputStream stderr();
        /** Return null if the process has not exited within the requested bound. */
        Integer awaitExit(long timeoutMillis) throws IOException, InterruptedException;
        /** Kill the process group and unblock both streams, even when called more than once. */
        void cancel();
    }

    private static final int MAX_TRACE_BYTES = 2 * 1024 * 1024;
    private static final int BUFFER_BYTES = 4096;
    private final LinuxGuestLaunchSession session;
    private final LinuxGuestRunJournal journal;
    private final String runId;
    private final SupervisorSource source;
    private final long deadlineMillis;
    private final AtomicBoolean cancelled = new AtomicBoolean();
    private final Object terminalLock = new Object();

    LinuxGuestTraceController(LinuxGuestLaunchSession session, LinuxGuestRunJournal journal,
                              String runId, SupervisorSource source, long deadlineMillis) {
        this.session = Objects.requireNonNull(session);
        this.journal = Objects.requireNonNull(journal);
        this.runId = Objects.requireNonNull(runId);
        this.source = Objects.requireNonNull(source);
        if (deadlineMillis < 1 || deadlineMillis > LinuxGuestLaunchSession.MAX_DEADLINE_MILLIS)
            throw new IllegalArgumentException("Guest supervisor deadline is outside policy");
        this.deadlineMillis = deadlineMillis;
        if (!session.matchesRunId(runId))
            throw new IllegalArgumentException("Guest supervisor run ID is not admitted");
    }

    /** A true result is the only path that may publish user-visible completion. */
    boolean observe() throws IOException {
        long endNanos = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(deadlineMillis);
        ExecutorService readers = Executors.newFixedThreadPool(2, daemonFactory());
        Future<Boolean> trace = readers.submit(this::readTrace);
        Future<Boolean> diagnostics = readers.submit(this::drainDiagnostics);
        IsolatedScriptReceipt.State failureState = IsolatedScriptReceipt.State.RETIRE_UNCONFIRMED;
        String detail = "Guest supervisor retirement was not confirmed";
        try {
            Integer exit;
            try {
                exit = source.awaitExit(remainingMillis(endNanos));
            } catch (IOException sourceFailure) {
                exit = -1;
            }
            if (exit == null) {
                failureState = IsolatedScriptReceipt.State.TIMED_OUT;
                detail = "Guest supervisor deadline exceeded";
            } else if (exit != 0) {
                failureState = IsolatedScriptReceipt.State.WORKER_DIED;
                detail = "Guest supervisor exited unsuccessfully";
            } else if (awaitReader(trace, endNanos) && awaitReader(diagnostics, endNanos)
                    && !cancelled.get() && session.traceEnded(true, true, 0)
                    && session.readyToPersistSuccess()) {
                synchronized (terminalLock) {
                    if (!cancelled.get() && session.readyToPersistSuccess()) {
                        // No guest text is copied into the receipt. The native supervisor discards
                        // guest stdout/stderr and the App creates this bounded terminal value.
                        return journal.complete(session, runId, "{\"exitCode\":0}");
                    }
                }
            }
            if (cancelled.get()) {
                failureState = IsolatedScriptReceipt.State.CANCELLED;
                detail = "Guest supervisor was cancelled";
            } else if (session.failure() != null) {
                detail = session.failure();
            }
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            failureState = IsolatedScriptReceipt.State.CANCELLED;
            detail = "Guest supervisor observation was interrupted";
        } catch (TimeoutException timeout) {
            failureState = IsolatedScriptReceipt.State.TIMED_OUT;
            detail = "Guest supervisor streams did not reach EOF before deadline";
        } catch (ExecutionException failed) {
            detail = "Guest supervisor stream failed before retirement";
        } finally {
            source.cancel();
            readers.shutdownNow();
        }
        // No failure receipt may replace a completed candidate. A candidate without its durable
        // publication marker is recovered as INTERRUPTED_UNCONFIRMED by the journal reader.
        if (!session.mayPublishSuccess()) {
            try {
                journal.fail(session, runId, failureState, detail);
            } catch (IOException journalFailure) {
                // A terminal may have been written before this call failed. The caller must read
                // the journal; it must never infer completion from supervisor exit alone.
                throw journalFailure;
            }
        }
        return false;
    }

    void cancel() {
        cancelled.set(true);
        // Revoke the live session immediately, including while a receipt candidate is syncing.
        // A decision that already passed markDurableSuccess is immutable by design.
        session.cancel();
        source.cancel();
    }

    private boolean readTrace() {
        byte[] buffer = new byte[BUFFER_BYTES];
        int total = 0;
        try {
            InputStream input = Objects.requireNonNull(source.stdout());
            while (!cancelled.get()) {
                int count = input.read(buffer);
                if (count == -1) return true;
                if (count == 0) continue;
                if (count > MAX_TRACE_BYTES - total || !session.acceptTrace(buffer, 0, count)) {
                    source.cancel();
                    return false;
                }
                total += count;
            }
        } catch (IOException | RuntimeException failed) {
            source.cancel();
        }
        return false;
    }

    private boolean drainDiagnostics() {
        byte[] buffer = new byte[BUFFER_BYTES];
        try {
            InputStream input = Objects.requireNonNull(source.stderr());
            while (!cancelled.get()) {
                if (input.read(buffer) == -1) return true;
            }
        } catch (IOException | RuntimeException failed) {
            source.cancel();
        }
        return false;
    }

    private static boolean awaitReader(Future<Boolean> future, long deadlineNanos)
            throws InterruptedException, ExecutionException, TimeoutException {
        return future.get(remainingMillis(deadlineNanos), TimeUnit.MILLISECONDS);
    }

    private static long remainingMillis(long deadlineNanos) throws TimeoutException {
        long remaining = deadlineNanos - System.nanoTime();
        if (remaining <= 0) throw new TimeoutException("Guest supervisor deadline elapsed");
        return Math.max(1, TimeUnit.NANOSECONDS.toMillis(remaining));
    }

    private static ThreadFactory daemonFactory() {
        return runnable -> {
            Thread thread = new Thread(runnable, "linux-guest-supervisor-stream");
            thread.setDaemon(true);
            return thread;
        };
    }
}
