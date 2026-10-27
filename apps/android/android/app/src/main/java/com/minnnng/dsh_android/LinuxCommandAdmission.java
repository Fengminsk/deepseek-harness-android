package com.minnnng.dsh_android;

import java.util.HashMap;
import java.util.HashSet;
import java.util.ArrayDeque;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/** App-owned lifecycle gate for internal isolated command requests. */
final class LinuxCommandAdmission implements AutoCloseable {
    static final class CancelledBeforeAdmission extends IllegalStateException {
        CancelledBeforeAdmission() { super("Linux command cancelled before admission"); }
    }
    static final int MAX_ACTIVE = 2;
    private static final int MAX_PENDING_CANCELLATIONS = 256;
    private static final int MAX_SETTLED_IDS = 512;

    static final class Ticket implements AutoCloseable {
        private final LinuxCommandAdmission owner;
        final String id;
        private final AtomicBoolean cancelled = new AtomicBoolean();
        private final CountDownLatch settled = new CountDownLatch(1);
        private boolean retirementConfirmed;
        private boolean released;

        private Ticket(LinuxCommandAdmission owner, String id) {
            this.owner = owner;
            this.id = id;
        }

        boolean isCancelled() { return cancelled.get(); }

        /** Called only after an authenticated guest retirement receipt. */
        void close(boolean confirmed) { owner.release(this, confirmed); }
        @Override public void close() { owner.release(this, false); }
    }

    record CancelOutcome(boolean requested, boolean settled) { }

    private final Map<String, Ticket> active = new HashMap<>();
    // Execute and cancel arrive on separate Binder dispatch workers. A cancel
    // can win the race before execute reaches admit; keep that ID fail-closed.
    private final Set<String> cancelledBeforeAdmission = new HashSet<>();
    // A terminal App call is still replay-blocked when child retirement was
    // unconfirmed; cancellation must not report that case as settled.
    private final Map<String, Boolean> settledIds = new HashMap<>();
    private final ArrayDeque<String> settledOrder = new ArrayDeque<>();
    private boolean closed;

    synchronized Ticket admit(String id) {
        if (closed) throw new IllegalStateException("Linux command owner is closed");
        if (!validId(id)) throw new IllegalArgumentException("Invalid Linux command run ID");
        if (cancelledBeforeAdmission.remove(id)) {
            rememberSettled(id, true);
            throw new CancelledBeforeAdmission();
        }
        if (settledIds.containsKey(id)) throw new IllegalArgumentException("Linux command run ID already settled");
        if (active.containsKey(id)) throw new IllegalArgumentException("Linux command run already exists");
        if (active.size() >= MAX_ACTIVE) throw new IllegalStateException("Linux command capacity reached");
        Ticket ticket = new Ticket(this, id);
        active.put(id, ticket);
        return ticket;
    }

    synchronized boolean cancel(String id) {
        Ticket ticket = active.get(id);
        if (ticket == null) return false;
        ticket.cancelled.set(true);
        return true;
    }

    CancelOutcome cancelAndWait(String id, long deadlineMillis) throws InterruptedException {
        if (!validId(id)) throw new IllegalArgumentException("Invalid Linux command run ID");
        if (deadlineMillis < 1 || deadlineMillis > 5_000) {
            throw new IllegalArgumentException("Invalid Linux command cancellation deadline");
        }
        Ticket ticket;
        synchronized (this) {
            ticket = active.get(id);
            if (ticket == null) {
                if (settledIds.containsKey(id)) return new CancelOutcome(false, settledIds.get(id));
                if (closed) return new CancelOutcome(false, false);
                cancelledBeforeAdmission.add(id);
                if (cancelledBeforeAdmission.size() > MAX_PENDING_CANCELLATIONS) {
                    // Capacity pressure must never turn an earlier cancel into
                    // an executable request. Retire this owner instead.
                    closed = true;
                    active.values().forEach(activeTicket -> activeTicket.cancelled.set(true));
                    throw new IllegalStateException("Linux command cancellation capacity reached");
                }
                return new CancelOutcome(true, true);
            }
            ticket.cancelled.set(true);
        }
        return new CancelOutcome(true, ticket.settled.await(deadlineMillis, TimeUnit.MILLISECONDS)
            && ticket.retirementConfirmed);
    }

    private synchronized void release(Ticket ticket, boolean confirmed) {
        if (ticket.released) return;
        ticket.released = true;
        ticket.retirementConfirmed = confirmed;
        active.remove(ticket.id, ticket);
        rememberSettled(ticket.id, confirmed);
        if (!confirmed) {
            // A missing retirement receipt can mean a child is still alive.
            // Do not admit another command under this owner after uncertainty.
            closed = true;
            active.values().forEach(other -> other.cancelled.set(true));
        }
        ticket.settled.countDown();
    }

    private void rememberSettled(String id, boolean confirmed) {
        if (settledIds.putIfAbsent(id, confirmed) != null) return;
        settledOrder.addLast(id);
        if (settledOrder.size() > MAX_SETTLED_IDS) settledIds.remove(settledOrder.removeFirst());
    }

    @Override public synchronized void close() {
        closed = true;
        active.values().forEach(ticket -> ticket.cancelled.set(true));
    }

    private static boolean validId(String id) {
        if (id == null) return false;
        try { return UUID.fromString(id).toString().equals(id); }
        catch (IllegalArgumentException ignored) { return false; }
    }
}
