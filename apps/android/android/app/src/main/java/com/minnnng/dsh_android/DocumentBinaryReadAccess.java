package com.minnnng.dsh_android;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

/** Reads a bounded binary SAF document twice before its bytes may reach a model tool. */
public final class DocumentBinaryReadAccess {
    public interface Source {
        void check() throws IOException;
        InputStream open() throws IOException;
    }

    public static final int MAX_IMAGE_BYTES = 20 * 1024 * 1024;
    private static final int BUFFER_BYTES = 64 * 1024;

    public static final class Result {
        public final byte[] bytes;
        public final String sha256;

        private Result(byte[] bytes, String sha256) {
            this.bytes = bytes;
            this.sha256 = sha256;
        }
    }

    private DocumentBinaryReadAccess() {}

    /** Validate the JSON limit without narrowing or accepting a numeric string. */
    public static int limit(Object value) {
        if (value instanceof Integer number && number > 0 && number <= MAX_IMAGE_BYTES) return number;
        if (value instanceof Long number && number > 0 && number <= MAX_IMAGE_BYTES) return number.intValue();
        throw new IllegalArgumentException("图片读取上限必须是 1 至 20 MiB 的整数");
    }

    /** A changed, canceled, revoked or oversized source returns no binary result. */
    public static Result read(Source source, int maxBytes) throws IOException {
        limit(maxBytes);
        source.check();
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        MessageDigest first = sha256();
        long firstLength = copy(source, output, first, maxBytes);
        source.check();
        MessageDigest second = sha256();
        long secondLength = copy(source, null, second, maxBytes);
        source.check();
        String digest = hex(first.digest());
        if (firstLength != secondLength || !digest.equals(hex(second.digest()))) {
            throw new IOException("文件在读取期间发生变化，请重新读取图片");
        }
        return new Result(output.toByteArray(), digest);
    }

    private static long copy(Source source, ByteArrayOutputStream output,
                             MessageDigest digest, int maxBytes) throws IOException {
        source.check();
        InputStream opened = source.open();
        if (opened == null) throw new IOException("文件提供方暂不可用，请重试或重新授权");
        try (InputStream stream = opened) {
            byte[] buffer = new byte[BUFFER_BYTES];
            long length = 0;
            for (;;) {
                source.check();
                int count = stream.read(buffer);
                source.check();
                if (count < 0) break;
                if (count == 0) {
                    int single = stream.read();
                    source.check();
                    if (single < 0) break;
                    buffer[0] = (byte) single;
                    count = 1;
                }
                if (count > maxBytes - length) {
                    throw new IOException("图片超过当前模型或传输允许的大小，请选择较小的图片");
                }
                digest.update(buffer, 0, count);
                if (output != null) output.write(buffer, 0, count);
                length += count;
            }
            return length;
        }
    }

    private static MessageDigest sha256() {
        try { return MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException impossible) { throw new IllegalStateException(impossible); }
    }

    private static String hex(byte[] bytes) {
        StringBuilder text = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) {
            text.append(Character.forDigit((value >>> 4) & 15, 16));
            text.append(Character.forDigit(value & 15, 16));
        }
        return text.toString();
    }
}
