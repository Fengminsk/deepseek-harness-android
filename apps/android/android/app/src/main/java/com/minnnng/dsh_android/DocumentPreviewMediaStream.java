package com.minnnng.dsh_android;

import java.io.IOException;
import java.io.InputStream;
import java.util.Objects;
import java.util.concurrent.atomic.AtomicBoolean;

/** Bounded lease consumer; owns no file, and releases once on EOF, close, or failed transfer. */
public final class DocumentPreviewMediaStream extends InputStream {
    public static final int CHUNK_BYTES = 256 * 1024;
    @FunctionalInterface public interface Reader { byte[] read(long offset, int length) throws IOException; }

    private final long length;
    private final Reader reader;
    private final Runnable release;
    private final AtomicBoolean closed = new AtomicBoolean();
    private final AtomicBoolean released = new AtomicBoolean();
    private long fetched;
    private byte[] buffer = new byte[0];
    private int cursor;

    public DocumentPreviewMediaStream(long length, Reader reader, Runnable release) {
        if (length < 0) throw new IllegalArgumentException("Negative lease length");
        this.length = length;
        this.reader = Objects.requireNonNull(reader);
        this.release = Objects.requireNonNull(release);
        if (length == 0) releaseOnce();
    }

    @Override public synchronized int read() throws IOException {
        byte[] single = new byte[1];
        return read(single, 0, 1) == -1 ? -1 : single[0] & 255;
    }

    @Override public synchronized int read(byte[] target, int offset, int count) throws IOException {
        if (offset < 0 || count < 0 || offset > target.length - count) throw new IndexOutOfBoundsException();
        if (count == 0) return 0;
        if (closed.get()) throw new IOException("Media stream is closed");
        if (cursor == buffer.length) {
            if (fetched == length) { releaseOnce(); return -1; }
            int requested = (int) Math.min(CHUNK_BYTES, length - fetched);
            try {
                byte[] next = reader.read(fetched, requested);
                if (closed.get()) throw new IOException("Media stream was closed during transfer");
                if (next == null || next.length != requested) throw new IOException("Incomplete media byte frame");
                buffer = next;
                cursor = 0;
                fetched += next.length;
                // The final window is already local; the runtime no longer needs its full-file lease.
                if (fetched == length) releaseOnce();
            } catch (IOException | RuntimeException failure) {
                close();
                throw failure;
            }
        }
        int copied = Math.min(count, buffer.length - cursor);
        System.arraycopy(buffer, cursor, target, offset, copied);
        cursor += copied;
        return copied;
    }

    @Override public synchronized int available() { return closed.get() ? 0 : buffer.length - cursor; }

    /** Does not acquire the reader monitor: disposal can revoke a lease while a chunk is waiting. */
    @Override public void close() {
        closed.set(true);
        releaseOnce();
    }

    private void releaseOnce() { if (released.compareAndSet(false, true)) release.run(); }
}
