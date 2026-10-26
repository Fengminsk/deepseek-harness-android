package com.minnnng.dsh_android;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.DirectoryStream;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Arrays;
import java.util.Objects;
import java.util.UUID;

/** App-private, per-call network audit. An admitted call ID is never admitted again. */
public final class IsolatedNetworkJournal {
    public interface DirectorySync { void sync(Path directory) throws IOException; }
    public enum State { ADMITTED, TERMINAL }
    public record Entry(String callId, String host, long startedEpochMillis, State state,
                        IsolatedNetworkBroker.Status status, boolean transportEntered) {
        public Entry {
            requireId(callId);
            if (host == null || host.length() > 253 || !host.matches("[a-z0-9.-]*"))
                throw new IllegalArgumentException("Invalid audit host");
            if (startedEpochMillis < 0 || state == null ||
                    (state == State.ADMITTED) != (status == null) ||
                    state == State.ADMITTED && transportEntered)
                throw new IllegalArgumentException("Invalid network audit state");
        }
    }

    private static final int MAGIC = 0x4453484e;
    private static final int VERSION = 1;
    private static final int MAX_FRAME_BYTES = 2048;
    public static final int MAX_FILES = 8192;
    public static final long MAX_STORED_BYTES = 16L * 1024 * 1024;
    public static final class CapacityExceededException extends IOException {
        CapacityExceededException() { super("Network audit storage limit reached"); }
    }
    private static final Object WRITE_LOCK = new Object();
    private final Path root;
    private final DirectorySync sync;
    private final int maxFiles;
    private final long maxStoredBytes;

    /** The parent is an existing App-private directory; the caller supplies a real directory fsync. */
    public IsolatedNetworkJournal(Path appPrivateParent, DirectorySync sync) throws IOException {
        this(appPrivateParent, sync, MAX_FILES, MAX_STORED_BYTES);
    }

    IsolatedNetworkJournal(Path appPrivateParent, DirectorySync sync,
                           int maxFiles, long maxStoredBytes) throws IOException {
        this.sync = Objects.requireNonNull(sync);
        if (maxFiles < 1 || maxStoredBytes < MAX_FRAME_BYTES)
            throw new IllegalArgumentException("Invalid network audit capacity");
        this.maxFiles = maxFiles;
        this.maxStoredBytes = maxStoredBytes;
        Path parent = Objects.requireNonNull(appPrivateParent).toAbsolutePath().normalize();
        if (!Files.isDirectory(parent, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(parent))
            throw new IOException("Network audit parent is unavailable");
        root = parent.resolve("isolated-network-calls");
        try {
            Files.createDirectory(root);
            sync.sync(parent);
        } catch (java.nio.file.FileAlreadyExistsException existing) {
            if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(root))
                throw new IOException("Network audit directory was replaced", existing);
        }
        checkRoot();
    }

    /** Admission is durable before DNS or TCP. A damaged file still reserves its call ID. */
    public void admit(String callId, String host) throws IOException {
        Entry entry = new Entry(callId, host, System.currentTimeMillis(), State.ADMITTED,
                null, false);
        synchronized (WRITE_LOCK) {
            checkRoot();
            if (Files.exists(file(callId), LinkOption.NOFOLLOW_LINKS))
                throw new java.nio.file.FileAlreadyExistsException(file(callId).toString());
            checkAdmissionCapacity();
            try (FileChannel channel = FileChannel.open(file(callId),
                    StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE,
                    LinkOption.NOFOLLOW_LINKS)) {
                writeAll(channel, encode(entry));
                channel.force(true);
            }
            sync.sync(root);
        }
    }

    /** Completion is publishable only after atomic replacement and directory sync return. */
    public void finish(String callId, IsolatedNetworkBroker.Status status,
                       boolean transportEntered) throws IOException {
        Objects.requireNonNull(status);
        synchronized (WRITE_LOCK) {
            checkRoot();
            Entry admitted = read(callId);
            if (admitted.state() != State.ADMITTED)
                throw new IOException("Network call is already terminal");
            Entry terminal = new Entry(callId, admitted.host(), admitted.startedEpochMillis(),
                    State.TERMINAL, status, transportEntered);
            Path temp = Files.createTempFile(root, "network-", ".tmp");
            try {
                try (FileChannel channel = FileChannel.open(temp, StandardOpenOption.WRITE,
                        LinkOption.NOFOLLOW_LINKS)) {
                    writeAll(channel, encode(terminal));
                    channel.force(true);
                }
                Files.move(temp, file(callId), StandardCopyOption.ATOMIC_MOVE,
                        StandardCopyOption.REPLACE_EXISTING);
                sync.sync(root);
            } finally { Files.deleteIfExists(temp); }
        }
    }

    /** ADMITTED after a crash means the server effect is uncertain; reading never replays work. */
    public Entry read(String callId) throws IOException {
        synchronized (WRITE_LOCK) {
            checkRoot();
            Path path = file(callId);
            if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(path))
                throw new IOException("Network audit is absent or damaged");
            byte[] frame;
            try (FileChannel channel = FileChannel.open(path, StandardOpenOption.READ,
                    LinkOption.NOFOLLOW_LINKS)) {
                long size = channel.size();
                if (size < 40 || size > MAX_FRAME_BYTES) throw new IOException("Network audit size is invalid");
                ByteBuffer data = ByteBuffer.allocate((int) size);
                while (data.hasRemaining()) {
                    if (channel.read(data) <= 0) throw new IOException("Network audit was truncated");
                }
                frame = data.array();
            }
            byte[] body = Arrays.copyOf(frame, frame.length - 32);
            if (!MessageDigest.isEqual(digest(body),
                    Arrays.copyOfRange(frame, frame.length - 32, frame.length)))
                throw new IOException("Network audit checksum mismatch");
            try (DataInputStream data = new DataInputStream(new ByteArrayInputStream(body))) {
                if (data.readInt() != MAGIC || data.readInt() != VERSION)
                    throw new IOException("Unknown network audit version");
                Entry entry = new Entry(data.readUTF(), data.readUTF(), data.readLong(),
                        State.valueOf(data.readUTF()), status(data.readUTF()), data.readBoolean());
                if (!callId.equals(entry.callId()) || data.available() != 0)
                    throw new IOException("Network audit identity mismatch");
                return entry;
            } catch (RuntimeException invalid) {
                throw new IOException("Invalid network audit values", invalid);
            }
        }
    }

    private static IsolatedNetworkBroker.Status status(String value) {
        return value.isEmpty() ? null : IsolatedNetworkBroker.Status.valueOf(value);
    }

    private static byte[] encode(Entry entry) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try (DataOutputStream out = new DataOutputStream(bytes)) {
            out.writeInt(MAGIC);
            out.writeInt(VERSION);
            out.writeUTF(entry.callId());
            out.writeUTF(entry.host());
            out.writeLong(entry.startedEpochMillis());
            out.writeUTF(entry.state().name());
            out.writeUTF(entry.status() == null ? "" : entry.status().name());
            out.writeBoolean(entry.transportEntered());
        }
        byte[] body = bytes.toByteArray();
        byte[] frame = Arrays.copyOf(body, body.length + 32);
        System.arraycopy(digest(body), 0, frame, body.length, 32);
        if (frame.length > MAX_FRAME_BYTES) throw new IOException("Network audit exceeds frame limit");
        return frame;
    }

    public static void requireCallId(String value) {
        if (value == null || !UUID.fromString(value).toString().equals(value))
            throw new IllegalArgumentException("Canonical call ID required");
    }

    private static void requireId(String value) { requireCallId(value); }

    private Path file(String callId) {
        requireId(callId);
        return root.resolve(callId + ".audit");
    }

    private void checkRoot() throws IOException {
        if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(root))
            throw new IOException("Network audit directory is unavailable");
    }

    /** Counts tombstones and crash-left temp files; no record is evicted or ID reused. */
    private void checkAdmissionCapacity() throws IOException {
        int count = 0;
        long bytes = 0;
        try (DirectoryStream<Path> entries = Files.newDirectoryStream(root)) {
            for (Path entry : entries) {
                if (!Files.isRegularFile(entry, LinkOption.NOFOLLOW_LINKS)
                        || Files.isSymbolicLink(entry))
                    throw new IOException("Unexpected network audit directory entry");
                count++;
                long size = Files.size(entry);
                if (size < 0 || size > maxStoredBytes) throw new CapacityExceededException();
                bytes += size;
                if (count >= maxFiles || bytes > maxStoredBytes - MAX_FRAME_BYTES)
                    throw new CapacityExceededException();
            }
        }
    }

    private static byte[] digest(byte[] body) {
        try { return MessageDigest.getInstance("SHA-256").digest(body); }
        catch (NoSuchAlgorithmException error) { throw new AssertionError(error); }
    }

    private static void writeAll(FileChannel channel, byte[] bytes) throws IOException {
        ByteBuffer source = ByteBuffer.wrap(bytes);
        while (source.hasRemaining()) channel.write(source);
    }
}
