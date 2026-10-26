package com.minnnng.dsh_android;

/** A committed completion waiting for a user notice, stored beside its end-sequence watermark. */
public final class TaskCompletionReceipt {
    public final long endSeq;
    public final String preview;

    private TaskCompletionReceipt(long endSeq, String preview) {
        this.endSeq = endSeq;
        this.preview = preview;
    }

    /** A later turn replaces this pending notice in the same session. */
    public boolean matchesWatermark(long committedEndSeq) { return committedEndSeq == endSeq; }

    public static String encode(long endSeq, String preview) {
        if (endSeq < 0 || preview != null && (preview.length() > 100 || preview.indexOf('\n') >= 0
                || preview.indexOf('\r') >= 0)) throw new IllegalArgumentException("Invalid completion receipt");
        return endSeq + "\n" + (preview == null ? "" : preview);
    }

    public static TaskCompletionReceipt decode(String value) {
        if (value == null || value.length() > 121) return null;
        int separator = value.indexOf('\n');
        if (separator < 1 || separator > 19 || value.indexOf('\n', separator + 1) >= 0) return null;
        String number = value.substring(0, separator);
        if (number.length() > 1 && number.charAt(0) == '0') return null;
        try {
            long sequence = Long.parseLong(number);
            String preview = value.substring(separator + 1);
            if (sequence < 0 || !Long.toString(sequence).equals(number)
                    || preview.length() > 100 || preview.indexOf('\r') >= 0) return null;
            return new TaskCompletionReceipt(sequence, preview.isEmpty() ? null : preview);
        } catch (NumberFormatException invalid) { return null; }
    }
}
