package com.minnnng.dsh_android;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.HashSet;
import java.util.UUID;
import java.util.zip.CRC32;

/** App-private, single-writer workflow ownership; no guest or model can call this class. */
public final class DurableWorkflowOwner {
    // Append states to preserve the ordinal in existing durable receipts.
    public enum State { ADMITTED, CANCEL_REQUESTED, COMPLETED, CANCELLED, INTERRUPTED_UNCONFIRMED, FAILED }
    public enum ChildState { RESERVED, LAUNCHING, RETIRED, INTERRUPTED_UNCONFIRMED }
    public record Child(String id, ChildState state) {}
    public record Entry(String runId, State state, List<Child> children, String outputJson) {
        public Entry { children = AndroidJava28.copyList(children); }
    }
    public record Recovery(String runId, List<String> childIdsToCancel) {
        public Recovery { childIdsToCancel = AndroidJava28.copyList(childIdsToCancel); }
    }
    public interface DirectorySync { void sync(Path directory) throws IOException; }

    private static final int MAGIC = 0x44534857;
    private static final int VERSION = 1;
    private static final int MAX_CHILDREN = 128;
    private static final int MAX_RUNS = 4096;
    private static final int MAX_FRAME = 128 * 1024;
    private static final int MAX_OUTPUT = 64 * 1024;
    private static final Object PROCESS_LOCK = new Object();
    private final Path root;
    private final Path lockPath;
    private final DirectorySync sync;
    private volatile boolean reconciled;

    /** Parent must be an existing App-private directory. Caller supplies an Android directory fsync. */
    public DurableWorkflowOwner(Path appPrivateParent, DirectorySync sync) throws IOException {
        this.sync = Objects.requireNonNull(sync);
        Path parent = appPrivateParent.toAbsolutePath().normalize();
        if (!Files.isDirectory(parent, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(parent))
            throw new IOException("Workflow parent is not an App-private directory");
        root = parent.resolve("workflow-runs");
        try {
            Files.createDirectory(root);
            sync.sync(parent);
        } catch (java.nio.file.FileAlreadyExistsException existing) {
            checkRoot();
        }
        checkRoot();
        lockPath = root.resolve("owner.lock");
        if (!Files.exists(lockPath, LinkOption.NOFOLLOW_LINKS)) {
            try (FileChannel channel = FileChannel.open(lockPath, StandardOpenOption.CREATE_NEW,
                    StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS)) {
                channel.force(true);
            } catch (java.nio.file.FileAlreadyExistsException concurrent) {
                // The other owner created the same lock file. Verify it below.
            }
            sync.sync(root);
        }
        if (!Files.isRegularFile(lockPath, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(lockPath))
            throw new IOException("Workflow lock is not a regular file");
    }

    /** Reserves a never-reusable run ID before any guest or child starts. */
    public void admit(String runId) throws IOException {
        validRunId(runId);
        withLock(() -> {
            requireReconciled();
            Path target = file(runId);
            int count = 0;
            try (DirectoryStream<Path> files = Files.newDirectoryStream(root, "run-*.receipt")) {
                for (Path ignored : files) {
                    if (++count >= MAX_RUNS) throw new IOException("Workflow receipt capacity exhausted");
                }
            }
            boolean created = false;
            try {
                try (FileChannel channel = FileChannel.open(target, StandardOpenOption.CREATE_NEW,
                        StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS)) {
                    created = true;
                    writeAll(channel, encode(new Entry(runId, State.ADMITTED, AndroidJava28.listOf(), null)));
                    channel.force(true);
                }
                sync.sync(root);
            } catch (IOException | RuntimeException uncertain) {
                if (created) reconciled = false;
                throw uncertain;
            }
            return null;
        });
    }

    /** A child ID is durable before activation; the future safe adapter must launch under this exact ID. */
    public String reserveChild(String runId) throws IOException {
        return withLock(() -> {
            requireReconciled();
            Entry entry = readInternal(runId);
            requireState(entry, State.ADMITTED);
            if (entry.children().size() >= MAX_CHILDREN) throw new IOException("Workflow child cap reached");
            // The original local subagent backend persists this exact ID as a
            // SessionId. Reserve a UUID before activation so the App receipt
            // and the child Session can refer to the same durable identity.
            String id = UUID.randomUUID().toString();
            List<Child> children = new ArrayList<>(entry.children());
            children.add(new Child(id, ChildState.RESERVED));
            replace(new Entry(runId, entry.state(), children, null));
            return id;
        });
    }

    /** Persist LAUNCHING before asking a confined child backend to start. */
    public void markLaunching(String runId, String childId) throws IOException {
        changeChild(runId, childId, ChildState.RESERVED, ChildState.LAUNCHING, false);
    }

    /** Call only after the safe backend has confirmed termination and durable child retirement. */
    public void confirmChildRetired(String runId, String childId) throws IOException {
        changeChild(runId, childId, ChildState.LAUNCHING, ChildState.RETIRED, true);
    }

    /** A safe backend may retire a cancelled or interrupted child only after confirming it is stopped. */
    public void confirmStoppedChild(String runId, String childId) throws IOException {
        withLock(() -> {
            requireReconciled();
            Entry entry = readInternal(runId);
            if (entry.state() != State.CANCEL_REQUESTED && entry.state() != State.INTERRUPTED_UNCONFIRMED)
                throw new IOException("Workflow run has not stopped");
            List<Child> children = new ArrayList<>(entry.children());
            int index = -1;
            for (int i = 0; i < children.size(); i++) {
                if (children.get(i).id().equals(childId)) { index = i; break; }
            }
            if (index < 0) throw new IOException("Child is not owned by workflow");
            if (children.get(index).state() != ChildState.RETIRED) {
                children.set(index, new Child(childId, ChildState.RETIRED));
                replace(new Entry(runId, entry.state(), children, null));
            }
            return null;
        });
    }

    /** Record cancellation before signalling guest and children; returned IDs remain owned by this run. */
    public List<String> requestCancel(String runId) throws IOException {
        return withLock(() -> {
            requireReconciled();
            Entry entry = readInternal(runId);
            if (entry.state() == State.CANCEL_REQUESTED) return pendingIds(entry);
            requireState(entry, State.ADMITTED);
            replace(new Entry(runId, State.CANCEL_REQUESTED, entry.children(), null));
            return pendingIds(entry);
        });
    }

    /** A completed guest receipt and retirement of every child precede success publication. */
    public Entry complete(String runId, IsolatedScriptReceipt scripts) throws IOException {
        Objects.requireNonNull(scripts);
        return withLock(() -> {
            requireReconciled();
            Entry entry = readInternal(runId);
            requireState(entry, State.ADMITTED);
            requireRetired(entry);
            IsolatedScriptReceipt.Entry script = scripts.read(runId);
            if (script.state() != IsolatedScriptReceipt.State.COMPLETED || script.outputJson() == null)
                throw new IOException("Guest completion is not confirmed");
            if (IsolatedScriptWire.utf8Bytes(script.outputJson()) > MAX_OUTPUT)
                throw new IOException("Workflow output is too large");
            Entry terminal = new Entry(runId, State.COMPLETED, entry.children(), script.outputJson());
            replace(terminal);
            return terminal;
        });
    }

    /** Cancellation is terminal only with a cancelled guest receipt and retired children. */
    public Entry confirmCancelled(String runId, IsolatedScriptReceipt scripts) throws IOException {
        Objects.requireNonNull(scripts);
        return withLock(() -> {
            requireReconciled();
            Entry entry = readInternal(runId);
            requireState(entry, State.CANCEL_REQUESTED);
            requireRetired(entry);
            if (scripts.read(runId).state() != IsolatedScriptReceipt.State.CANCELLED)
                throw new IOException("Guest cancellation is not confirmed");
            Entry terminal = new Entry(runId, State.CANCELLED, entry.children(), null);
            replace(terminal);
            return terminal;
        });
    }

    /** A confirmed guest error is terminal only after every owned child has retired. */
    public Entry confirmFailed(String runId, IsolatedScriptReceipt scripts) throws IOException {
        Objects.requireNonNull(scripts);
        return withLock(() -> {
            requireReconciled();
            Entry entry = readInternal(runId);
            if (entry.state() != State.ADMITTED && entry.state() != State.CANCEL_REQUESTED)
                throw new IOException("Workflow run is not active");
            requireRetired(entry);
            IsolatedScriptReceipt.State guest = scripts.read(runId).state();
            if (guest != IsolatedScriptReceipt.State.ERROR
                    && guest != IsolatedScriptReceipt.State.TIMED_OUT
                    && guest != IsolatedScriptReceipt.State.WORKER_DIED)
                throw new IOException("Guest failure is not confirmed");
            Entry terminal = new Entry(runId, State.FAILED, entry.children(), null);
            replace(terminal);
            return terminal;
        });
    }

    /** A completed V8 call can still report a DSL-level error; never persist its output as success. */
    public Entry confirmGuestReportedFailure(String runId, IsolatedScriptReceipt scripts) throws IOException {
        Objects.requireNonNull(scripts);
        return withLock(() -> {
            requireReconciled();
            Entry entry = readInternal(runId);
            if (entry.state() != State.ADMITTED && entry.state() != State.CANCEL_REQUESTED)
                throw new IOException("Workflow run is not active");
            requireRetired(entry);
            IsolatedScriptReceipt.Entry script = scripts.read(runId);
            if (script.state() != IsolatedScriptReceipt.State.COMPLETED || script.outputJson() == null)
                throw new IOException("Guest-reported failure lacks a completed script receipt");
            Entry terminal = new Entry(runId, State.FAILED, entry.children(), null);
            replace(terminal);
            return terminal;
        });
    }

    /** Persist an uncertain run without changing any other live workflow. */
    public Entry markUnconfirmed(String runId) throws IOException {
        return withLock(() -> {
            requireReconciled();
            Entry entry = readInternal(runId);
            if (terminal(entry.state())) return entry;
            List<Child> children = new ArrayList<>();
            for (Child child : entry.children()) children.add(new Child(child.id(),
                    child.state() == ChildState.RETIRED ? ChildState.RETIRED
                            : ChildState.INTERRUPTED_UNCONFIRMED));
            Entry uncertain = new Entry(runId, State.INTERRUPTED_UNCONFIRMED, children, null);
            replace(uncertain);
            return uncertain;
        });
    }

    /** Startup reconciliation never replays an admitted run or child. */
    public List<Recovery> recoverInterrupted() throws IOException {
        return withLock(() -> {
            reconciled = false;
            List<Recovery> recovered = new ArrayList<>();
            try (DirectoryStream<Path> files = Files.newDirectoryStream(root, "run-*.receipt")) {
                for (Path path : files) {
                    if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(path))
                        throw new IOException("Workflow receipt is not a regular file");
                    String name = path.getFileName().toString();
                    String runId = name.substring(4, name.length() - ".receipt".length());
                    Entry entry = readInternal(runId);
                    if (terminal(entry.state())) {
                        if (entry.state() == State.INTERRUPTED_UNCONFIRMED
                                && !pendingIds(entry).isEmpty())
                            recovered.add(new Recovery(runId, pendingIds(entry)));
                        continue;
                    }
                    List<String> pending = pendingIds(entry);
                    List<Child> children = new ArrayList<>();
                    for (Child child : entry.children()) children.add(new Child(child.id(),
                            child.state() == ChildState.RETIRED ? ChildState.RETIRED
                                    : ChildState.INTERRUPTED_UNCONFIRMED));
                    replace(new Entry(runId, State.INTERRUPTED_UNCONFIRMED, children, null));
                    recovered.add(new Recovery(runId, pending));
                }
            }
            reconciled = true;
            return AndroidJava28.copyList(recovered);
        });
    }

    /** Reads one durable state; malformed or torn files fail closed and preserve their run IDs. */
    public Entry read(String runId) throws IOException { return withLock(() -> readInternal(runId)); }

    private void changeChild(String runId, String childId, ChildState before,
                             ChildState after, boolean allowCancellation) throws IOException {
        withLock(() -> {
            requireReconciled();
            Entry entry = readInternal(runId);
            if (entry.state() != State.ADMITTED
                    && !(allowCancellation && entry.state() == State.CANCEL_REQUESTED))
                throw new IOException("Workflow run is no longer active");
            List<Child> children = new ArrayList<>(entry.children());
            int index = -1;
            for (int i = 0; i < children.size(); i++) {
                if (children.get(i).id().equals(childId)) { index = i; break; }
            }
            if (index < 0 || children.get(index).state() != before)
                throw new IOException("Child is not owned in the expected state");
            children.set(index, new Child(childId, after));
            replace(new Entry(runId, entry.state(), children, null));
            return null;
        });
    }

    private static List<String> pendingIds(Entry entry) {
        List<String> ids = new ArrayList<>();
        for (Child child : entry.children()) if (child.state() != ChildState.RETIRED) ids.add(child.id());
        return AndroidJava28.copyList(ids);
    }

    private static void requireRetired(Entry entry) throws IOException {
        if (!pendingIds(entry).isEmpty()) throw new IOException("Workflow children are not retired");
    }

    private static void requireState(Entry entry, State wanted) throws IOException {
        if (entry.state() != wanted) throw new IOException("Workflow run has already changed state");
    }

    private void requireReconciled() throws IOException {
        if (!reconciled) throw new IOException("Workflow startup recovery is required");
    }

    private static boolean terminal(State state) {
        return state == State.COMPLETED || state == State.CANCELLED || state == State.FAILED
                || state == State.INTERRUPTED_UNCONFIRMED;
    }

    private void replace(Entry entry) throws IOException {
        try {
            Path temp = Files.createTempFile(root, "workflow-", ".tmp");
            try {
                try (FileChannel channel = FileChannel.open(temp, StandardOpenOption.WRITE,
                        LinkOption.NOFOLLOW_LINKS)) {
                    writeAll(channel, encode(entry));
                    channel.force(true);
                }
                Files.move(temp, file(entry.runId()), StandardCopyOption.ATOMIC_MOVE,
                        StandardCopyOption.REPLACE_EXISTING);
                sync.sync(root);
            } finally { Files.deleteIfExists(temp); }
        } catch (IOException | RuntimeException uncertain) {
            reconciled = false;
            throw uncertain;
        }
    }

    private Entry readInternal(String runId) throws IOException {
        Path target = file(runId);
        if (!Files.isRegularFile(target, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(target))
            throw new IOException("Workflow receipt is missing or not regular");
        long size = Files.size(target);
        if (size < 16 || size > MAX_FRAME) throw new IOException("Workflow receipt has invalid size");
        byte[] frame = new byte[(int) size];
        try (FileChannel channel = FileChannel.open(target, StandardOpenOption.READ,
                LinkOption.NOFOLLOW_LINKS)) {
            ByteBuffer bytes = ByteBuffer.wrap(frame);
            while (bytes.hasRemaining()) if (channel.read(bytes) < 0) throw new IOException("Workflow receipt truncated");
        }
        return decode(runId, frame);
    }

    private static byte[] encode(Entry entry) throws IOException {
        ByteArrayOutputStream body = new ByteArrayOutputStream();
        try (DataOutputStream out = new DataOutputStream(body)) {
            out.writeInt(MAGIC);
            out.writeInt(VERSION);
            out.writeUTF(entry.runId());
            out.writeByte(entry.state().ordinal());
            out.writeShort(entry.children().size());
            for (Child child : entry.children()) {
                out.writeUTF(child.id());
                out.writeByte(child.state().ordinal());
            }
            out.writeBoolean(entry.outputJson() != null);
            if (entry.outputJson() != null) {
                byte[] output = entry.outputJson().getBytes(StandardCharsets.UTF_8);
                if (output.length > MAX_OUTPUT) throw new IOException("Workflow output is too large");
                out.writeInt(output.length);
                out.write(output);
            }
        }
        byte[] content = body.toByteArray();
        if (content.length > MAX_FRAME - 8) throw new IOException("Workflow receipt is too large");
        CRC32 crc = new CRC32();
        crc.update(content);
        ByteArrayOutputStream frame = new ByteArrayOutputStream();
        try (DataOutputStream out = new DataOutputStream(frame)) {
            out.writeInt(content.length);
            out.write(content);
            out.writeInt((int) crc.getValue());
        }
        return frame.toByteArray();
    }

    private static Entry decode(String requested, byte[] frame) throws IOException {
        try (DataInputStream in = new DataInputStream(new ByteArrayInputStream(frame))) {
            int length = in.readInt();
            if (length < 12 || length != frame.length - 8) throw new IOException("Workflow frame length mismatch");
            byte[] content = new byte[length];
            in.readFully(content);
            CRC32 crc = new CRC32();
            crc.update(content);
            if ((int) crc.getValue() != in.readInt()) throw new IOException("Workflow frame checksum mismatch");
            try (DataInputStream data = new DataInputStream(new ByteArrayInputStream(content))) {
                if (data.readInt() != MAGIC || data.readInt() != VERSION)
                    throw new IOException("Workflow frame version mismatch");
                String stored = data.readUTF();
                if (!stored.equals(requested)) throw new IOException("Workflow run ID mismatch");
                int stateIndex = data.readUnsignedByte();
                if (stateIndex >= State.values().length) throw new IOException("Workflow state invalid");
                State state = State.values()[stateIndex];
                int count = data.readUnsignedShort();
                if (count > MAX_CHILDREN) throw new IOException("Workflow child count invalid");
                List<Child> children = new ArrayList<>();
                Set<String> childIds = new HashSet<>();
                for (int i = 0; i < count; i++) {
                    String id = data.readUTF();
                    // Earlier receipts used runId:ordinal. Preserve their
                    // recovery path while new reservations use Session UUIDs.
                    if (!(id.equals(requested + ":" + (i + 1)) || canonicalUuid(id))
                            || id.equals(requested) || !childIds.add(id))
                        throw new IOException("Workflow child ownership invalid");
                    int childState = data.readUnsignedByte();
                    if (childState >= ChildState.values().length) throw new IOException("Workflow child state invalid");
                    children.add(new Child(id, ChildState.values()[childState]));
                }
                String output = null;
                if (data.readBoolean()) {
                    int outputLength = data.readInt();
                    if (outputLength < 0 || outputLength > MAX_OUTPUT || outputLength > data.available())
                        throw new IOException("Workflow output length invalid");
                    byte[] outputBytes = new byte[outputLength];
                    data.readFully(outputBytes);
                    output = new String(outputBytes, StandardCharsets.UTF_8);
                    if (!java.util.Arrays.equals(output.getBytes(StandardCharsets.UTF_8), outputBytes))
                        throw new IOException("Workflow output UTF-8 invalid");
                }
                if (data.available() != 0 || (state == State.COMPLETED) != (output != null))
                    throw new IOException("Workflow terminal output invalid");
                return new Entry(requested, state, children, output);
            }
        } catch (IllegalArgumentException malformed) {
            throw new IOException("Workflow receipt malformed", malformed);
        }
    }

    private Path file(String runId) {
        validRunId(runId);
        return root.resolve("run-" + runId + ".receipt");
    }

    private static void validRunId(String runId) {
        if (runId == null || !runId.equals(UUID.fromString(runId).toString()))
            throw new IllegalArgumentException("Canonical workflow UUID required");
    }

    private static boolean canonicalUuid(String id) {
        try { return id.equals(UUID.fromString(id).toString()); }
        catch (IllegalArgumentException invalid) { return false; }
    }

    private void checkRoot() throws IOException {
        if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(root))
            throw new IOException("Workflow directory was replaced");
    }

    private interface Operation<T> { T run() throws IOException; }

    private <T> T withLock(Operation<T> operation) throws IOException {
        synchronized (PROCESS_LOCK) {
            checkRoot();
            try (FileChannel channel = FileChannel.open(lockPath, StandardOpenOption.WRITE,
                    LinkOption.NOFOLLOW_LINKS); FileLock ignored = channel.lock()) {
                return operation.run();
            }
        }
    }

    private static void writeAll(FileChannel channel, byte[] bytes) throws IOException {
        ByteBuffer buffer = ByteBuffer.wrap(bytes);
        while (buffer.hasRemaining()) channel.write(buffer);
    }
}
