package com.minnnng.dsh_android;

import java.io.IOException;
import java.io.InputStream;
import java.io.InterruptedIOException;
import java.math.BigDecimal;
import java.nio.ByteBuffer;
import java.nio.CharBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;

/** Reads bounded UTF-8 pages only while their persisted document grant remains valid. */
public final class DocumentReadAccess {
    public interface Source {
        boolean isGranted(String root);
        InputStream open(String root, String path) throws IOException;
    }

    public static final class Page {
        public final String text;
        public final long offset;
        public final long nextOffset;
        public final boolean truncated;

        private Page(String text, long offset, long nextOffset, boolean truncated) {
            this.text = text;
            this.offset = offset;
            this.nextOffset = nextOffset;
            this.truncated = truncated;
        }
    }

    private static final int PAGE_BYTES = 262144;
    private static final long MAX_OFFSET = 9007199254740991L;

    private DocumentReadAccess() {}

    /** Validate the raw JSON value before Android can narrow or coerce a continuation position. */
    public static long offset(Object value) {
        if (value == null) return 0;
        if (value instanceof Number number) {
            try {
                long result = new BigDecimal(number.toString()).longValueExact();
                if (result >= 0 && result <= MAX_OFFSET) return result;
            } catch (ArithmeticException | NumberFormatException invalid) {
                // JSON positions must survive the JavaScript/Android round trip exactly.
            }
        }
        throw new IllegalArgumentException("读取位置必须是非负安全整数，请从头读取");
    }

    /** A failed or revoked read returns no page. Already displayed pages remain caller-owned. */
    public static Page read(Source source, String root, String path, long offset) throws IOException {
        if (offset < 0 || offset > MAX_OFFSET) throw new IllegalArgumentException("读取位置超出支持范围，请从头读取");
        checkpoint(source, root);
        byte[] bytes = new byte[PAGE_BYTES + 4];
        int total = 0;
        try (InputStream stream = source.open(root, path)) {
            if (stream == null) throw new IOException("文件提供方暂不可用，请重试或重新授权");
            long remaining = offset;
            while (remaining > 0) {
                checkpoint(source, root);
                long skipped = stream.skip(remaining);
                checkpoint(source, root);
                if (skipped == 0) {
                    if (stream.read() < 0) throw new IOException("读取位置已超出文件末尾，文件可能已变化");
                    remaining--;
                } else {
                    remaining -= skipped;
                }
            }
            while (total < bytes.length) {
                checkpoint(source, root);
                int count = stream.read(bytes, total, bytes.length - total);
                checkpoint(source, root);
                if (count < 0) break;
                if (count == 0) {
                    int next = stream.read();
                    if (next < 0) break;
                    bytes[total++] = (byte) next;
                } else {
                    total += count;
                }
            }
        }
        checkpoint(source, root);
        int limit = Math.min(total, PAGE_BYTES);
        for (int index = 0; index < limit; index++) {
            if (bytes[index] == 0) throw new IOException("当前仅支持 UTF-8 文本文件");
        }
        ByteBuffer input = ByteBuffer.wrap(bytes, 0, limit);
        CharBuffer text = CharBuffer.allocate(PAGE_BYTES);
        var decoder = StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT);
        var outcome = decoder.decode(input, text, total <= PAGE_BYTES);
        if (outcome.isError()) {
            throw new IOException("文件不是有效 UTF-8 文本，或读取位置不在字符边界");
        }
        int consumed = input.position();
        text.flip();
        long nextOffset = offset + consumed;
        if (nextOffset > MAX_OFFSET) throw new IOException("读取位置超出支持范围，无法继续分页");
        return new Page(text.toString(), offset, nextOffset, total > consumed);
    }

    private static void checkpoint(Source source, String root) throws InterruptedIOException {
        if (Thread.currentThread().isInterrupted()) throw new InterruptedIOException("文件读取已停止");
        if (!source.isGranted(root)) throw new SecurityException("文件授权不存在或已撤销，请重新授权");
    }
}
