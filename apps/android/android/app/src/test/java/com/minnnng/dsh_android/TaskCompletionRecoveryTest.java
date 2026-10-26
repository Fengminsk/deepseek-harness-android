package com.minnnng.dsh_android;

import java.util.HashMap;
import java.util.Map;

/** Host test for committed notification replay after an unexpected process death. */
public final class TaskCompletionRecoveryTest {
    public static void main(String[] args) {
        Map<String, Object> snapshot = new HashMap<>();
        snapshot.put("end:later", 17L);
        snapshot.put("pending:later", TaskCompletionReceipt.encode(17, "later finished"));
        snapshot.put("end:earlier", 0L);
        snapshot.put("pending:earlier", TaskCompletionReceipt.encode(0, null));
        snapshot.put("end:stale", 31L);
        snapshot.put("pending:stale", TaskCompletionReceipt.encode(30, "old turn"));
        snapshot.put("pending:missing-watermark", TaskCompletionReceipt.encode(1, "orphan"));
        snapshot.put("end:wrong-type", "4");
        snapshot.put("pending:wrong-type", TaskCompletionReceipt.encode(4, "not durable"));
        snapshot.put("end:bad-receipt", 8L);
        snapshot.put("pending:bad-receipt", "8\nline\nbreak");
        snapshot.put("end:non-string", 9L);
        snapshot.put("pending:non-string", 9L);
        snapshot.put("end:", 10L);
        snapshot.put("pending:", TaskCompletionReceipt.encode(10, "no session"));
        snapshot.put("end:oversized", 11L);
        snapshot.put("pending:" + "s".repeat(513), TaskCompletionReceipt.encode(11, "oversized"));
        snapshot.put("unrelated", "retained");

        TaskCompletionRecovery.Plan plan = TaskCompletionRecovery.inspect(snapshot);
        check(plan.candidates.size() == 2, "unexpected pending completion was accepted");
        check("earlier".equals(plan.candidates.get(0).sessionId)
                && plan.candidates.get(0).receipt.endSeq == 0
                && plan.candidates.get(0).receipt.preview == null,
                "a valid first-turn completion was lost");
        check("later".equals(plan.candidates.get(1).sessionId)
                && plan.candidates.get(1).receipt.endSeq == 17,
                "valid receipts were not recovered in deterministic order");
        check(plan.invalidKeys.size() == 7, "invalid pending receipts were not isolated");
        check(plan.invalidKeys.contains("pending:stale")
                && plan.invalidKeys.contains("pending:missing-watermark")
                && plan.invalidKeys.contains("pending:bad-receipt")
                && plan.invalidKeys.contains("pending:wrong-type")
                && plan.invalidKeys.contains("pending:non-string")
                && plan.invalidKeys.contains("pending:")
                && plan.invalidKeys.contains("pending:" + "s".repeat(513)),
                "an invalid receipt could be delivered or left in the recovery queue");
        check(snapshot.size() == 18 && "retained".equals(snapshot.get("unrelated")),
                "inspection mutated the persisted snapshot");
        System.out.println("Task completion recovery: valid-only deterministic replay plan passed");
    }

    private static void check(boolean result, String message) {
        if (!result) throw new AssertionError(message);
    }
}
