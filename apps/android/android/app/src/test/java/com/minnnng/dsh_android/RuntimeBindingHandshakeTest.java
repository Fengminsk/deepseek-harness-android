package com.minnnng.dsh_android;

import java.util.ArrayList;
import java.util.List;

/** Runs the same coordinator used by MainActivity, with deterministic lifecycle/Binder seams. */
public final class RuntimeBindingHandshakeTest {
    private static int checks;
    private static void check(boolean value, String message) {
        checks++;
        if (!value) throw new AssertionError(message);
    }
    private static final class Result implements RuntimeBindingHandshake.Completion {
        int calls;
        String code;
        @Override public void finish(String next, String message) { calls++; code = next; }
        void success() { check(calls == 1 && code == null, "expected one confirmed binding"); }
        void error(String expected) { check(calls == 1 && expected.equals(code), "expected " + expected + ", got " + code); }
    }
    private static final class Clock implements RuntimeBindingHandshake.Scheduler {
        final List<Runnable> scheduled = new ArrayList<>();
        @Override public void schedule(Runnable task, long delay) {
            check(delay == 12_000, "handshake deadline must be bounded");
            scheduled.add(task);
        }
        @Override public void cancel(Runnable task) { scheduled.remove(task); }
        void timeout() { for (Runnable task : new ArrayList<>(scheduled)) task.run(); }
    }
    private static final class Host implements RuntimeBindingHandshake.Host {
        boolean foreground = true, transitioning, alive, started, nodeStarted;
        boolean failStart, failBind, failProbe, failCancel, synchronousProbe;
        int starts, binds, probes, cancels, nodeBoots;
        String mode = "active", phase = "starting";
        RuntimeBindingHandshake.Completion reply;
        @Override public boolean foreground() { return foreground; }
        @Override public boolean transitioning() { return transitioning; }
        @Override public boolean alive() { return alive; }
        @Override public void ensureStarted() {
            starts++;
            if (failStart) throw new IllegalStateException("start blocked");
            // This is AgentService's existing onStartCommand/started contract.
            if (started) return;
            started = true;
            if (mode.equals("maintenance")) phase = "maintenance";
            else { nodeStarted = true; nodeBoots++; }
        }
        @Override public void bind() {
            binds++;
            if (failBind) throw new IllegalStateException("bind denied");
        }
        @Override public Runnable probe(RuntimeBindingHandshake.Completion completion) {
            probes++;
            if (failProbe) throw new IllegalStateException("dead Binder");
            reply = completion;
            if (synchronousProbe) completion.finish(null, null);
            return () -> {
                cancels++;
                if (failCancel) throw new IllegalStateException("detached probe");
            };
        }
        void connected(RuntimeBindingHandshake handshake) { alive = true; handshake.connected(); }
        void status() { reply.finish(null, null); }
    }
    private static final class Fixture {
        final Host host = new Host();
        final Clock clock = new Clock();
        final RuntimeBindingHandshake handshake = new RuntimeBindingHandshake(host, clock);
        Result ensure() { Result result = new Result(); handshake.ensure(result, false); return result; }
    }

    public static void main(String[] args) {
        Fixture initial = new Fixture();
        Result first = initial.ensure();
        Result joined = initial.ensure();
        check(initial.host.starts == 1 && initial.host.binds == 1 && initial.host.probes == 0,
                "joined foreground calls must share one start/bind");
        check(first.calls == 0 && joined.calls == 0, "bind request is not confirmation");
        initial.host.connected(initial.handshake);
        initial.handshake.connected();
        check(initial.host.probes == 1 && first.calls == 0, "registration must precede one status probe");
        initial.host.status();
        first.success(); joined.success();
        check(initial.clock.scheduled.isEmpty() && initial.host.cancels == 1, "confirmed probe must release deadline/resources");
        initial.host.status();
        first.success();

        Fixture live = new Fixture();
        live.host.started = live.host.alive = live.host.nodeStarted = true;
        live.host.nodeBoots = 1;
        live.host.phase = "ready";
        Result liveResult = live.ensure();
        live.host.status(); liveResult.success();
        check(live.host.starts == 1 && live.host.binds == 0 && live.host.nodeBoots == 1,
                "live service gets idempotent start and probe, never another bind or Node boot");
        Result secondResume = live.ensure(); live.host.status(); secondResume.success();
        check(live.host.nodeBoots == 1 && live.host.binds == 0, "later foreground entry must retain running Node");

        Fixture boundOnly = new Fixture();
        boundOnly.host.alive = true;
        Result started = boundOnly.ensure();
        check(boundOnly.host.starts == 1 && boundOnly.host.nodeBoots == 1 && boundOnly.host.binds == 0,
                "AUTO_CREATE bound-only recreation still needs onStartCommand");
        boundOnly.host.status(); started.success();

        Fixture maintenance = new Fixture();
        maintenance.host.mode = "maintenance";
        Result maintained = maintenance.ensure();
        maintenance.host.connected(maintenance.handshake); maintenance.host.status(); maintained.success();
        check(maintenance.host.mode.equals("maintenance") && !maintenance.host.nodeStarted && maintenance.host.nodeBoots == 0,
                "saved maintenance must not switch to active or start Node");

        Fixture failed = new Fixture();
        failed.host.started = failed.host.alive = true;
        failed.host.phase = "failed";
        Result failedServiceBinding = failed.ensure(); failed.host.status(); failedServiceBinding.success();
        check(failed.host.phase.equals("failed") && failed.host.nodeBoots == 0,
                "binding confirmation is not runtime ready and must not restart a failed live service");

        Fixture transition = new Fixture();
        transition.host.transitioning = true;
        transition.ensure().error("busy");
        check(transition.host.starts == 0 && transition.host.binds == 0, "explicit recovery owns the service during transition");
        transition.host.transitioning = false;
        Result interrupted = transition.ensure();
        transition.host.connected(transition.handshake);
        RuntimeBindingHandshake.Completion old = transition.host.reply;
        transition.host.transitioning = true;
        transition.handshake.transitionStarted();
        interrupted.error("busy");
        old.finish(null, null); interrupted.error("busy");
        check(transition.host.cancels == 1, "transition must cancel the old read probe");

        Fixture background = new Fixture();
        background.host.foreground = false;
        background.ensure().error("not-foreground");
        check(background.host.starts == 0, "background retries cannot start a foreground service");
        background.host.foreground = true;
        Result left = background.ensure();
        background.host.foreground = false;
        background.handshake.backgrounded(); left.error("not-foreground");
        check(background.host.started, "leaving App does not stop the started service");

        Fixture permission = new Fixture();
        Result opening = new Result();
        permission.handshake.ensure(opening, true);
        permission.host.foreground = false;
        permission.handshake.backgrounded();
        check(opening.calls == 0, "initial notification permission prompt must not cancel startup");
        permission.host.connected(permission.handshake); permission.host.status(); opening.success();

        Fixture deadline = new Fixture();
        Result timedOut = deadline.ensure();
        deadline.clock.timeout(); timedOut.error("binding-timeout");
        Result retry = deadline.ensure();
        check(deadline.host.binds == 2, "a timed-out zombie bind must be retryable");
        deadline.host.connected(deadline.handshake); deadline.host.status(); retry.success();
        check(deadline.host.nodeBoots == 1, "retry cannot boot Node twice in same started service");

        Fixture late = new Fixture();
        late.host.alive = true;
        Result expired = late.ensure();
        RuntimeBindingHandshake.Completion lateReply = late.host.reply;
        late.clock.timeout(); expired.error("binding-timeout");
        Result current = late.ensure();
        lateReply.finish(null, null);
        check(current.calls == 0, "old status reply must not complete a new handshake");
        late.host.status(); current.success();
        long epoch = late.handshake.newBinding();
        check(late.handshake.accepts(epoch), "current binding epoch accepted");
        late.handshake.invalidateBinding();
        check(!late.handshake.accepts(epoch), "old Binder notifications rejected after invalidation");
        long nextEpoch = late.handshake.newBinding();
        check(!late.handshake.accepts(epoch) && late.handshake.accepts(nextEpoch), "new binding isolates queued replies");

        Fixture death = new Fixture();
        death.host.alive = true;
        Result dying = death.ensure();
        death.host.alive = false;
        death.host.status(); dying.error("disconnected");
        Result reconnect = death.ensure();
        death.handshake.disconnected(); reconnect.error("disconnected");
        check(death.host.binds == 1, "service loss is reported, not automatically replayed");

        for (int fault = 0; fault < 3; fault++) {
            Fixture broken = new Fixture();
            broken.host.failStart = fault == 0;
            broken.host.failBind = fault == 1;
            broken.host.failProbe = fault == 2;
            broken.host.alive = fault == 2;
            broken.ensure().error(fault == 2 ? "disconnected" : "binding-failed");
            check(broken.clock.scheduled.isEmpty(), "failed admission must clear deadline");
        }

        Fixture callbacks = new Fixture();
        callbacks.host.failCancel = true;
        callbacks.handshake.ensure((code, message) -> { throw new IllegalStateException("detached UI"); }, false);
        Result healthyWaiter = callbacks.ensure();
        callbacks.host.connected(callbacks.handshake); callbacks.host.status(); healthyWaiter.success();
        check(callbacks.clock.scheduled.isEmpty(), "detached callbacks must not strand joined callers");

        Fixture synchronous = new Fixture();
        synchronous.host.alive = synchronous.host.synchronousProbe = true;
        synchronous.ensure().success();
        check(synchronous.host.cancels == 1, "synchronous status completion still cancels its resource");

        Fixture closing = new Fixture();
        Result closed = closing.ensure();
        long closingEpoch = closing.handshake.newBinding();
        closing.handshake.close(); closed.error("closed");
        check(!closing.handshake.accepts(closingEpoch), "destroyed Activity cannot accept old events");
        closing.ensure().error("closed");
        check(closing.host.starts == 1, "closed owner cannot start another service");
        System.out.println("RuntimeBindingHandshake: " + checks + " checks passed");
    }
}
