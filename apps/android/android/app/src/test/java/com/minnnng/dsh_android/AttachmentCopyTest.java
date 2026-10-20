package com.minnnng.dsh_android;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.util.Arrays;
import java.util.concurrent.atomic.AtomicInteger;

public final class AttachmentCopyTest {
    public static void main(String[] args) throws Exception {
        byte[] bytes = new byte[262145];
        for (int index = 0; index < bytes.length; index++) bytes[index] = (byte) index;
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        long copied = AttachmentCopy.copy(new ByteArrayInputStream(bytes), output, () -> false);
        if (copied != bytes.length || !Arrays.equals(bytes, output.toByteArray())) {
            throw new AssertionError("Selected binary bytes changed");
        }
        output.reset();
        if (AttachmentCopy.copy(new ByteArrayInputStream(new byte[0]), output, () -> false) != 0) {
            throw new AssertionError("Empty files must remain valid");
        }
        ByteArrayInputStream zeroRead = new ByteArrayInputStream(new byte[] {1, 2, 3}) {
            @Override public synchronized int read(byte[] buffer, int offset, int length) { return 0; }
        };
        AttachmentCopy.copy(zeroRead, output, () -> false);
        if (!Arrays.equals(output.toByteArray(), new byte[] {1, 2, 3})) {
            throw new AssertionError("Provider zero-read fallback changed bytes");
        }
        AtomicInteger chunks = new AtomicInteger();
        try {
            AttachmentCopy.copy(new ByteArrayInputStream(bytes), new ByteArrayOutputStream(),
                () -> chunks.incrementAndGet() > 1);
            throw new AssertionError("Cancellation ignored");
        } catch (IOException expected) {
            if (chunks.get() != 2) throw new AssertionError("Cancellation did not stop promptly");
        }
        try {
            AttachmentCopy.copy(new ByteArrayInputStream(bytes), new OutputStream() {
                @Override public void write(int value) throws IOException { throw new IOException("disk full"); }
            }, () -> false);
            throw new AssertionError("Write failure was hidden");
        } catch (IOException expected) {
            if (!"disk full".equals(expected.getMessage())) throw expected;
        }
        System.out.println("AttachmentCopy: binary/empty/zero-read/cancellation/write-failure passed");
    }
}
