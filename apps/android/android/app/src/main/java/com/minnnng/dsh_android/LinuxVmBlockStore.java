package com.minnnng.dsh_android;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ReadOnlyBufferException;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;
import java.util.TreeMap;
import java.util.concurrent.CancellationException;
import java.util.function.BooleanSupplier;

/**
 * Immutable, synced 64 KiB content blocks for one private guest disk store.
 * Callers retain exclusive access to buffer bytes during each operation and own
 * directory fsync, manifest publication and lifetime. Unpublished blocks are kept.
 * Buffer position/limit are preserved; the disk spans byte zero through limit.
 */
final class LinuxVmBlockStore {
    static final int BLOCK_BYTES = 64 * 1024;
    static final int MAX_BYTES = 256 * 1024 * 1024;
    private static final Object JVM_PUBLISH_LOCK = new Object();
    private final Path directory;

    LinuxVmBlockStore(File directory) throws IOException {
        this.directory = Objects.requireNonNull(directory, "directory").toPath().toAbsolutePath().normalize();
        Files.createDirectories(this.directory);
        requireDirectory();
    }

    /** Hash every block, including an exact-length final block, without disk I/O. */
    Map<Integer, String> hashes(ByteBuffer buffer) {
        ByteBuffer input = disk(buffer);
        Map<Integer, String> result = new LinkedHashMap<>();
        for (int index = 0; index < blockCount(input.limit()); index++) {
            result.put(index, hash(readBuffer(input, index)));
        }
        return Collections.unmodifiableMap(result);
    }

    /**
     * Return the complete difference from the supplied full baseline. Reverting a
     * block to baseline omits it from the result. Failure returns no manifest;
     * earlier synced blocks may remain unreferenced. Existing block files must
     * validate even when another store or process published them first.
     */
    Map<Integer, String> capture(ByteBuffer buffer, Map<Integer, String> baseHashes) throws IOException {
        return capture(buffer, baseHashes, () -> false);
    }

    /** Cancellation stops before the next block and before returning a manifest; synced orphan blocks remain. */
    Map<Integer, String> capture(ByteBuffer buffer, Map<Integer, String> baseHashes,
                                BooleanSupplier cancelled) throws IOException {
        Objects.requireNonNull(cancelled, "cancelled");
        ByteBuffer input = disk(buffer);
        Map<Integer, String> baseline = manifest(baseHashes, input.limit(), true);
        Map<Integer, String> result = new LinkedHashMap<>();
        for (int index = 0; index < blockCount(input.limit()); index++) {
            if (cancelled.getAsBoolean()) throw new CancellationException("Linux VM block capture was cancelled");
            byte[] bytes = readBuffer(input, index);
            String checksum = hash(bytes);
            if (!checksum.equals(baseline.get(index))) {
                publish(checksum, bytes);
                result.put(index, checksum);
            }
        }
        if (cancelled.getAsBoolean()) throw new CancellationException("Linux VM block capture was cancelled");
        return Collections.unmodifiableMap(result);
    }

    /**
     * Validate the entire manifest and its files before writing, then recheck each
     * file when applying it with at most one block of scratch memory. Any I/O
     * failure during application requires the caller to discard this buffer;
     * this method never publishes a durable disk pointer. Read-only targets fail
     * before file access, including for an empty manifest.
     */
    void overlay(ByteBuffer buffer, Map<Integer, String> blocks) throws IOException {
        if (Objects.requireNonNull(buffer, "buffer").isReadOnly()) throw new ReadOnlyBufferException();
        ByteBuffer target = disk(buffer);
        Map<Integer, String> checked = manifest(blocks, target.limit(), false);
        requireDirectory();
        for (Map.Entry<Integer, String> entry : checked.entrySet()) {
            readBlock(entry.getValue(), blockLength(target.limit(), entry.getKey()));
        }
        for (Map.Entry<Integer, String> entry : checked.entrySet()) {
            byte[] bytes = readBlock(entry.getValue(), blockLength(target.limit(), entry.getKey()));
            target.position(entry.getKey() * BLOCK_BYTES);
            target.put(bytes);
        }
    }

    private void publish(String checksum, byte[] bytes) throws IOException {
        // The JVM monitor prevents OverlappingFileLockException between store
        // instances; the file lock covers independent App processes as well.
        synchronized (JVM_PUBLISH_LOCK) {
            requireDirectory();
            try (FileChannel channel = FileChannel.open(directory.resolve(".publish.lock"),
                    StandardOpenOption.CREATE, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS);
                 FileLock ignored = channel.lock()) {
                Path target = blockPath(checksum);
                if (Files.exists(target, LinkOption.NOFOLLOW_LINKS)) {
                    readBlock(checksum, bytes.length);
                    return;
                }
                Path temporary = Files.createTempFile(directory, ".block-", ".tmp");
                try {
                    try (FileOutputStream output = new FileOutputStream(temporary.toFile())) {
                        output.write(bytes);
                        output.getFD().sync();
                    }
                    Files.move(temporary, target, StandardCopyOption.ATOMIC_MOVE);
                    readBlock(checksum, bytes.length);
                } finally {
                    Files.deleteIfExists(temporary);
                }
            }
        }
    }

    private byte[] readBlock(String checksum, int length) throws IOException {
        Path path = blockPath(checksum);
        BasicFileAttributes attributes = Files.readAttributes(path, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
        if (!attributes.isRegularFile() || attributes.size() != length) {
            throw new IOException("Invalid Linux VM block type or length: " + checksum);
        }
        byte[] bytes = new byte[length];
        try (FileChannel channel = FileChannel.open(path, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS)) {
            if (channel.size() != length) throw new IOException("Linux VM block length changed: " + checksum);
            ByteBuffer destination = ByteBuffer.wrap(bytes);
            while (destination.hasRemaining()) {
                if (channel.read(destination) < 0) throw new IOException("Truncated Linux VM block: " + checksum);
            }
            if (channel.read(ByteBuffer.allocate(1)) != -1) throw new IOException("Linux VM block grew: " + checksum);
        }
        if (!hash(bytes).equals(checksum)) throw new IOException("Linux VM block checksum differs: " + checksum);
        return bytes;
    }

    private void requireDirectory() throws IOException {
        if (!Files.isDirectory(directory, LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException("Linux VM block store is not a private directory");
        }
    }

    private Path blockPath(String checksum) {
        return directory.resolve("block-" + checksum + ".bin");
    }

    private static ByteBuffer disk(ByteBuffer buffer) {
        Objects.requireNonNull(buffer, "buffer");
        if (buffer.limit() > MAX_BYTES) throw new IllegalArgumentException("Linux VM disk exceeds 256 MiB");
        ByteBuffer duplicate = buffer.duplicate();
        duplicate.position(0);
        return duplicate;
    }

    private static int blockCount(int limit) {
        return (limit + BLOCK_BYTES - 1) / BLOCK_BYTES;
    }

    private static int blockLength(int limit, int index) {
        return Math.min(BLOCK_BYTES, limit - index * BLOCK_BYTES);
    }

    private static byte[] readBuffer(ByteBuffer buffer, int index) {
        byte[] bytes = new byte[blockLength(buffer.limit(), index)];
        buffer.position(index * BLOCK_BYTES);
        buffer.get(bytes);
        return bytes;
    }

    private static Map<Integer, String> manifest(Map<Integer, String> supplied, int limit, boolean full) {
        Objects.requireNonNull(supplied, "blocks");
        int count = blockCount(limit);
        if (supplied.size() > count || (full && supplied.size() != count)) {
            throw new IllegalArgumentException("Linux VM block manifest count differs");
        }
        Map<Integer, String> result = new TreeMap<>();
        for (Map.Entry<Integer, String> entry : supplied.entrySet()) {
            Integer index = entry.getKey();
            String checksum = entry.getValue();
            if (index == null || index < 0 || index >= count || checksum == null || !checksum.matches("[0-9a-f]{64}")) {
                throw new IllegalArgumentException("Invalid Linux VM block index or checksum");
            }
            result.put(index, checksum);
        }
        if (full && result.size() != count) throw new IllegalArgumentException("Incomplete Linux VM baseline");
        return result;
    }

    private static String hash(byte[] bytes) {
        final byte[] digest;
        try { digest = MessageDigest.getInstance("SHA-256").digest(bytes); }
        catch (NoSuchAlgorithmException error) { throw new AssertionError(error); }
        char[] hex = new char[digest.length * 2];
        char[] alphabet = "0123456789abcdef".toCharArray();
        for (int i = 0; i < digest.length; i++) {
            hex[i * 2] = alphabet[(digest[i] >>> 4) & 15];
            hex[i * 2 + 1] = alphabet[digest[i] & 15];
        }
        return new String(hex);
    }
}
