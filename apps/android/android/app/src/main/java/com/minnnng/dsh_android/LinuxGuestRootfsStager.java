package com.minnnng.dsh_android;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.PosixFilePermission;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.EnumSet;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.BooleanSupplier;
import java.util.zip.GZIPInputStream;

/**
 * Stages a pinned, data-only rootfs snapshot inside a directory owned by the isolated UID.
 * The caller must supply a trusted directory created by that UID, never an App or model path.
 * This class does not launch a process or authorize native guest execution.
 * It keeps only the owner execute bit of executable files in the pinned image;
 * all group, other-user and special mode bits are removed.
 */
final class LinuxGuestRootfsStager {
    private static final int MAX_ARCHIVE = 8 * 1024 * 1024;
    private static final int MAX_TAR = 32 * 1024 * 1024;
    private static final int MAX_ENTRY = 16 * 1024 * 1024;
    private static final int MAX_ENTRIES = 2048;
    private static final int BLOCK = 512;
    private static final Set<PosixFilePermission> DIRECTORY_MODE = EnumSet.of(
        PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE,
        PosixFilePermission.OWNER_EXECUTE);
    private static final Set<PosixFilePermission> FILE_MODE = EnumSet.of(
        PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE);
    private static final Set<PosixFilePermission> PUBLISHED_FILE_MODE = EnumSet.of(
        PosixFilePermission.OWNER_READ);
    private static final Set<PosixFilePermission> PUBLISHED_EXECUTABLE_FILE_MODE = EnumSet.of(
        PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_EXECUTE);
    private static final Set<PosixFilePermission> PUBLISHED_DIRECTORY_MODE = EnumSet.of(
        PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_EXECUTE);

    private record Entry(String name, char type, int offset, int size, String linkTarget,
                         boolean executable) {}

    @FunctionalInterface interface TreeRemover { void remove(Path directory) throws IOException; }

    static final class Staged implements AutoCloseable {
        private final Path directory;
        private final TreeRemover remover;
        private boolean closed;
        private Staged(Path directory) { this(directory, LinuxGuestRootfsStager::removeOwnedTree); }
        Staged(Path directory, TreeRemover remover) {
            this.directory = directory;
            this.remover = remover;
        }
        Path directory() { return directory; }
        @Override public synchronized void close() throws IOException {
            if (closed) return;
            remover.remove(directory);
            closed = true;
        }
    }

    static Staged stagePinned(ByteBuffer sealedArchive, Path isolatedOwnedParent,
                              String runId, BooleanSupplier cancelled) throws IOException {
        return stage(sealedArchive, isolatedOwnedParent, runId, cancelled,
            LinuxImageLeaseOwner.SHA256, LinuxImageLeaseOwner.ARCHIVE_BYTES);
    }

    // Package-private fixture seam. Production must call stagePinned with the source lock.
    static Staged stage(ByteBuffer sealedArchive, Path isolatedOwnedParent, String runId,
                        BooleanSupplier cancelled, String sha256, long archiveBytes)
                        throws IOException {
        if (sealedArchive == null || !sealedArchive.isReadOnly() ||
            isolatedOwnedParent == null || cancelled == null ||
            !validRunId(runId) ||
            !sha256.matches("[0-9a-f]{64}") || archiveBytes <= 0 ||
            archiveBytes > MAX_ARCHIVE || sealedArchive.remaining() != archiveBytes) {
            throw new IOException("Invalid isolated rootfs offer");
        }
        Path parent = isolatedOwnedParent.toAbsolutePath().normalize();
        if (!Files.isDirectory(parent, LinkOption.NOFOLLOW_LINKS) ||
            Files.isSymbolicLink(parent)) throw new IOException("Untrusted guest staging parent");
        if (!Files.getFileStore(parent).supportsFileAttributeView("posix") &&
            !System.getProperty("os.name", "").startsWith("Windows")) {
            throw new IOException("Guest staging requires POSIX file permissions");
        }
        byte[] compressed = new byte[(int) archiveBytes];
        sealedArchive.slice().get(compressed);
        if (!ImageDigestHex.encode(sha256(compressed)).equals(sha256)) {
            throw new IOException("Pinned rootfs digest changed");
        }
        checkCancelled(cancelled);
        byte[] tar = inflateBounded(compressed, cancelled);
        List<Entry> entries = validateTar(tar);
        checkCancelled(cancelled);
        Path published = parent.resolve(runId);
        Path staging = parent.resolve(".staging-" + runId);
        if (Files.exists(published, LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException("Rootfs run already exists");
        }
        Files.createDirectory(staging);
        boolean staged = true;
        try {
            setMode(staging, DIRECTORY_MODE);
            // Directories and regular files are materialized before any symlink exists.
            List<Entry> directories = new ArrayList<>();
            for (Entry entry : entries) if (entry.type == '5' && !entry.name.isEmpty()) {
                directories.add(entry);
            }
            directories.sort(Comparator.comparingInt(entry ->
                entry.name.length() - entry.name.replace("/", "").length()));
            for (Entry entry : directories) {
                checkCancelled(cancelled);
                Path dest = staging.resolve(entry.name);
                Files.createDirectory(dest);
                setMode(dest, DIRECTORY_MODE);
            }
            for (Entry entry : entries) {
                checkCancelled(cancelled);
                if (entry.type == '0') {
                    Path dest = staging.resolve(entry.name);
                    try (var output = Files.newOutputStream(dest, StandardOpenOption.CREATE_NEW,
                            StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS)) {
                        output.write(tar, entry.offset, entry.size);
                    }
                    setMode(dest, FILE_MODE);
                }
            }
            for (Entry entry : entries) {
                checkCancelled(cancelled);
                if (entry.type == '2') {
                    Files.createSymbolicLink(staging.resolve(entry.name), Paths.get(entry.linkTarget));
                }
            }
            // Read-only publication is advisory for this UID; isolation is the security boundary.
            // Preserve owner execution for pinned ELF/script files while stripping special bits.
            for (Entry entry : entries) {
                if (entry.type == '0') setMode(
                    staging.resolve(entry.name), entry.executable
                        ? PUBLISHED_EXECUTABLE_FILE_MODE : PUBLISHED_FILE_MODE);
            }
            for (int index = directories.size() - 1; index >= 0; index--) {
                Entry entry = directories.get(index);
                setMode(
                    staging.resolve(entry.name), PUBLISHED_DIRECTORY_MODE);
            }
            setMode(staging, PUBLISHED_DIRECTORY_MODE);
            checkCancelled(cancelled);
            if (Files.exists(published, LinkOption.NOFOLLOW_LINKS)) {
                throw new IOException("Rootfs run appeared during staging");
            }
            try {
                Files.move(staging, published, StandardCopyOption.ATOMIC_MOVE);
            } catch (AtomicMoveNotSupportedException unsupported) {
                throw new IOException("Atomic guest rootfs publication unavailable", unsupported);
            }
            staged = false;
            return new Staged(published);
        } finally {
            if (staged) removeOwnedTree(staging);
        }
    }

    private static byte[] inflateBounded(byte[] compressed, BooleanSupplier cancelled)
            throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        try (GZIPInputStream gzip = new GZIPInputStream(new ByteArrayInputStream(compressed))) {
            byte[] chunk = new byte[64 * 1024];
            int read;
            while ((read = gzip.read(chunk)) != -1) {
                checkCancelled(cancelled);
                if (read == 0) continue;
                if (output.size() > MAX_TAR - read) throw new IOException("Rootfs tar exceeds limit");
                output.write(chunk, 0, read);
            }
        }
        return output.toByteArray();
    }

    private static List<Entry> validateTar(byte[] tar) throws IOException {
        if (tar.length % BLOCK != 0) throw new IOException("Rootfs tar is not block aligned");
        List<Entry> entries = new ArrayList<>();
        Map<String, Character> kinds = new HashMap<>();
        int cursor = 0;
        boolean ended = false;
        while (cursor + BLOCK <= tar.length) {
            if (zeroBlock(tar, cursor)) { ended = true; break; }
            if (entries.size() == MAX_ENTRIES) throw new IOException("Rootfs has too many entries");
            int checksum = (int) octal(tar, cursor + 148, 8);
            int actual = 0;
            for (int i = 0; i < BLOCK; i++) {
                actual += i >= 148 && i < 156 ? 32 : tar[cursor + i] & 0xff;
            }
            if (checksum != actual || !ascii(tar, cursor + 257, 6).startsWith("ustar")) {
                throw new IOException("Rootfs tar header rejected");
            }
            String name = ascii(tar, cursor, 100);
            String prefix = ascii(tar, cursor + 345, 155);
            if (!prefix.isEmpty()) name = prefix + "/" + name;
            name = safeName(name);
            char type = (char) (tar[cursor + 156] & 0xff);
            if (type == '\0') type = '0';
            if (type != '0' && type != '5' && type != '2') {
                throw new IOException("Rootfs tar entry type rejected");
            }
            long mode = octal(tar, cursor + 100, 8);
            if (mode > 07777) throw new IOException("Rootfs tar mode rejected");
            long size = octal(tar, cursor + 124, 12);
            if (size > MAX_ENTRY || ((type == '5' || type == '2') && size != 0)) {
                throw new IOException("Rootfs tar entry size rejected");
            }
            String link = type == '2' ? safeLink(name, ascii(tar, cursor + 157, 100)) : "";
            long padded = ((size + BLOCK - 1) / BLOCK) * BLOCK;
            long end = (long) cursor + BLOCK + padded;
            if (end > tar.length) throw new IOException("Rootfs tar entry truncated");
            if (name.isEmpty() && type != '5') throw new IOException("Rootfs root is not a directory");
            if (kinds.putIfAbsent(name, type) != null) {
                throw new IOException("Duplicate rootfs member");
            }
            entries.add(new Entry(name, type, cursor + BLOCK, (int) size, link,
                    type == '0' && (mode & 0100) != 0));
            cursor = (int) end;
        }
        if (!ended || tar.length - cursor < BLOCK * 2) {
            throw new IOException("Rootfs tar has no end marker");
        }
        for (int i = cursor; i < tar.length; i++) {
            if (tar[i] != 0) throw new IOException("Rootfs tar has trailing data");
        }
        if (entries.isEmpty()) throw new IOException("Rootfs tar is empty");
        for (Entry entry : entries) {
            if (entry.name.isEmpty()) continue;
            int slash = entry.name.lastIndexOf('/');
            if (slash >= 0 && !Character.valueOf('5').equals(
                    kinds.get(entry.name.substring(0, slash)))) {
                throw new IOException("Rootfs member parent is not a directory");
            }
        }
        return entries;
    }

    /** Host-testable member-graph check; staging still requires an isolated-owned parent. */
    static int inspectTar(byte[] tar) throws IOException { return validateTar(tar).size(); }

    /** Host inspection of the pinned image's executable regular files. */
    static List<String> inspectExecutableFiles(byte[] tar) throws IOException {
        List<String> names = new ArrayList<>();
        for (Entry entry : validateTar(tar)) if (entry.executable) names.add(entry.name);
        return names;
    }

    private static String safeName(String input) throws IOException {
        if (input.equals(".") || input.equals("./")) return "";
        while (input.startsWith("./")) input = input.substring(2);
        if (input.endsWith("/")) input = input.substring(0, input.length() - 1);
        if (input.isEmpty() || input.startsWith("/") || input.indexOf('\\') >= 0 ||
            input.length() > 255) throw new IOException("Rootfs member path rejected");
        for (String part : input.split("/", -1)) {
            if (part.isEmpty() || part.equals(".") || part.equals("..") || part.length() > 100) {
                throw new IOException("Rootfs member traversal rejected");
            }
        }
        return input;
    }

    /** Rewrite guest-absolute targets to host-relative links within the staged root. */
    static String safeLink(String name, String raw) throws IOException {
        if (raw.isEmpty() || raw.indexOf('\\') >= 0 || raw.length() > 255) {
            throw new IOException("Rootfs symlink target rejected");
        }
        Path parent = Paths.get(name).getParent();
        if (parent == null) parent = Paths.get("");
        Path rootTarget = raw.startsWith("/") ? Paths.get(raw.substring(1)) : parent.resolve(raw);
        rootTarget = rootTarget.normalize();
        if (rootTarget.isAbsolute() || rootTarget.startsWith("..") ||
            rootTarget.toString().isEmpty()) throw new IOException("Rootfs symlink escapes root");
        String relative = parent.relativize(rootTarget).toString().replace('\\', '/');
        if (relative.isEmpty()) throw new IOException("Rootfs symlink target is empty");
        return relative;
    }

    private static String ascii(byte[] bytes, int offset, int length) throws IOException {
        int end = offset;
        while (end < offset + length && bytes[end] != 0) {
            int c = bytes[end] & 0xff;
            if (c < 32 || c > 126) throw new IOException("Rootfs tar text rejected");
            end++;
        }
        return new String(bytes, offset, end - offset, StandardCharsets.US_ASCII);
    }

    private static long octal(byte[] bytes, int offset, int length) throws IOException {
        String value = ascii(bytes, offset, length).trim();
        if (!value.matches("[0-7]+")) throw new IOException("Rootfs tar number rejected");
        try { return Long.parseLong(value, 8); }
        catch (NumberFormatException invalid) { throw new IOException("Rootfs tar number overflow", invalid); }
    }

    private static boolean zeroBlock(byte[] tar, int offset) {
        for (int i = 0; i < BLOCK; i++) if (tar[offset + i] != 0) return false;
        return true;
    }

    private static byte[] sha256(byte[] bytes) throws IOException {
        try { return MessageDigest.getInstance("SHA-256").digest(bytes); }
        catch (NoSuchAlgorithmException unavailable) { throw new IOException(unavailable); }
    }

    private static void checkCancelled(BooleanSupplier cancelled) throws IOException {
        if (cancelled.getAsBoolean() || Thread.currentThread().isInterrupted()) {
            throw new IOException("Rootfs staging cancelled");
        }
    }

    private static boolean validRunId(String runId) {
        if (runId == null) return false;
        try { return UUID.fromString(runId).toString().equals(runId); }
        catch (IllegalArgumentException invalid) { return false; }
    }

    private static void removeOwnedTree(Path directory) throws IOException {
        if (!Files.exists(directory, LinkOption.NOFOLLOW_LINKS)) return;
        List<Path> entries = new ArrayList<>();
        try (var paths = Files.walk(directory)) {
            paths.forEach(entries::add);
        }
        // Published directories are 0500. Restore 0700 before removing any child.
        for (Path path : entries) {
            if (Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS)) {
                setMode(path, DIRECTORY_MODE);
            } else if (!Files.isSymbolicLink(path)) {
                setMode(path, FILE_MODE);
            }
        }
        entries.sort(Comparator.reverseOrder());
        for (Path path : entries) {
            Files.delete(path);
        }
    }

    private static void setMode(Path path, Set<PosixFilePermission> mode) throws IOException {
        try { Files.setPosixFilePermissions(path, mode); }
        catch (UnsupportedOperationException unsupported) {
            // Host Windows tests exercise graph and cleanup. Android must fail closed.
            if (!System.getProperty("os.name", "").startsWith("Windows")) {
                throw new IOException("POSIX permissions unavailable", unsupported);
            }
        }
    }
}
