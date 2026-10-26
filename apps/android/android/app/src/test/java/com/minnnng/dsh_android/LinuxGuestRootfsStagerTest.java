package com.minnnng.dsh_android;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.zip.GZIPInputStream;
import java.util.zip.GZIPOutputStream;

/** Host checks for the complete member graph before any isolated-UID file write. */
public final class LinuxGuestRootfsStagerTest {
    public static void main(String[] args) throws Exception {
        byte[] good = tar(
            entry(".", '5', "", new byte[0]),
            entry("./bin", '5', "", new byte[0]),
            entry("./bin/busybox", '0', "", "elf".getBytes(StandardCharsets.US_ASCII), 0755),
            entry("./bin/sh", '2', "/bin/busybox", new byte[0]));
        require(LinuxGuestRootfsStager.inspectTar(good) == 4, "Safe graph rejected");
        require(LinuxGuestRootfsStager.inspectExecutableFiles(good).equals(
            java.util.List.of("bin/busybox")), "Executable tar mode was not retained");
        require(LinuxGuestRootfsStager.safeLink("usr/bin/yes", "/bin/busybox")
            .equals("../../bin/busybox"), "Absolute guest link escaped or changed target");
        require(LinuxGuestRootfsStager.safeLink("usr/lib/a", "../bin/a")
            .equals("../bin/a"), "Safe relative guest link changed target");
        rejectLink("usr/lib/a", "/../../etc/passwd");
        rejectLink("usr/lib/a", "../../../etc/passwd");
        rejectLink("usr/lib/a", ".");
        reject(tar(entry("../outside", '0', "", new byte[0])));
        reject(tar(entry("/outside", '0', "", new byte[0])));
        reject(tar(entry("a/../outside", '0', "", new byte[0])));
        reject(tar(entry("a", '2', "/../../etc/passwd", new byte[0])));
        reject(tar(entry("a", '2', "../../etc/passwd", new byte[0])));
        reject(tar(entry("a", '1', "b", new byte[0]))); // hard link
        reject(tar(entry("a", '3', "", new byte[0]))); // device node
        reject(tar(entry("a", '6', "", new byte[0]))); // FIFO
        reject(tar(entry("a", 'x', "", new byte[0]))); // PAX path override
        reject(tar(entry("a", 'L', "", new byte[0]))); // GNU long path override
        reject(tar(entry("a", '0', "", new byte[0]), entry("a", '0', "", new byte[0])));
        reject(tar(entry("a", '2', "b", new byte[0]),
            entry("a/child", '0', "", new byte[0])));
        reject(tar(entry("a/child", '0', "", new byte[0])));
        byte[] oversized = entry("big", '0', "", new byte[0]);
        octal(oversized, 124, 12, 16L * 1024 * 1024 + 1);
        checksum(oversized);
        reject(tar(oversized));
        byte[] invalidMode = entry("bad-mode", '0', "", new byte[0]);
        octal(invalidMode, 100, 8, 010000);
        checksum(invalidMode);
        reject(tar(invalidMode));
        byte[] corrupt = good.clone();
        corrupt[148] ^= 1;
        reject(corrupt);
        byte[] trailing = good.clone();
        trailing[trailing.length - 1] = 1;
        reject(trailing);
        Path parent = Files.createTempDirectory("rootfs-guard-");
        try {
            ByteBuffer mutable = ByteBuffer.wrap(new byte[] { 1 });
            rejectedStage(mutable, parent, "wrong", "0".repeat(64), 1);
            rejectedStage(mutable, parent, UUID.randomUUID().toString(), "0".repeat(64), 1);
            require(empty(parent), "Rejected offer wrote a stage");
            byte[] nested = tar(entry(".", '5', "", new byte[0]),
                entry("./usr", '5', "", new byte[0]),
                entry("./usr/bin", '5', "", new byte[0]),
                entry("./usr/bin/tool", '0', "", new byte[] { 1, 2, 3 }, 0755),
                entry("./usr/bin/config", '0', "", new byte[] { 4 }, 0644));
            byte[] gzip = gzip(nested);
            String hash = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                .digest(gzip));
            Path published;
            try (LinuxGuestRootfsStager.Staged staged = LinuxGuestRootfsStager.stage(
                    ByteBuffer.wrap(gzip).asReadOnlyBuffer(), parent,
                    UUID.randomUUID().toString(), () -> false, hash, gzip.length)) {
                published = staged.directory();
                require(Files.readAllBytes(published.resolve("usr/bin/tool")).length == 3,
                    "Published nested tree missing");
                if (Files.getFileStore(parent).supportsFileAttributeView("posix")) {
                    require(Files.getPosixFilePermissions(published.resolve("usr/bin/tool")).contains(
                        java.nio.file.attribute.PosixFilePermission.OWNER_EXECUTE),
                        "Executable lost owner execute permission");
                    require(!Files.getPosixFilePermissions(published.resolve("usr/bin/config")).contains(
                        java.nio.file.attribute.PosixFilePermission.OWNER_EXECUTE),
                        "Non-executable gained owner execute permission");
                }
            }
            require(!Files.exists(published), "Close left a published nested tree");
            require(empty(parent), "Close left a stage");
            AtomicInteger checks = new AtomicInteger();
            rejectedStageCancelled(ByteBuffer.wrap(gzip).asReadOnlyBuffer(), parent,
                UUID.randomUUID().toString(), hash, gzip.length,
                () -> checks.incrementAndGet() >= 5);
            require(empty(parent),
                "Cancelled staging left owned partial files");
            Path retry = Files.createTempFile(parent, "retry-close-", ".tmp");
            AtomicInteger removalAttempts = new AtomicInteger();
            LinuxGuestRootfsStager.Staged retryStage = new LinuxGuestRootfsStager.Staged(
                retry, directory -> {
                    if (removalAttempts.incrementAndGet() == 1)
                        throw new IOException("Synthetic cleanup interruption");
                    Files.delete(directory);
                });
            try { retryStage.close(); throw new AssertionError("Cleanup should fail once"); }
            catch (IOException expected) { /* The staged tree remains owned for retry. */ }
            require(Files.exists(retry), "Failed cleanup removed the fixture unexpectedly");
            retryStage.close();
            retryStage.close();
            require(removalAttempts.get() == 2 && !Files.exists(retry),
                "Staged cleanup was not retryable and idempotent");
        } finally { Files.delete(parent); }
        if (args.length == 1) {
            Path official = Path.of(args[0]);
            byte[] compressed = Files.readAllBytes(official);
            String digest = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                .digest(compressed));
            require(compressed.length == LinuxImageLeaseOwner.ARCHIVE_BYTES &&
                digest.equals(LinuxImageLeaseOwner.SHA256), "Official source lock changed");
            ByteArrayOutputStream tar = new ByteArrayOutputStream();
            try (GZIPInputStream gzip = new GZIPInputStream(
                    new java.io.ByteArrayInputStream(compressed))) {
                gzip.transferTo(tar);
            }
            require(LinuxGuestRootfsStager.inspectTar(tar.toByteArray()) == 515,
                "Official Alpine member graph changed");
            require(LinuxGuestRootfsStager.inspectExecutableFiles(tar.toByteArray())
                .contains("bin/busybox"), "Official Alpine executable mode was lost");
        }
        System.out.println("LinuxGuestRootfsStagerTest passed");
    }

    private static byte[] entry(String name, char type, String link, byte[] content)
            throws IOException {
        return entry(name, type, link, content, 0600);
    }

    private static byte[] entry(String name, char type, String link, byte[] content,
                                int mode) throws IOException {
        byte[] header = new byte[512];
        text(header, 0, 100, name);
        octal(header, 100, 8, mode);
        octal(header, 108, 8, 0);
        octal(header, 116, 8, 0);
        octal(header, 124, 12, content.length);
        octal(header, 136, 12, 0);
        header[156] = (byte) type;
        text(header, 157, 100, link);
        text(header, 257, 6, "ustar");
        checksum(header);
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(header);
        out.write(content);
        out.write(new byte[(512 - content.length % 512) % 512]);
        return out.toByteArray();
    }

    private static byte[] tar(byte[]... entries) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        for (byte[] entry : entries) out.write(entry);
        out.write(new byte[1024]);
        return out.toByteArray();
    }

    private static void text(byte[] header, int offset, int length, String value) {
        byte[] bytes = value.getBytes(StandardCharsets.US_ASCII);
        if (bytes.length > length) throw new IllegalArgumentException("Fixture field too long");
        System.arraycopy(bytes, 0, header, offset, bytes.length);
    }

    private static void octal(byte[] header, int offset, int length, long value) {
        byte[] bytes = Long.toOctalString(value).getBytes(StandardCharsets.US_ASCII);
        for (int i = offset; i < offset + length - 1; i++) header[i] = '0';
        System.arraycopy(bytes, 0, header, offset + length - bytes.length - 1, bytes.length);
    }

    private static void checksum(byte[] header) {
        for (int i = 148; i < 156; i++) header[i] = ' ';
        int sum = 0;
        for (int i = 0; i < 512; i++) sum += header[i] & 0xff;
        octal(header, 148, 8, sum);
    }

    private static void reject(byte[] bytes) throws Exception {
        try { LinuxGuestRootfsStager.inspectTar(bytes); }
        catch (IOException expected) { return; }
        throw new AssertionError("Unsafe tar member graph accepted");
    }

    private static void rejectLink(String name, String target) throws Exception {
        try { LinuxGuestRootfsStager.safeLink(name, target); }
        catch (IOException expected) { return; }
        throw new AssertionError("Unsafe symlink target accepted");
    }

    private static byte[] gzip(byte[] bytes) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (GZIPOutputStream gzip = new GZIPOutputStream(out)) { gzip.write(bytes); }
        return out.toByteArray();
    }

    private static void rejectedStage(ByteBuffer buffer, Path parent, String id,
                                      String hash, long length) throws Exception {
        try {
            LinuxGuestRootfsStager.stage(buffer, parent, id, () -> false, hash, length);
        } catch (IOException expected) { return; }
        throw new AssertionError("Unsafe image offer accepted");
    }

    private static void rejectedStageCancelled(ByteBuffer buffer, Path parent, String id,
            String hash, long length, java.util.function.BooleanSupplier cancelled)
            throws Exception {
        try { LinuxGuestRootfsStager.stage(buffer, parent, id, cancelled, hash, length); }
        catch (IOException expected) { return; }
        throw new AssertionError("Cancelled stage was published");
    }

    private static void require(boolean condition, String detail) {
        if (!condition) throw new AssertionError(detail);
    }

    private static boolean empty(Path directory) throws IOException {
        try (var entries = Files.list(directory)) { return entries.findAny().isEmpty(); }
    }
}
