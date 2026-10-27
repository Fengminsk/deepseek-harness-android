package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.channels.OverlappingFileLockException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

/** Lifetime proof for workflow children confined to this App process, never for OS descendants. */
public final class WorkflowProcessLease {
    public enum Observation { LIVE, STOPPED, UNKNOWN }
    private static final Map<Path, WorkflowProcessLease> CURRENT = new HashMap<>();
    private final Path root;
    private final String id = UUID.randomUUID().toString();
    // Retain both references for the entire process lifetime. There is intentionally no close API.
    private final FileChannel channel;
    private final FileLock lock;

    private WorkflowProcessLease(Path parent, DurableWorkflowOwner.DirectorySync sync) throws IOException {
        root = parent.resolve("workflow-process-leases");
        try { Files.createDirectory(root); sync.sync(parent); }
        catch (java.nio.file.FileAlreadyExistsException existing) { checkRoot(); }
        checkRoot();
        channel = FileChannel.open(root.resolve(id + ".lease"), StandardOpenOption.CREATE_NEW,
                StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS);
        FileLock held = null;
        try {
            held = channel.lock();
            channel.force(true);
            sync.sync(root);
            lock = held;
        } catch (IOException | RuntimeException failure) {
            if (held != null) held.release();
            channel.close();
            throw failure;
        }
    }

    public static synchronized WorkflowProcessLease current(Path appPrivateParent,
            DurableWorkflowOwner.DirectorySync sync) throws IOException {
        Path parent = appPrivateParent.toAbsolutePath().normalize();
        if (!Files.isDirectory(parent, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(parent))
            throw new IOException("Workflow lease parent is not an App-private directory");
        WorkflowProcessLease existing = CURRENT.get(parent);
        if (existing != null) { existing.requireHeld(); return existing; }
        WorkflowProcessLease created = new WorkflowProcessLease(parent, sync);
        CURRENT.put(parent, created);
        return created;
    }

    public String id() throws IOException { requireHeld(); return id; }

    String idFor(Path parent) throws IOException {
        if (!root.getParent().equals(parent.toAbsolutePath().normalize()))
            throw new IOException("Workflow lease belongs to another App-private directory");
        return id();
    }

    /** Missing process identity or a held lock is not proof of termination. No PID reuse assumption. */
    public boolean confirmsStopped(String previousId) throws IOException {
        return observe(previousId) == Observation.STOPPED;
    }

    public Observation observe(String previousId) throws IOException {
        requireHeld();
        if (previousId == null) return Observation.UNKNOWN;
        IsolatedScriptWire.requireUuid(previousId);
        if (id.equals(previousId)) return Observation.LIVE;
        checkRoot();
        Path previous = root.resolve(previousId + ".lease");
        if (!Files.isRegularFile(previous, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(previous))
            return Observation.UNKNOWN;
        try (FileChannel prior = FileChannel.open(previous, StandardOpenOption.WRITE,
                LinkOption.NOFOLLOW_LINKS)) {
            try (FileLock available = prior.tryLock()) {
                return available != null ? Observation.STOPPED : Observation.LIVE;
            }
            catch (OverlappingFileLockException liveInThisProcess) { return Observation.LIVE; }
        }
    }

    private void requireHeld() throws IOException {
        if (!channel.isOpen() || !lock.isValid()) throw new IOException("Workflow process lease was lost");
    }

    private void checkRoot() throws IOException {
        if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(root))
            throw new IOException("Workflow lease directory was replaced");
    }
}
