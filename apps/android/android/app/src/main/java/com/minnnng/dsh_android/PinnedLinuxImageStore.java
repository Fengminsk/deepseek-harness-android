package com.minnnng.dsh_android;

import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Set;
import java.util.UUID;

/** App-owned archive installation. The published archive is data, never executable authority. */
final class PinnedLinuxImageStore {
    static final String SOURCE_URL =
        "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/" +
        "alpine-minirootfs-3.24.3-aarch64.tar.gz";
    private static final String FORMAT = "pocket-linux-archive-v1";
    private static final String ARCHIVE = "image.tar.gz";
    private static final String RECEIPT = "receipt.txt";
    private static final String LOCK = "install.lock";
    private static final Object PROCESS_LOCK = new Object();
    private final Path root;
    private final String version;
    private final String sha256;
    private final long bytes;
    private final String sourceUrl;

    record Installed(Path directory, Path archive, String version, String sha256,
                     long bytes, boolean executable) { }

    PinnedLinuxImageStore(Path noBackupDirectory) {
        this(noBackupDirectory, LinuxImageLeaseOwner.VERSION,
            LinuxImageLeaseOwner.SHA256, LinuxImageLeaseOwner.ARCHIVE_BYTES, SOURCE_URL);
    }

    /** Package-local fixture identity; production always uses the reviewed source. */
    PinnedLinuxImageStore(Path noBackupDirectory, String version, String sha256,
                          long bytes, String sourceUrl) {
        if (noBackupDirectory == null || !noBackupDirectory.isAbsolute() ||
            version == null || !version.matches("[A-Za-z0-9][A-Za-z0-9._-]{0,63}") ||
            sha256 == null || !sha256.matches("[0-9a-f]{64}") ||
            bytes < 1 || bytes > 8L * 1024 * 1024 ||
            sourceUrl == null || !sourceUrl.startsWith("https://")) {
            throw new IllegalArgumentException("Pinned Linux image identity is invalid");
        }
        this.root = noBackupDirectory.toAbsolutePath().normalize().resolve("linux-userland");
        this.version = version;
        this.sha256 = sha256;
        this.bytes = bytes;
        this.sourceUrl = sourceUrl;
    }

    synchronized Installed inspect() throws IOException {
        return locked(() -> inspectPublished(false));
    }

    /** Reads exactly one pinned archive and atomically publishes a complete release. */
    synchronized Installed install(InputStream source) throws IOException {
        if (source == null) throw new IllegalArgumentException("Image input is required");
        return locked(() -> {
            Installed present = inspectPublished(false);
            if (present != null) return present;
            Path versions = root.resolve("versions");
            Path stage = versions.resolve(".staging-" + UUID.randomUUID());
            Files.createDirectory(stage);
            try {
                copyAndVerify(source, stage.resolve(ARCHIVE));
                writeReceipt(stage.resolve(RECEIPT));
                Path release = versions.resolve(sha256);
                if (Files.exists(release, LinkOption.NOFOLLOW_LINKS)) {
                    return inspectPublished(true);
                }
                // The two files are durable before visibility. Directory fsync is not
                // portable on Android, so sudden-power-loss durability is not claimed.
                Files.move(stage, release, StandardCopyOption.ATOMIC_MOVE);
                return inspectPublished(true);
            } finally {
                if (Files.exists(stage, LinkOption.NOFOLLOW_LINKS)) deleteStage(stage);
            }
        });
    }

    private interface Operation<T> { T run() throws IOException; }

    private <T> T locked(Operation<T> operation) throws IOException {
        synchronized (PROCESS_LOCK) {
            requirePlainDirectory(root.getParent());
            createPlainDirectory(root);
            Path versions = root.resolve("versions");
            createPlainDirectory(versions);
            Path lockPath = root.resolve(LOCK);
            if (Files.exists(lockPath, LinkOption.NOFOLLOW_LINKS) &&
                (Files.isSymbolicLink(lockPath) ||
                    !Files.isRegularFile(lockPath, LinkOption.NOFOLLOW_LINKS))) {
                throw new IOException("Linux image installation lock changed type");
            }
            try (FileChannel channel = FileChannel.open(lockPath, StandardOpenOption.CREATE,
                    StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS);
                 FileLock ignored = channel.lock()) {
                requirePlainDirectory(root);
                requirePlainDirectory(versions);
                retireAbandonedStages(versions);
                return operation.run();
            }
        }
    }

    private Installed inspectPublished(boolean required) throws IOException {
        Path release = root.resolve("versions").resolve(sha256);
        if (!Files.exists(release, LinkOption.NOFOLLOW_LINKS)) {
            if (required) throw new IOException("Pinned Linux archive publication is missing");
            return null;
        }
        requirePlainDirectory(release);
        try (DirectoryStream<Path> children = Files.newDirectoryStream(release)) {
            Set<String> seen = new java.util.HashSet<>();
            for (Path child : children) seen.add(child.getFileName().toString());
            if (seen.size() != 2 || !seen.contains(ARCHIVE) || !seen.contains(RECEIPT)) {
                throw new IOException("Pinned Linux archive release contains an unexpected entry");
            }
        }
        Path archive = release.resolve(ARCHIVE);
        verifyArchive(archive);
        Path receipt = release.resolve(RECEIPT);
        BasicFileAttributes receiptInfo = attributes(receipt);
        byte[] expectedReceipt = receiptText().getBytes(StandardCharsets.UTF_8);
        if (!receiptInfo.isRegularFile() || receiptInfo.size() != expectedReceipt.length ||
            !receiptMatches(receipt, receiptInfo, expectedReceipt)) {
            throw new IOException("Pinned Linux archive receipt changed");
        }
        return new Installed(release, archive, version, sha256, bytes, false);
    }

    private void copyAndVerify(InputStream source, Path destination) throws IOException {
        MessageDigest digest = digest();
        long copied = 0;
        try (FileChannel output = FileChannel.open(destination, StandardOpenOption.CREATE_NEW,
                StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS)) {
            byte[] buffer = new byte[64 * 1024];
            while (true) {
                int count = source.read(buffer);
                if (count < 0) break;
                if (count == 0) throw new IOException("Pinned Linux archive source stopped making progress");
                if (count > bytes - copied) throw new IOException("Pinned Linux archive exceeds byte limit");
                ByteBuffer chunk = ByteBuffer.wrap(buffer, 0, count);
                while (chunk.hasRemaining()) output.write(chunk);
                digest.update(buffer, 0, count);
                copied += count;
            }
            output.force(true);
        }
        if (copied != bytes || !sha256.equals(ImageDigestHex.encode(digest.digest()))) {
            throw new IOException("Pinned Linux archive size or SHA-256 mismatch");
        }
        verifyArchive(destination);
    }

    private void verifyArchive(Path archive) throws IOException {
        BasicFileAttributes before = attributes(archive);
        if (!before.isRegularFile() || before.size() != bytes) {
            throw new IOException("Pinned Linux archive size or type changed");
        }
        MessageDigest digest = digest();
        long counted = 0;
        try (FileChannel source = FileChannel.open(archive, StandardOpenOption.READ,
                LinkOption.NOFOLLOW_LINKS)) {
            ByteBuffer buffer = ByteBuffer.allocate(64 * 1024);
            while (source.read(buffer) != -1) {
                buffer.flip();
                counted += buffer.remaining();
                if (counted > bytes) throw new IOException("Pinned Linux archive grew");
                digest.update(buffer);
                buffer.clear();
            }
        }
        BasicFileAttributes after = attributes(archive);
        if (counted != bytes || after.size() != before.size() ||
            !after.lastModifiedTime().equals(before.lastModifiedTime()) ||
            (before.fileKey() != null && !before.fileKey().equals(after.fileKey())) ||
            !sha256.equals(ImageDigestHex.encode(digest.digest()))) {
            throw new IOException("Pinned Linux archive digest or identity changed");
        }
    }

    private void writeReceipt(Path receipt) throws IOException {
        byte[] value = receiptText().getBytes(StandardCharsets.UTF_8);
        try (FileChannel output = FileChannel.open(receipt, StandardOpenOption.CREATE_NEW,
                StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS)) {
            ByteBuffer data = ByteBuffer.wrap(value);
            while (data.hasRemaining()) output.write(data);
            output.force(true);
        }
    }

    private static boolean receiptMatches(Path receipt, BasicFileAttributes before,
                                          byte[] expected) throws IOException {
        ByteBuffer value = ByteBuffer.allocate(expected.length + 1);
        try (FileChannel input = FileChannel.open(receipt, StandardOpenOption.READ,
                LinkOption.NOFOLLOW_LINKS)) {
            while (value.hasRemaining() && input.read(value) != -1) { /* Bounded receipt. */ }
        }
        BasicFileAttributes after = attributes(receipt);
        if (!after.isRegularFile() || after.size() != before.size() ||
            !after.lastModifiedTime().equals(before.lastModifiedTime()) ||
            (before.fileKey() != null && !before.fileKey().equals(after.fileKey())) ||
            value.position() != expected.length) return false;
        value.flip();
        for (byte item : expected) if (value.get() != item) return false;
        return true;
    }

    private String receiptText() {
        return FORMAT + "\nversion=" + version + "\nabi=" + LinuxImageLeaseOwner.ABI +
            "\nsha256=" + sha256 + "\nbytes=" + bytes + "\nsource=" + sourceUrl +
            "\nlicenseReview=required\nexecutable=false\n";
    }

    private static void retireAbandonedStages(Path versions) throws IOException {
        try (DirectoryStream<Path> stages = Files.newDirectoryStream(versions, ".staging-*")) {
            for (Path stage : stages) {
                String name = stage.getFileName().toString();
                if (!validUuid(name.substring(".staging-".length()))) {
                    throw new IOException("Unknown Linux image staging entry");
                }
                deleteStage(stage);
            }
        }
    }

    private static void deleteStage(Path stage) throws IOException {
        requirePlainDirectory(stage);
        try (DirectoryStream<Path> children = Files.newDirectoryStream(stage)) {
            for (Path child : children) {
                String name = child.getFileName().toString();
                if ((!name.equals(ARCHIVE) && !name.equals(RECEIPT)) ||
                    !attributes(child).isRegularFile()) {
                    throw new IOException("Unknown Linux image staging content retained");
                }
                Files.delete(child);
            }
        }
        Files.delete(stage);
    }

    private static boolean validUuid(String value) {
        try { return UUID.fromString(value).toString().equals(value); }
        catch (IllegalArgumentException invalid) { return false; }
    }

    private static void createPlainDirectory(Path directory) throws IOException {
        if (!Files.exists(directory, LinkOption.NOFOLLOW_LINKS)) Files.createDirectory(directory);
        requirePlainDirectory(directory);
    }

    private static void requirePlainDirectory(Path directory) throws IOException {
        if (Files.isSymbolicLink(directory) ||
            !Files.isDirectory(directory, LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException("Linux image directory is absent or linked");
        }
    }

    private static BasicFileAttributes attributes(Path path) throws IOException {
        return Files.readAttributes(path, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
    }

    private static MessageDigest digest() {
        try { return MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
    }
}
