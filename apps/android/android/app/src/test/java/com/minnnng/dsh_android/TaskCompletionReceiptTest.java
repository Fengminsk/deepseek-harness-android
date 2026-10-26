package com.minnnng.dsh_android;

/** Host test for the crash boundary between durable completion and system notification delivery. */
public final class TaskCompletionReceiptTest {
    public static void main(String[] args) {
        String stored = TaskCompletionReceipt.encode(42, "任务已完成。");
        TaskCompletionReceipt recovered = TaskCompletionReceipt.decode(stored);
        check(recovered != null && recovered.endSeq == 42 && "任务已完成。".equals(recovered.preview),
                "committed pending notice was not recoverable after process death");
        check(recovered.matchesWatermark(42) && !recovered.matchesWatermark(43),
                "older pending notice could replay after a later committed turn");
        TaskCompletionState replacement = new TaskCompletionState();
        check(replacement.claim("session", recovered.endSeq, -1), "pending notice was rejected by a fresh owner");
        check(!replacement.claim("session", recovered.endSeq, recovered.endSeq),
                "committed completion could be emitted twice as a live event");

        TaskCompletionReceipt noPreview = TaskCompletionReceipt.decode(TaskCompletionReceipt.encode(0, null));
        check(noPreview != null && noPreview.endSeq == 0 && noPreview.preview == null,
                "empty preview changed the completion receipt");
        for (String invalid : new String[] {null, "", "-1\n", "+1\n", "01\n", "1", "1\nx\ny",
                "9223372036854775808\n", "2\r\n", "2\nline\rbreak"}) {
            check(TaskCompletionReceipt.decode(invalid) == null, "invalid receipt was replayed: " + invalid);
        }
        boolean rejected = false;
        try { TaskCompletionReceipt.encode(1, "a\nb"); }
        catch (IllegalArgumentException expected) { rejected = true; }
        check(rejected, "multiline notification preview entered durable receipt");
        System.out.println("Task completion receipt: crash recovery and invalid/stale input passed");
    }

    private static void check(boolean result, String message) {
        if (!result) throw new AssertionError(message);
    }
}
