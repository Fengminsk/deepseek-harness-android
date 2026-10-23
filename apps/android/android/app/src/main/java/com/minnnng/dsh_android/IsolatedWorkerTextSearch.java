package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.CharBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/** Bounded literal search over text granted to a separate-UID worker. */
public final class IsolatedWorkerTextSearch {
    public static final int MAX_QUERY_BYTES = 4096;
    public static final int MAX_MATCHES = 256;
    public static final int MAX_PREVIEW_CHARS = 160;

    public record Spec(String query, int maxMatches) {
        public Spec {
            if (query == null || query.isEmpty() || maxMatches < 1 || maxMatches > MAX_MATCHES)
                throw new IllegalArgumentException("Invalid isolated-worker search");
            try {
                int bytes = StandardCharsets.UTF_8.newEncoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .encode(CharBuffer.wrap(query)).remaining();
                if (bytes > MAX_QUERY_BYTES) throw new IllegalArgumentException("Worker search query exceeds 4096 bytes");
            } catch (CharacterCodingException invalid) {
                throw new IllegalArgumentException("Worker search query is not valid UTF-8", invalid);
            }
        }
    }

    public record Hit(int line, int column, String preview) {}
    public record Result(List<Hit> hits, boolean truncated) {
        public Result { hits = List.copyOf(hits); }
    }

    private IsolatedWorkerTextSearch() {}

    /** Return one-based locations and line previews; a result cap reports truncation explicitly. */
    public static Result search(String source, Spec spec) throws IOException {
        if (source.getBytes(StandardCharsets.UTF_8).length > IsolatedWorkerInput.MAX_TEXT_BYTES)
            throw new IOException("Worker search input exceeds 64 KiB");
        List<Hit> hits = new ArrayList<>();
        int cursor = 0;
        int line = 1;
        int lineStart = 0;
        while (true) {
            if (Thread.currentThread().isInterrupted()) throw new IOException("Worker search interrupted");
            int found = source.indexOf(spec.query(), cursor);
            if (found < 0) return new Result(hits, false);
            if (hits.size() == spec.maxMatches()) return new Result(hits, true);
            while (lineStart <= found) {
                int newline = source.indexOf('\n', lineStart);
                if (newline < 0 || newline >= found) break;
                line++;
                lineStart = newline + 1;
            }
            int lineEnd = source.indexOf('\n', found);
            if (lineEnd < 0) lineEnd = source.length();
            int columnOffset = source.codePointCount(lineStart, found);
            int lineLength = source.codePointCount(lineStart, lineEnd);
            int queryLength = spec.query().codePointCount(0, spec.query().length());
            int width = Math.min(MAX_PREVIEW_CHARS, lineLength);
            int contextBefore = Math.max(0, (width - Math.min(queryLength, width)) / 2);
            int previewStartColumn = Math.min(Math.max(0, columnOffset - contextBefore), lineLength - width);
            int previewStart = source.offsetByCodePoints(lineStart, previewStartColumn);
            int previewEnd = source.offsetByCodePoints(previewStart, width);
            String preview = source.substring(previewStart, previewEnd);
            if (preview.endsWith("\r")) preview = preview.substring(0, preview.length() - 1);
            hits.add(new Hit(line, columnOffset + 1, preview));
            cursor = found + spec.query().length();
        }
    }
}
