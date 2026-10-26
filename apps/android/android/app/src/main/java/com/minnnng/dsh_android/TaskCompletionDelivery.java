package com.minnnng.dsh_android;

import java.util.ArrayList;
import java.util.List;

/** Main-thread ownership of completion notices while their durable watermarks are being written. */
public final class TaskCompletionDelivery {
    public static final class Ticket {
        public final String sessionId;
        public final long endSeq;
        public final String preview;
        public final boolean eligible;
        private volatile boolean finished;
        private volatile boolean persisted;

        private Ticket(String sessionId, long endSeq, String preview, boolean eligible) {
            this.sessionId = sessionId;
            this.endSeq = endSeq;
            this.preview = preview;
            this.eligible = eligible;
        }

        /** Called by the single persistence writer before posting delivery to the main thread. */
        public void finish(boolean persisted) {
            this.persisted = persisted;
            this.finished = true;
        }

        public boolean isFinished() { return finished; }
        public boolean isPersisted() { return finished && persisted; }
    }

    private final List<Ticket> pending = new ArrayList<>();

    public Ticket add(String sessionId, long endSeq, String preview, boolean eligible) {
        Ticket ticket = new Ticket(sessionId, endSeq, preview, eligible);
        pending.add(ticket);
        return ticket;
    }

    public void delivered(Ticket ticket) { pending.remove(ticket); }

    /** A required notice remains recoverable until Android accepts the post. */
    public static boolean shouldAcknowledge(boolean persisted, boolean required, boolean posted) {
        return persisted && (!required || posted);
    }

    /** Snapshot only committed tickets; an unfinished write must never produce an unfenced notice. */
    public List<Ticket> persistedAtShutdown() {
        List<Ticket> result = new ArrayList<>();
        for (Ticket ticket : pending) if (ticket.isPersisted()) result.add(ticket);
        return result;
    }

    public int unfinishedCount() {
        int count = 0;
        for (Ticket ticket : pending) if (!ticket.isFinished()) count++;
        return count;
    }

    public void clear() { pending.clear(); }
}
