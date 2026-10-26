package com.minnnng.dsh_android;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

/** A provider-metadata revision for one SAF document, without exposing its URI. */
public final class DocumentRevision {
    private DocumentRevision() {}

    /** Stable across process restarts; same-size edits are undetectable if a provider omits modification time. */
    public static String token(String uri, String name, String mime, Long size, Long modified) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            part(digest, uri);
            part(digest, name);
            part(digest, mime);
            part(digest, size == null ? null : size.toString());
            part(digest, modified == null ? null : modified.toString());
            StringBuilder token = new StringBuilder(64);
            for (byte value : digest.digest()) {
                token.append(Character.forDigit((value >>> 4) & 15, 16));
                token.append(Character.forDigit(value & 15, 16));
            }
            return token.toString();
        } catch (NoSuchAlgorithmException impossible) {
            throw new IllegalStateException("SHA-256 is unavailable", impossible);
        }
    }

    private static void part(MessageDigest digest, String value) {
        if (value == null) {
            digest.update(ByteBuffer.allocate(Integer.BYTES).putInt(-1).array());
            return;
        }
        byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
        digest.update(ByteBuffer.allocate(Integer.BYTES).putInt(bytes.length).array());
        digest.update(bytes);
    }
}
