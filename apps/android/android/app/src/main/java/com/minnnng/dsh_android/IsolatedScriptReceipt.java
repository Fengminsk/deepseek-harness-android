package com.minnnng.dsh_android;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.UUID;
import java.util.zip.CRC32;

/** App-private run receipts plus an append-only admitted-ID ledger. */
public final class IsolatedScriptReceipt {
    public enum State {
        ADMITTED, COMPLETED, CANCELLED, TIMED_OUT, WORKER_DIED, ERROR,
        RETIRE_UNCONFIRMED, INTERRUPTED_UNCONFIRMED
    }

    public record Entry(String runId, State state, String outputJson, String logsJson, String detail) {
        public Entry(String runId, State state, String outputJson, String detail) {
            this(runId, state, outputJson, state == State.COMPLETED ? "[]" : null, detail);
        }
        public Entry {
            IsolatedScriptWire.requireUuid(runId);
            Objects.requireNonNull(state);
            if (state == State.COMPLETED) {
                if (outputJson == null || logsJson == null
                        || !logsJson.startsWith("[") || !logsJson.endsWith("]")
                        || IsolatedScriptWire.utf8Bytes(logsJson) > PtcScriptEngine.MAX_LOG_BYTES
                        || IsolatedScriptWire.utf8Bytes(outputJson) >
                           PtcScriptEngine.MAX_OUTPUT_BYTES - IsolatedScriptWire.utf8Bytes(logsJson))
                    throw new IllegalArgumentException("Completed receipt needs bounded JSON");
            } else if (outputJson != null || logsJson != null)
                throw new IllegalArgumentException("Noncompletion has output or logs");
            if (detail != null && IsolatedScriptWire.utf8Bytes(detail) > IsolatedScriptWire.MAX_DETAIL_BYTES)
                throw new IllegalArgumentException("Receipt detail is too large");
        }
    }

    public interface DirectorySync { void sync(Path directory) throws IOException; }

    /** Retained active receipts or admitted IDs have exhausted their storage budget. */
    public static final class CapacityExceededException extends IOException {
        public CapacityExceededException() { super("Script receipt capacity exhausted"); }
    }

    private static final int MAGIC = 0x44534853;
    private static final int VERSION = 2;
    private static final int MAX_FRAME_BYTES = 100 * 1024;
    private static final int MAX_FILES = 1024;
    private static final long MAX_TOTAL_BYTES = 128L * 1024 * 1024;
    private static final long MAX_LEDGER_BYTES = 128L * 1024 * 1024;
    private static final int LEDGER_MAGIC = 0x44534849;
    private static final int LEDGER_VERSION = 1;
    private static final int LEDGER_HEADER_BYTES = 12;
    private static final int LEDGER_ENTRY_BYTES = 20;
    private static final int MIGRATION_MAGIC = 0x4453484d;
    private static final int MIGRATION_VERSION = 1;
    private static final int MIGRATION_MARKER_BYTES = 12;
    private static final String MIGRATION_MARKER = "migration-v1.complete";
    private static final Object WRITE_LOCK = new Object();
    private final Path root;
    private final DirectorySync sync;
    private final int maxFiles;
    private final long maxTotalBytes;
    private final long maxLedgerBytes;

    /** The caller supplies an existing App-private parent directory, never a guest path. */
    public IsolatedScriptReceipt(Path appPrivateParent, DirectorySync sync) throws IOException {
        this(appPrivateParent, sync, MAX_FILES, MAX_TOTAL_BYTES, MAX_LEDGER_BYTES);
    }

    /** Test-only lower budgets exercise exhaustion without creating a thousand run files. */
    IsolatedScriptReceipt(Path appPrivateParent, DirectorySync sync,
                          int maxFiles, long maxTotalBytes) throws IOException {
        this(appPrivateParent, sync, maxFiles, maxTotalBytes, MAX_LEDGER_BYTES);
    }

    IsolatedScriptReceipt(Path appPrivateParent, DirectorySync sync,
                          int maxFiles, long maxTotalBytes, long maxLedgerBytes) throws IOException {
        if (maxFiles < 1 || maxFiles > MAX_FILES || maxTotalBytes < MAX_FRAME_BYTES
                || maxTotalBytes > MAX_TOTAL_BYTES || maxLedgerBytes < LEDGER_HEADER_BYTES + LEDGER_ENTRY_BYTES
                || maxLedgerBytes > MAX_LEDGER_BYTES) {
            throw new IllegalArgumentException("Invalid script receipt capacity");
        }
        this.sync = Objects.requireNonNull(sync);
        this.maxFiles = maxFiles;
        this.maxTotalBytes = maxTotalBytes;
        this.maxLedgerBytes = maxLedgerBytes;
        Path parent = appPrivateParent.toAbsolutePath().normalize();
        if (!Files.isDirectory(parent, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(parent))
            throw new IOException("Script receipt parent is not a private directory");
        root = parent.resolve("isolated-script-runs");
        try {
            Files.createDirectory(root);
            sync.sync(parent);
        } catch (java.nio.file.FileAlreadyExistsException existing) {
            if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(root))
                throw new IOException("Script receipt directory was replaced", existing);
        }
        checkRoot();
        synchronized (WRITE_LOCK) {
            discardUnpublishedTemps();
            if (!migrationComplete()) {
                migrateExistingReceipts();
                markMigrationComplete();
            }
        }
    }

    /** The ID ledger and receipt are durable before Service binding; compacted IDs still refuse replay. */
    public void admit(String runId) throws IOException {
        Entry admitted = new Entry(runId, State.ADMITTED, null, null);
        synchronized (WRITE_LOCK) {
            checkRoot();
            Inventory inventory = inventory();
            Path file = file(runId);
            if (Files.exists(file, LinkOption.NOFOLLOW_LINKS) || ledgerContains(runId))
                throw new IOException("Script run ID was already admitted");
            long ledgerRequired = Files.exists(ledgerFile(runId), LinkOption.NOFOLLOW_LINKS)
                    ? LEDGER_ENTRY_BYTES : LEDGER_HEADER_BYTES + LEDGER_ENTRY_BYTES;
            if (inventory.ledgerBytes() > maxLedgerBytes - ledgerRequired)
                throw new CapacityExceededException();
            pruneTerminalsForCapacity(inventory);
            appendLedger(runId);
            byte[] frame = encode(admitted);
            try (FileChannel channel = FileChannel.open(file, StandardOpenOption.CREATE_NEW,
                    StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS)) {
                writeAll(channel, frame);
                channel.force(true);
            }
            sync.sync(root);
        }
    }

    /** Read-only replay guard; includes IDs whose terminal receipt was compacted. */
    boolean hasEverAdmitted(String runId) throws IOException {
        IsolatedScriptWire.requireUuid(runId);
        synchronized (WRITE_LOCK) {
            checkRoot();
            return Files.exists(file(runId), LinkOption.NOFOLLOW_LINKS) || ledgerContains(runId);
        }
    }

    /** A terminal result becomes publishable only after this replacement and directory sync return. */
    public void finish(Entry terminal) throws IOException {
        if (terminal.state() == State.ADMITTED) throw new IllegalArgumentException("Terminal state required");
        synchronized (WRITE_LOCK) {
            checkRoot();
            Entry current = read(terminal.runId());
            if (current.state() != State.ADMITTED) throw new IOException("Script run is already terminal");
            Path temp = Files.createTempFile(root, "receipt-", ".tmp");
            try {
                try (FileChannel channel = FileChannel.open(temp, StandardOpenOption.WRITE,
                        LinkOption.NOFOLLOW_LINKS)) {
                    writeAll(channel, encode(terminal));
                    channel.force(true);
                }
                Files.move(temp, file(terminal.runId()), StandardCopyOption.ATOMIC_MOVE,
                        StandardCopyOption.REPLACE_EXISTING);
                sync.sync(root);
            } finally { Files.deleteIfExists(temp); }
        }
    }

    /** Startup reconciliation never runs a script again; an unfinished receipt stays inspectable. */
    public List<Entry> recoverInterrupted() throws IOException {
        synchronized (WRITE_LOCK) {
            checkRoot();
            List<Entry> recovered = new ArrayList<>();
            for (String runId : inventory().runIds()) {
                Entry entry;
                try {
                    entry = read(runId);
                } catch (IOException | IllegalArgumentException damaged) {
                    // Preserve this receipt and its run ID. Other admissions must still recover.
                    continue;
                }
                if (entry.state() == State.ADMITTED) {
                    Entry stopped = new Entry(runId, State.INTERRUPTED_UNCONFIRMED, null,
                            "App restarted before guest retirement was confirmed");
                    finish(stopped);
                    recovered.add(stopped);
                }
            }
            return AndroidJava28.copyList(recovered);
        }
    }

    public Entry read(String runId) throws IOException {
        checkRoot();
        Path target = file(runId);
        if (!Files.isRegularFile(target, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(target))
            throw new IOException("Script receipt is absent or not regular");
        byte[] frame;
        try (FileChannel channel = FileChannel.open(target, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS)) {
            long size = channel.size();
            if (size < 40 || size > MAX_FRAME_BYTES) throw new IOException("Script receipt is damaged");
            ByteBuffer content = ByteBuffer.allocate((int)size);
            while (content.hasRemaining()) {
                if (channel.read(content) <= 0) throw new IOException("Script receipt was truncated");
            }
            frame = content.array();
        }
        byte[] content = java.util.Arrays.copyOf(frame, frame.length - 32);
        byte[] checksum = java.util.Arrays.copyOfRange(frame, frame.length - 32, frame.length);
        if (!MessageDigest.isEqual(digest(content), checksum)) throw new IOException("Script receipt checksum mismatch");
        try (DataInputStream data = new DataInputStream(new ByteArrayInputStream(content))) {
            if (data.readInt() != MAGIC) throw new IOException("Unknown script receipt magic");
            int version = data.readInt();
            if (version != 1 && version != VERSION) throw new IOException("Unknown script receipt version");
            String storedRun = data.readUTF();
            State state = State.valueOf(data.readUTF());
            String output = readValue(data, PtcScriptEngine.MAX_OUTPUT_BYTES);
            String detail = readValue(data, IsolatedScriptWire.MAX_DETAIL_BYTES);
            String logs = version == 1 ? (state == State.COMPLETED ? "[]" : null)
                    : readValue(data, PtcScriptEngine.MAX_LOG_BYTES);
            if (data.available() != 0 || !runId.equals(storedRun)) throw new IOException("Script receipt identity mismatch");
            return new Entry(storedRun, state, output, logs, detail);
        } catch (RuntimeException invalid) { throw new IOException("Script receipt contains invalid values", invalid); }
    }

    private Path file(String runId) {
        IsolatedScriptWire.requireUuid(runId);
        return root.resolve(runId + ".receipt");
    }

    private void checkRoot() throws IOException {
        if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(root))
            throw new IOException("Script receipt directory is unavailable");
    }

    /** A failed replacement leaves its original receipt and ID ledger intact. */
    private void discardUnpublishedTemps() throws IOException {
        boolean deleted = false;
        for (String pattern : new String[] { "receipt-*.tmp", "migration-*.tmp" }) {
            try (DirectoryStream<Path> files = Files.newDirectoryStream(root, pattern)) {
                for (Path path : files) {
                    if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS))
                        throw new IOException("Script receipt temp is not regular");
                    Files.delete(path);
                    deleted = true;
                }
            }
        }
        if (deleted) sync.sync(root);
    }

    /** A synced marker avoids rescanning every retained receipt after the legacy import. */
    private boolean migrationComplete() throws IOException {
        Path marker = root.resolve(MIGRATION_MARKER);
        if (!Files.exists(marker, LinkOption.NOFOLLOW_LINKS)) return false;
        if (!Files.isRegularFile(marker, LinkOption.NOFOLLOW_LINKS))
            throw new IOException("Script receipt migration marker is not regular");
        try (FileChannel channel = FileChannel.open(marker, StandardOpenOption.READ,
                LinkOption.NOFOLLOW_LINKS)) {
            if (channel.size() != MIGRATION_MARKER_BYTES)
                throw new IOException("Script receipt migration marker is damaged");
            ByteBuffer data = ByteBuffer.allocate(MIGRATION_MARKER_BYTES);
            readAll(channel, data);
            byte[] bytes = data.array();
            CRC32 checksum = new CRC32();
            checksum.update(bytes, 0, 8);
            if (ByteBuffer.wrap(bytes).getInt() != MIGRATION_MAGIC
                    || ByteBuffer.wrap(bytes, 4, 4).getInt() != MIGRATION_VERSION
                    || ByteBuffer.wrap(bytes, 8, 4).getInt() != (int)checksum.getValue())
                throw new IOException("Script receipt migration marker is damaged");
            return true;
        }
    }

    private void markMigrationComplete() throws IOException {
        byte[] frame = new byte[MIGRATION_MARKER_BYTES];
        ByteBuffer data = ByteBuffer.wrap(frame);
        data.putInt(MIGRATION_MAGIC).putInt(MIGRATION_VERSION);
        CRC32 checksum = new CRC32();
        checksum.update(frame, 0, 8);
        data.putInt((int)checksum.getValue());
        Path temp = Files.createTempFile(root, "migration-", ".tmp");
        try {
            try (FileChannel channel = FileChannel.open(temp, StandardOpenOption.WRITE,
                    LinkOption.NOFOLLOW_LINKS)) {
                writeAll(channel, frame);
                channel.force(true);
            }
            Files.move(temp, root.resolve(MIGRATION_MARKER), StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING);
            sync.sync(root);
        } finally { Files.deleteIfExists(temp); }
    }

    private Path ledgerFile(String runId) {
        IsolatedScriptWire.requireUuid(runId);
        return root.resolve("ledger-" + runId.substring(0, 2) + ".log");
    }

    private static byte[] ledgerEntry(String runId) {
        UUID id = UUID.fromString(runId);
        ByteBuffer bytes = ByteBuffer.allocate(LEDGER_ENTRY_BYTES);
        bytes.putLong(id.getMostSignificantBits());
        bytes.putLong(id.getLeastSignificantBits());
        CRC32 checksum = new CRC32();
        checksum.update(bytes.array(), 0, 16);
        bytes.putInt((int)checksum.getValue());
        return bytes.array();
    }

    /** A bad bucket refuses every ID in that bucket; other buckets remain available. */
    private boolean ledgerContains(String runId) throws IOException {
        Path path = ledgerFile(runId);
        if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) return false;
        if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS))
            throw new IOException("Script ID ledger is not regular");
        byte[] wanted = ledgerEntry(runId);
        int bucket = Integer.parseInt(runId.substring(0, 2), 16);
        try (FileChannel channel = FileChannel.open(path, StandardOpenOption.READ,
                LinkOption.NOFOLLOW_LINKS)) {
            long size = channel.size();
            if (size < LEDGER_HEADER_BYTES || size > maxLedgerBytes
                    || (size - LEDGER_HEADER_BYTES) % LEDGER_ENTRY_BYTES != 0)
                throw new IOException("Script ID ledger has a torn or excessive frame");
            ByteBuffer header = ByteBuffer.allocate(LEDGER_HEADER_BYTES);
            readAll(channel, header);
            header.flip();
            if (header.getInt() != LEDGER_MAGIC || header.getInt() != LEDGER_VERSION
                    || header.getInt() != bucket)
                throw new IOException("Script ID ledger header mismatch");
            ByteBuffer entry = ByteBuffer.allocate(LEDGER_ENTRY_BYTES);
            boolean found = false;
            while (channel.position() < size) {
                entry.clear();
                readAll(channel, entry);
                byte[] bytes = entry.array();
                CRC32 checksum = new CRC32();
                checksum.update(bytes, 0, 16);
                if ((int)checksum.getValue() != ByteBuffer.wrap(bytes, 16, 4).getInt()
                        || (bytes[0] & 0xff) != bucket)
                    throw new IOException("Script ID ledger entry is damaged");
                if (MessageDigest.isEqual(bytes, wanted)) found = true;
            }
            return found;
        }
    }

    /** The ID record is synced before creating a bindable receipt. */
    private void appendLedger(String runId) throws IOException {
        Path path = ledgerFile(runId);
        boolean created = false;
        if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) {
            try (FileChannel channel = FileChannel.open(path, StandardOpenOption.CREATE_NEW,
                    StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS)) {
                ByteBuffer header = ByteBuffer.allocate(LEDGER_HEADER_BYTES);
                header.putInt(LEDGER_MAGIC).putInt(LEDGER_VERSION)
                        .putInt(Integer.parseInt(runId.substring(0, 2), 16));
                writeAll(channel, header.array());
                channel.force(true);
                created = true;
            }
            sync.sync(root);
        }
        if (!created && ledgerContains(runId))
            throw new IOException("Script run ID was already admitted");
        try (FileChannel channel = FileChannel.open(path, StandardOpenOption.WRITE,
                LinkOption.NOFOLLOW_LINKS)) {
            channel.position(channel.size());
            writeAll(channel, ledgerEntry(runId));
            channel.force(true);
        }
    }

    /** Legacy receipt names are made non-replayable before any terminal receipt can be pruned. */
    private void migrateExistingReceipts() throws IOException {
        for (String runId : inventory().runIds()) {
            try { IsolatedScriptWire.requireUuid(runId); }
            catch (IllegalArgumentException invalidName) { continue; }
            try {
                if (ledgerContains(runId)) continue;
            } catch (IOException damagedBucket) {
                // Retain this receipt. Admission in its bucket will fail, while other buckets can recover.
                continue;
            }
            long required = Files.exists(ledgerFile(runId), LinkOption.NOFOLLOW_LINKS)
                    ? LEDGER_ENTRY_BYTES : LEDGER_HEADER_BYTES + LEDGER_ENTRY_BYTES;
            if (inventory().ledgerBytes() > maxLedgerBytes - required)
                throw new CapacityExceededException();
            appendLedger(runId);
        }
    }

    /** Only terminal receipts are compacted; their IDs already exist in the durable ledger. */
    private void pruneTerminalsForCapacity(Inventory current) throws IOException {
        // Reserve one slot for an atomic terminal replacement after this admission.
        int admissionLimit = Math.max(1, maxFiles - 1);
        while (current.fileCount() >= admissionLimit
                || current.totalBytes() > maxTotalBytes - MAX_FRAME_BYTES) {
            Path oldest = null;
            java.nio.file.attribute.FileTime timestamp = null;
            for (String runId : current.runIds()) {
                Entry entry;
                try { entry = read(runId); }
                catch (IOException | IllegalArgumentException damaged) { continue; }
                if (entry.state() == State.ADMITTED) continue;
                try {
                    if (!ledgerContains(runId)) continue;
                } catch (IOException damagedBucket) {
                    // Never delete a receipt whose admitted ID cannot be verified in durable storage.
                    continue;
                }
                Path candidate = file(runId);
                var modified = Files.getLastModifiedTime(candidate, LinkOption.NOFOLLOW_LINKS);
                if (oldest == null || modified.compareTo(timestamp) < 0) {
                    oldest = candidate;
                    timestamp = modified;
                }
            }
            if (oldest == null) throw new CapacityExceededException();
            Files.delete(oldest);
            sync.sync(root);
            current = inventory();
        }
    }

    private record Inventory(List<String> runIds, int fileCount, long totalBytes,
                             long ledgerBytes) {}

    /** Bounds both the startup scan and all files left by admission or interrupted replacement. */
    private Inventory inventory() throws IOException {
        checkRoot();
        List<String> runIds = new ArrayList<>();
        int count = 0;
        long bytes = 0;
        long ledgerBytes = 0;
        try (DirectoryStream<Path> files = Files.newDirectoryStream(root)) {
            for (Path path : files) {
                if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS))
                    throw new IOException("Script receipt directory contains a non-file entry");
                long size = Files.size(path);
                String name = path.getFileName().toString();
                if (name.equals(MIGRATION_MARKER)) {
                    if (size != MIGRATION_MARKER_BYTES || !migrationComplete())
                        throw new IOException("Script receipt migration marker is damaged");
                    continue;
                }
                if (name.matches("ledger-[0-9a-f]{2}\\.log")) {
                    if (size < 0 || size > maxLedgerBytes - ledgerBytes)
                        throw new CapacityExceededException();
                    ledgerBytes += size;
                    continue;
                }
                if (!name.endsWith(".receipt") && !name.matches("receipt-.+\\.tmp"))
                    throw new IOException("Script receipt directory contains an unknown file");
                if (++count > maxFiles || size < 0 || size > maxTotalBytes - bytes)
                    throw new CapacityExceededException();
                bytes += size;
                if (name.endsWith(".receipt"))
                    runIds.add(name.substring(0, name.length() - ".receipt".length()));
            }
        }
        return new Inventory(runIds, count, bytes, ledgerBytes);
    }

    private static void readAll(FileChannel channel, ByteBuffer target) throws IOException {
        while (target.hasRemaining()) {
            if (channel.read(target) <= 0) throw new IOException("Script ID ledger was truncated");
        }
    }

    private static byte[] encode(Entry entry) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try (DataOutputStream out = new DataOutputStream(bytes)) {
            out.writeInt(MAGIC);
            out.writeInt(VERSION);
            out.writeUTF(entry.runId());
            out.writeUTF(entry.state().name());
            writeValue(out, entry.outputJson());
            writeValue(out, entry.detail());
            writeValue(out, entry.logsJson());
        }
        byte[] content = bytes.toByteArray();
        byte[] frame = java.util.Arrays.copyOf(content, content.length + 32);
        System.arraycopy(digest(content), 0, frame, content.length, 32);
        if (frame.length > MAX_FRAME_BYTES) throw new IOException("Script receipt exceeds frame limit");
        return frame;
    }

    private static void writeValue(DataOutputStream out, String value) throws IOException {
        if (value == null) { out.writeInt(-1); return; }
        byte[] bytes = value.getBytes(java.nio.charset.StandardCharsets.UTF_8);
        out.writeInt(bytes.length);
        out.write(bytes);
    }

    private static String readValue(DataInputStream input, int limit) throws IOException {
        int length = input.readInt();
        if (length == -1) return null;
        if (length < 0 || length > limit) throw new IOException("Script receipt value exceeds limit");
        byte[] bytes = new byte[length];
        input.readFully(bytes);
        try {
            return java.nio.charset.StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
                    .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes)).toString();
        } catch (java.nio.charset.CharacterCodingException invalid) {
            throw new IOException("Script receipt UTF-8 is invalid", invalid);
        }
    }

    private static byte[] digest(byte[] bytes) {
        try { return MessageDigest.getInstance("SHA-256").digest(bytes); }
        catch (NoSuchAlgorithmException failure) { throw new AssertionError(failure); }
    }

    private static void writeAll(FileChannel channel, byte[] bytes) throws IOException {
        ByteBuffer source = ByteBuffer.wrap(bytes);
        while (source.hasRemaining()) channel.write(source);
    }
}
