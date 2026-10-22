package com.minnnng.dsh_android;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InterruptedIOException;
import java.nio.charset.StandardCharsets;
import java.math.BigDecimal;

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
        long offset = 0;
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
        largeOffsets();
        nonSeekableLargeOffset();
        revokedWhileSeeking();
        interruptedWhileReading();
        unavailableOrMoved();
        System.out.println("DocumentReadAccess: grants, UTF-8 pages, >2GiB positions, bounded non-seekable fallback, strict JSON offsets, in-flight revoke/interrupt, and provider failures passed");
    }

    private static void largeOffsets() throws Exception {
        check(DocumentReadAccess.offset(null) == 0, "missing offset defaults to first page");
        check(DocumentReadAccess.offset(4294967296L) == 4294967296L, "4GiB position was narrowed");
        check(DocumentReadAccess.offset(4294967296d) == 4294967296L, "exact JSON double position failed");
        check(DocumentReadAccess.offset(new BigDecimal("4294967296.0")) == 4294967296L, "integral decimal position failed");
        for (Object invalid : new Object[] { -1, 1.5, "4294967296", true, Double.NaN,
                Double.POSITIVE_INFINITY, 9007199254740992L, new BigDecimal("1.00000000000000001"), new Object() }) {
            rejects(IllegalArgumentException.class, () -> DocumentReadAccess.offset(invalid));
        }
        class SparseSource implements DocumentReadAccess.Source {
            int opened, closed, reads, seeks;
            public boolean isGranted(String root) { return ROOT.equals(root); }
            public InputStream open(String root, String path) { return streamAt(0); }
            public DocumentReadAccess.Opened openAt(String root, String path, long offset) {
                seeks++;
                return new DocumentReadAccess.Opened(streamAt(offset), offset);
            }
            private InputStream streamAt(long start) {
                opened++;
                return new InputStream() {
                    long position = start;
                    public long skip(long count) { throw new AssertionError("Directly positioned stream must not skip"); }
                    public int read() { throw new AssertionError("Unexpected byte-at-a-time read"); }
                    public int read(byte[] buffer, int at, int count) {
                        reads++;
                        for (int index = 0; index < count; index++) buffer[at + index] = (byte) ('A' + (position++ % 26));
                        return count;
                    }
                    public void close() { closed++; }
                };
            }
        }
        SparseSource sparse = new SparseSource();
        for (long position : new long[] { Integer.MAX_VALUE - 2L, 4294967296L }) {
            var page = DocumentReadAccess.read(sparse, ROOT, "large.txt", position);
            check(page.offset == position && page.nextOffset == position + 262144, "large page offset wrapped");
            check(page.truncated && page.text.length() == 262144, "large page exceeded the bounded page size");
            check(page.text.charAt(0) == 'A' + position % 26, "large page returned a different part of the file");
        }
        rejects(IOException.class, () -> DocumentReadAccess.read(sparse, ROOT, "large.txt", 9007199254740991L));
        check(sparse.opened == sparse.closed && sparse.reads == 3 && sparse.seeks == 3,
            "large offset scanning was not bounded or leaked streams");
    }

    private static void nonSeekableLargeOffset() throws Exception {
        class NonSeekableSource implements DocumentReadAccess.Source {
            int bulkReads, singleReads, closed;
            public boolean isGranted(String root) { return ROOT.equals(root); }
            public InputStream open(String root, String path) {
                return new InputStream() {
                    public long skip(long count) { return 0; }
                    public int read() { singleReads++; return 'x'; }
                    public int read(byte[] bytes, int at, int count) {
                        bulkReads++;
                        java.util.Arrays.fill(bytes, at, at + count, (byte) 'x');
                        return count;
                    }
                    public void close() { closed++; }
                };
            }
        }
        NonSeekableSource source = new NonSeekableSource();
        var page = DocumentReadAccess.read(source, ROOT, "large.txt", 8L * 1024 * 1024);
        check(page.offset == 8L * 1024 * 1024 && page.text.length() == 262144,
            "non-seekable provider lost the page position");
        check(source.bulkReads < 140 && source.singleReads == 0,
            "non-seekable provider was read byte by byte");
        try {
            DocumentReadAccess.read(source, ROOT, "large.txt", 64L * 1024 * 1024 + 1);
            throw new AssertionError("Expected bounded non-seekable position failure");
        } catch (IOException expected) {
            check(expected.getMessage().contains("64 MiB"), "large-file fallback has no recovery guidance");
        }
        check(source.bulkReads < 1200 && source.closed == 2,
            "bounded seek failure kept scanning or leaked a provider stream");

        class RevokingFallbackSource implements DocumentReadAccess.Source {
            boolean granted = true;
            int reads, closed;
            public boolean isGranted(String root) { return granted; }
            public InputStream open(String root, String path) {
                return new InputStream() {
                    public long skip(long count) { return 0; }
                    public int read() { throw new AssertionError("Revoked fallback must not continue"); }
                    public int read(byte[] bytes, int at, int count) {
                        reads++;
                        granted = false;
                        return count;
                    }
                    public void close() { closed++; }
                };
            }
        }
        RevokingFallbackSource revoked = new RevokingFallbackSource();
        rejects(SecurityException.class, () -> DocumentReadAccess.read(revoked, ROOT, "", 1024));
        check(revoked.reads == 1 && revoked.closed == 1, "revoked fallback read continued or leaked stream");

        DocumentReadAccess.Source noSkip = new DocumentReadAccess.Source() {
            public boolean isGranted(String root) { return true; }
            public InputStream open(String root, String path) {
                return new InputStream() {
                    int next;
                    public long skip(long count) { throw new AssertionError("Provider skip must never be called"); }
                    public int read() { return next++ < 8 ? 'x' : -1; }
                };
            }
        };
        check(DocumentReadAccess.read(noSkip, ROOT, "", 2).text.equals("xxxxxx"),
            "bounded fallback accidentally called provider skip");

        class InvalidPosition implements DocumentReadAccess.Source {
            int closed;
            public boolean isGranted(String root) { return true; }
            public InputStream open(String root, String path) { throw new AssertionError("Invalid direct position must not reopen"); }
            public DocumentReadAccess.Opened openAt(String root, String path, long offset) {
                return new DocumentReadAccess.Opened(new ByteArrayInputStream(new byte[] {'x'}) {
                    public void close() { closed++; }
                }, offset + 1);
            }
        }
        InvalidPosition invalidPosition = new InvalidPosition();
        rejects(IOException.class, () -> DocumentReadAccess.read(invalidPosition, ROOT, "", 2));
        check(invalidPosition.closed == 1, "invalid direct position leaked stream");
    }

    private static void revokedWhileSeeking() throws Exception {
        class RevokingSource implements DocumentReadAccess.Source {
            boolean granted = true;
            int positions, reads, closed;
            public boolean isGranted(String root) { return granted; }
            public InputStream open(String root, String path) { throw new AssertionError("Positioned source must not reopen"); }
            public DocumentReadAccess.Opened openAt(String root, String path, long offset) {
                positions++;
                granted = false;
                return new DocumentReadAccess.Opened(new InputStream() {
                    public int read() { reads++; return 'x'; }
                    public void close() { closed++; }
                }, offset);
            }
        }
        RevokingSource source = new RevokingSource();
        rejects(SecurityException.class, () -> DocumentReadAccess.read(source, ROOT, "", 16));
        check(source.positions == 1 && source.reads == 0 && source.closed == 1,
            "revocation during direct positioning must prevent provider reads and close the stream");
    }

    private static void interruptedWhileReading() throws Exception {
        Source unopened = new Source("text");
        try {
            Thread.currentThread().interrupt();
            rejects(InterruptedIOException.class, () -> DocumentReadAccess.read(unopened, ROOT, "", 0));
            check(unopened.opened == 0, "interrupted read opened a provider");
        } finally { Thread.interrupted(); }
        class InterruptingSource implements DocumentReadAccess.Source {
            int reads, closed;
            public boolean isGranted(String root) { return true; }
            public InputStream open(String root, String path) {
                return new InputStream() {
                    public int read() { throw new AssertionError("Unexpected single read"); }
                    public int read(byte[] data, int at, int count) {
                        reads++;
                        data[at] = 'x';
                        Thread.currentThread().interrupt();
                        return 1;
                    }
                    public void close() { closed++; }
                };
            }
        }
        InterruptingSource source = new InterruptingSource();
        try {
            rejects(InterruptedIOException.class, () -> DocumentReadAccess.read(source, ROOT, "", 0));
            check(source.reads == 1 && source.closed == 1, "interrupted read continued or leaked its stream");
        } finally { Thread.interrupted(); }
    }

    private static void unavailableOrMoved() throws Exception {
        for (boolean missing : new boolean[] { false, true }) {
            DocumentReadAccess.Source source = new DocumentReadAccess.Source() {
                public boolean isGranted(String root) { return true; }
                public InputStream open(String root, String path) throws IOException {
                    if (missing) throw new java.io.FileNotFoundException("moved");
                    return null;
                }
            };
            rejects(missing ? java.io.FileNotFoundException.class : IOException.class,
                () -> DocumentReadAccess.read(source, ROOT, "", 0));
        }
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
