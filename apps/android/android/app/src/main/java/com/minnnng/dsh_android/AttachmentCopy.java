package com.minnnng.dsh_android;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.function.BooleanSupplier;

/** Copies selected document bytes without retaining the complete document in memory. */
public final class AttachmentCopy {
    private AttachmentCopy() {}

    /** Callers own both streams and remove their private incomplete destination on failure. */
    public static long copy(InputStream input, OutputStream output, BooleanSupplier cancelled) throws IOException {
        byte[] buffer = new byte[65536];
        long total = 0;
        while (true) {
            if (cancelled.getAsBoolean()) throw new IOException("附件导入已取消");
            int count = input.read(buffer);
            if (count < 0) break;
            if (count == 0) {
                int value = input.read();
                if (value < 0) break;
                output.write(value);
                total = Math.addExact(total, 1);
            } else {
                output.write(buffer, 0, count);
                total = Math.addExact(total, count);
            }
        }
        if (cancelled.getAsBoolean()) throw new IOException("附件导入已取消");
        output.flush();
        return total;
    }
}
