package com.minnnng.dsh_android;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

/** Bounded bytes admitted to a separate-UID worker through an explicit descriptor. */
public final class IsolatedWorkerInput {
    public static final int MAX_BYTES = 256 * 1024;
    public static final int MAX_TEXT_BYTES = 64 * 1024;

    public record Digest(int bytes, String sha256) {}

    private IsolatedWorkerInput() {}

    public static Digest digest(InputStream source) throws IOException {
        final MessageDigest hash;
        try { hash = MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException exception) { throw new IllegalStateException(exception); }
        byte[] buffer = new byte[8192];
        int count = 0;
        while (true) {
            if (Thread.currentThread().isInterrupted()) throw new IOException("Worker input interrupted");
            int read = source.read(buffer);
            if (read < 0) break;
            if (read == 0) continue;
            if (read > MAX_BYTES - count) throw new IOException("Worker input exceeds 256 KiB");
            hash.update(buffer, 0, read);
            count += read;
        }
        StringBuilder hex = new StringBuilder(64);
        for (byte value : hash.digest()) hex.append(Character.forDigit((value >>> 4) & 15, 16))
            .append(Character.forDigit(value & 15, 16));
        return new Digest(count, hex.toString());
    }

    /** Read one App-granted descriptor without replacing malformed UTF-8 or truncating content. */
    public static String readUtf8(InputStream source) throws IOException {
        if (Thread.currentThread().isInterrupted()) throw new IOException("Worker input interrupted");
        ByteArrayOutputStream bounded = new ByteArrayOutputStream();
        byte[] chunk = new byte[8192];
        while (bounded.size() <= MAX_TEXT_BYTES) {
            int remaining = MAX_TEXT_BYTES + 1 - bounded.size();
            int count = source.read(chunk, 0, Math.min(chunk.length, remaining));
            if (count < 0) break;
            if (count == 0) {
                int one = source.read();
                if (one < 0) break;
                bounded.write(one);
            } else {
                bounded.write(chunk, 0, count);
            }
            if (Thread.currentThread().isInterrupted()) throw new IOException("Worker input interrupted");
        }
        byte[] content = bounded.toByteArray();
        if (Thread.currentThread().isInterrupted()) throw new IOException("Worker input interrupted");
        if (content.length > MAX_TEXT_BYTES) throw new IOException("Worker text exceeds 64 KiB");
        try {
            return StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(content)).toString();
        } catch (CharacterCodingException exception) {
            throw new IOException("Worker text is not valid UTF-8", exception);
        }
    }
}
