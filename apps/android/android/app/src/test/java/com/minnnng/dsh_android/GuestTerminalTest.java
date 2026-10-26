package com.minnnng.dsh_android;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicInteger;

/** Host-side terminal race checks; Binder and UID behavior still need device evidence. */
public final class GuestTerminalTest {
    public static void main(String[] args) {
        for (GuestTerminal.Kind first : GuestTerminal.Kind.values()) {
            for (GuestTerminal.Kind late : GuestTerminal.Kind.values()) {
                GuestTerminal gate = new GuestTerminal();
                GuestTerminal.Outcome initial = result(first);
                if (!gate.finish(initial) || gate.finish(result(late)) || gate.outcome() != initial) {
                    throw new AssertionError("Guest request produced a second outcome: " + first + ", " + late);
                }
            }
        }
        try {
            new GuestTerminal.Outcome(GuestTerminal.Kind.COMPLETED, null, null);
            throw new AssertionError("Missing completed JSON accepted");
        } catch (IllegalArgumentException expected) { /* Invalid result rejected. */ }
        try {
            new GuestTerminal.Outcome(GuestTerminal.Kind.CANCELLED, "{}", null);
            throw new AssertionError("Cancellation JSON accepted");
        } catch (IllegalArgumentException expected) { /* Partial output rejected. */ }
        for (int i = 0; i < 100; i++) race();
    }

    private static GuestTerminal.Outcome result(GuestTerminal.Kind kind) {
        return new GuestTerminal.Outcome(kind, kind == GuestTerminal.Kind.COMPLETED ? "{}" : null, null);
    }

    private static void race() {
        GuestTerminal gate = new GuestTerminal();
        CountDownLatch start = new CountDownLatch(1);
        CountDownLatch done = new CountDownLatch(4);
        AtomicInteger winners = new AtomicInteger();
        GuestTerminal.Kind[] kinds = {
            GuestTerminal.Kind.COMPLETED, GuestTerminal.Kind.CANCELLED,
            GuestTerminal.Kind.TIMED_OUT, GuestTerminal.Kind.WORKER_DIED,
        };
        for (GuestTerminal.Kind kind : kinds) {
            Thread contender = new Thread(() -> {
                try {
                    start.await();
                    if (gate.finish(result(kind))) winners.incrementAndGet();
                } catch (InterruptedException error) {
                    Thread.currentThread().interrupt();
                    throw new AssertionError(error);
                } finally { done.countDown(); }
            });
            contender.start();
        }
        start.countDown();
        try { done.await(); }
        catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new AssertionError(error);
        }
        if (winners.get() != 1 || gate.outcome() == null) throw new AssertionError("Guest race had no unique terminal result");
    }
}
