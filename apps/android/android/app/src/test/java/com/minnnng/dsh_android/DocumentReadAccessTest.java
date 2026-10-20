package com.minnnng.dsh_android;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

/** Checks the production reader against provider-like streams and changing persisted grants. */
public final class DocumentReadAccessTest {
    private static final String ROOT = "granted-opaque-id";

    private static final class Source implements DocumentReadAccess.Source {
        private final byte[] bytes;
        boolean granted = true;
        boolean revokeDuringRead;
        boolean refusesSkip;
        boolean zeroBulkReads;
        int opened;
        int closed;

        Source(byte[] bytes) { this.bytes = bytes; }
        Source(String text) { this(text.getBytes(StandardCharsets.UTF_8)); }

        @Override public boolean isGranted(String root) { return granted && ROOT.equals(root); }

        @Override public InputStream open(String root, String path) {
            opened++;
            return new ByteArrayInputStream(bytes) {
                @Override public synchronized long skip(long count) {
                    return refusesSkip ? 0 : super.skip(count);
                }
                @Override public synchronized int read(byte[] buffer, int offset, int count) {
                    if (revokeDuringRead) granted = false;
                    return zeroBulkReads ? 0 : super.read(buffer, offset, count);
                }
                @Override public void close() { closed++; }
            };
        }
    }

    public static void main(String[] args) throws Exception {
        String expected = "a".repeat(262143) + "你🙂" + "界".repeat(100000) + "fin";
        Source unicode = new Source(expected);
        StringBuilder joined = new StringBuilder();
        int offset = 0;
        int pages = 0;
        while (true) {
            var page = DocumentReadAccess.read(unicode, ROOT, "", offset);
            check(page.offset == offset, "page start changed");
            joined.append(page.text);
            pages++;
            if (!page.truncated) break;
            check(page.nextOffset > offset, "Unicode page made no progress");
            offset = page.nextOffset;
        }
        check(pages == 3 && joined.toString().equals(expected), "UTF-8 text changed across page boundaries");
        check(unicode.opened == unicode.closed, "provider stream leaked");

        Source emoji = new Source("x".repeat(262142) + "🙂tail");
        var first = DocumentReadAccess.read(emoji, ROOT, "", 0);
        var second = DocumentReadAccess.read(emoji, ROOT, "", first.nextOffset);
        check(first.nextOffset == 262142 && second.text.equals("🙂tail"), "four-byte character was split");

        Source revoked = new Source("private");
        revoked.granted = false;
        rejects(SecurityException.class, () -> DocumentReadAccess.read(revoked, ROOT, "", 0));
        check(revoked.opened == 0, "revoked grant opened a provider");
        revoked.granted = true;
        rejects(SecurityException.class, () -> DocumentReadAccess.read(revoked, "content://untrusted/path", "", 0));
        check(revoked.opened == 0, "arbitrary URI bypassed opaque grant lookup");
        revoked.revokeDuringRead = true;
        rejects(SecurityException.class, () -> DocumentReadAccess.read(revoked, ROOT, "", 0));
        check(revoked.closed == 1, "revocation during read leaked stream");
        rejects(SecurityException.class, () -> DocumentReadAccess.read(revoked, ROOT, "", 0));
        check(revoked.opened == 1, "later read ignored revocation");

        Source provider = new Source("abcdef");
        provider.refusesSkip = true;
        provider.zeroBulkReads = true;
        check(DocumentReadAccess.read(provider, ROOT, "", 2).text.equals("cdef"), "non-seekable provider failed");
        check(DocumentReadAccess.read(provider, ROOT, "", 6).text.isEmpty(), "EOF page failed");
        rejects(IOException.class, () -> DocumentReadAccess.read(provider, ROOT, "", 7));
        rejects(IllegalArgumentException.class, () -> DocumentReadAccess.read(provider, ROOT, "", -1));
        rejects(IOException.class, () -> DocumentReadAccess.read(new Source("你"), ROOT, "", 1));
        rejects(IOException.class, () -> DocumentReadAccess.read(new Source(new byte[] {(byte) 0xe4, (byte) 0xbd}), ROOT, "", 0));
        rejects(IOException.class, () -> DocumentReadAccess.read(new Source(new byte[] {'a', 0, 'b'}), ROOT, "", 0));
        check(provider.closed == provider.opened, "failed provider read leaked stream");
        System.out.println("DocumentReadAccess: revoked grants, arbitrary IDs, in-flight revocation, UTF-8 pages, provider streams and failures passed");
    }

    private interface Checked { void run() throws Exception; }

    private static void rejects(Class<? extends Throwable> type, Checked action) throws Exception {
        try { action.run(); }
        catch (Throwable failure) {
            if (type.isInstance(failure)) return;
            throw new AssertionError("Unexpected failure", failure);
        }
        throw new AssertionError("Expected " + type.getSimpleName());
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
