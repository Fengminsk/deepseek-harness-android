package com.minnnng.dsh_android;

import java.util.Objects;
import java.util.concurrent.atomic.AtomicReference;

/** First terminal observation wins for one isolated guest request. */
public final class GuestTerminal {
    public enum Kind { COMPLETED, CANCELLED, TIMED_OUT, WORKER_DIED, ERROR }

    public record Outcome(Kind kind, String json, String detail) {
        public Outcome {
            Objects.requireNonNull(kind);
            if (kind == Kind.COMPLETED && json == null) {
                throw new IllegalArgumentException("Completed guest result needs JSON");
            }
            if (kind != Kind.COMPLETED && json != null) {
                throw new IllegalArgumentException("Failed guest result cannot carry JSON");
            }
        }
    }

    private final AtomicReference<Outcome> outcome = new AtomicReference<>();

    public boolean finish(Outcome next) {
        return outcome.compareAndSet(null, Objects.requireNonNull(next));
    }

    public Outcome outcome() { return outcome.get(); }
}
