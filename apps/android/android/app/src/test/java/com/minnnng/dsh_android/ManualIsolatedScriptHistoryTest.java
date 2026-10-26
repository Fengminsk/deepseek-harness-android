package com.minnnng.dsh_android;

import java.util.LinkedHashMap;
import java.util.Map;

/** Dependency-free host test, like the existing isolated execution tests. */
public final class ManualIsolatedScriptHistoryTest {
    private static void check(boolean value) { if (!value) throw new AssertionError(); }

    public static void main(String[] args) {
        Map<String, String> entries = new LinkedHashMap<>();
        String latest = null;
        for (int index = 0; index < 70; index++) {
            ManualRunHistory.makeRoom(entries, latest, value -> value);
            latest = "run-" + index;
            entries.put(latest, index % 2 == 0 ? "terminal" : "denied");
        }
        check(entries.size() <= 32 && "denied".equals(entries.get(latest)));
        entries.clear();
        for (int index = 0; index < 32; index++) {
            entries.put("run-" + index, switch (index % 3) {
                case 0 -> "awaiting-approval";
                case 1 -> "running";
                default -> "unconfirmed";
            });
        }
        try {
            ManualRunHistory.makeRoom(entries, null, value -> value);
            throw new AssertionError("Active or uncertain run was evicted");
        } catch (IllegalStateException expected) { /* Exhausted safely. */ }
        check(entries.size() == 32);
        System.out.println("ManualIsolatedScriptHistoryTest passed");
    }
}
