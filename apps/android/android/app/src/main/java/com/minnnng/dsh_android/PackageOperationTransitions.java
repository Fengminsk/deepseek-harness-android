package com.minnnng.dsh_android;

import java.util.function.Consumer;
import java.util.regex.Pattern;
import java.util.UUID;

/** Main-thread transition admission. A Node acknowledgment is required before saving mode or stopping it. */
public final class PackageOperationTransitions implements AutoCloseable {
    public enum Availability { RUNNING, STOPPED, UNKNOWN }
    public record Reply(boolean accepted, String epoch, String state, String code, String message) {}
    public interface Rpc {
        void request(String method, String token, String epoch, Consumer<Reply> completion);
    }
    public interface Scheduler {
        void schedule(Runnable callback, long milliseconds);
        void cancel(Runnable callback);
    }

    private static final long RESERVATION_MS = 15_000;
    private static final Pattern TOKEN = Pattern.compile(
            "[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}");
    private final Rpc rpc;
    private final Scheduler scheduler;
    private Entry entry;
    private boolean closed;

    private final class Entry {
        final String token;
        final String nodeToken = UUID.randomUUID().toString();
        final Object owner;
        final boolean node;
        final Runnable expiry;
        String epoch;
        String state = "reserving";
        Consumer<Reply> completion;

        Entry(String token, Object owner, boolean node, Consumer<Reply> completion) {
            this.token = token;
            this.owner = owner;
            this.node = node;
            this.completion = completion;
            this.expiry = () -> end(this, denied("runtime/transition-expired",
                    "服务切换预留已超时，旧服务未被主动停止；请重新读取状态"));
        }
    }

    public PackageOperationTransitions(Rpc rpc, Scheduler scheduler) {
        this.rpc = rpc;
        this.scheduler = scheduler;
    }

    public boolean busy() { return entry != null; }

    public static Reply denied(String code, String message) {
        return new Reply(false, null, null, code, message);
    }

    public void reserve(String token, Object owner, Availability availability, Consumer<Reply> completion) {
        if (closed || !TOKEN.matcher(token).matches() || entry != null) {
            completion.accept(denied("runtime/busy", "恢复操作或服务切换仍在执行，请等待操作结果"));
            return;
        }
        if (availability == Availability.UNKNOWN) {
            completion.accept(denied("runtime/package-state-unknown", "无法确认插件管理操作状态，未切换服务；请等待运行时就绪"));
            return;
        }
        Entry pending = new Entry(token, owner, availability == Availability.RUNNING, completion);
        entry = pending;
        scheduler.schedule(pending.expiry, RESERVATION_MS);
        if (!pending.node) {
            pending.state = "reserved";
            deliver(pending, new Reply(true, null, "reserved", null, null));
            return;
        }
        rpc.request("reserve", pending.nodeToken, null, reply -> {
            if (entry != pending || !pending.state.equals("reserving")) {
                // A delayed successful acknowledgment must not retain a reservation after cancellation.
                if (reply.accepted()) releaseNode(pending, reply.epoch());
                return;
            }
            if (!reply.accepted()) { end(pending, reply); return; }
            if (reply.epoch() == null || reply.epoch().isBlank() || !"reserved".equals(reply.state())) {
                end(pending, denied("runtime/transition-unconfirmed", "服务切换预留结果未确认，旧服务保持运行"));
                return;
            }
            pending.epoch = reply.epoch();
            pending.state = "reserved";
            deliver(pending, reply);
        });
    }

    public void commit(String token, Object owner, Consumer<Reply> completion) {
        Entry pending = entry;
        if (closed || pending == null || !pending.token.equals(token) || !pending.owner.equals(owner)
                || !pending.state.equals("reserved")) {
            completion.accept(denied("runtime/transition-expired", "服务切换预留已失效，旧服务未被主动停止；请重新读取状态"));
            return;
        }
        pending.completion = completion;
        pending.state = "committing";
        if (!pending.node) { committed(pending, new Reply(true, null, "committed", null, null)); return; }
        rpc.request("commit", pending.nodeToken, pending.epoch, reply -> {
            if (entry != pending || !pending.state.equals("committing")) {
                if (reply.accepted()) releaseNode(pending, reply.epoch());
                return;
            }
            if (!reply.accepted()) { end(pending, reply); return; }
            if (!pending.epoch.equals(reply.epoch()) || !"committed".equals(reply.state())) {
                end(pending, denied("runtime/transition-unconfirmed", "无法确认当前运行时的切换预留，旧服务未被主动停止"));
                return;
            }
            committed(pending, reply);
        });
    }

    private void committed(Entry pending, Reply reply) {
        scheduler.cancel(pending.expiry);
        pending.state = "stopping";
        deliver(pending, reply);
    }

    public void release(String token, Object owner) {
        if (entry != null && entry.token.equals(token) && entry.owner.equals(owner) && !entry.state.equals("stopping")) {
            end(entry, denied("runtime/transition-released", "服务切换已取消，旧服务未被主动停止"));
        }
    }

    public void disconnect(Object owner) {
        if (entry != null && entry.owner.equals(owner) && !entry.state.equals("stopping")) {
            end(entry, denied("runtime/disconnected", "切换连接已断开，旧服务未被主动停止"));
        }
    }

    public void unavailable() {
        if (entry != null && !entry.state.equals("stopping")) {
            end(entry, denied("runtime/unavailable", "运行时连接已中断，服务切换结果未确认"));
        }
    }

    private void end(Entry pending, Reply reply) {
        if (entry != pending) return;
        entry = null;
        scheduler.cancel(pending.expiry);
        if (pending.node) releaseNode(pending, pending.epoch);
        deliver(pending, reply);
    }

    private void releaseNode(Entry pending, String epoch) {
        rpc.request("release", pending.nodeToken, epoch, ignored -> {
            // A missing release ACK cannot authorize another transition: its reserve must query Node again.
        });
    }

    private void deliver(Entry pending, Reply reply) {
        Consumer<Reply> completion = pending.completion;
        pending.completion = null;
        if (completion != null) completion.accept(reply);
    }

    @Override public void close() {
        closed = true;
        // Once stop is authorized, only process exit may reopen package admission.
        if (entry != null && entry.state.equals("stopping")) {
            scheduler.cancel(entry.expiry);
            entry = null;
            return;
        }
        unavailable();
    }
}
