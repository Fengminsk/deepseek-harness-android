package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.CharBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;

/** One bounded, literal edit over text granted by the App; no filesystem paths cross to the worker. */
public final class IsolatedWorkerTextEdit {
    public static final int MAX_ARGUMENT_BYTES = 4096;
    public static final int MAX_REPLACEMENTS = 4096;

    public record Spec(String needle, String replacement, int maxReplacements) {
        public Spec {
            if (needle == null || needle.isEmpty() || replacement == null
                    || utf8Bytes(needle) > MAX_ARGUMENT_BYTES
                    || utf8Bytes(replacement) > MAX_ARGUMENT_BYTES
                    || maxReplacements < 1 || maxReplacements > MAX_REPLACEMENTS)
                throw new IllegalArgumentException("Invalid isolated-worker text edit");
        }
    }

    private IsolatedWorkerTextEdit() {}

    private static int utf8Bytes(String value) {
        try {
            return StandardCharsets.UTF_8.newEncoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .encode(CharBuffer.wrap(value)).remaining();
        } catch (CharacterCodingException invalid) {
            throw new IllegalArgumentException("Worker edit argument is not valid UTF-8", invalid);
        }
    }

    /** Refuse a partial edit when the occurrence or output limit is exceeded. */
    public static String replace(String source, Spec spec) throws IOException {
        if (source.getBytes(StandardCharsets.UTF_8).length > IsolatedWorkerInput.MAX_TEXT_BYTES)
            throw new IOException("Worker edit input exceeds 64 KiB");
        StringBuilder output = new StringBuilder(source.length());
        int cursor = 0;
        int count = 0;
        while (true) {
            if (Thread.currentThread().isInterrupted()) throw new IOException("Worker edit interrupted");
            int found = source.indexOf(spec.needle(), cursor);
            if (found < 0) {
                output.append(source, cursor, source.length());
                break;
            }
            if (++count > spec.maxReplacements()) throw new IOException("Worker edit exceeds replacement limit");
            output.append(source, cursor, found).append(spec.replacement());
            if (output.length() > IsolatedWorkerInput.MAX_TEXT_BYTES)
                throw new IOException("Worker edit output exceeds 64 KiB");
            cursor = found + spec.needle().length();
        }
        String result = output.toString();
        if (result.getBytes(StandardCharsets.UTF_8).length > IsolatedWorkerInput.MAX_TEXT_BYTES)
            throw new IOException("Worker edit output exceeds 64 KiB");
        return result;
    }
}
