package com.minnnng.dsh_android;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Locale;
import java.util.UUID;
import java.util.function.BooleanSupplier;

/** App-owned, version-checked atomic commit for bounded isolated-worker text. */
public final class IsolatedWorkerWriteback {
    public static final String MISSING = "missing";
    // Bridge calls construct a writer per request. One App-process lock fences
    // their revision-check-and-replace sequences across those instances.
    private static final Object COMMIT_LOCK = new Object();

    public interface DirectorySync { void sync(Path directory) throws IOException; }

    public record Receipt(String previousSha256, String sha256, int bytes) {}

    /** Immutable App-side snapshot; the worker receives only its separately opened descriptor. */
    public static final class Snapshot {
        private final String sha256;
        private final byte[] content;
        private Snapshot(String sha256, byte[] content) {
            this.sha256 = sha256;
            this.content = content.clone();
        }
        public String sha256() { return sha256; }
        public byte[] content() { return content.clone(); }
    }

    /** A post-rename sync failure leaves the new file visible; callers must inspect it before retrying. */
    public static final class CommitUncertain extends IOException {
        public final Receipt receipt;
        public CommitUncertain(Receipt receipt, IOException cause) {
            super("Workspace file was replaced, but directory durability could not be confirmed", cause);
            this.receipt = receipt;
        }
    }

    private final Path privateRoot;
    private final Path workspaceRoot;
    private final DirectorySync sync;

    /** Both roots are selected by the App. Paths are relative children of one private workspace. */
    public IsolatedWorkerWriteback(Path privateRoot, Path workspaceRoot, DirectorySync sync) throws IOException {
        this.privateRoot = privateRoot.toAbsolutePath().normalize();
        this.workspaceRoot = workspaceRoot.toAbsolutePath().normalize();
        this.sync = sync;
        checkWorkspace();
    }

    /** Read the current target revision before granting a worker request. */
    public String version(String filename) throws IOException {
        synchronized (COMMIT_LOCK) {
            return revision(target(filename));
        }
    }

    /** Snapshot one App-selected direct child with a content revision for later writeback. */
    public Snapshot snapshot(String filename, BooleanSupplier cancelled) throws IOException {
        synchronized (COMMIT_LOCK) {
            checkCancelled(cancelled);
            Path source = target(filename);
            if (!Files.isRegularFile(source, LinkOption.NOFOLLOW_LINKS))
                throw new IOException("Workspace source is not a regular file");
            byte[] content;
            try (InputStream input = Files.newInputStream(source, LinkOption.NOFOLLOW_LINKS)) {
                content = readBounded(input, cancelled);
            }
            IsolatedWorkerInput.readUtf8(new ByteArrayInputStream(content));
            checkCancelled(cancelled);
            return new Snapshot(hash(content), content);
        }
    }

    /** Never accepts a worker-selected path; a stale revision, cancellation, or invalid target leaves the old file intact. */
    public Receipt commit(String filename, String expectedSha256, byte[] content,
                                       BooleanSupplier cancelled) throws IOException {
        synchronized (COMMIT_LOCK) {
            return commitLocked(filename, expectedSha256, content, cancelled);
        }
    }

    private Receipt commitLocked(String filename, String expectedSha256, byte[] content,
                                 BooleanSupplier cancelled) throws IOException {
        if (!validRevision(expectedSha256)) throw new IOException("Invalid expected workspace revision");
        if (content.length > IsolatedWorkerInput.MAX_TEXT_BYTES) throw new IOException("Worker output exceeds 64 KiB");
        IsolatedWorkerInput.readUtf8(new ByteArrayInputStream(content));
        checkCancelled(cancelled);
        Path destination = target(filename);
        String before = revision(destination);
        if (!before.equals(expectedSha256)) throw new IOException("Workspace file changed before writeback");
        String after = hash(content);
        Path parent = destination.getParent();
        Path staged = parent.resolve("." + destination.getFileName() + "." + UUID.randomUUID() + ".pending");
        boolean moved = false;
        try {
            checkWorkspace();
            try (FileChannel channel = FileChannel.open(staged, StandardOpenOption.CREATE_NEW,
                    StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS)) {
                for (int offset = 0; offset < content.length; offset += 8192) {
                    checkCancelled(cancelled);
                    ByteBuffer chunk = ByteBuffer.wrap(content, offset, Math.min(8192, content.length - offset));
                    while (chunk.hasRemaining()) channel.write(chunk);
                }
                checkCancelled(cancelled);
                channel.force(true);
            }
            checkCancelled(cancelled);
            destination = target(filename);
            if (!revision(destination).equals(expectedSha256))
                throw new IOException("Workspace file changed before writeback");
            Files.move(staged, destination, StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING);
            moved = true;
            Receipt receipt = new Receipt(before, after, content.length);
            try { sync.sync(parent); }
            catch (IOException failure) { throw new CommitUncertain(receipt, failure); }
            return receipt;
        } finally {
            if (!moved) Files.deleteIfExists(staged);
        }
    }

    private void checkWorkspace() throws IOException {
        if (!Files.isDirectory(privateRoot) || Files.isSymbolicLink(privateRoot)
                || !workspaceRoot.startsWith(privateRoot) || workspaceRoot.equals(privateRoot))
            throw new IOException("Workspace is outside the App private directory");
        Path path = privateRoot;
        for (Path part : privateRoot.relativize(workspaceRoot)) {
            path = path.resolve(part);
            if (!Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(path))
                throw new IOException("Workspace contains a non-directory or symbolic link");
        }
    }

    private Path target(String filename) throws IOException {
        checkWorkspace();
        if (filename == null || filename.isEmpty() || filename.indexOf('\\') >= 0
                || filename.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 1024)
            throw new IOException("Invalid workspace relative path");
        String[] segments = filename.split("/", -1);
        if (segments.length > 16) throw new IOException("Workspace path exceeds depth limit");
        Path target = workspaceRoot;
        for (int index = 0; index < segments.length; index++) {
            String segment = segments[index];
            if (segment.isEmpty() || segment.equals(".") || segment.equals("..")
                    || segment.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 180
                    || segment.codePoints().anyMatch(Character::isISOControl))
                throw new IOException("Invalid workspace relative path");
            target = target.resolve(segment);
            if (index < segments.length - 1
                    && (!Files.isDirectory(target, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(target)))
                throw new IOException("Workspace path contains a non-directory or symbolic link");
        }
        if (Files.isSymbolicLink(target)) throw new IOException("Workspace target is a symbolic link");
        return target;
    }

    private static String revision(Path target) throws IOException {
        if (!Files.exists(target, LinkOption.NOFOLLOW_LINKS)) return MISSING;
        if (!Files.isRegularFile(target, LinkOption.NOFOLLOW_LINKS))
            throw new IOException("Workspace target is not a regular file");
        try (InputStream input = Files.newInputStream(target, LinkOption.NOFOLLOW_LINKS)) {
            return hash(readBounded(input, () -> false));
        }
    }

    private static byte[] readBounded(InputStream input, BooleanSupplier cancelled) throws IOException {
        byte[] content = new byte[IsolatedWorkerInput.MAX_TEXT_BYTES + 1];
        int count = 0;
        while (count < content.length) {
            checkCancelled(cancelled);
            int read = input.read(content, count, Math.min(8192, content.length - count));
            if (read < 0) break;
            count += read;
        }
        checkCancelled(cancelled);
        if (count > IsolatedWorkerInput.MAX_TEXT_BYTES)
            throw new IOException("Workspace target exceeds 64 KiB");
        return java.util.Arrays.copyOf(content, count);
    }

    private static boolean validRevision(String value) {
        return MISSING.equals(value) || value != null && value.matches("[0-9a-f]{64}");
    }

    private static void checkCancelled(BooleanSupplier cancelled) throws IOException {
        if (Thread.currentThread().isInterrupted() || cancelled.getAsBoolean())
            throw new IOException("Isolated-worker writeback cancelled");
    }

    private static String hash(byte[] value) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(value);
            StringBuilder hex = new StringBuilder(64);
            for (byte b : digest) hex.append(String.format(Locale.ROOT, "%02x", b & 255));
            return hex.toString();
        } catch (NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
    }
}
