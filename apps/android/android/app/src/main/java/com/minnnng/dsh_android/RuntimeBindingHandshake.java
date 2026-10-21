package com.minnnng.dsh_android;

import java.util.ArrayList;
import java.util.List;

/** Main-thread, bounded binding recovery. It never stores or replays Agent operations. */
public final class RuntimeBindingHandshake implements AutoCloseable {
    public interface Completion { void finish(String code, String message); }
    public interface Scheduler {
        void schedule(Runnable task, long milliseconds);
        void cancel(Runnable task);
    }
    public interface Host {
        boolean foreground();
        boolean transitioning();
        boolean alive();
        /** Idempotent start of the Android service; the service owns its saved mode. */
        void ensureStarted();
        void bind();
        /** A read-only status request, after client registration on the same Binder. */
        Runnable probe(Completion completion);
    }

    private static final long TIMEOUT_MS = 12_000;
    private final Host host;
    private final Scheduler scheduler;
    private Entry current;
    private boolean closed;
    private long bindingGeneration;

    private final class Entry {
        final List<Completion> waiters = new ArrayList<>();
        final Runnable timeout = () -> finish(this, "binding-timeout",
                "连接本地服务超时，请重试；未重新执行任何 Agent 操作");
        boolean probing;
        boolean opening;
        Runnable cancelProbe;
    }

    public RuntimeBindingHandshake(Host host, Scheduler scheduler) {
        this.host = host;
        this.scheduler = scheduler;
    }

    public long newBinding() { return ++bindingGeneration; }
    public void invalidateBinding() { bindingGeneration++; }
    public boolean accepts(long generation) { return !closed && generation == bindingGeneration; }

    /** Opening is only the existing explicit initial "start" call, never a retry. */
    public void ensure(Completion completion, boolean opening) {
        if (closed) { completion.finish("closed", "界面已关闭"); return; }
        if (host.transitioning()) { completion.finish("busy", "运行时模式正在切换，请等待切换完成"); return; }
        if (!opening && !host.foreground()) {
            completion.finish("not-foreground", "请返回 App 后重新连接本地服务");
            return;
        }
        if (current != null) { current.waiters.add(completion); return; }
        Entry entry = new Entry();
        entry.opening = opening;
        entry.waiters.add(completion);
        current = entry;
        scheduler.schedule(entry.timeout, TIMEOUT_MS);
        try {
            // AUTO_CREATE can reconnect a bound-only service without onStartCommand.
            // AgentService's started guard makes this safe for a live runtime too.
            host.ensureStarted();
            if (host.alive()) probe(entry);
            else host.bind();
        } catch (Exception failure) {
            finish(entry, "binding-failed", "无法连接本地服务，请返回 App 后重试");
        }
    }

    public void connected() {
        Entry entry = current;
        if (entry == null) return;
        if (host.transitioning()) { transitionStarted(); return; }
        if (!host.alive()) { disconnected(); return; }
        probe(entry);
    }

    private void probe(Entry entry) {
        if (current != entry || entry.probing) return;
        entry.probing = true;
        try {
            Runnable cancel = host.probe((code, message) -> {
                if (current != entry) return;
                if (host.transitioning()) { transitionStarted(); return; }
                if (code == null && !host.alive()) { disconnected(); return; }
                finish(entry, code, message);
            });
            if (current == entry) entry.cancelProbe = cancel;
            else cancelSafely(cancel);
        } catch (Exception failure) {
            finish(entry, "disconnected", "本地服务连接已断开，请重试连接");
        }
    }

    public void disconnected() {
        if (current != null) finish(current, "disconnected", "本地服务连接已断开，未重放旧操作");
    }

    public void transitionStarted() {
        if (current != null) finish(current, "busy", "运行时模式正在切换，请等待切换完成");
    }

    public void backgrounded() {
        // The initial notification permission prompt may pause the Activity while
        // its already-requested startup is binding. Do not turn that into failure.
        if (current != null && !current.opening)
            finish(current, "not-foreground", "已离开 App，返回后可继续核对本地服务");
    }

    private void cancelSafely(Runnable cancel) {
        if (cancel == null) return;
        try { cancel.run(); }
        catch (RuntimeException ignored) { /* Settling other joined callers must continue. */ }
    }

    private void finish(Entry entry, String code, String message) {
        if (current != entry) return;
        current = null;
        scheduler.cancel(entry.timeout);
        cancelSafely(entry.cancelProbe);
        List<Completion> waiters = new ArrayList<>(entry.waiters);
        entry.waiters.clear();
        for (Completion waiter : waiters) {
            try { waiter.finish(code, message); }
            catch (RuntimeException ignored) { /* A detached UI result must not strand its peers. */ }
        }
    }

    @Override public void close() {
        if (closed) return;
        closed = true;
        invalidateBinding();
        if (current != null) finish(current, "closed", "界面已关闭，请重新打开 App 查看运行时状态");
    }
}
