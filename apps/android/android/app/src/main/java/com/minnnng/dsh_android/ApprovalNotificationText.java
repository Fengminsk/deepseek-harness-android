package com.minnnng.dsh_android;

/** Presentation only. The original DSH request and action ledger retain all decision semantics. */
public final class ApprovalNotificationText {
    static final int DETAIL_LIMIT = 3500;
    static final int NOTICE_LIMIT = 400;
    static final String TRUNCATED = "\n\n内容已截断，点击通知在 App 中查看完整参数。";

    private ApprovalNotificationText() {}

    /**
     * @param arguments original tool/call arguments, including malformed JSON when present
     * @param command decoded android_shell command, or null when unavailable
     * @param cwd actual Android runtime process directory, never a guessed session directory
     */
    public static String format(String tool, String reason, String arguments, String command, String cwd) {
        StringBuilder body = new StringBuilder();
        if ("android_shell".equals(tool)) {
            body.append("工作目录：\n").append(blank(cwd) ? "未提供" : cwd).append("\n\n");
            if (command != null) {
                body.append("命令：\n").append(command.isEmpty() ? "（空字符串）" : command);
            } else {
                body.append("命令：未提供可读命令");
                appendArguments(body, arguments);
            }
        } else {
            appendArguments(body, arguments);
        }
        if (!blank(reason)) body.append("\n\n审批说明：\n").append(reason);
        return bounded(body.toString(), DETAIL_LIMIT);
    }

    /** Status never replaces the command being authorized, including after an unknown reply result. */
    public static String withNotice(String body, String notice) {
        if (blank(notice)) return body;
        return bounded(notice, NOTICE_LIMIT) + "\n\n" + body;
    }

    private static void appendArguments(StringBuilder body, String arguments) {
        if (body.length() > 0) body.append("\n\n");
        if (arguments == null) body.append("参数：未提供工具参数，请在 App 中查看请求详情。");
        else body.append("原始参数：").append('\n').append(arguments.isEmpty() ? "（空字符串）" : arguments);
    }

    private static boolean blank(String value) {
        return value == null || value.trim().isEmpty();
    }

    /** Bound UTF-16 length for the native notification carrier without splitting an emoji. */
    private static String bounded(String value, int limit) {
        if (value.length() <= limit) return value;
        int prefix = limit - TRUNCATED.length();
        if (prefix > 0 && Character.isHighSurrogate(value.charAt(prefix - 1))
                && Character.isLowSurrogate(value.charAt(prefix))) prefix--;
        return value.substring(0, prefix) + TRUNCATED;
    }
}
