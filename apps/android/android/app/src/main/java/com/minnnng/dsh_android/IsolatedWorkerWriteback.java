package com.minnnng.dsh_android;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.channels.SeekableByteChannel;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.NoSuchFileException;
import java.nio.file.OpenOption;
import java.nio.file.Path;
import java.nio.file.SecureDirectoryStream;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.BasicFileAttributeView;
import java.nio.file.attribute.BasicFileAttributes;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.locks.ReentrantLock;
import java.util.function.BooleanSupplier;

/** App-owned, version-checked commit for bounded isolated-worker text. */
public final class IsolatedWorkerWriteback {
    public static final String MISSING = "missing";
    // Bridge calls construct a writer per request. One App-process lock fences
    // their revision-check-and-replace sequences across those instances.
    private static final Object COMMIT_LOCK = new Object();

    public interface DirectorySync { void sync(Path directory) throws IOException; }
    interface DirectoryOpener { DirectoryStream<Path> open(Path directory) throws IOException; }

    public record Receipt(String previousSha256, String sha256, int bytes) {}

    /** One lease's publication point; a cancellation during rename leaves the run outcome unconfirmed. */
    public static final class PublishGate {
        private final AtomicBoolean cancelled = new AtomicBoolean();
        private final AtomicBoolean overlapped = new AtomicBoolean();
        private final ReentrantLock rename = new ReentrantLock();

        /** Revokes future replacements without waiting for a blocked filesystem provider. */
        public void cancel() {
            cancelled.set(true);
            if (!rename.tryLock()) {
                overlapped.set(true);
                return;
            }
            rename.unlock();
        }

        /** A rename overlapped cancellation, so the caller must inspect the file before retry. */
        public boolean outcomeUnconfirmed() { return overlapped.get(); }

        private void publish(Target target, Path staged, BooleanSupplier callerCancelled) throws IOException {
            rename.lock();
            try {
                if (cancelled.get()) throw new IOException("Workspace publication cancelled");
                checkCancelled(callerCancelled);
                target.directory.move(staged, target.directory, target.name);
            } finally { rename.unlock(); }
        }
    }

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

    /** A post-rename verification or sync failure requires inspection before retrying. */
    public static final class CommitUncertain extends IOException {
        public final Receipt receipt;
        public CommitUncertain(Receipt receipt, IOException cause) {
            super("Workspace replacement may be visible, but its content or durability could not be confirmed", cause);
            this.receipt = receipt;
        }
    }

    private final Path privateRoot;
    private final Path workspaceRoot;
    private final DirectorySync sync;
    private final DirectoryOpener opener;
    private final boolean requireDirectoryIdentity;

    /** Both roots are selected by the App. Paths are relative children of one private workspace. */
    public IsolatedWorkerWriteback(Path privateRoot, Path workspaceRoot, DirectorySync sync) throws IOException {
        this(privateRoot, workspaceRoot, sync, Files::newDirectoryStream, true);
    }

    // The package-private opener lets host tests exercise the same relative
    // operations on Windows, whose default provider lacks SecureDirectoryStream.
    IsolatedWorkerWriteback(Path privateRoot, Path workspaceRoot, DirectorySync sync,
            DirectoryOpener opener) throws IOException {
        this(privateRoot, workspaceRoot, sync, opener, false);
    }

    private IsolatedWorkerWriteback(Path privateRoot, Path workspaceRoot, DirectorySync sync,
            DirectoryOpener opener, boolean requireDirectoryIdentity) throws IOException {
        this.privateRoot = privateRoot.toAbsolutePath().normalize();
        this.workspaceRoot = workspaceRoot.toAbsolutePath().normalize();
        this.sync = sync;
        this.opener = opener;
        this.requireDirectoryIdentity = requireDirectoryIdentity;
        checkWorkspace();
    }

    /** Read the current target revision before granting a worker request. */
    public String version(String filename) throws IOException {
        synchronized (COMMIT_LOCK) {
            try (Target target = openTarget(filename)) {
                verifyNoHardlinkAlias(target, target.name);
                return revision(target);
            }
        }
    }

    /** Snapshot one App-selected direct child with a content revision for later writeback. */
    public Snapshot snapshot(String filename, BooleanSupplier cancelled) throws IOException {
        synchronized (COMMIT_LOCK) {
            checkCancelled(cancelled);
            try (Target target = openTarget(filename)) {
                verifyNoHardlinkAlias(target, target.name);
                byte[] content = read(target, cancelled, false);
                verifyNoHardlinkAlias(target, target.name);
                IsolatedWorkerInput.readUtf8(new ByteArrayInputStream(content));
                checkCancelled(cancelled);
                return new Snapshot(hash(content), content);
            }
        }
    }

    /** Never accepts a worker-selected path; cancellation before publication leaves the old file intact. */
    public Receipt commit(String filename, String expectedSha256, byte[] content,
                                       BooleanSupplier cancelled) throws IOException {
        return commit(filename, expectedSha256, content, cancelled, new PublishGate());
    }

    /** An App-owned lease gate must be shared with cancellation and final retirement. */
    public Receipt commit(String filename, String expectedSha256, byte[] content,
                          BooleanSupplier cancelled, PublishGate publishGate) throws IOException {
        synchronized (COMMIT_LOCK) {
            return commitLocked(filename, expectedSha256, content, cancelled, publishGate);
        }
    }

    private Receipt commitLocked(String filename, String expectedSha256, byte[] content,
                                 BooleanSupplier cancelled, PublishGate publishGate) throws IOException {
        rejectProtectedWrite(filename);
        if (!validRevision(expectedSha256)) throw new IOException("Invalid expected workspace revision");
        if (content.length > IsolatedWorkerInput.MAX_TEXT_BYTES) throw new IOException("Worker output exceeds 64 KiB");
        IsolatedWorkerInput.readUtf8(new ByteArrayInputStream(content));
        checkCancelled(cancelled);
        try (Target target = openTarget(filename)) {
            verifyNoHardlinkAlias(target, target.name);
            String before = revision(target);
            if (!before.equals(expectedSha256)) throw new IsolatedCapabilityBroker.StaleRevision();
            String after = hash(content);
            Path staged = java.nio.file.Paths.get("." + target.name + "." + UUID.randomUUID() + ".pending");
            boolean moved = false;
            try {
                // Both the temporary file and rename stay relative to the *same open
                // directory*, even if another App-UID writer renames its path.
                try (SeekableByteChannel channel = target.directory.newByteChannel(staged,
                        Set.<OpenOption>of(StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE,
                                LinkOption.NOFOLLOW_LINKS))) {
                    if (!(channel instanceof FileChannel fileChannel))
                        throw new IOException("Workspace provider cannot durably stage a file");
                    for (int offset = 0; offset < content.length; offset += 8192) {
                        checkCancelled(cancelled);
                        ByteBuffer chunk = ByteBuffer.wrap(content, offset, Math.min(8192, content.length - offset));
                        while (chunk.hasRemaining()) channel.write(chunk);
                    }
                    checkCancelled(cancelled);
                    fileChannel.force(true);
                }
                // A name-based rename cannot pin the inode opened above. Check
                // the staged name immediately after close and again before move.
                StageIdentity stage = verifyNamed(target, staged, after, content.length, null);
                checkCancelled(cancelled);
                if (!revision(target).equals(expectedSha256))
                    throw new IsolatedCapabilityBroker.StaleRevision();
                verifyNoHardlinkAlias(target, target.name);
                ensureDirectoryStillNamed(target);
                verifyNamed(target, staged, after, content.length, stage.fileKey());
                publishGate.publish(target, staged, cancelled);
                moved = true;
                Receipt receipt = new Receipt(before, after, content.length);
                try {
                    verifyNamed(target, target.name, after, content.length, stage.fileKey());
                    ensureDirectoryStillNamed(target);
                    sync.sync(target.parent);
                    ensureDirectoryStillNamed(target);
                    target.close();
                }
                catch (IOException failure) { throw new CommitUncertain(receipt, failure); }
                return receipt;
            } finally {
                if (!moved) {
                    try { target.directory.deleteFile(staged); }
                    catch (NoSuchFileException missing) { /* No stage was created. */ }
                }
            }
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

    private Target openTarget(String filename) throws IOException {
        checkWorkspace();
        if (filename == null || filename.isEmpty() || filename.indexOf('\\') >= 0
                || filename.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 1024)
            throw new IOException("Invalid workspace relative path");
        String[] segments = filename.split("/", -1);
        if (segments.length > 16) throw new IOException("Workspace path exceeds depth limit");
        for (int index = 0; index < segments.length; index++) {
            String segment = segments[index];
            if (segment.isEmpty() || segment.equals(".") || segment.equals("..")
                    || segment.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 180
                    || segment.codePoints().anyMatch(Character::isISOControl))
                throw new IOException("Invalid workspace relative path");
        }
        DirectoryStream<Path> root = opener.open(privateRoot);
        if (!(root instanceof SecureDirectoryStream<Path> secureRoot)) {
            root.close();
            throw new IOException("Workspace provider lacks race-free directory operations");
        }
        java.util.ArrayList<SecureDirectoryStream<Path>> opened = new java.util.ArrayList<>();
        opened.add(secureRoot);
        Path parent = privateRoot;
        try {
            for (Path part : privateRoot.relativize(workspaceRoot)) {
                secureRoot = secureRoot.newDirectoryStream(part, LinkOption.NOFOLLOW_LINKS);
                opened.add(secureRoot);
                parent = parent.resolve(part);
            }
            for (int index = 0; index < segments.length - 1; index++) {
                Path part = java.nio.file.Paths.get(segments[index]);
                secureRoot = secureRoot.newDirectoryStream(part, LinkOption.NOFOLLOW_LINKS);
                opened.add(secureRoot);
                parent = parent.resolve(part);
            }
            return new Target(secureRoot, parent, java.nio.file.Paths.get(segments[segments.length - 1]),
                    opened, requireDirectoryIdentity);
        } catch (IOException | RuntimeException failure) {
            for (int index = opened.size() - 1; index >= 0; index--) {
                try { opened.get(index).close(); }
                catch (IOException closeFailure) { failure.addSuppressed(closeFailure); }
            }
            throw failure;
        }
    }

    private static final class Target implements AutoCloseable {
        final SecureDirectoryStream<Path> directory;
        final Path parent;
        final Path name;
        private final java.util.List<SecureDirectoryStream<Path>> opened;
        private final boolean requireDirectoryIdentity;
        private boolean closed;

        Target(SecureDirectoryStream<Path> directory, Path parent, Path name,
                java.util.List<SecureDirectoryStream<Path>> opened, boolean requireDirectoryIdentity) {
            this.directory = directory;
            this.parent = parent;
            this.name = name;
            this.opened = opened;
            this.requireDirectoryIdentity = requireDirectoryIdentity;
        }

        @Override public void close() throws IOException {
            if (closed) return;
            closed = true;
            IOException failure = null;
            for (int index = opened.size() - 1; index >= 0; index--) {
                try { opened.get(index).close(); }
                catch (IOException closeFailure) {
                    if (failure == null) failure = closeFailure;
                    else failure.addSuppressed(closeFailure);
                }
            }
            if (failure != null) throw failure;
        }
    }

    private static void ensureDirectoryStillNamed(Target target) throws IOException {
        if (!target.requireDirectoryIdentity) return; // Windows host test adapter has no file key.
        BasicFileAttributeView anchoredView = target.directory.getFileAttributeView(BasicFileAttributeView.class);
        if (anchoredView == null) throw new IOException("Workspace provider lacks directory attributes");
        BasicFileAttributes anchored = anchoredView.readAttributes();
        BasicFileAttributes named = Files.readAttributes(target.parent, BasicFileAttributes.class,
                LinkOption.NOFOLLOW_LINKS);
        if (!anchored.isDirectory() || !named.isDirectory() || anchored.fileKey() == null
                || !anchored.fileKey().equals(named.fileKey()))
            throw new IOException("Workspace directory changed during writeback");
    }

    private static void rejectProtectedWrite(String filename) throws IOException {
        if (filename == null) throw new IOException("Missing workspace target");
        for (String segment : filename.split("/")) {
            if (segment.equals(".git") || segment.equals(".agents")
                    || segment.equals(".codex") || segment.equals(".aws"))
                throw new IOException("Protected workspace metadata cannot be written");
        }
    }

    /** A guest-visible file must not be an alias of another App-private inode. */
    private static void verifyNoHardlinkAlias(Target target, Path name) throws IOException {
        if (!target.requireDirectoryIdentity) return; // Windows host adapter has no Unix link count.
        try {
            BasicFileAttributeView anchoredView = target.directory.getFileAttributeView(name,
                    BasicFileAttributeView.class, LinkOption.NOFOLLOW_LINKS);
            if (anchoredView == null) throw new IOException("Workspace provider lacks file attributes");
            BasicFileAttributes anchored = anchoredView.readAttributes();
            BasicFileAttributes named = Files.readAttributes(target.parent.resolve(name),
                    BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
            Object links = Files.getAttribute(target.parent.resolve(name), "unix:nlink", LinkOption.NOFOLLOW_LINKS);
            if (!anchored.isRegularFile() || anchored.fileKey() == null
                    || !anchored.fileKey().equals(named.fileKey())
                    || !(links instanceof Number) || ((Number) links).longValue() != 1)
                throw new IOException("Workspace file has an unapproved hard-link alias");
        } catch (NoSuchFileException missing) {
            // A missing target is valid only for a version-preconditioned create.
        } catch (UnsupportedOperationException | IllegalArgumentException unsupported) {
            throw new IOException("Workspace provider cannot verify hard-link aliases", unsupported);
        }
    }

    private static String revision(Target target) throws IOException {
        try { return hash(read(target, () -> false, true)); }
        catch (NoSuchFileException missing) { return MISSING; }
    }

    private record StageIdentity(Object fileKey) {}

    private static StageIdentity verifyNamed(Target target, Path name, String expectedSha256,
            int expectedBytes, Object expectedFileKey) throws IOException {
        BasicFileAttributeView view = target.directory.getFileAttributeView(name,
                BasicFileAttributeView.class, LinkOption.NOFOLLOW_LINKS);
        if (view == null) throw new IOException("Workspace provider lacks file attributes");
        BasicFileAttributes before = view.readAttributes();
        if (!before.isRegularFile() || (target.requireDirectoryIdentity && before.fileKey() == null)
                || (expectedFileKey != null && !expectedFileKey.equals(before.fileKey())))
            throw new IOException("Workspace file identity changed during replacement");
        byte[] bytes = readNamed(target, name, () -> false);
        BasicFileAttributes after = view.readAttributes();
        if (!after.isRegularFile() || (before.fileKey() != null && !before.fileKey().equals(after.fileKey()))
                || bytes.length != expectedBytes || !hash(bytes).equals(expectedSha256))
            throw new IOException("Workspace file content changed during replacement");
        return new StageIdentity(before.fileKey());
    }

    private static byte[] read(Target target, BooleanSupplier cancelled, boolean allowMissing) throws IOException {
        BasicFileAttributeView view = target.directory.getFileAttributeView(target.name,
                BasicFileAttributeView.class, LinkOption.NOFOLLOW_LINKS);
        if (view == null) throw new IOException("Workspace provider lacks file attributes");
        try {
            if (!view.readAttributes().isRegularFile())
                throw new IOException("Workspace target is not a regular file");
        } catch (NoSuchFileException missing) {
            if (!allowMissing) throw new IOException("Workspace source is not a regular file", missing);
            throw missing;
        }
        return readNamed(target, target.name, cancelled);
    }

    private static byte[] readNamed(Target target, Path name, BooleanSupplier cancelled) throws IOException {
        try (SeekableByteChannel channel = target.directory.newByteChannel(name,
                Set.<OpenOption>of(StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS));
             InputStream input = java.nio.channels.Channels.newInputStream(channel)) {
            return readBounded(input, cancelled);
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
