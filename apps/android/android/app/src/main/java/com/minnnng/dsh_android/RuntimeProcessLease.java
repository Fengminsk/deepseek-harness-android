package com.minnnng.dsh_android;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.channels.OverlappingFileLockException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;

/** App-private process marker. A dead process releases the lock but cannot clear the marker. */
public final class RuntimeProcessLease implements AutoCloseable {
    private static final String NAME = "agent-running-v1";
    private static final String LOCK_NAME = "agent-running-v1.lock";
    private final RandomAccessFile file;
    private final FileLock lock;
    private final File directory;
    private final long startedAtMillis;
    private boolean closed;

    private RuntimeProcessLease(RandomAccessFile file, FileLock lock, File directory, long startedAtMillis) {
        this.file = file;
        this.lock = lock;
        this.directory = directory;
        this.startedAtMillis = startedAtMillis;
    }

    /** Must finish before Node is admitted; an orphan is recorded, never restarted. */
    public static RuntimeProcessLease start(File directory, long startedAtMillis) throws IOException {
        if (startedAtMillis <= 0 || startedAtMillis == Long.MAX_VALUE)
            throw new IllegalArgumentException("Invalid runtime start time");
        // Keep the lock inode stable. The marker is replaced atomically so a kill
        // during its write cannot leave a truncated lease that blocks every boot.
        RandomAccessFile file = new RandomAccessFile(new File(directory, LOCK_NAME), "rw");
        FileLock lock = null;
        try {
            lock = file.getChannel().tryLock();
            if (lock == null) throw new IOException("Another runtime process owns the lease");
            cleanUnpublishedMarkers(directory);
            Long previous = readMarker(directory);
            RuntimeInterruptionRecord receipt = RuntimeInterruptionRecord.read(directory);
            if (receipt != null && receipt.timeMillis == Long.MAX_VALUE)
                throw new IOException("Invalid prior runtime interruption time");
            if (previous != null) {
                if (receipt == null || receipt.timeMillis < previous) {
                    RuntimeInterruptionRecord.write(directory, RuntimeInterruptionRecord.RUNTIME_LOST,
                            Math.max(startedAtMillis, previous + 1));
                    receipt = RuntimeInterruptionRecord.read(directory);
                }
            }
            long generationTime = receipt == null ? startedAtMillis
                    : Math.max(startedAtMillis, receipt.timeMillis + 1);
            writeMarker(directory, generationTime);
            return new RuntimeProcessLease(file, lock, directory, generationTime);
        } catch (IOException | RuntimeException failure) {
            try { if (lock != null) lock.release(); }
            finally { file.close(); }
            throw failure;
        }
    }

    /** Returns null while a process still owns the lease or no Node was admitted. */
    public static Long orphanedStart(File directory) throws IOException {
        File marker = new File(directory, NAME);
        if (!marker.exists()) return null;
        try (RandomAccessFile file = new RandomAccessFile(new File(directory, LOCK_NAME), "rw")) {
            FileLock lock;
            try { lock = file.getChannel().tryLock(); }
            catch (OverlappingFileLockException activeInThisProcess) { return null; }
            if (lock == null) return null;
            try (FileLock ignored = lock) { return readMarker(directory); }
        }
    }

    /** A committed replacement clears the marker but retains the lease until process exit. */
    public synchronized void preparePlannedProcessExit() throws IOException {
        if (closed) throw new IOException("Runtime process lease was already released");
        writeMarker(directory, null);
    }

    /** Releases a lease after an already quiescent runtime has stopped. */
    public synchronized void closePlanned() throws IOException {
        if (closed) return;
        try { preparePlannedProcessExit(); }
        finally { close(); }
    }

    /** Keep an interruption receipt newer than this generation even if wall time moves backwards. */
    public long interruptionTime(long nowMillis) {
        return Math.max(nowMillis, startedAtMillis + 1);
    }

    /** Process death implicitly performs this release; the marker intentionally remains. */
    @Override public synchronized void close() throws IOException {
        if (closed) return;
        closed = true;
        try { lock.release(); }
        finally { file.close(); }
    }

    private static Long readMarker(File directory) throws IOException {
        File marker = new File(directory, NAME);
        if (!marker.exists()) return null;
        long size = marker.length();
        if (size == 0) return null;
        if (size > 64) throw new IOException("Invalid runtime process marker");
        ByteBuffer bytes = ByteBuffer.allocate((int) size);
        try (FileChannel channel = FileChannel.open(marker.toPath())) {
            while (bytes.hasRemaining()) {
                if (channel.read(bytes) < 0) throw new IOException("Incomplete runtime process marker");
            }
        }
        String text = new String(bytes.array(), StandardCharsets.UTF_8);
        if (!text.startsWith("1\n") || !text.endsWith("\n")) {
            throw new IOException("Invalid runtime process marker");
        }
        String number = text.substring(2, text.length() - 1);
        try {
            long value = Long.parseLong(number);
            if (value <= 0 || value == Long.MAX_VALUE || !Long.toString(value).equals(number)) {
                throw new IOException("Invalid runtime process marker");
            }
            return value;
        } catch (NumberFormatException invalid) {
            throw new IOException("Invalid runtime process marker", invalid);
        }
    }

    private static void writeMarker(File directory, Long timeMillis) throws IOException {
        File marker = new File(directory, NAME);
        if (timeMillis == null) {
            Files.deleteIfExists(marker.toPath());
            return;
        }
        File temporary = File.createTempFile(NAME + "-", ".tmp", directory);
        try {
            byte[] bytes = ("1\n" + timeMillis + "\n").getBytes(StandardCharsets.UTF_8);
            try (FileOutputStream output = new FileOutputStream(temporary)) {
                output.write(bytes);
                output.getFD().sync();
            }
            Files.move(temporary.toPath(), marker.toPath(),
                    StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } finally {
            Files.deleteIfExists(temporary.toPath());
        }
    }

    private static void cleanUnpublishedMarkers(File directory) throws IOException {
        File[] files = directory.listFiles();
        if (files == null) throw new IOException("Could not inspect runtime process marker directory");
        for (File entry : files) {
            if (entry.getName().startsWith(NAME + "-") && entry.getName().endsWith(".tmp")) {
                Files.deleteIfExists(entry.toPath());
            }
        }
    }
}
