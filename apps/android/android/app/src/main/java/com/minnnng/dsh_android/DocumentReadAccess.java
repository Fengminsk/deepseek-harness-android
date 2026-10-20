package com.minnnng.dsh_android;

import java.io.IOException;
import java.io.InputStream;
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
        public final int offset;
        public final int nextOffset;
        public final boolean truncated;

        private Page(String text, int offset, int nextOffset, boolean truncated) {
            this.text = text;
            this.offset = offset;
            this.nextOffset = nextOffset;
            this.truncated = truncated;
        }
    }

    private static final int PAGE_BYTES = 262144;

    private DocumentReadAccess() {}

    /** A failed or revoked read returns no page. Already displayed pages remain caller-owned. */
    public static Page read(Source source, String root, String path, int offset) throws IOException {
        if (offset < 0) throw new IllegalArgumentException("读取位置不能小于零");
        requireGrant(source, root);
        byte[] bytes = new byte[PAGE_BYTES + 4];
        int total = 0;
        try (InputStream stream = source.open(root, path)) {
            if (stream == null) throw new IOException("文件提供方暂不可用，请重试或重新授权");
            long remaining = offset;
            while (remaining > 0) {
                long skipped = stream.skip(remaining);
                if (skipped == 0) {
                    if (stream.read() < 0) throw new IOException("读取位置已超出文件末尾，文件可能已变化");
                    remaining--;
                } else {
                    remaining -= skipped;
                }
            }
            while (total < bytes.length) {
                int count = stream.read(bytes, total, bytes.length - total);
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
        requireGrant(source, root);
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
        return new Page(text.toString(), offset, Math.addExact(offset, consumed), total > consumed);
    }

    private static void requireGrant(Source source, String root) {
        if (!source.isGranted(root)) throw new SecurityException("文件授权不存在或已撤销，请重新授权");
    }
}
