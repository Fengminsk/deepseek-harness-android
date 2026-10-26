package com.minnnng.dsh_android;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.security.MessageDigest;
import java.util.Arrays;

public final class DocumentBinaryReadAccessTest {
    private static int checks;

    public static void main(String[] args) throws Exception {
        readsStableBinary();
        rejectsChangedSecondPass();
        rejectsUnknownSizeOverLimit();
        rejectsRevocationAndCancellation();
        validatesWireLimit();
        System.out.println("DocumentBinaryReadAccess: " + checks + " checks passed");
    }

    private static void readsStableBinary() throws Exception {
        byte[] image = new byte[] { (byte) 0x89, 0x50, 0x4e, 0x47, 0, 1, 2 };
        var result = DocumentBinaryReadAccess.read(source(image, image), image.length);
        check(Arrays.equals(result.bytes, image));
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(image);
        StringBuilder expected = new StringBuilder();
        for (byte value : digest) expected.append(String.format("%02x", value & 0xff));
        check(result.sha256.equals(expected.toString()));
    }

    private static void rejectsChangedSecondPass() throws Exception {
        byte[] first = new byte[] { 1, 2, 3, 4 };
        byte[] second = new byte[] { 1, 2, 3, 5 };
        fails(() -> DocumentBinaryReadAccess.read(source(first, second), 8), "变化");
        fails(() -> DocumentBinaryReadAccess.read(source(first, new byte[] { 1, 2, 3 }), 8), "变化");
    }

    private static void rejectsUnknownSizeOverLimit() throws Exception {
        byte[] oversized = new byte[DocumentBinaryReadAccess.MAX_IMAGE_BYTES + 1];
        fails(() -> DocumentBinaryReadAccess.read(source(oversized, oversized),
            DocumentBinaryReadAccess.MAX_IMAGE_BYTES), "大小");
    }

    private static void rejectsRevocationAndCancellation() throws Exception {
        byte[] image = new byte[] { 1, 2, 3 };
        var source = new DocumentBinaryReadAccess.Source() {
            int opens;
            @Override public void check() throws IOException {
                if (opens > 0) throw new IOException("授权已撤销");
            }
            @Override public InputStream open() { opens++; return new ByteArrayInputStream(image); }
        };
        fails(() -> DocumentBinaryReadAccess.read(source, 8), "授权已撤销");
        var canceled = new DocumentBinaryReadAccess.Source() {
            @Override public void check() throws IOException { throw new IOException("读取已取消"); }
            @Override public InputStream open() { throw new AssertionError("canceled read opened provider"); }
        };
        fails(() -> DocumentBinaryReadAccess.read(canceled, 8), "读取已取消");
    }

    private static void validatesWireLimit() {
        check(DocumentBinaryReadAccess.limit(1) == 1);
        check(DocumentBinaryReadAccess.limit((long) DocumentBinaryReadAccess.MAX_IMAGE_BYTES)
            == DocumentBinaryReadAccess.MAX_IMAGE_BYTES);
        for (Object invalid : new Object[] { null, 0, -1, "1", 1.0,
                (long) DocumentBinaryReadAccess.MAX_IMAGE_BYTES + 1 }) {
            try { DocumentBinaryReadAccess.limit(invalid); throw new AssertionError("accepted " + invalid); }
            catch (IllegalArgumentException expected) { checks++; }
        }
    }

    private static DocumentBinaryReadAccess.Source source(byte[] first, byte[] second) {
        return new DocumentBinaryReadAccess.Source() {
            int opens;
            @Override public void check() {}
            @Override public InputStream open() {
                return new ByteArrayInputStream(opens++ == 0 ? first : second);
            }
        };
    }

    private interface Checked { void run() throws Exception; }
    private static void fails(Checked action, String expected) throws Exception {
        try { action.run(); throw new AssertionError("expected " + expected); }
        catch (IOException failure) { check(failure.getMessage().contains(expected)); }
    }
    private static void check(boolean valid) {
        if (!valid) throw new AssertionError();
        checks++;
    }
}
