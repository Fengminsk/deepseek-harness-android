package com.minnnng.dsh_android;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.security.DigestInputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.function.BooleanSupplier;

/** Fixed private cache access for a fully verified historical attachment. */
public final class AttachmentFileCache {
    private AttachmentFileCache() {}

    public static void validateId(String id) {
        if (id == null || !id.matches("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")) {
            throw new IllegalArgumentException("附件读取标识无效");
        }
    }

    public static void validateFilename(String name) {
        if (name == null || name.isEmpty() || name.equals(".") || name.equals("..")
                || name.getBytes(StandardCharsets.UTF_8).length > 255
                || name.chars().anyMatch(value -> value == '/' || value == '\\' || value < 32 || value == 127)) {
            throw new IllegalArgumentException("附件文件名无效");
        }
    }

    public static void validateAttachmentId(String attachmentId) {
        if (attachmentId == null || !attachmentId.matches("sha256:[a-f0-9]{64}")) {
            throw new IllegalArgumentException("附件摘要无效");
        }
    }

    public static File source(File directory, String id, long bytes) throws IOException {
        validateId(id);
        if (bytes < 0) throw new IllegalArgumentException("附件大小无效");
        File root = directory.getCanonicalFile();
        File source = new File(root, id + ".file");
        if (!source.getCanonicalFile().getParentFile().equals(root)
                || !Files.isRegularFile(source.toPath(), LinkOption.NOFOLLOW_LINKS)
                || Files.size(source.toPath()) != bytes) {
            throw new IOException("附件副本已失效，请重新打开");
        }
        return source;
    }

    /** The caller owns its output stream and reports possible partial destinations on failure. */
    public static long copy(File source, long expectedBytes, String attachmentId,
            OutputStream output, BooleanSupplier cancelled) throws IOException {
        validateAttachmentId(attachmentId);
        MessageDigest digest;
        try { digest = MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException impossible) { throw new IllegalStateException(impossible); }
        byte[] expectedDigest = new byte[32];
        for (int i = 0; i < expectedDigest.length; i++) {
            expectedDigest[i] = (byte) Integer.parseInt(attachmentId.substring(7 + i * 2, 9 + i * 2), 16);
        }
        try (InputStream input = new DigestInputStream(
                Files.newInputStream(source.toPath(), LinkOption.NOFOLLOW_LINKS), digest)) {
            if (Files.size(source.toPath()) != expectedBytes) throw new IOException("附件副本已变化");
            long copied = AttachmentCopy.copy(input, output, cancelled);
            if (copied != expectedBytes || Files.size(source.toPath()) != expectedBytes
                    || !MessageDigest.isEqual(expectedDigest, digest.digest())) throw new IOException("附件副本已变化");
            return copied;
        }
    }
}
