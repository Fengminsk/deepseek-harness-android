package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/**
 * Trusted App-side journal for a proposed Linux guest. It never starts a guest or grants Shell.
 * Its separate receipt tree must not be passed to the V8 script result reader. A completed
 * receipt is only a candidate until an App-verified session commits and its publication marker
 * is durable. On restart, a candidate without that marker is uncertain and is never replayed.
 */
final class LinuxGuestRunJournal {
    private static final int MARKER_MAGIC = 0x44534847;
    private static final int MARKER_VERSION = 1;
    private static final int MARKER_BYTES = 4 + 4 + 16 + 32;
    private final Path root;
    private final Path publications;
    private final Path receiptFiles;
    private final IsolatedScriptReceipt receipts;
    private final IsolatedScriptReceipt.DirectorySync sync;

    LinuxGuestRunJournal(Path appPrivateParent, IsolatedScriptReceipt.DirectorySync sync)
            throws IOException {
        this.sync = Objects.requireNonNull(sync);
        Path parent = appPrivateParent.toAbsolutePath().normalize();
        checkDirectory(parent);
        root = parent.resolve("linux-guest-runs");
        ensureDirectory(root, parent);
        publications = root.resolve("publications");
        ensureDirectory(publications, root);
        receipts = new IsolatedScriptReceipt(root, sync);
        receiptFiles = root.resolve("isolated-script-runs");
    }

    /** Use as IsolatedExecutionPolicyOwner.DurableAdmission; reserve before binding Service. */
    IsolatedExecutionPolicyOwner.DurableAdmission admission() {
        return (runId, scope) -> receipts.admit(runId);
    }

    void admit(String runId) throws IOException { receipts.admit(runId); }

    /**
     * The trace, broker settlements and lease must still be live after the candidate fsync.
     * Only this method's successful return permits user-visible success notification.
     */
    synchronized boolean complete(LinuxGuestLaunchSession session, String runId,
                                  String outputJson) throws IOException {
        Objects.requireNonNull(session);
        IsolatedScriptWire.requireUuid(runId);
        if (!session.matchesRunId(runId) || !session.readyToPersistSuccess()) return false;
        IsolatedScriptReceipt.Entry candidate = new IsolatedScriptReceipt.Entry(
                runId, IsolatedScriptReceipt.State.COMPLETED, outputJson, null);
        receipts.finish(candidate);
        if (!session.markDurableSuccess()) return false;
        writePublication(runId, outputJson);
        return session.markPublicationCommitted();
    }

    /** Cancellation, Binder/Service death and unconfirmed descendants never carry output. */
    synchronized void fail(LinuxGuestLaunchSession session, String runId,
                           IsolatedScriptReceipt.State state, String detail) throws IOException {
        if (state == IsolatedScriptReceipt.State.ADMITTED
                || state == IsolatedScriptReceipt.State.COMPLETED)
            throw new IllegalArgumentException("Guest failure must be terminal and unsuccessful");
        Objects.requireNonNull(session);
        session.cancel();
        receipts.finish(new IsolatedScriptReceipt.Entry(runId, state, null, detail));
    }

    /** A Service death with unconfirmed tracee retirement is conservatively uncertain. */
    void serviceDied(LinuxGuestLaunchSession session, String runId) throws IOException {
        fail(session, runId, IsolatedScriptReceipt.State.RETIRE_UNCONFIRMED,
                "Guest Service died before all tracees were confirmed retired");
    }

    /** Sole user-visible read path: a candidate is never presented as completed. */
    synchronized IsolatedScriptReceipt.Entry read(String runId) throws IOException {
        IsolatedScriptReceipt.Entry entry = receipts.read(runId);
        Path marker = publication(runId);
        if (entry.state() != IsolatedScriptReceipt.State.COMPLETED) {
            if (Files.exists(marker, LinkOption.NOFOLLOW_LINKS))
                throw new IOException("Guest publication conflicts with terminal state");
            return entry;
        }
        if (!Files.exists(marker, LinkOption.NOFOLLOW_LINKS)) return uncertain(runId);
        if (!validPublication(marker, runId, entry.outputJson()))
            throw new IOException("Guest publication is damaged or mismatched");
        return entry;
    }

    /** Reconcile app-process death without rerunning a guest or exposing raw candidates. */
    synchronized List<IsolatedScriptReceipt.Entry> recover() throws IOException {
        receipts.recoverInterrupted();
        checkDirectory(receiptFiles);
        List<IsolatedScriptReceipt.Entry> results = new ArrayList<>();
        try (DirectoryStream<Path> files = Files.newDirectoryStream(receiptFiles, "*.receipt")) {
            for (Path path : files) {
                String name = path.getFileName().toString();
                String runId = name.substring(0, name.length() - ".receipt".length());
                IsolatedScriptWire.requireUuid(runId);
                results.add(read(runId));
            }
        }
        return AndroidJava28.copyList(results);
    }

    private void writePublication(String runId, String outputJson) throws IOException {
        Path marker = publication(runId);
        UUID id = UUID.fromString(runId);
        ByteBuffer frame = ByteBuffer.allocate(MARKER_BYTES);
        frame.putInt(MARKER_MAGIC).putInt(MARKER_VERSION);
        frame.putLong(id.getMostSignificantBits()).putLong(id.getLeastSignificantBits());
        frame.put(digest(runId, outputJson));
        checkDirectory(publications);
        if (Files.exists(marker, LinkOption.NOFOLLOW_LINKS))
            throw new IOException("Guest result was already published");
        Path temp = Files.createTempFile(publications, "publication-", ".tmp");
        boolean renamed = false;
        try {
            try (FileChannel channel = FileChannel.open(temp, StandardOpenOption.WRITE,
                    LinkOption.NOFOLLOW_LINKS)) {
                frame.flip();
                while (frame.hasRemaining()) channel.write(frame);
                channel.force(true);
            }
            Files.move(temp, marker, StandardCopyOption.ATOMIC_MOVE);
            renamed = true;
            sync.sync(publications);
        } catch (IOException failed) {
            if (renamed) {
                try {
                    Files.deleteIfExists(marker);
                    sync.sync(publications);
                } catch (IOException cleanup) { failed.addSuppressed(cleanup); }
            }
            throw failed;
        } finally {
            Files.deleteIfExists(temp);
        }
    }

    private boolean validPublication(Path marker, String runId, String outputJson) throws IOException {
        if (!Files.isRegularFile(marker, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(marker))
            return false;
        ByteBuffer frame = ByteBuffer.allocate(MARKER_BYTES);
        try (FileChannel channel = FileChannel.open(marker, StandardOpenOption.READ,
                LinkOption.NOFOLLOW_LINKS)) {
            if (channel.size() != MARKER_BYTES) return false;
            while (frame.hasRemaining()) {
                if (channel.read(frame) <= 0) return false;
            }
        }
        frame.flip();
        UUID id = UUID.fromString(runId);
        if (frame.getInt() != MARKER_MAGIC || frame.getInt() != MARKER_VERSION
                || frame.getLong() != id.getMostSignificantBits()
                || frame.getLong() != id.getLeastSignificantBits()) return false;
        byte[] actual = new byte[32];
        frame.get(actual);
        return MessageDigest.isEqual(actual, digest(runId, outputJson));
    }

    private Path publication(String runId) {
        IsolatedScriptWire.requireUuid(runId);
        return publications.resolve(runId + ".published");
    }

    private static IsolatedScriptReceipt.Entry uncertain(String runId) {
        return new IsolatedScriptReceipt.Entry(runId,
                IsolatedScriptReceipt.State.INTERRUPTED_UNCONFIRMED, null,
                "Guest result was fsynced but publication was not confirmed");
    }

    private static byte[] digest(String runId, String outputJson) {
        try {
            MessageDigest sha = MessageDigest.getInstance("SHA-256");
            sha.update(runId.getBytes(StandardCharsets.UTF_8));
            sha.update((byte) 0);
            return sha.digest(outputJson.getBytes(StandardCharsets.UTF_8));
        } catch (NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
    }

    private void ensureDirectory(Path directory, Path parent) throws IOException {
        try {
            Files.createDirectory(directory);
            sync.sync(parent);
        } catch (java.nio.file.FileAlreadyExistsException existing) {
            checkDirectory(directory);
        }
    }

    private static void checkDirectory(Path path) throws IOException {
        if (!Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(path))
            throw new IOException("Guest journal directory is unavailable");
    }
}
