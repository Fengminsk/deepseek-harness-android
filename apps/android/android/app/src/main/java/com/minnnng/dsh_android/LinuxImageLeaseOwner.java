package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HashMap;
import java.util.Map;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;
import java.util.function.LongSupplier;

/**
 * App-owned, data-only lease for one digest-pinned Alpine archive. No guest
 * path, URL, release name, command or digest is accepted at this boundary.
 * The matching source identity is reviewed in linux-userland-source-lock.mjs.
 */
final class LinuxImageLeaseOwner implements AutoCloseable {
    static final String VERSION = "3.24.3";
    static final String ABI = "arm64-v8a";
    static final String SHA256 = "4d3f80afaebd447c5591a63a73bde380a149fe8b2d85488cafabb2ff97551f50";
    static final long ARCHIVE_BYTES = 4_029_999L;
    private static final int MAX_PENDING = 2;
    private static final int MAX_SETTLED = 4096;
    private static final long MAX_LEASE_MILLIS = 60_000L;

    record Offer(String runId, String token, String version, String abi,
                 String sha256, long bytes, long expiresAtMillis) { }
    record Claim(Path archive, String sha256, long bytes, long expiresAtMillis) { }

    private final Path installationRoot;
    private final LongSupplier nowMillis;
    private final String version;
    private final String imageSha256;
    private final long imageBytes;
    private final Map<String, Offer> pending = new HashMap<>();
    private final Set<String> settled = new HashSet<>();
    private boolean closed;

    LinuxImageLeaseOwner(Path installationRoot) throws IOException {
        this(installationRoot, () -> System.nanoTime() / 1_000_000L,
                VERSION, SHA256, ARCHIVE_BYTES);
    }

    /** Package-local fixture pin; production constructs the fixed-source overload above. */
    LinuxImageLeaseOwner(Path installationRoot, LongSupplier nowMillis,
                         String version, String imageSha256, long imageBytes) throws IOException {
        if (installationRoot == null || !installationRoot.isAbsolute() || nowMillis == null)
            throw new IllegalArgumentException("An absolute App-owned image root and clock are required");
        if (version == null || !version.matches("[A-Za-z0-9][A-Za-z0-9._-]{0,63}") ||
                imageSha256 == null || !imageSha256.matches("[0-9a-f]{64}") ||
                imageBytes < 1 || imageBytes > 64L * 1024 * 1024)
            throw new IllegalArgumentException("Invalid pinned image identity");
        requirePlainDirectory(installationRoot);
        this.installationRoot = installationRoot.toAbsolutePath().normalize();
        this.nowMillis = nowMillis;
        this.version = version;
        this.imageSha256 = imageSha256;
        this.imageBytes = imageBytes;
    }

    synchronized Offer issue(String runId, long leaseMillis) throws IOException {
        requireOpen();
        requireUuid(runId);
        if (leaseMillis < 1 || leaseMillis > MAX_LEASE_MILLIS)
            throw new IllegalArgumentException("Image lease deadline is out of range");
        expire();
        if (pending.size() >= MAX_PENDING || pending.containsKey(runId) ||
                settled.contains(runId) || settled.size() + pending.size() >= MAX_SETTLED)
            throw new IllegalStateException("Image lease capacity or run identity conflict");
        verifyArchive(archivePath());
        long expiry = Math.addExact(nowMillis.getAsLong(), leaseMillis);
        Offer offer = new Offer(runId, UUID.randomUUID().toString(), version, ABI,
                imageSha256, imageBytes, expiry);
        pending.put(runId, offer);
        return offer;
    }

    synchronized Claim claim(String runId, String token) throws IOException {
        requireOpen();
        requireUuid(runId);
        requireUuid(token);
        Offer offer = pending.get(runId);
        if (offer == null || !offer.token().equals(token))
            throw new IllegalArgumentException("Image lease does not match this run");
        pending.remove(runId); // An uncertain attempt must never replay the capability.
        settled.add(runId);
        if (nowMillis.getAsLong() >= offer.expiresAtMillis())
            throw new IllegalStateException("Image lease expired");
        Path archive = archivePath();
        verifyArchive(archive);
        if (nowMillis.getAsLong() >= offer.expiresAtMillis())
            throw new IllegalStateException("Image lease expired during verification");
        return new Claim(archive, imageSha256, imageBytes, offer.expiresAtMillis());
    }

    synchronized void revoke(String runId) {
        requireUuid(runId);
        if (pending.remove(runId) != null) settled.add(runId);
    }

    private Path archivePath() throws IOException {
        requirePlainDirectory(installationRoot);
        Path versions = installationRoot.resolve("versions");
        Path release = versions.resolve(imageSha256);
        requirePlainDirectory(versions);
        requirePlainDirectory(release);
        Path archive = release.resolve("image.tar.gz");
        if (Files.isSymbolicLink(archive) || !Files.isRegularFile(archive, LinkOption.NOFOLLOW_LINKS))
            throw new IOException("Pinned image archive is absent or linked");
        return archive;
    }

    private static void requirePlainDirectory(Path directory) throws IOException {
        if (Files.isSymbolicLink(directory) ||
                !Files.isDirectory(directory, LinkOption.NOFOLLOW_LINKS))
            throw new IOException("Image directory is absent or linked");
    }

    private void verifyArchive(Path archive) throws IOException {
        BasicFileAttributes before = Files.readAttributes(archive, BasicFileAttributes.class,
                LinkOption.NOFOLLOW_LINKS);
        if (!before.isRegularFile() || before.isSymbolicLink() || before.size() != imageBytes)
            throw new IOException("Pinned image archive changed");
        MessageDigest digest = sha256();
        try (FileChannel channel = FileChannel.open(archive, StandardOpenOption.READ,
                LinkOption.NOFOLLOW_LINKS)) {
            ByteBuffer buffer = ByteBuffer.allocate(64 * 1024);
            long count = 0;
            while (channel.read(buffer) != -1) {
                buffer.flip();
                count += buffer.remaining();
                digest.update(buffer);
                buffer.clear();
                if (count > imageBytes) throw new IOException("Pinned image exceeded its byte limit");
            }
            if (count != imageBytes) throw new IOException("Pinned image ended early");
        }
        BasicFileAttributes after = Files.readAttributes(archive, BasicFileAttributes.class,
                LinkOption.NOFOLLOW_LINKS);
        if (!after.isRegularFile() || after.size() != before.size() ||
                !after.lastModifiedTime().equals(before.lastModifiedTime()) ||
                (before.fileKey() != null && !before.fileKey().equals(after.fileKey())) ||
                !imageSha256.equals(ImageDigestHex.encode(digest.digest())))
            throw new IOException("Pinned image digest or identity changed");
    }

    private void expire() {
        pending.values().removeIf(it -> {
            if (nowMillis.getAsLong() < it.expiresAtMillis()) return false;
            settled.add(it.runId());
            return true;
        });
    }
    private void requireOpen() { if (closed) throw new IllegalStateException("Image lease owner is closed"); }
    private static MessageDigest sha256() {
        try { return MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
    }
    private static void requireUuid(String value) {
        try { if (value == null || !UUID.fromString(value).toString().equals(value))
            throw new IllegalArgumentException("Invalid image run/token identity"); }
        catch (IllegalArgumentException invalid) {
            throw new IllegalArgumentException("Invalid image run/token identity", invalid);
        }
    }
    @Override public synchronized void close() { closed = true; pending.clear(); settled.clear(); }
}
