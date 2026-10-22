package com.minnnng.dsh_android;

import java.io.File;
import java.io.IOException;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.channels.OverlappingFileLockException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.StandardOpenOption;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

/** Cross-process ownership for temporary attachment copies, separate from durable DSH attachments. */
public final class AttachmentCacheLease implements AutoCloseable {
    // Java forbids overlapping locks even when both are shared. Reuse one lock per JVM and count owners.
    private static final Map<String, Shared> HELD = new HashMap<>();
    private static final class Shared {
        final FileChannel channel;
        final FileLock lock;
        int references = 1;
        Shared(FileChannel channel, FileLock lock) { this.channel = channel; this.lock = lock; }
    }
    private final File directory;
    private final String key;
    private boolean closed;

    private AttachmentCacheLease(File directory, String key) { this.directory = directory; this.key = key; }
    public File directory() { return directory; }
    public String instance() { return directory.getName(); }

    /** The service holds this lease until its Node instance actually stops, or process death releases it. */
    public static AttachmentCacheLease create(File root) throws IOException {
        File instance = new File(root.getCanonicalFile(), UUID.randomUUID().toString());
        if (!instance.mkdir()) throw new IOException("无法创建附件实例目录");
        File marker = new File(instance, ".lease");
        Files.createFile(marker.toPath());
        AttachmentCacheLease lease = acquire(root, instance.getName());
        try { collect(root); }
        catch (IOException ignored) { /* Uncollected copies stay private and a later instance can retry. */ }
        return lease;
    }

    public static AttachmentCacheLease acquire(File root, String instance) throws IOException {
        AttachmentFileCache.validateId(instance);
        File directory = new File(root.getCanonicalFile(), instance);
        if (!directory.getCanonicalFile().equals(directory.getAbsoluteFile())
                || !Files.isDirectory(directory.toPath(), LinkOption.NOFOLLOW_LINKS)) throw new IOException("附件实例已失效");
        File marker = new File(directory, ".lease");
        String key = marker.getAbsolutePath();
        synchronized (HELD) {
            Shared existing = HELD.get(key);
            if (existing != null) {
                existing.references++;
                return new AttachmentCacheLease(directory, key);
            }
            FileChannel channel = FileChannel.open(marker.toPath(), StandardOpenOption.READ, StandardOpenOption.WRITE,
                    LinkOption.NOFOLLOW_LINKS);
            try {
                FileLock lock = channel.tryLock(0, Long.MAX_VALUE, true);
                if (lock == null) throw new IOException("附件实例正在清理，请重新打开");
                HELD.put(key, new Shared(channel, lock));
                return new AttachmentCacheLease(directory, key);
            } catch (IOException | RuntimeException failure) {
                channel.close();
                throw failure;
            }
        }
    }

    /** No recursion: unknown names, directories and symlinks are preserved, including unknown roots. */
    public static void collect(File root) throws IOException {
        File canonicalRoot = root.getCanonicalFile();
        File[] directories = canonicalRoot.listFiles();
        if (directories == null) throw new IOException("无法读取附件缓存目录");
        for (File directory : directories) {
            try { AttachmentFileCache.validateId(directory.getName()); }
            catch (IllegalArgumentException unknown) { continue; }
            if (!Files.isDirectory(directory.toPath(), LinkOption.NOFOLLOW_LINKS)
                    || !directory.getCanonicalFile().equals(directory.getAbsoluteFile())) continue;
            File marker = new File(directory, ".lease");
            if (!Files.isRegularFile(marker.toPath(), LinkOption.NOFOLLOW_LINKS)) continue;
            synchronized (HELD) {
                if (HELD.containsKey(marker.getAbsolutePath())) continue;
                try (FileChannel channel = FileChannel.open(marker.toPath(), StandardOpenOption.READ,
                        StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS)) {
                    FileLock lock;
                    try { lock = channel.tryLock(); }
                    catch (OverlappingFileLockException inUse) { continue; }
                    if (lock == null) continue;
                    try (lock) {
                        File[] files = directory.listFiles();
                        if (files == null) continue;
                        for (File file : files) {
                            String name = file.getName();
                            String id = name.endsWith(".partial") ? name.substring(0, name.length() - 8)
                                    : name.endsWith(".file") ? name.substring(0, name.length() - 5)
                                    : name.startsWith(".pocket-publish-") ? name.substring(16) : "";
                            try { AttachmentFileCache.validateId(id); }
                            catch (IllegalArgumentException unknown) { continue; }
                            if (Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS)) Files.deleteIfExists(file.toPath());
                        }
                    }
                }
                File[] remaining = directory.listFiles();
                if (remaining != null && remaining.length == 1 && remaining[0].getName().equals(".lease")) {
                    // A late opener cannot obtain useful source bytes: known files were removed under the exclusive lock.
                    Files.deleteIfExists(marker.toPath());
                    Files.deleteIfExists(directory.toPath());
                }
            }
        }
    }

    @Override public void close() throws IOException {
        synchronized (HELD) {
            if (closed) return;
            closed = true;
            Shared shared = HELD.get(key);
            if (shared != null && --shared.references == 0) {
                HELD.remove(key);
                try { shared.lock.release(); }
                finally { shared.channel.close(); }
            }
        }
    }
}
