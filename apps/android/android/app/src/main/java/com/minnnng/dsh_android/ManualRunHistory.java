package com.minnnng.dsh_android;

import java.util.ArrayList;
import java.util.Map;
import java.util.function.Function;

/** Keeps active and uncertain manual runs while bounded settled runs remain durable elsewhere. */
public final class ManualRunHistory {
    private ManualRunHistory() {}

    public static <T> void makeRoom(Map<String, T> entries, String latestId,
                                    Function<T, String> stage) {
        if (entries.size() < 32) return;
        for (var entry : new ArrayList<>(entries.entrySet())) {
            if (entry.getKey().equals(latestId)) continue;
            String value = stage.apply(entry.getValue());
            if ("terminal".equals(value) || "denied".equals(value)) {
                entries.remove(entry.getKey(), entry.getValue());
                if (entries.size() < 32) return;
            }
        }
        throw new IllegalStateException("Too many active or uncertain manual runs");
    }
}
