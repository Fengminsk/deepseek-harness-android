package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.DirectoryStream;
import java.nio.file.LinkOption;
import java.nio.file.OpenOption;
import java.nio.file.Path;
import java.nio.file.SecureDirectoryStream;
import java.nio.file.StandardCopyOption;
import java.nio.channels.FileChannel;
import java.nio.channels.SeekableByteChannel;
import java.nio.file.attribute.FileAttribute;
import java.util.Comparator;
import java.util.Iterator;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Consumer;

public final class IsolatedWorkerWritebackTest {
    private static String readString(Path path) throws IOException {
        return new String(Files.readAllBytes(path), StandardCharsets.UTF_8);
    }

    public static void main(String[] args) throws Exception {
        Path fixture = Files.createTempDirectory(Path.of(System.getProperty("java.io.tmpdir")), "writeback-");
        try {
            Path privateRoot = Files.createDirectory(fixture.resolve("private"));
            Path workspace = Files.createDirectory(privateRoot.resolve("workspace"));
            AtomicInteger syncs = new AtomicInteger();
            var writer = writer(privateRoot, workspace, directory -> {
                check(directory.startsWith(workspace), "synced outside workspace");
                syncs.incrementAndGet();
            });
            check(writer.version("笔记.txt").equals(IsolatedWorkerWriteback.MISSING), "missing revision");
            byte[] first = "第一版\n".getBytes(StandardCharsets.UTF_8);
            var created = writer.commit("笔记.txt", IsolatedWorkerWriteback.MISSING, first, () -> false);
            check(created.bytes() == first.length && created.previousSha256().equals(IsolatedWorkerWriteback.MISSING), "create receipt");
            check(writer.version("笔记.txt").equals(created.sha256()), "created revision");
            check(readString(workspace.resolve("笔记.txt")).equals("第一版\n"), "created content");
            Files.createDirectory(workspace.resolve(".git"));
            reject(() -> writer.commit(".git/config", IsolatedWorkerWriteback.MISSING,
                    first, () -> false), "protected Git metadata write");
            check(!Files.exists(workspace.resolve(".git/config")), "protected metadata was created");
            var snapshot = writer.snapshot("笔记.txt", () -> false);
            check(snapshot.sha256().equals(created.sha256())
                    && new String(snapshot.content(), StandardCharsets.UTF_8).equals("第一版\n"),
                "App-selected snapshot did not pair bytes with revision");
            snapshot.content()[0] = 0;
            check(new String(snapshot.content(), StandardCharsets.UTF_8).equals("第一版\n"),
                "snapshot exposed mutable granted bytes");
            byte[] second = "第二版\n".getBytes(StandardCharsets.UTF_8);
            var replaced = writer.commit("笔记.txt", created.sha256(), second, () -> false);
            check(replaced.previousSha256().equals(created.sha256()), "replacement revision");
            check(syncs.get() == 2, "directory sync count");
            var competingWriter = writer(privateRoot, workspace, directory -> {});
            var firstEntered = new CountDownLatch(1);
            var secondEntered = new CountDownLatch(1);
            var releaseFirst = new CountDownLatch(1);
            var pool = Executors.newFixedThreadPool(2);
            try {
                var firstCommit = pool.submit(() -> writer.commit("concurrent.txt", IsolatedWorkerWriteback.MISSING,
                    "first".getBytes(StandardCharsets.UTF_8), () -> {
                        firstEntered.countDown();
                        try { return !releaseFirst.await(3, TimeUnit.SECONDS); }
                        catch (InterruptedException interrupted) {
                            Thread.currentThread().interrupt();
                            return true;
                        }
                    }));
                check(firstEntered.await(3, TimeUnit.SECONDS), "first writer never entered commit");
                var secondWriter = pool.submit(() -> {
                    secondEntered.countDown();
                    try {
                        competingWriter.commit("concurrent.txt", IsolatedWorkerWriteback.MISSING,
                            "second".getBytes(StandardCharsets.UTF_8), () -> false);
                        return false;
                    } catch (IOException stale) { return true; }
                });
                check(secondEntered.await(3, TimeUnit.SECONDS), "second writer never attempted commit");
                Thread.sleep(100);
                check(!secondWriter.isDone(), "independent writer passed a pending revision check");
                releaseFirst.countDown();
                firstCommit.get(3, TimeUnit.SECONDS);
                check(secondWriter.get(3, TimeUnit.SECONDS), "competing writer silently overwrote the first");
                check(readString(workspace.resolve("concurrent.txt")).equals("first"),
                    "concurrent winner changed");
            } finally {
                releaseFirst.countDown();
                pool.shutdownNow();
            }
            byte[] exactLimit = new byte[IsolatedWorkerInput.MAX_TEXT_BYTES];
            var exact = writer.commit("exact.txt", IsolatedWorkerWriteback.MISSING, exactLimit, () -> false);
            check(exact.bytes() == exactLimit.length && Files.size(workspace.resolve("exact.txt")) == exactLimit.length,
                "exact writeback limit");

            reject(() -> writer.commit("笔记.txt", created.sha256(), first, () -> false), "stale revision");
            reject(() -> writer.commit("../escape", replaced.sha256(), first, () -> false), "parent traversal");
            reject(() -> writer.commit("nested/file", replaced.sha256(), first, () -> false), "absent nested directory");
            reject(() -> writer.commit("/absolute", replaced.sha256(), first, () -> false), "absolute target");
            reject(() -> writer.commit("folder//file", replaced.sha256(), first, () -> false), "empty path component");
            reject(() -> writer.commit("folder/./file", replaced.sha256(), first, () -> false), "dot path component");
            reject(() -> writer.commit("folder/../file", replaced.sha256(), first, () -> false), "parent path component");
            reject(() -> writer.commit("folder\\file", replaced.sha256(), first, () -> false), "backslash path component");
            reject(() -> writer.commit("笔记.txt", "0".repeat(63), first, () -> false), "invalid revision");
            reject(() -> writer.commit("笔记.txt", replaced.sha256(), new byte[IsolatedWorkerInput.MAX_TEXT_BYTES + 1], () -> false), "oversize");
            reject(() -> writer.commit("笔记.txt", replaced.sha256(), new byte[] {(byte) 0xc3, 0x28}, () -> false), "malformed UTF-8");
            reject(() -> writer.commit("笔记.txt", replaced.sha256(), first, () -> true), "pre-cancelled");
            var revokedPublication = new IsolatedWorkerWriteback.PublishGate();
            revokedPublication.cancel();
            reject(() -> writer.commit("笔记.txt", replaced.sha256(), first, () -> false,
                revokedPublication), "revoked publication");
            check(readString(workspace.resolve("笔记.txt")).equals("第二版\n"),
                "revoked publication changed the target");
            reject(() -> writer.snapshot("笔记.txt", () -> true), "cancelled snapshot");
            reject(() -> writer.snapshot("../escape", () -> false), "snapshot traversal");
            AtomicInteger checkpoints = new AtomicInteger();
            reject(() -> writer.commit("笔记.txt", replaced.sha256(), new byte[20000],
                () -> checkpoints.incrementAndGet() >= 3), "mid-write cancellation");
            check(readString(workspace.resolve("笔记.txt")).equals("第二版\n"), "failure replaced target");
            try (var entries = Files.list(workspace)) {
                check(entries.noneMatch(path -> path.getFileName().toString().endsWith(".pending")), "staged file survived failure");
            }

            Files.createDirectory(workspace.resolve("folder"));
            Path nested = Files.createDirectory(workspace.resolve("folder/deeper"));
            var nestedCreated = writer.commit("folder/deeper/notes.txt", IsolatedWorkerWriteback.MISSING,
                "nested text".getBytes(StandardCharsets.UTF_8), () -> false);
            check(writer.snapshot("folder/deeper/notes.txt", () -> false).sha256().equals(nestedCreated.sha256()),
                "nested snapshot revision");
            check(readString(nested.resolve("notes.txt")).equals("nested text"), "nested writeback");
            check(writer.version("folder/deeper/notes.txt").equals(nestedCreated.sha256()), "nested version");
            reject(() -> writer.version("folder"), "directory target");
            Files.write(workspace.resolve("large.txt"), new byte[IsolatedWorkerInput.MAX_TEXT_BYTES + 1]);
            reject(() -> writer.version("large.txt"), "oversized existing target");
            reject(() -> writer.snapshot("large.txt", () -> false), "oversized snapshot");
            Files.write(workspace.resolve("invalid.txt"), new byte[] {(byte) 0xc3, 0x28});
            reject(() -> writer.snapshot("invalid.txt", () -> false), "malformed snapshot");
            boolean symlinkAvailable = false;
            try {
                Files.createSymbolicLink(workspace.resolve("alias.txt"), workspace.resolve("笔记.txt"));
                symlinkAvailable = true;
            } catch (java.nio.file.FileSystemException | UnsupportedOperationException | SecurityException unavailable) {
                // Some Windows hosts do not permit creating symlinks without developer mode.
            }
            if (symlinkAvailable) reject(() -> writer.snapshot("alias.txt", () -> false), "symbolic-link snapshot");
            if (symlinkAvailable) {
                Files.createSymbolicLink(workspace.resolve("folder-link"), workspace.resolve("folder"));
                reject(() -> writer.snapshot("folder-link/deeper/notes.txt", () -> false), "symbolic-link parent");
                reject(() -> writer.commit("folder-link/other.txt", IsolatedWorkerWriteback.MISSING,
                    first, () -> false), "symbolic-link parent write");
            }
            reject(() -> writer(privateRoot, fixture, directory -> {}), "outside private root");
            var uncertain = writer(privateRoot, workspace, directory -> { throw new IOException("sync failed"); });
            try {
                uncertain.commit("笔记.txt", replaced.sha256(), first, () -> false);
                throw new AssertionError("post-rename sync failure looked successful");
            } catch (IsolatedWorkerWriteback.CommitUncertain failure) {
                check(failure.receipt.sha256().equals(created.sha256()), "uncertain receipt");
                check(readString(workspace.resolve("笔记.txt")).equals("第一版\n"), "post-rename state hidden");
            }
            try (DirectoryStream<Path> provider = Files.newDirectoryStream(privateRoot)) {
                var production = new IsolatedWorkerWriteback(privateRoot, workspace, directory -> {});
                if (provider instanceof SecureDirectoryStream<?>) {
                    var receipt = production.commit("provider.txt", IsolatedWorkerWriteback.MISSING,
                            first, () -> false);
                    check(production.version("provider.txt").equals(receipt.sha256()),
                            "real provider relative commit");
                    Path privateSecret = Files.write(privateRoot.resolve("secret.txt"),
                            "private".getBytes(StandardCharsets.UTF_8));
                    Path alias = workspace.resolve("alias-hardlink.txt");
                    try {
                        Files.createLink(alias, privateSecret);
                        reject(() -> production.snapshot("alias-hardlink.txt", () -> false),
                                "App-private hard-link alias read");
                        reject(() -> production.commit("alias-hardlink.txt", production.version("provider.txt"),
                                second, () -> false), "App-private hard-link alias write");
                    } catch (UnsupportedOperationException | java.nio.file.FileSystemException unavailable) {
                        // The device provider check is required even when this host cannot create a hard link.
                    }
                } else {
                    reject(() -> production.version("笔记.txt"), "provider without secure directory operations");
                }
            }
            var tamperedStage = new IsolatedWorkerWriteback(privateRoot, workspace, directory -> {},
                root -> new HostSecureDirectoryStream(root, source -> {
                    try {
                        Files.delete(source);
                        Files.write(source, "tampered".getBytes(StandardCharsets.UTF_8));
                    }
                    catch (IOException failure) { throw new RuntimeException(failure); }
                }));
            try {
                tamperedStage.commit("tampered.txt", IsolatedWorkerWriteback.MISSING,
                    "expected".getBytes(StandardCharsets.UTF_8), () -> false);
                throw new AssertionError("stage replacement produced a clean receipt");
            } catch (IsolatedWorkerWriteback.CommitUncertain failure) {
                check(readString(workspace.resolve("tampered.txt")).equals("tampered"),
                    "tamper fixture did not run");
            }
            var moveEntered = new CountDownLatch(1);
            var releaseMove = new CountDownLatch(1);
            var publication = new IsolatedWorkerWriteback.PublishGate();
            var delayedMove = new IsolatedWorkerWriteback(privateRoot, workspace, directory -> {},
                root -> new HostSecureDirectoryStream(root, source -> {
                    if (!source.getFileName().toString().contains("overlap.txt")) return;
                    moveEntered.countDown();
                    boolean interrupted = false;
                    while (true) {
                        try { releaseMove.await(); break; }
                        catch (InterruptedException failure) { interrupted = true; }
                    }
                    if (interrupted) Thread.currentThread().interrupt();
                }));
            var publicationPool = Executors.newSingleThreadExecutor();
            try {
                var pending = publicationPool.submit(() -> delayedMove.commit("overlap.txt",
                    IsolatedWorkerWriteback.MISSING, first, () -> false, publication));
                check(moveEntered.await(3, TimeUnit.SECONDS), "publication did not reach rename");
                publication.cancel();
                check(publication.outcomeUnconfirmed(), "cancellation concealed in-flight rename");
                releaseMove.countDown();
                pending.get(3, TimeUnit.SECONDS);
                check(readString(workspace.resolve("overlap.txt")).equals("第一版\n"),
                    "blocked provider did not demonstrate late replacement");
                reject(() -> delayedMove.commit("overlap.txt", delayedMove.version("overlap.txt"),
                    second, () -> false, publication), "replacement after cancellation");
            } finally {
                releaseMove.countDown();
                publicationPool.shutdownNow();
            }
            System.out.println("IsolatedWorkerWriteback: scope, revisions, limits, cancellation, stage verification, provider gate and uncertain sync passed");
        } finally {
            try (var paths = Files.walk(fixture)) {
                for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(path);
            }
        }
    }

    private interface Checked { void run() throws Exception; }

    private static IsolatedWorkerWriteback writer(Path privateRoot, Path workspace,
            IsolatedWorkerWriteback.DirectorySync sync) throws IOException {
        // Windows has no SecureDirectoryStream. This test adapter exercises the
        // same relative-operation code; Android's real provider must be checked
        // separately on a device before claiming race-proof operation there.
        return new IsolatedWorkerWriteback(privateRoot, workspace, sync, HostSecureDirectoryStream::new);
    }

    private static final class HostSecureDirectoryStream implements SecureDirectoryStream<Path> {
        private final Path directory;
        private final Consumer<Path> beforeMove;
        HostSecureDirectoryStream(Path directory) throws IOException {
            this(directory, source -> {});
        }
        HostSecureDirectoryStream(Path directory, Consumer<Path> beforeMove) throws IOException {
            if (!Files.isDirectory(directory, LinkOption.NOFOLLOW_LINKS))
                throw new IOException("Not a directory");
            this.directory = directory;
            this.beforeMove = beforeMove;
        }
        @Override public Iterator<Path> iterator() { throw new UnsupportedOperationException(); }
        @Override public void close() {}
        @Override public SecureDirectoryStream<Path> newDirectoryStream(Path path, LinkOption... options)
                throws IOException {
            if (Files.isSymbolicLink(directory.resolve(path))) throw new IOException("Symbolic-link directory");
            return new HostSecureDirectoryStream(directory.resolve(path), beforeMove);
        }
        @Override public SeekableByteChannel newByteChannel(Path path, Set<? extends OpenOption> options,
                FileAttribute<?>... attrs) throws IOException {
            return FileChannel.open(directory.resolve(path), options, attrs);
        }
        @Override public void deleteFile(Path path) throws IOException { Files.delete(directory.resolve(path)); }
        @Override public void deleteDirectory(Path path) throws IOException { Files.delete(directory.resolve(path)); }
        @Override public void move(Path srcpath, SecureDirectoryStream<Path> targetdir, Path targetpath)
                throws IOException {
            HostSecureDirectoryStream target = (HostSecureDirectoryStream) targetdir;
            beforeMove.accept(directory.resolve(srcpath));
            Files.move(directory.resolve(srcpath), target.directory.resolve(targetpath),
                    StandardCopyOption.REPLACE_EXISTING);
        }
        @Override public <V extends java.nio.file.attribute.FileAttributeView> V getFileAttributeView(Class<V> type) {
            return Files.getFileAttributeView(directory, type);
        }
        @Override public <V extends java.nio.file.attribute.FileAttributeView> V getFileAttributeView(
                Path path, Class<V> type, LinkOption... options) {
            return Files.getFileAttributeView(directory.resolve(path), type, options);
        }
    }

    private static void reject(Checked action, String label) throws Exception {
        try { action.run(); }
        catch (IOException expected) { return; }
        throw new AssertionError("Accepted " + label);
    }

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
}
