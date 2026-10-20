package com.minnnng.dsh_android;

/** Standalone JVM checks; no Android runtime, notification permission or credentials required. */
public final class ApprovalNotificationTextTest {
    public static void main(String[] args) {
        String command = "printf '%s\\n' 'hello world'\nls -la \"资料 📁\"";
        String shell = ApprovalNotificationText.format(
                "android_shell", "是否允许一次？", "{\"command\":\"original wire JSON\"}",
                command, "/data/user/0/com.minnnng.dsh_android/files/workspace");
        check(shell.contains("命令：\n" + command), "decoded multiline command was altered");
        check(shell.contains("工作目录：\n/data/user/0/com.minnnng.dsh_android/files/workspace"), "actual cwd missing");
        check(shell.contains("审批说明：\n是否允许一次？"), "reason missing");
        check(!shell.contains(ApprovalNotificationText.TRUNCATED), "small command falsely marked as truncated");

        String original = "{ \"path\": \"资料 📁\", \"nested\": [1, true, null] }\n";
        String other = ApprovalNotificationText.format("file_write", "保存文件", original, null, "/guessed");
        check(other.contains(original), "non-shell arguments were rewritten");
        check(!other.contains("工作目录"), "non-shell cwd was inferred");

        String malformed = "{\"command\":";
        String bad = ApprovalNotificationText.format("android_shell", "审核", malformed, null, null);
        check(bad.contains("命令：未提供可读命令"), "malformed command falsely shown as readable");
        check(bad.contains("原始参数：\n" + malformed), "malformed original arguments discarded");
        check(bad.contains("工作目录：\n未提供"), "missing cwd not identified");

        String missing = ApprovalNotificationText.format("android_shell", null, null, null, null);
        check(missing.contains("未提供工具参数"), "missing arguments hidden");
        check(!missing.contains("null"), "null leaked into presentation");
        check(ApprovalNotificationText.format("android_shell", null, "{}", "", "/workspace")
                .contains("命令：\n（空字符串）"), "empty and missing command conflated");
        check(ApprovalNotificationText.format("other", null, "", null, null)
                .contains("原始参数：\n（空字符串）"), "empty and missing arguments conflated");

        String huge = "📁".repeat(ApprovalNotificationText.DETAIL_LIMIT);
        String longShell = ApprovalNotificationText.format("android_shell", "reason", null, huge, "/workspace");
        check(longShell.endsWith(ApprovalNotificationText.TRUNCATED), "long details silently truncated");
        check(longShell.length() <= ApprovalNotificationText.DETAIL_LIMIT &&
                longShell.length() >= ApprovalNotificationText.DETAIL_LIMIT - 1,
                "detail budget violated");
        check(longShell.contains("工作目录：\n/workspace"), "long command displaced its execution directory");
        check(validSurrogates(longShell), "Unicode command truncated inside an emoji");

        String status = ApprovalNotificationText.withNotice(shell, "尚未确认处理结果，请在 App 中查看");
        check(status.startsWith("尚未确认处理结果"), "status notice missing");
        check(status.endsWith(shell), "status notice replaced command or cwd");
        check(ApprovalNotificationText.withNotice(shell, null).equals(shell), "empty status changed body");
        String hugeStatus = ApprovalNotificationText.withNotice(longShell, huge);
        check(hugeStatus.endsWith(longShell), "long status consumed tool details");
        check(hugeStatus.length() <=
                ApprovalNotificationText.NOTICE_LIMIT + ApprovalNotificationText.DETAIL_LIMIT + 2,
                "combined notification text exceeds bounded fields");
        check(validSurrogates(hugeStatus), "status truncation split an emoji");
        System.out.println("ApprovalNotificationText: shell, raw arguments, missing/malformed input, Unicode truncation and status detail checks passed");
    }

    private static boolean validSurrogates(String value) {
        for (int index = 0; index < value.length(); index++) {
            char c = value.charAt(index);
            if (Character.isHighSurrogate(c)) {
                if (++index >= value.length() || !Character.isLowSurrogate(value.charAt(index))) return false;
            } else if (Character.isLowSurrogate(c)) return false;
        }
        return true;
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
