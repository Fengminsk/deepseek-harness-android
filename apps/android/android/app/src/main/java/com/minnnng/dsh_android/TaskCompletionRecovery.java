package com.minnnng.dsh_android;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.Map;

/** Pure snapshot validation before pending notices reach Android's main thread. */
public final class TaskCompletionRecovery {
    private static final String PREFIX = "pending:";

    public static final class Candidate {
        public final String sessionId;
        public final TaskCompletionReceipt receipt;

        private Candidate(String sessionId, TaskCompletionReceipt receipt) {
            this.sessionId = sessionId;
            this.receipt = receipt;
        }
    }

    public static final class Plan {
        public final List<Candidate> candidates;
        public final List<String> invalidKeys;

        private Plan(List<Candidate> candidates, List<String> invalidKeys) {
            this.candidates = Collections.unmodifiableList(candidates);
            this.invalidKeys = Collections.unmodifiableList(invalidKeys);
        }
    }

    private TaskCompletionRecovery() {}

    /** Never activates tasks or consults Session history; only committed matching receipts survive. */
    public static Plan inspect(Map<String, ?> snapshot) {
        List<Candidate> candidates = new ArrayList<>();
        List<String> invalid = new ArrayList<>();
        for (Map.Entry<String, ?> entry : snapshot.entrySet()) {
            String key = entry.getKey();
            if (!key.startsWith(PREFIX)) continue;
            String sessionId = key.substring(PREFIX.length());
            TaskCompletionReceipt receipt = entry.getValue() instanceof String
                    ? TaskCompletionReceipt.decode((String) entry.getValue()) : null;
            Object watermark = snapshot.get("end:" + sessionId);
            if (AndroidJava28.isBlank(sessionId) || sessionId.length() > 512 || receipt == null
                    || !(watermark instanceof Long)
                    || !receipt.matchesWatermark((Long) watermark)) {
                invalid.add(key);
            } else {
                candidates.add(new Candidate(sessionId, receipt));
            }
        }
        candidates.sort(Comparator.comparing(candidate -> candidate.sessionId));
        Collections.sort(invalid);
        return new Plan(candidates, invalid);
    }
}
