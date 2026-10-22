package com.minnnng.dsh_android;

import java.util.HashMap;
import java.util.Map;

/** Service-owned notification deduplication and per-Activity visible-session state. */
public final class TaskCompletionState {
    private final Map<String, Long> settled = new HashMap<>();
    private final Map<String, String> visible = new HashMap<>();
    private boolean closed;

    /** Claims one real completion once; the persisted watermark also fences process replacement. */
    public boolean claim(String sessionId, long endSeq, long persistedSeq) {
        if (sessionId == null || sessionId.isBlank() || sessionId.length() > 512 || endSeq < 0) {
            throw new IllegalArgumentException("Invalid task completion");
        }
        if (closed || endSeq <= Math.max(settled.getOrDefault(sessionId, -1L), persistedSeq)) return false;
        settled.put(sessionId, endSeq);
        return true;
    }

    /** A null session or a paused Activity never suppresses another view's completion. */
    public void viewing(String owner, String sessionId, boolean foreground) {
        if (closed) return;
        if (foreground && sessionId != null && !sessionId.isBlank()) visible.put(owner, sessionId);
        else visible.remove(owner);
    }

    public void disconnected(String owner) { visible.remove(owner); }
    public boolean shouldAlert(String sessionId) { return !closed && !visible.containsValue(sessionId); }
    public void close() { closed = true; visible.clear(); settled.clear(); }
}
