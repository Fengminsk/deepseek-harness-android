package com.minnnng.dsh_android;

import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/** Bounded, strict UTF-8 literal search. A failed file never contributes partial matches. */
public final class DocumentTextSearch {
    private DocumentTextSearch() {}

    public interface Check {
        void check();
        default void beforeRead() { check(); }
        default void read(int bytes) {}
    }

    public static final class LimitException extends IOException {
        public LimitException() { super("file_bytes"); }
    }
    public static final class BinaryException extends IOException {
        public BinaryException() { super("binary"); }
    }
    public static final class Match {
        public final long lineNumber;
        public final String line;
        public final boolean previewTruncated;
        Match(long lineNumber, String line, boolean previewTruncated) {
            this.lineNumber = lineNumber;
            this.line = line;
            this.previewTruncated = previewTruncated;
        }
    }
    public static final class Result {
        public final List<Match> matches;
        public final long matchedLines;
        public final long bytesRead;
        Result(List<Match> matches, long matchedLines, long bytesRead) {
            this.matches = matches;
            this.matchedLines = matchedLines;
            this.bytesRead = bytesRead;
        }
    }
    /** The provider stream remains owned by the caller, including on cancellation. */
    public static Result scan(InputStream input, String query, boolean caseSensitive,
                              long byteLimit, int matchLimit, int previewChars, Check check) throws IOException {
        if (query.isEmpty() || query.length() > 256 || query.indexOf('\n') >= 0 || query.indexOf('\r') >= 0
                || query.indexOf('\0') >= 0) throw new IllegalArgumentException("Use 1–256 characters on one line");
        if (byteLimit < 1 || matchLimit < 1 || previewChars < 512) throw new IllegalArgumentException("Invalid search limits");
        CountingInput counted = new CountingInput(input, byteLimit, check);
        var reader = new InputStreamReader(counted, StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT));
        Matcher matcher = new Matcher(query, caseSensitive, previewChars);
        List<Match> matches = new ArrayList<>();
        char[] buffer = new char[4096];
        long number = 1, found = 0;
        boolean previousCr = false;
        int length;
        check.check();
        while ((length = reader.read(buffer)) != -1) {
            check.check();
            for (int i = 0; i < length; i++) {
                if ((i & 255) == 0) check.check();
                char c = buffer[i];
                if (c == '\0') throw new BinaryException();
                if (c == '\n' && previousCr) { previousCr = false; continue; }
                previousCr = c == '\r';
                if (c == '\r' || c == '\n') {
                    if (matcher.matched) {
                        found++;
                        if (matches.size() < matchLimit) matches.add(matcher.result(number));
                    }
                    number++;
                    matcher.reset();
                } else {
                    matcher.push(c);
                }
            }
        }
        if (matcher.matched) {
            found++;
            if (matches.size() < matchLimit) matches.add(matcher.result(number));
        }
        check.check();
        return new Result(matches, found, counted.count);
    }

    private static final class CountingInput extends FilterInputStream {
        private final long limit;
        private final Check check;
        long count;
        CountingInput(InputStream input, long limit, Check check) {
            super(input); this.limit = limit; this.check = check;
        }
        @Override public int read(byte[] bytes, int offset, int length) throws IOException {
            check.beforeRead();
            int read = in.read(bytes, offset, (int) Math.min(length, limit - count + 1));
            if (read > 0) { count += read; check.read(read); if (count > limit) throw new LimitException(); }
            check.check();
            return read;
        }
        @Override public int read() throws IOException {
            check.beforeRead();
            int value = in.read();
            if (value != -1) {
                count++;
                check.read(1);
                if (count > limit) throw new LimitException();
            }
            check.check();
            return value;
        }
    }

    /** KMP keeps matching linear even for a huge single line or repetitive query. */
    private static final class Matcher {
        final int[] query;
        final char[] before;
        final int[] prefix;
        final boolean sensitive;
        final int previewLimit;
        final StringBuilder preview = new StringBuilder();
        int matchedPrefix, ringAt, ringSize;
        char highSurrogate;
        long chars, previewStart;
        boolean matched;
        Matcher(String query, boolean sensitive, int previewLimit) {
            this.sensitive = sensitive;
            this.previewLimit = previewLimit;
            this.query = query.codePoints().map(this::fold).toArray();
            this.before = new char[query.length() + 120];
            this.prefix = new int[this.query.length];
            for (int i = 1, j = 0; i < this.query.length; i++) {
                while (j > 0 && this.query[i] != this.query[j]) j = prefix[j - 1];
                if (this.query[i] == this.query[j]) j++;
                prefix[i] = j;
            }
        }
        int fold(int c) { return sensitive ? c : Character.toLowerCase(Character.toUpperCase(c)); }
        void push(char c) {
            chars++;
            if (matched) {
                if (preview.length() < previewLimit) preview.append(c);
                return;
            }
            before[ringAt] = c;
            ringAt = (ringAt + 1) % before.length;
            ringSize = Math.min(before.length, ringSize + 1);
            if (Character.isHighSurrogate(c)) { highSurrogate = c; return; }
            int codePoint = highSurrogate == 0 ? c : Character.toCodePoint(highSurrogate, c);
            highSurrogate = 0;
            int normalized = fold(codePoint);
            while (matchedPrefix > 0 && normalized != query[matchedPrefix]) matchedPrefix = prefix[matchedPrefix - 1];
            if (normalized == query[matchedPrefix]) matchedPrefix++;
            if (matchedPrefix != query.length) return;
            matched = true;
            previewStart = chars - ringSize;
            int start = (ringAt - ringSize + before.length) % before.length;
            for (int i = 0; i < ringSize; i++) preview.append(before[(start + i) % before.length]);
        }
        Match result(long number) {
            String text = preview.toString();
            // Context windows never expose half of a supplementary code point.
            if (!text.isEmpty() && Character.isLowSurrogate(text.charAt(0))) text = text.substring(1);
            if (!text.isEmpty() && Character.isHighSurrogate(text.charAt(text.length() - 1))) text = text.substring(0, text.length() - 1);
            boolean cut = previewStart > 0 || chars > previewStart + preview.length();
            return new Match(number, (previewStart > 0 ? "…" : "") + text
                    + (chars > previewStart + preview.length() ? "…" : ""), cut);
        }
        void reset() {
            matchedPrefix = 0; ringAt = 0; ringSize = 0; chars = 0; previewStart = 0; highSurrogate = 0;
            matched = false; preview.setLength(0);
        }
    }
}
