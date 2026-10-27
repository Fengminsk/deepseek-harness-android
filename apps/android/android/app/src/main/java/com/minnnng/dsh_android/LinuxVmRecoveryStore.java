package com.minnnng.dsh_android;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * Durable run identity and disk-pointer attribution. Mutations require the caller's exclusive
 * session owner.lock. Observation never mutates or starts a worker. A DISPATCHED record alone
 * cannot prove retirement after owner death; it remains blocked until separate OS evidence exists.
 * Legacy files are read by the Android adapter and are never rewritten here.
 */
final class LinuxVmRecoveryStore {
    static final int MAX_RECORDS = 1024;
    static final int MAX_PAYLOAD = 1024 * 1024;
    private static final int RUN_MAGIC = 0x44535232;
    private static final int POINTER_MAGIC = 0x44535033;
    private static final Set<String> OPERATIONS = AndroidJava28.setOf("execute", "import", "export");
    private static final Set<String> STATUSES = AndroidJava28.setOf("completed", "cancelled", "timed_out", "failed",
            "worker_died", "interrupted", "recovered_committed", "outcome_uncertain");
    private static final Set<String> REASONS = AndroidJava28.setOf("admitted_not_dispatched", "execution_in_flight",
            "retired_before_publication", "export_publication_unconfirmed", "terminal_record",
            "pointer_committed", "interrupted_before_commit");
    interface DirectorySync { void sync(Path directory) throws IOException; }
    interface PayloadValidator { void validate(byte[] payload) throws IOException; }
    interface LegacyReader {
        byte[] pointer() throws IOException;
        List<View> records() throws IOException;
    }
    interface Faults { void hit(String point) throws IOException; }
    record View(String runId, String operation, String state, Boolean retirementConfirmed,
                Boolean diskCommitted, Boolean filePublished, Integer exitCode, String reason,
                boolean needsReview, boolean blocked) { }
    record Snapshot(String status, boolean blocked, boolean needsReview, Boolean requestedRunFound,
                    boolean truncated, List<View> records) { }

    /** Shared native/host contract encoder; the Android adapter wraps this exact JSON. */
    static String inspectionJson(String sessionId, Snapshot snapshot) {
        StringBuilder json = new StringBuilder("{\"version\":1,\"sessionId\":").append(quote(sessionId))
                .append(",\"status\":").append(quote(snapshot.status()))
                .append(",\"blocked\":").append(snapshot.blocked()).append(",\"needsReview\":").append(snapshot.needsReview())
                .append(",\"requestedRunFound\":").append(snapshot.requestedRunFound())
                .append(",\"truncated\":").append(snapshot.truncated()).append(",\"automaticReplay\":false,\"records\":[");
        boolean first = true;
        for (View record : snapshot.records()) {
            if (!first) json.append(','); first = false;
            json.append("{\"runId\":").append(quote(record.runId())).append(",\"operation\":").append(quote(record.operation()))
                    .append(",\"state\":").append(quote(record.state()))
                    .append(",\"retirementConfirmed\":").append(record.retirementConfirmed())
                    .append(",\"diskCommitted\":").append(record.diskCommitted()).append(",\"filePublished\":").append(record.filePublished())
                    .append(",\"exitCode\":").append(record.exitCode()).append(",\"reason\":").append(quote(record.reason()))
                    .append(",\"needsReview\":").append(record.needsReview()).append('}');
        }
        return json.append("]}").toString();
    }
    private static String quote(String text) {
        StringBuilder result = new StringBuilder("\"");
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c == '\\' || c == '"') result.append('\\').append(c);
            else if (c < 0x20) result.append(String.format("\\u%04x", (int) c));
            else result.append(c);
        }
        return result.append('"').toString();
    }
    record Pointer(String runId, String digest, byte[] payload) {
        Pointer { payload = payload.clone(); }
        @Override public byte[] payload() { return payload.clone(); }
    }
    static final class BarrierException extends IOException {
        final Snapshot snapshot;
        BarrierException(Snapshot snapshot) { super("Linux recovery requires inspection"); this.snapshot = snapshot; }
    }
    private record Run(String id, String session, String operation, String before, long created,
                       int phase, String status, Integer exit, Boolean disk, Boolean published,
                       boolean exportPrepared, String reason) { }
    private final Path root;
    private final Path runs;
    private final String session;
    private final DirectorySync sync;
    private final PayloadValidator validator;
    private final LegacyReader legacy;
    private final Faults faults;

    LinuxVmRecoveryStore(Path root, String session, DirectorySync sync,
                         PayloadValidator validator, LegacyReader legacy) {
        this(root, session, sync, validator, legacy, point -> { });
    }
    LinuxVmRecoveryStore(Path root, String session, DirectorySync sync,
                         PayloadValidator validator, LegacyReader legacy, Faults faults) {
        this.root = root.toAbsolutePath().normalize(); this.runs = this.root.resolve("runs-v2");
        if (session == null || session.isEmpty() || session.length() > 256) throw new IllegalArgumentException("Invalid session");
        this.session = session; this.sync = Objects.requireNonNull(sync);
        this.validator = Objects.requireNonNull(validator); this.legacy = Objects.requireNonNull(legacy);
        this.faults = Objects.requireNonNull(faults);
    }

    /** New pointers are authoritative. A corrupt v3 pointer never falls back to an older image. */
    Pointer pointer() throws IOException {
        Path file = root.resolve("state-v3.bin");
        if (!Files.exists(file, LinkOption.NOFOLLOW_LINKS)) {
            byte[] old = legacy.pointer();
            if (old == null) return null;
            validator.validate(old);
            return new Pointer(null, digest(old), old);
        }
        byte[] encoded = read(file, MAX_PAYLOAD + 512);
        byte[] body = checked(encoded);
        try (DataInputStream in = new DataInputStream(new ByteArrayInputStream(body))) {
            if (in.readInt() != POINTER_MAGIC || in.readInt() != 1 || !session.equals(in.readUTF()))
                throw new IOException("Invalid Linux pointer identity");
            String id = in.readUTF(); requireId(id);
            int size = in.readInt();
            if (size < 1 || size > MAX_PAYLOAD || size != in.available()) throw new IOException("Invalid pointer length");
            byte[] payload = new byte[size]; in.readFully(payload); validator.validate(payload);
            return new Pointer(id, digest(encoded), payload);
        } catch (IllegalArgumentException invalid) { throw new IOException("Invalid Linux pointer", invalid); }
    }

    /** Called under owner.lock, before any worker can be dispatched. Does not retry any command. */
    void admit(String id, String operation) throws IOException {
        requireId(id);
        if (!OPERATIONS.contains(operation)) throw new IllegalArgumentException("Invalid Linux operation");
        Snapshot snapshot = observe(null, false);
        if (snapshot.blocked() || snapshot.needsReview()) throw new BarrierException(snapshot);
        List<Run> prior = loadRuns();
        if (prior.size() >= MAX_RECORDS) throw new BarrierException(unknown(null, "scan_incomplete"));
        // There is no review acknowledgement protocol in this increment. A recovered fact
        // blocks new admission, so a successor cannot overwrite its pointer attribution.
        Pointer current = pointer();
        if (prior.stream().anyMatch(run -> run.id().equals(id))
                || legacy.records().stream().anyMatch(run -> run.runId().equals(id)))
            throw new IOException("Linux run ID already exists");
        if (!Files.exists(runs, LinkOption.NOFOLLOW_LINKS)) { Files.createDirectory(runs); sync.sync(root); }
        requireDirectory(runs);
        save(new Run(id, session, operation, current == null ? "none" : current.digest(),
                System.currentTimeMillis(), 0, "", null, null, null, false, "admitted_not_dispatched"));
    }

    /** Persist before the first Binder START, even when that dispatch later fails. */
    void dispatched(String id) throws IOException {
        Run run = load(id);
        if (run.phase() == 1) return;
        if (run.phase() != 0) throw new IOException("Linux run cannot dispatch in this phase");
        save(copy(run, 1, "", null, null, null, false, "execution_in_flight"));
    }

    /** Only authenticated same-owner native return or Binder death may call this method. */
    void retired(String id, String status, Integer exit) throws IOException {
        if (!STATUSES.contains(status) || status.equals("recovered_committed") || status.equals("outcome_uncertain"))
            throw new IllegalArgumentException("Invalid Linux retirement outcome");
        if (exit != null && (exit < 0 || exit > 255)) throw new IllegalArgumentException("Invalid exit code");
        Run run = load(id);
        if (run.phase() != 0 && run.phase() != 1) throw new IOException("Linux run cannot retire in this phase");
        save(copy(run, 2, status, exit, null, run.operation().equals("export") ? false : null,
                false, "retired_before_publication"));
    }

    /** Atomic pointer includes the retiring run and the complete disk payload in one checksummed file. */
    void publish(String id, byte[] payload) throws IOException {
        Run run = load(id);
        if (run.phase() != 2 || !run.status().equals("completed") || run.operation().equals("export"))
            throw new IOException("Linux run has no disk publication authority");
        Pointer current = pointer();
        if (!run.before().equals(current == null ? "none" : current.digest()))
            throw new IOException("Linux pointer changed before publication");
        if (payload.length < 1 || payload.length > MAX_PAYLOAD) throw new IOException("Invalid disk payload size");
        validator.validate(payload);
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try (DataOutputStream out = new DataOutputStream(bytes)) {
            out.writeInt(POINTER_MAGIC); out.writeInt(1); out.writeUTF(session); out.writeUTF(id);
            out.writeInt(payload.length); out.write(payload);
        }
        atomic(root.resolve("state-v3.bin"), seal(bytes.toByteArray()), "pointer");
    }

    /** Export's file effect becomes unknown before entering rename, independently of disk completion. */
    void prepareExport(String id) throws IOException {
        Run run = load(id);
        if (run.phase() != 2 || !run.operation().equals("export") || run.exportPrepared())
            throw new IOException("Linux export cannot prepare in this phase");
        save(copy(run, 2, run.status(), run.exit(), false, null, true, "export_publication_unconfirmed"));
    }

    void settle(String id, String status, boolean diskCommitted, Boolean filePublished) throws IOException {
        Run run = load(id);
        if (run.phase() != 2 || !STATUSES.contains(status)) throw new IOException("Linux retirement not recorded");
        if (run.operation().equals("export") ? diskCommitted : filePublished != null)
            throw new IllegalArgumentException("Invalid publication kind");
        Pointer current = pointer();
        if (diskCommitted && (current == null || !id.equals(current.runId())))
            throw new IOException("Linux commit pointer does not belong to this run");
        if (!diskCommitted && current != null && id.equals(current.runId()))
            throw new IOException("Cannot label a published Linux disk uncommitted");
        if (!diskCommitted && !run.before().equals(current == null ? "none" : current.digest()))
            throw new IOException("Cannot attribute a changed Linux pointer");
        if (diskCommitted && !status.equals("completed") && !status.equals("recovered_committed"))
            throw new IOException("Invalid Linux committed outcome");
        if (run.operation().equals("export") && filePublished == null && !status.equals("outcome_uncertain"))
            throw new IOException("Unknown export publication requires an uncertain outcome");
        save(copy(run, 3, status, run.exit(), diskCommitted, filePublished,
                run.exportPrepared(), "terminal_record"));
    }

    /** No dispatched run is downgraded to an unstarted/rolled-back run during stack cleanup. */
    void abandonBeforeDispatch(String id) throws IOException {
        Run run = load(id);
        if (run.phase() == 0) save(copy(run, 3, "interrupted", null, false,
                run.operation().equals("export") ? false : null, false, "admitted_not_dispatched"));
    }

    Snapshot observe(String id, boolean active) {
        if (id != null) requireId(id);
        List<Run> values;
        List<View> old;
        try { requireDirectory(root); values = loadRuns(); old = legacy.records(); }
        catch (IOException | IllegalArgumentException invalid) { return unknown(id, "record_invalid"); }
        Pointer current;
        try { current = pointer(); }
        catch (IOException | IllegalArgumentException invalid) { return unknown(id, "pointer_invalid"); }
        if (current != null && current.runId() != null
                && values.stream().noneMatch(run -> current.runId().equals(run.id()) && run.phase() >= 2))
            return unknown(id, "pointer_invalid");
        if (current != null && current.runId() == null && values.isEmpty() && old.isEmpty())
            return unknown(id, "legacy_unconfirmed");
        List<View> views = new ArrayList<>();
        boolean blocked = false, review = false;
        for (Run run : values) {
            View view = classify(run, current, active); views.add(view);
            blocked |= view.blocked(); review |= view.needsReview();
        }
        for (View view : old) {
            if (values.stream().anyMatch(run -> run.id().equals(view.runId()))) continue;
            views.add(view); blocked |= view.blocked(); review |= view.needsReview();
        }
        views.sort(Comparator.comparing(View::needsReview).reversed());
        Boolean found = id == null ? null : views.stream().anyMatch(view -> id.equals(view.runId()));
        List<View> selected = new ArrayList<>();
        for (View view : views) if (id == null || id.equals(view.runId())) selected.add(view);
        boolean truncated = selected.size() > 32;
        if (truncated) selected = new ArrayList<>(selected.subList(0, 32));
        String status = active ? "active" : blocked ? "blocked"
                : values.isEmpty() && old.isEmpty() && current == null ? "absent" : "ready";
        return new Snapshot(status, active || blocked, review, found, truncated, AndroidJava28.copyList(selected));
    }

    private static Snapshot unknown(String id, String reason) {
        List<View> records = id == null ? AndroidJava28.listOf() : AndroidJava28.listOf(new View(id, "unknown", "unknown",
                null, null, null, null, reason, true, true));
        return new Snapshot("unknown", true, true, null, false, records);
    }

    private View classify(Run run, Pointer pointer, boolean active) {
        if (run.phase() == 3) {
            boolean uncertain = run.status().equals("outcome_uncertain")
                    || run.operation().equals("export") && run.published() == null;
            String state = uncertain ? "outcome_uncertain" : run.status().equals("completed") ? "completed"
                    : run.status().equals("recovered_committed") ? "recovered_committed" : "interrupted";
            boolean recovered = run.reason().equals("pointer_committed")
                    || run.reason().equals("interrupted_before_commit") || run.reason().equals("admitted_not_dispatched");
            return view(run, state, true, run.disk(), run.published(),
                    uncertain ? "export_publication_unconfirmed" : run.reason(), uncertain || recovered, uncertain);
        }
        if (active) return view(run, run.phase() == 0 ? "admitted" : "running", null, null,
                null, "live_owner", false, true);
        if (run.phase() == 0) return view(run, "interrupted", true, false,
                run.operation().equals("export") ? false : null, "admitted_not_dispatched", true, false);
        if (run.phase() == 1) return view(run, "outcome_uncertain", null, null,
                null, "retirement_unconfirmed", true, true);
        if (run.operation().equals("export")) return view(run, run.exportPrepared() ? "outcome_uncertain" : "interrupted",
                true, false, run.exportPrepared() ? null : false, run.exportPrepared()
                        ? "export_publication_unconfirmed" : "interrupted_before_commit", true, run.exportPrepared());
        if (pointer != null && run.id().equals(pointer.runId()))
            return view(run, "recovered_committed", true, true, null, "pointer_committed", true, false);
        if (run.before().equals(pointer == null ? "none" : pointer.digest()))
            return view(run, "interrupted", true, false, null, "interrupted_before_commit", true, false);
        return view(run, "outcome_uncertain", true, null, null, "pointer_invalid", true, true);
    }

    private static View view(Run run, String state, Boolean retired, Boolean disk, Boolean published,
                             String reason, boolean review, boolean blocked) {
        return new View(run.id(), run.operation(), state, retired, disk, published, run.exit(), reason, review, blocked);
    }
    private Run copy(Run run, int phase, String status, Integer exit, Boolean disk, Boolean published,
                     boolean prepared, String reason) {
        return new Run(run.id(), session, run.operation(), run.before(), run.created(), phase, status,
                exit, disk, published, prepared, reason);
    }

    private List<Run> loadRuns() throws IOException {
        List<Run> result = new ArrayList<>();
        if (!Files.exists(runs, LinkOption.NOFOLLOW_LINKS)) return result;
        requireDirectory(runs);
        int scanned = 0;
        try (DirectoryStream<Path> entries = Files.newDirectoryStream(runs)) {
            for (Path file : entries) {
                if (++scanned > MAX_RECORDS) throw new IOException("Linux recovery record limit");
                String name = file.getFileName().toString();
                if (name.startsWith(".") && name.endsWith(".pending")) continue;
                if (!name.endsWith(".bin")) throw new IOException("Unknown Linux recovery entry");
                String id = name.substring(0, name.length() - 4); requireId(id);
                result.add(load(id));
            }
        }
        result.sort(Comparator.comparingLong(Run::created).reversed());
        return result;
    }
    private Run load(String id) throws IOException {
        requireId(id);
        byte[] body = checked(read(runs.resolve(id + ".bin"), 4096));
        try (DataInputStream in = new DataInputStream(new ByteArrayInputStream(body))) {
            if (in.readInt() != RUN_MAGIC || in.readInt() != 1) throw new IOException("Invalid Linux run version");
            Run run = new Run(in.readUTF(), in.readUTF(), in.readUTF(), in.readUTF(), in.readLong(),
                    in.readUnsignedByte(), in.readUTF(), exit(in.readInt()), bool(in.readByte()),
                    bool(in.readByte()), in.readBoolean(), in.readUTF());
            if (!id.equals(run.id()) || !session.equals(run.session()) || !OPERATIONS.contains(run.operation())
                    || !(run.before().equals("none") || run.before().matches("[0-9a-f]{64}"))
                    || run.created() < 0 || run.phase() > 3 || in.available() != 0
                    || run.phase() < 2 && !run.status().isEmpty()
                    || run.phase() < 2 && (run.exit() != null || run.disk() != null || run.published() != null || run.exportPrepared())
                    || run.phase() >= 2 && !STATUSES.contains(run.status())
                    || !REASONS.contains(run.reason())
                    || !run.operation().equals("export") && (run.published() != null || run.exportPrepared())
                    || run.operation().equals("export") && Boolean.TRUE.equals(run.disk())
                    || run.phase() == 2 && Boolean.TRUE.equals(run.disk())
                    || Boolean.TRUE.equals(run.disk()) && !run.status().equals("completed") && !run.status().equals("recovered_committed")
                    || run.phase() == 3 && run.disk() == null
                    || run.phase() == 3 && run.operation().equals("export") && run.published() == null && !run.status().equals("outcome_uncertain"))
                throw new IOException("Invalid Linux run record");
            return run;
        } catch (IllegalArgumentException invalid) { throw new IOException("Invalid Linux run fields", invalid); }
    }
    private void save(Run run) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try (DataOutputStream out = new DataOutputStream(bytes)) {
            out.writeInt(RUN_MAGIC); out.writeInt(1); out.writeUTF(run.id()); out.writeUTF(session);
            out.writeUTF(run.operation()); out.writeUTF(run.before()); out.writeLong(run.created());
            out.writeByte(run.phase()); out.writeUTF(run.status()); out.writeInt(run.exit() == null ? -1 : run.exit());
            out.writeByte(run.disk() == null ? -1 : run.disk() ? 1 : 0);
            out.writeByte(run.published() == null ? -1 : run.published() ? 1 : 0);
            out.writeBoolean(run.exportPrepared()); out.writeUTF(run.reason());
        }
        atomic(runs.resolve(run.id() + ".bin"), seal(bytes.toByteArray()), "run_" + run.phase());
    }

    private void atomic(Path target, byte[] bytes, String kind) throws IOException {
        requireDirectory(root); requireDirectory(target.getParent());
        Path temporary = target.resolveSibling("." + target.getFileName() + "-" + UUID.randomUUID() + ".pending");
        try (FileChannel channel = FileChannel.open(temporary, StandardOpenOption.CREATE_NEW,
                StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS)) {
            ByteBuffer buffer = ByteBuffer.wrap(bytes);
            while (buffer.hasRemaining()) channel.write(buffer);
            channel.force(true);
        }
        faults.hit(kind + "_before_move");
        Files.move(temporary, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        faults.hit(kind + "_after_move");
        sync.sync(target.getParent());
        faults.hit(kind + "_after_sync");
    }
    private static byte[] read(Path file, int maximum) throws IOException {
        if (!Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS)) throw new IOException("Invalid recovery file type");
        try (FileChannel channel = FileChannel.open(file, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS)) {
            long size = channel.size();
            if (size < 32 || size > maximum) throw new IOException("Invalid recovery file size");
            ByteBuffer bytes = ByteBuffer.allocate((int) size);
            while (bytes.hasRemaining()) if (channel.read(bytes) < 0) throw new IOException("Truncated recovery file");
            if (channel.read(ByteBuffer.allocate(1)) != -1) throw new IOException("Recovery file grew");
            return bytes.array();
        }
    }
    private static byte[] seal(byte[] bytes) {
        byte[] sealed = java.util.Arrays.copyOf(bytes, bytes.length + 32);
        System.arraycopy(sha(bytes), 0, sealed, bytes.length, 32); return sealed;
    }
    private static byte[] checked(byte[] bytes) throws IOException {
        byte[] body = java.util.Arrays.copyOf(bytes, bytes.length - 32);
        if (!MessageDigest.isEqual(sha(body), java.util.Arrays.copyOfRange(bytes, body.length, bytes.length)))
            throw new IOException("Recovery file checksum differs");
        return body;
    }
    static String digest(byte[] bytes) {
        StringBuilder result = new StringBuilder();
        for (byte value : sha(bytes)) result.append(String.format("%02x", value & 255));
        return result.toString();
    }
    private static byte[] sha(byte[] bytes) {
        try { return MessageDigest.getInstance("SHA-256").digest(bytes); }
        catch (NoSuchAlgorithmException impossible) { throw new IllegalStateException(impossible); }
    }
    static void requireId(String id) {
        if (id == null || !UUID.fromString(id).toString().equals(id)) throw new IllegalArgumentException("Invalid Linux run ID");
    }
    private static void requireDirectory(Path directory) throws IOException {
        if (!Files.isDirectory(directory, LinkOption.NOFOLLOW_LINKS)) throw new IOException("Invalid recovery directory");
    }
    private static Integer exit(int value) throws IOException {
        if (value < -1 || value > 255) throw new IOException("Invalid exit code"); return value < 0 ? null : value;
    }
    private static Boolean bool(int value) throws IOException {
        if (value < -1 || value > 1) throw new IOException("Invalid recovery boolean"); return value < 0 ? null : value == 1;
    }
}
