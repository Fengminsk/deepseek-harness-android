package com.minnnng.dsh_android;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.channels.OverlappingFileLockException;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/** Durable App-side policy history. It never restores a granted lease after process death. */
public final class IsolatedExecutionApprovalStore
        implements IsolatedExecutionPolicyOwner.DurableTransition, AutoCloseable {
    public static final int MAX_TRANSITIONS = 256;
    public static final int MAX_LOG_BYTES = 1024 * 1024;
    public static final int MAX_SCOPE_BYTES = 16 * 1024;
    private static final int MAGIC = 0x44534841;
    private static final int FORMAT = 1;
    private static final String LOG = "policy-transitions.log";
    private static final String LOCK = "policy-transitions.lock";

    public interface DirectorySync { void sync(Path directory) throws IOException; }

    private record Frame(long version, byte[] previousHash, byte[] scope, byte kind,
                         String approvalId, boolean granted) {}
    private record ScopeView(long version, boolean granted) {}

    private final Path root;
    private final String ownerId;
    private final String sessionId;
    private final DirectorySync sync;
    private final FileChannel lockChannel;
    private final FileLock lock;
    private final List<Frame> frames = new ArrayList<>();
    private final Set<String> usedApprovals = new HashSet<>();
    private byte[] latestHash;
    private long latestVersion = 1;
    private boolean closed;
    private boolean released;
    private byte[] preparedHash;
    private String preparedApprovalId;
    private IsolatedExecutionPolicyOwner issuedOwner;

    /** The directory must already exist inside the App-selected private root. */
    public IsolatedExecutionApprovalStore(Path appPrivateRoot, Path directory,
                                          String ownerId, String sessionId,
                                          DirectorySync sync) throws IOException {
        this.ownerId = Objects.requireNonNull(ownerId);
        this.sessionId = Objects.requireNonNull(sessionId);
        IsolatedScriptWire.requireUuid(sessionId);
        this.sync = Objects.requireNonNull(sync);
        Path privateRoot = appPrivateRoot.toRealPath();
        this.root = directory.toRealPath();
        if (!Files.isDirectory(privateRoot, LinkOption.NOFOLLOW_LINKS)
                || !Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS)
                || Files.isSymbolicLink(appPrivateRoot) || Files.isSymbolicLink(directory)
                || root.equals(privateRoot) || !root.startsWith(privateRoot))
            throw new IOException("Approval store is outside the App-private root");
        // Scope validates the owner identity even when the log is absent.
        IsolatedExecutionPolicyOwner.Scope.denied(ownerId, sessionId, 1);
        latestHash = hash(encodeScope(IsolatedExecutionPolicyOwner.Scope.denied(ownerId, sessionId, 1)));
        Path lockPath = root.resolve(LOCK);
        boolean newLock = !Files.exists(lockPath, LinkOption.NOFOLLOW_LINKS);
        if (!newLock && (!Files.isRegularFile(lockPath, LinkOption.NOFOLLOW_LINKS)
                || Files.isSymbolicLink(lockPath)))
            throw new IOException("Approval lock is not regular");
        FileChannel channel = FileChannel.open(lockPath, StandardOpenOption.CREATE,
                StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS);
        FileLock held = null;
        try {
            if (newLock) sync.sync(root);
            try { held = channel.tryLock(); }
            catch (OverlappingFileLockException busy) {
                throw new IOException("Approval store already has a writer", busy);
            }
            if (held == null) throw new IOException("Approval store already has a writer");
            discardUnpublishedTemps();
            load();
            byte[] canonicalDenied = hash(encodeScope(
                    IsolatedExecutionPolicyOwner.Scope.denied(ownerId, sessionId, latestVersion)));
            if (!MessageDigest.isEqual(latestHash, canonicalDenied)) {
                if (latestVersion == Long.MAX_VALUE - 1)
                    throw new IOException("Approval policy version exhausted");
                append(IsolatedExecutionPolicyOwner.Scope.denied(ownerId, sessionId,
                        latestVersion + 1), (byte)3, null);
            }
        } catch (IOException | RuntimeException failure) {
            if (held != null) try { held.release(); }
            catch (IOException closeFailure) { failure.addSuppressed(closeFailure); }
            try { channel.close(); }
            catch (IOException closeFailure) { failure.addSuppressed(closeFailure); }
            throw failure;
        }
        lockChannel = channel;
        lock = held;
    }

    /** Recovery exposes only the new denied version, never a stored grant or live lease. */
    public synchronized IsolatedExecutionPolicyOwner.Scope recoveredDenied() throws IOException {
        requireOpen();
        return IsolatedExecutionPolicyOwner.Scope.denied(ownerId, sessionId, latestVersion);
    }

    /** The caller must bind admission to the one-use script receipt store. */
    public synchronized IsolatedExecutionPolicyOwner newOwner(
            IsolatedExecutionPolicyOwner.DurableAdmission admission) throws IOException {
        requireOpen();
        if (issuedOwner != null) throw new IOException("Approval store already issued an owner");
        issuedOwner = new IsolatedExecutionPolicyOwner(recoveredDenied(), admission, this);
        return issuedOwner;
    }

    /** Trusted App UI prepares one exact grant; this store cannot authenticate a user gesture. */
    public synchronized void prepareTrustedUiApproval(IsolatedExecutionPolicyOwner.Scope next,
                                                       String approvalId) throws IOException {
        requireOpen();
        Objects.requireNonNull(next);
        if (preparedHash != null || !identity(next) || next.version() != latestVersion + 1 || !hasGrant(next)
                || !canonicalUuid(approvalId) || usedApprovals.contains(approvalId))
            throw new IllegalArgumentException("Invalid or repeated App approval");
        preparedHash = hash(encodeScope(next));
        preparedApprovalId = approvalId;
    }

    /** Called by PolicyOwner.replace; a failed or uncertain write permanently closes this writer. */
    @Override public synchronized void record(IsolatedExecutionPolicyOwner.Scope previous,
                                               IsolatedExecutionPolicyOwner.Scope next) throws IOException {
        requireOpen();
        Objects.requireNonNull(previous);
        Objects.requireNonNull(next);
        byte[] approvedHash = preparedHash;
        String approvedId = preparedApprovalId;
        preparedHash = null;
        preparedApprovalId = null;
        byte[] previousHash = hash(encodeScope(previous));
        byte[] nextHash = hash(encodeScope(next));
        if (!identity(previous) || !identity(next) || previous.version() != latestVersion
                || next.version() != latestVersion + 1
                || !MessageDigest.isEqual(previousHash, latestHash))
            throw new IllegalArgumentException("Approval policy transition does not match durable state");
        boolean grant = hasGrant(next);
        String approvalId = grant ? approvedId : null;
        if (grant && (approvalId == null || !MessageDigest.isEqual(approvedHash, nextHash)))
            throw new IllegalArgumentException("Granted scope lacks an exact App approval");
        try { append(next, grant ? (byte)1 : (byte)2, approvalId); }
        catch (IOException | RuntimeException failure) { closed = true; throw failure; }
    }

    public synchronized int transitionCount() throws IOException {
        requireOpen();
        return frames.size();
    }

    @Override public void close() throws IOException {
        IsolatedExecutionPolicyOwner owner;
        synchronized (this) {
            if (released) return;
            released = true;
            closed = true;
            owner = issuedOwner;
        }
        // Never wait for the owner's monitor while holding the store monitor:
        // owner.replace holds that monitor while it calls this store.
        if (owner != null) owner.close();
        try { if (lock.isValid()) lock.release(); }
        finally { lockChannel.close(); }
    }

    private void append(IsolatedExecutionPolicyOwner.Scope next, byte kind,
                        String approvalId) throws IOException {
        if (frames.size() >= MAX_TRANSITIONS) throw new IOException("Approval history is full");
        byte[] scope = encodeScope(next);
        if (scope.length > MAX_SCOPE_BYTES) throw new IOException("Approval scope exceeds frame limit");
        List<Frame> changed = new ArrayList<>(frames);
        changed.add(new Frame(next.version(), latestHash.clone(), scope, kind, approvalId,
                hasGrant(next)));
        byte[] log = encodeLog(changed);
        if (log.length > MAX_LOG_BYTES) throw new IOException("Approval history exceeds byte limit");
        Path temp = Files.createTempFile(root, "approval-", ".tmp");
        try {
            try (FileChannel channel = FileChannel.open(temp, StandardOpenOption.WRITE,
                    LinkOption.NOFOLLOW_LINKS)) {
                ByteBuffer buffer = ByteBuffer.wrap(log);
                while (buffer.hasRemaining()) channel.write(buffer);
                channel.force(true);
            }
            Files.move(temp, root.resolve(LOG), StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING);
            sync.sync(root);
        } finally { Files.deleteIfExists(temp); }
        frames.add(changed.get(changed.size() - 1));
        latestHash = hash(scope);
        latestVersion = next.version();
        if (approvalId != null) usedApprovals.add(approvalId);
    }

    private byte[] encodeLog(List<Frame> history) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try (DataOutputStream out = new DataOutputStream(bytes)) {
            out.writeInt(MAGIC);
            out.writeInt(FORMAT);
            out.writeUTF(ownerId);
            out.writeUTF(sessionId);
            out.writeInt(history.size());
            for (Frame frame : history) {
                out.write(frame.previousHash());
                out.writeByte(frame.kind());
                out.writeUTF(frame.approvalId() == null ? "" : frame.approvalId());
                out.writeInt(frame.scope().length);
                out.write(frame.scope());
            }
        }
        byte[] content = bytes.toByteArray();
        byte[] log = Arrays.copyOf(content, content.length + 32);
        System.arraycopy(hash(content), 0, log, content.length, 32);
        return log;
    }

    private void load() throws IOException {
        Path file = root.resolve(LOG);
        if (!Files.exists(file, LinkOption.NOFOLLOW_LINKS)) return;
        if (!Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(file)
                || Files.size(file) > MAX_LOG_BYTES)
            throw new IOException("Approval history is invalid or full");
        byte[] log = Files.readAllBytes(file);
        if (log.length < 48) throw new IOException("Approval history is truncated");
        byte[] content = Arrays.copyOf(log, log.length - 32);
        if (!MessageDigest.isEqual(hash(content), Arrays.copyOfRange(log, content.length, log.length)))
            throw new IOException("Approval history checksum mismatch");
        try (DataInputStream in = new DataInputStream(new ByteArrayInputStream(content))) {
            if (in.readInt() != MAGIC || in.readInt() != FORMAT
                    || !ownerId.equals(in.readUTF()) || !sessionId.equals(in.readUTF()))
                throw new IOException("Approval history identity mismatch");
            int count = in.readInt();
            if (count < 1 || count > MAX_TRANSITIONS)
                throw new IOException("Approval history count is invalid");
            for (int index = 0; index < count; index++) {
                byte[] previousHash = new byte[32];
                in.readFully(previousHash);
                byte kind = in.readByte();
                String approval = in.readUTF();
                int size = in.readInt();
                if (size < 1 || size > MAX_SCOPE_BYTES
                        || !MessageDigest.isEqual(previousHash, latestHash))
                    throw new IOException("Approval history chain is damaged");
                byte[] scope = new byte[size];
                in.readFully(scope);
                ScopeView view = parseScope(scope);
                if (view.version() != latestVersion + 1 || kind < 1 || kind > 3
                        || (kind == 1) != view.granted() || kind == 3 && view.granted()
                        || (kind == 1 && (!canonicalUuid(approval) || !usedApprovals.add(approval)))
                        || (kind != 1 && !approval.isEmpty()))
                    throw new IOException("Approval history transition is invalid");
                frames.add(new Frame(view.version(), previousHash, scope, kind,
                        approval.isEmpty() ? null : approval, view.granted()));
                latestHash = hash(scope);
                latestVersion = view.version();
            }
            if (in.available() != 0) throw new IOException("Approval history has trailing data");
        }
    }

    private void discardUnpublishedTemps() throws IOException {
        boolean deleted = false;
        try (DirectoryStream<Path> pending = Files.newDirectoryStream(root, "approval-*.tmp")) {
            for (Path path : pending) {
                if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(path))
                    throw new IOException("Approval temp is not regular");
                Files.delete(path);
                deleted = true;
            }
        }
        if (deleted) sync.sync(root);
    }

    private static ScopeView parseScope(byte[] scope) throws IOException {
        try (DataInputStream in = new DataInputStream(new ByteArrayInputStream(scope))) {
            long version = in.readLong();
            nullable(in);
            nullable(in);
            int readable = readSet(in);
            int writable = readSet(in);
            int hosts = readSet(in);
            int fileCalls = in.readInt();
            int networkCalls = in.readInt();
            long lease = in.readLong();
            if (version < 2 || fileCalls < 0 || fileCalls > IsolatedCapabilityBroker.MAX_CALLS
                    || networkCalls < 0 || networkCalls > IsolatedNetworkBroker.MAX_CALLS
                    || lease < 1 || lease > IsolatedCapabilityBroker.MAX_LEASE_MILLIS
                    || in.available() != 0)
                throw new IOException("Approval scope is invalid");
            return new ScopeView(version, readable > 0 || writable > 0 || hosts > 0);
        }
    }

    private static byte[] encodeScope(IsolatedExecutionPolicyOwner.Scope scope) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try (DataOutputStream out = new DataOutputStream(bytes)) {
            out.writeLong(scope.version());
            nullable(out, scope.appPrivateRoot());
            nullable(out, scope.workspaceRoot());
            writeSet(out, scope.readablePaths());
            writeSet(out, scope.writablePaths());
            writeSet(out, scope.exactHosts());
            out.writeInt(scope.fileCallLimit());
            out.writeInt(scope.networkCallLimit());
            out.writeLong(scope.leaseMillis());
        }
        return bytes.toByteArray();
    }

    private static void writeSet(DataOutputStream out, Set<String> values) throws IOException {
        if (values.size() > 32) throw new IOException("Approval scope set is excessive");
        out.writeInt(values.size());
        List<String> sorted = new ArrayList<>(values);
        Collections.sort(sorted);
        for (String value : sorted) out.writeUTF(value);
    }

    private static int readSet(DataInputStream in) throws IOException {
        int count = in.readInt();
        if (count < 0 || count > 32) throw new IOException("Approval scope set is excessive");
        String last = null;
        for (int i = 0; i < count; i++) {
            String next = in.readUTF();
            if (next.isEmpty() || last != null && next.compareTo(last) <= 0)
                throw new IOException("Approval scope set is invalid");
            last = next;
        }
        return count;
    }

    private static void nullable(DataOutputStream out, Path value) throws IOException {
        out.writeBoolean(value != null);
        if (value != null) out.writeUTF(value.toString());
    }

    private static void nullable(DataInputStream in) throws IOException {
        if (in.readBoolean() && in.readUTF().isEmpty()) throw new IOException("Empty approval path");
    }

    private boolean identity(IsolatedExecutionPolicyOwner.Scope scope) {
        return ownerId.equals(scope.ownerId()) && sessionId.equals(scope.sessionId());
    }

    private static boolean hasGrant(IsolatedExecutionPolicyOwner.Scope scope) {
        return !scope.readablePaths().isEmpty() || !scope.writablePaths().isEmpty()
                || !scope.exactHosts().isEmpty();
    }

    private static boolean canonicalUuid(String value) {
        try { return value != null && UUID.fromString(value).toString().equals(value); }
        catch (IllegalArgumentException invalid) { return false; }
    }

    private void requireOpen() throws IOException {
        if (closed) throw new IOException("Approval store is closed after an uncertain transition");
    }

    private static byte[] hash(byte[] value) {
        try { return MessageDigest.getInstance("SHA-256").digest(value); }
        catch (NoSuchAlgorithmException unavailable) { throw new AssertionError(unavailable); }
    }
}
