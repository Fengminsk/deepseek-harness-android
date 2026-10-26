package com.minnnng.dsh_android;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InterruptedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.StandardCopyOption;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.UUID;

/** Bounded, immutable, app-private copy for one SAF document read sequence. */
public final class DocumentSnapshotStore {
    public interface Reader<T> { T read() throws IOException; }
    public interface Source {
        void check() throws IOException;
        InputStream open() throws IOException;
    }

    public static final long MAX_FILE_BYTES = 256L * 1024 * 1024;
    public static final long MAX_CACHE_BYTES = 512L * 1024 * 1024;
    public static final long TTL_MILLIS = 30L * 60 * 1000;
    public static final int MAX_ENTRIES = 8;
    private static final long MIN_FREE_BYTES = 128L * 1024 * 1024;
    private static final Object LOCK = new Object();
    private final File directory;
    private final long maxFileBytes, maxCacheBytes, ttlMillis, minFreeBytes;

    public DocumentSnapshotStore(File appCacheDirectory) {
        this(appCacheDirectory, MAX_FILE_BYTES, MAX_CACHE_BYTES, TTL_MILLIS, MIN_FREE_BYTES);
    }

    DocumentSnapshotStore(File appCacheDirectory, long maxFileBytes, long maxCacheBytes, long ttlMillis, long minFreeBytes) {
        directory = new File(appCacheDirectory, "document-read-snapshots");
        this.maxFileBytes = maxFileBytes;
        this.maxCacheBytes = maxCacheBytes;
        this.ttlMillis = ttlMillis;
        this.minFreeBytes = minFreeBytes;
    }

    public static final class Snapshot {
        public final File file;
        public final String version;
        private Snapshot(File file, String version) { this.file = file; this.version = version; }
    }

    /** Copies once, then reopens the provider once to reject edits occurring during capture. */
    public Snapshot create(String identity, String metadataVersion, Source source) throws IOException {
        validateToken(identity);
        validateToken(metadataVersion);
        synchronized (LOCK) {
            prepare();
            // Reserve room before writing so the temporary copy cannot take the committed
            // 512 MiB cache above its cap while a large provider stream is still arriving.
            ensureRoom(Math.min(maxFileBytes, maxCacheBytes), new File(directory, ".pending"));
            Path temporary = new File(directory, ".part-" + UUID.randomUUID()).toPath();
            Path temporaryInfo = new File(directory, ".part-" + UUID.randomUUID()).toPath();
            try {
                MessageDigest first = sha256();
                long length = 0;
                long nextCheck = 1024 * 1024;
                source.check();
                try (InputStream input = requireStream(source.open()); FileOutputStream output = new FileOutputStream(temporary.toFile())) {
                    byte[] buffer = new byte[64 * 1024];
                    for (int count; (count = input.read(buffer)) != -1;) {
                        if (count == 0) {
                            int single = input.read();
                            if (single == -1) break;
                            buffer[0] = (byte) single;
                            count = 1;
                        }
                        length += count;
                        if (length >= nextCheck) { source.check(); nextCheck = length + 1024 * 1024; }
                        if (length > maxFileBytes) throw new IOException("文件超过 256 MiB 稳定阅读上限，请选择较小的文件");
                        if (directory.getUsableSpace() < minFreeBytes) throw new IOException("设备缓存空间不足，无法建立稳定阅读副本");
                        first.update(buffer, 0, count);
                        output.write(buffer, 0, count);
                    }
                    output.getFD().sync();
                }
                source.check();
                MessageDigest second = sha256();
                long verifiedLength = 0;
                nextCheck = 1024 * 1024;
                try (InputStream input = requireStream(source.open())) {
                    byte[] buffer = new byte[64 * 1024];
                    for (int count; (count = input.read(buffer)) != -1;) {
                        if (count == 0) {
                            int single = input.read();
                            if (single == -1) break;
                            buffer[0] = (byte) single;
                            count = 1;
                        }
                        verifiedLength += count;
                        if (verifiedLength >= nextCheck) { source.check(); nextCheck = verifiedLength + 1024 * 1024; }
                        if (verifiedLength > maxFileBytes) throw new IOException("文件超过 256 MiB 稳定阅读上限，请选择较小的文件");
                        second.update(buffer, 0, count);
                    }
                }
                source.check();
                String hash = hex(first.digest());
                if (verifiedLength != length || !hash.equals(hex(second.digest()))) {
                    throw new IOException("文件在建立稳定副本时发生变化，请从头重新读取");
                }
                String version = DocumentRevision.token(identity, metadataVersion, hash, length, null);
                File destination = new File(directory, version + ".bin");
                File info = new File(directory, version + ".meta");
                ensureRoom(length, destination);
                Files.write(temporaryInfo, (identity + "\n" + metadataVersion + "\n" + length + "\n" + hash + "\n").getBytes(StandardCharsets.US_ASCII));
                publish(temporary, destination.toPath());
                publish(temporaryInfo, info.toPath());
                destination.setLastModified(System.currentTimeMillis());
                info.setLastModified(destination.lastModified());
                return new Snapshot(destination, version);
            } finally {
                Files.deleteIfExists(temporary);
                Files.deleteIfExists(temporaryInfo);
            }
        }
    }

    /** Metadata identity and the grant are checked by the caller before and after reading this file. */
    public Snapshot get(String identity, String metadataVersion, String version) throws IOException {
        validateToken(identity);
        validateToken(metadataVersion);
        validateToken(version);
        synchronized (LOCK) {
            prepare();
            File file = new File(directory, version + ".bin");
            File info = new File(directory, version + ".meta");
            if (!file.isFile() || Files.isSymbolicLink(file.toPath()) || file.length() > maxFileBytes ||
                    !info.isFile() || Files.isSymbolicLink(info.toPath()) || info.length() > 256) {
                throw new IOException("文件稳定阅读副本已过期，请从头重新读取");
            }
            // This is app-private cache storage. The manifest binds a snapshot to the exact
            // grant/path/provider identity without rescanning up to 256 MiB on every page.
            String[] parts = new String(Files.readAllBytes(info.toPath()), StandardCharsets.US_ASCII).split("\n");
            if (parts.length != 4 || !identity.equals(parts[0]) || !metadataVersion.equals(parts[1]) ||
                    !Long.toString(file.length()).equals(parts[2]) || !parts[3].matches("[0-9a-f]{64}")) {
                throw new IOException("文件稳定阅读副本已变化，请从头重新读取");
            }
            String actual = DocumentRevision.token(identity, metadataVersion, parts[3], file.length(), null);
            if (!actual.equals(version)) throw new IOException("文件稳定阅读副本已变化，请从头重新读取");
            file.setLastModified(System.currentTimeMillis());
            info.setLastModified(file.lastModified());
            return new Snapshot(file, version);
        }
    }

    /** Keep a page's file open/use and cache eviction in one process-wide critical section. */
    public <T> T withPinnedSnapshot(Snapshot snapshot, Reader<T> reader) throws IOException {
        synchronized (LOCK) {
            if (!snapshot.file.isFile() || Files.isSymbolicLink(snapshot.file.toPath())) {
                throw new IOException("文件稳定阅读副本已过期，请从头重新读取");
            }
            return reader.read();
        }
    }

    private void prepare() throws IOException {
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("无法创建文件阅读缓存");
        if (Files.isSymbolicLink(directory.toPath())) throw new IOException("文件阅读缓存路径无效");
        long now = System.currentTimeMillis();
        File[] files = directory.listFiles();
        if (files == null) throw new IOException("无法读取文件阅读缓存");
        for (File file : files) {
            if (file.getName().startsWith(".part-") ||
                    file.getName().matches("[0-9a-f]{64}\\.(bin|meta)") &&
                    (Files.isSymbolicLink(file.toPath()) || now - file.lastModified() > ttlMillis)) {
                Files.deleteIfExists(file.toPath());
            }
        }
        for (File file : files) {
            String name = file.getName();
            if (!name.matches("[0-9a-f]{64}\\.(bin|meta)")) continue;
            String sibling = name.endsWith(".bin") ? name.replace(".bin", ".meta") : name.replace(".meta", ".bin");
            if (!new File(directory, sibling).isFile()) Files.deleteIfExists(file.toPath());
        }
    }

    private void ensureRoom(long incoming, File replacement) throws IOException {
        ArrayList<File> files = new ArrayList<>();
        long total = incoming;
        File[] listed = directory.listFiles();
        if (listed == null) throw new IOException("无法读取文件阅读缓存");
        for (File file : listed) {
            if (file.equals(replacement) || !file.isFile() || !file.getName().matches("[0-9a-f]{64}\\.bin")) continue;
            files.add(file);
            total += file.length();
        }
        files.sort(Comparator.comparingLong(File::lastModified));
        int count = files.size() + 1;
        for (File file : files) {
            if (total <= maxCacheBytes && count <= MAX_ENTRIES) break;
            long size = file.length();
            Files.delete(file.toPath());
            Files.deleteIfExists(new File(directory, file.getName().replace(".bin", ".meta")).toPath());
            total -= size;
            count--;
        }
        if (total > maxCacheBytes) throw new IOException("文件阅读缓存已满，请稍后重试");
    }

    private static InputStream requireStream(InputStream stream) throws IOException {
        if (stream == null) throw new IOException("文件提供方暂不可用，请重试或重新授权");
        return stream;
    }
    private static void publish(Path source, Path destination) throws IOException {
        try { Files.move(source, destination, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE); }
        catch (AtomicMoveNotSupportedException unsupported) {
            Files.move(source, destination, StandardCopyOption.REPLACE_EXISTING);
        }
    }
    private static void validateToken(String value) {
        if (value == null || !value.matches("[0-9a-f]{64}")) throw new IllegalArgumentException("无效的文件版本，请从头重新读取");
    }
    private static MessageDigest sha256() {
        try { return MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException impossible) { throw new IllegalStateException(impossible); }
    }
    private static String hex(byte[] bytes) {
        StringBuilder result = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) {
            result.append(Character.forDigit((value >>> 4) & 15, 16));
            result.append(Character.forDigit(value & 15, 16));
        }
        return result.toString();
    }
}
