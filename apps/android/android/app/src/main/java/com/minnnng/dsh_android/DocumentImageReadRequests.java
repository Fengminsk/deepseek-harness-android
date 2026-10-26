package com.minnnng.dsh_android;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.function.LongSupplier;

/**
 * Bounds in-flight SAF image reads before any provider stream is opened. Cancellation is also
 * recorded briefly when it races ahead of admission, so a delayed read cannot begin afterward.
 * The caller owns the actual provider stream and must always call finish in a finally block.
 */
final class DocumentImageReadRequests {
    static final int MAX_ACTIVE = 2;
    private static final int MAX_CANCELLED = 128;
    private static final long CANCELLED_TTL_MILLIS = 60_000L;

    private record Active(String root, Runnable cancel) {}

    private final LongSupplier elapsedMillis;
    private final Map<String, Active> active = new HashMap<>();
    private final LinkedHashMap<String, Long> cancelled = new LinkedHashMap<>();
    private boolean closed;

    DocumentImageReadRequests(LongSupplier elapsedMillis) {
        this.elapsedMillis = Objects.requireNonNull(elapsedMillis);
    }

    synchronized void begin(String id, String root, Runnable cancel) {
        Objects.requireNonNull(id);
        Objects.requireNonNull(root);
        Objects.requireNonNull(cancel);
        prune();
        if (closed) throw new IllegalStateException("图片阅读器已停止");
        if (cancelled.remove(id) != null) throw new IllegalStateException("图片读取已取消");
        if (active.containsKey(id)) throw new IllegalStateException("图片读取请求正在执行");
        if (active.size() >= MAX_ACTIVE) {
            throw new IllegalStateException("图片读取任务已满，请等待当前读取完成");
        }
        active.put(id, new Active(root, cancel));
    }

    synchronized void finish(String id) {
        active.remove(id);
    }

    void cancel(String id) {
        Runnable action;
        synchronized (this) {
            prune();
            Active running = active.get(id);
            if (!closed && running == null) cancelled.put(id, elapsedMillis.getAsLong());
            prune();
            action = running == null ? null : running.cancel();
        }
        if (action != null) action.run();
    }

    void revokeRoot(String root) {
        List<Runnable> actions = new ArrayList<>();
        synchronized (this) {
            for (Active request : active.values()) {
                if (request.root().equals(root)) actions.add(request.cancel());
            }
        }
        actions.forEach(Runnable::run);
    }

    void close() {
        List<Runnable> actions = new ArrayList<>();
        synchronized (this) {
            if (closed) return;
            closed = true;
            cancelled.clear();
            for (Active request : active.values()) actions.add(request.cancel());
            active.clear();
        }
        actions.forEach(Runnable::run);
    }

    synchronized int activeCount() { return active.size(); }

    private void prune() {
        long now = elapsedMillis.getAsLong();
        Iterator<Map.Entry<String, Long>> cursor = cancelled.entrySet().iterator();
        while (cursor.hasNext()) {
            Map.Entry<String, Long> entry = cursor.next();
            if (now - entry.getValue() > CANCELLED_TTL_MILLIS) cursor.remove();
        }
        while (cancelled.size() > MAX_CANCELLED) {
            cancelled.remove(cancelled.keySet().iterator().next());
        }
    }
}
