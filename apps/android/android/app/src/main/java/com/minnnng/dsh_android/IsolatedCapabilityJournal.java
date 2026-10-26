package com.minnnng.dsh_android;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.CharBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.OpenOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/** Bounded, fsynced App-private capability log. Recovery inspects facts but never repeats a call. */
public final class IsolatedCapabilityJournal implements IsolatedCapabilityBroker.AuditSink {
    public static final long MAX_BYTES = 16L * 1024 * 1024;
    private static final int MAX_FRAME_BYTES = 2048;
    private static final int MAX_REVIEW_ITEMS = 4096;
    private static final Object APPEND_LOCK = new Object();
    private final Path root;
    private final Path file;
    private final IsolatedWorkerWriteback.DirectorySync syncDirectory;
    private final RecoveryReport startupReport;
    private long expectedBytes;
    private boolean writeUncertain;
    private boolean admissionReady;

    public record CallReview(String callId, IsolatedCapabilityBroker.Action action, String target,
                             String expectedRevision, String resultRevision, String reason) {}
    public record RunReview(String ownerId, String runId, boolean unfinished, boolean auditUncertain,
                            List<CallReview> calls) {}
    /** A damaged frame or incomplete/uncertain run needs manual inspection before another admission. */
    public record RecoveryReport(long bytes, boolean damaged, String damage,
                                 boolean capacityReached, List<RunReview> runs, boolean truncated) {
        public RecoveryReport { runs = AndroidJava28.copyList(runs); }
        public boolean requiresInspection() { return damaged || truncated || !runs.isEmpty(); }
        public boolean canAppend() { return !requiresInspection() && !capacityReached; }
    }

    public IsolatedCapabilityJournal(Path appPrivateDirectory,
                                     IsolatedWorkerWriteback.DirectorySync syncDirectory) throws IOException {
        this.root = appPrivateDirectory.toAbsolutePath().normalize();
        this.syncDirectory = Objects.requireNonNull(syncDirectory);
        if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(root))
            throw new IOException("Capability journal root is not an App-private directory");
        this.file = root.resolve("isolated-capabilities.jsonl");
        this.startupReport = inspectLocked();
        this.expectedBytes = startupReport.bytes();
        this.admissionReady = startupReport.canAppend();
    }

    /** Startup status stays available even if later App-owned calls append to the same log. */
    public RecoveryReport startupReport() { return startupReport; }

    /** Reads the current bounded journal, including incomplete calls and torn frames. */
    public RecoveryReport inspect() throws IOException {
        synchronized (APPEND_LOCK) { return inspectLocked(); }
    }

    /** Recheck the App-private log before a new file-granted run consumes approval. */
    public void requireCleanAdmission() throws IOException {
        synchronized (APPEND_LOCK) {
            if (writeUncertain || !admissionReady || !startupReport.canAppend())
                throw new IOException("Capability audit outcome is uncertain; inspect the retained journal");
            RecoveryReport current = inspectLocked();
            if (current.bytes() != expectedBytes) {
                writeUncertain = true;
                throw new IOException("Capability journal changed outside this writer");
            }
            // A live run is also unfinished here. Do not admit another
            // file-granted run until its terminal record has been inspected.
            if (!current.canAppend())
                throw new IOException("Capability audit has an unfinished or uncertain run");
        }
    }

    /** Explicit maintenance after every run and call is settled; keeps the old log as an archive. */
    public Path archiveSettled() throws IOException {
        synchronized (APPEND_LOCK) {
            RecoveryReport current = inspectLocked();
            if (writeUncertain || startupReport.requiresInspection() || current.requiresInspection()
                    || current.bytes() != expectedBytes)
                throw new IOException("Capability journal needs inspection; archival refused");
            if (current.bytes() == 0) throw new IOException("Capability journal has no settled history to archive");
            Path archive = root.resolve("isolated-capabilities-" + UUID.randomUUID() + ".jsonl");
            Files.move(file, archive, StandardCopyOption.ATOMIC_MOVE);
            try { syncDirectory.sync(root); }
            catch (IOException | RuntimeException failure) { writeUncertain = true; throw failure; }
            expectedBytes = 0;
            admissionReady = true;
            return archive;
        }
    }

    @Override public void record(IsolatedCapabilityBroker.Event event) throws IOException {
        byte[] line = json(event).getBytes(StandardCharsets.UTF_8);
        if (line.length > MAX_FRAME_BYTES) throw new IOException("Capability event exceeds journal frame limit");
        synchronized (APPEND_LOCK) {
            if (writeUncertain || !admissionReady)
                throw new IOException("Capability journal cannot accept work; inspect recovery report and archive only settled history");
            try (FileChannel channel = FileChannel.open(file, Set.<OpenOption>of(
                    StandardOpenOption.CREATE, StandardOpenOption.WRITE,
                    StandardOpenOption.APPEND, LinkOption.NOFOLLOW_LINKS))) {
                if (channel.size() != expectedBytes) {
                    writeUncertain = true;
                    throw new IOException("Capability journal changed outside this writer; inspect before admitting work");
                }
                if (expectedBytes > MAX_BYTES - line.length)
                    throw new IOException("Capability journal capacity reached; stop active runs and archive settled history");
                try {
                    ByteBuffer bytes = ByteBuffer.wrap(line);
                    while (bytes.hasRemaining()) channel.write(bytes);
                    channel.force(true);
                    syncDirectory.sync(root);
                    expectedBytes += line.length;
                } catch (IOException | RuntimeException failure) {
                    writeUncertain = true;
                    throw failure;
                }
            }
        }
    }

    private RecoveryReport inspectLocked() throws IOException {
        if (!Files.exists(file, LinkOption.NOFOLLOW_LINKS))
            return new RecoveryReport(0, false, null, false, AndroidJava28.listOf(), false);
        if (!Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(file))
            throw new IOException("Capability journal is not a regular file");
        RecoveryState state = new RecoveryState();
        long bytes = 0;
        String damage = null;
        ByteArrayOutputStream line = new ByteArrayOutputStream(MAX_FRAME_BYTES);
        try (FileChannel channel = FileChannel.open(file,
                Set.<OpenOption>of(StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS))) {
            ByteBuffer chunk = ByteBuffer.allocate(8192);
            while (damage == null && channel.read(chunk) >= 0) {
                chunk.flip();
                if (!chunk.hasRemaining()) { chunk.clear(); continue; }
                while (chunk.hasRemaining()) {
                    int value = chunk.get() & 0xff;
                    bytes++;
                    if (bytes > MAX_BYTES) { damage = "Journal exceeds capacity"; break; }
                    if (value == '\n') {
                        try { state.accept(parse(line.toByteArray())); }
                        catch (RuntimeException invalid) { damage = "Invalid frame ending at byte " + bytes; break; }
                        line.reset();
                    } else {
                        if (line.size() >= MAX_FRAME_BYTES - 1) {
                            damage = "Frame exceeds limit at byte " + bytes; break;
                        }
                        line.write(value);
                    }
                }
                chunk.clear();
            }
            if (damage == null && line.size() != 0) damage = "Torn final frame";
            if (damage == null && channel.size() != bytes) damage = "Journal changed during inspection";
        }
        return state.report(bytes, damage);
    }

    private static Frame parse(byte[] bytes) {
        String source;
        try {
            source = StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString();
        } catch (CharacterCodingException invalid) { throw new IllegalArgumentException(invalid); }
        Cursor cursor = new Cursor(source);
        cursor.take('{');
        int version = cursor.integer("v");
        if (version != 1) throw new IllegalArgumentException("Unknown journal version");
        long time = cursor.longNumber("timeMs");
        if (time < 0) throw new IllegalArgumentException("Invalid journal timestamp");
        IsolatedCapabilityBroker.Phase phase = enumValue(IsolatedCapabilityBroker.Phase.class,
                cursor.string("phase"));
        if (phase == null) throw new IllegalArgumentException("Missing journal phase");
        String owner = cursor.string("ownerId");
        String run = cursor.string("runId");
        String call = cursor.string("callId");
        String grant = cursor.string("grantId");
        String target = cursor.string("target");
        List<String> actions = cursor.array("grantActions");
        String actionText = cursor.string("action");
        String statusText = cursor.string("status");
        String terminalText = cursor.string("terminal");
        String expected = null;
        String result = null;
        if (cursor.moreFields()) {
            expected = cursor.string("expectedRevision");
            result = cursor.string("resultRevision");
        }
        cursor.take('}');
        cursor.done();
        if (owner == null || owner.isEmpty() || run == null || run.isEmpty())
            throw new IllegalArgumentException("Missing journal owner or run");
        for (String name : actions == null ? List.<String>of() : actions)
            enumValue(IsolatedCapabilityBroker.Action.class, name);
        return new Frame(phase, owner, run, call, grant, target, actions,
                enumValue(IsolatedCapabilityBroker.Action.class, actionText),
                enumValue(IsolatedCapabilityBroker.Status.class, statusText),
                enumValue(IsolatedCapabilityBroker.Terminal.class, terminalText), expected, result);
    }

    private static <T extends Enum<T>> T enumValue(Class<T> type, String value) {
        if (value == null) return null;
        try { return Enum.valueOf(type, value); }
        catch (IllegalArgumentException invalid) { throw new IllegalArgumentException("Unknown journal enum", invalid); }
    }

    private record Frame(IsolatedCapabilityBroker.Phase phase, String owner, String run,
                         String call, String grant, String target, List<String> grantActions,
                         IsolatedCapabilityBroker.Action action, IsolatedCapabilityBroker.Status status,
                         IsolatedCapabilityBroker.Terminal terminal, String expected, String result) {}

    private static final class RecoveryState {
        private final Map<String, RunState> runs = new LinkedHashMap<>();

        void accept(Frame frame) {
            RunState run = runs.get(frame.run());
            if (frame.phase() == IsolatedCapabilityBroker.Phase.RUN_OPENED) {
                if (run != null || frame.call() != null || frame.grant() != null
                        || frame.status() != null || frame.terminal() != null)
                    throw new IllegalArgumentException("Invalid run opening");
                runs.put(frame.run(), new RunState(frame.owner(), frame.run()));
                return;
            }
            if (run == null || !run.owner.equals(frame.owner()))
                throw new IllegalArgumentException("Event without owning run");
            switch (frame.phase()) {
                case GRANT_ISSUED -> {
                    if (run.finished || frame.grant() == null || frame.target() == null
                            || frame.grantActions() == null || frame.grantActions().isEmpty()
                            || frame.call() != null || frame.action() != null || frame.status() != null
                            || frame.terminal() != null)
                        throw new IllegalArgumentException("Invalid grant event");
                }
                case CALL_STARTED -> {
                    if (run.finished || frame.call() == null || frame.grant() == null
                            || frame.action() == null || frame.target() == null || frame.status() != null
                            || frame.terminal() != null || run.calls.containsKey(frame.call()))
                        throw new IllegalArgumentException("Invalid call start");
                    run.calls.put(frame.call(), new CallState(frame));
                }
                case CALL_SETTLED -> {
                    CallState call = run.calls.get(frame.call());
                    if (call == null || call.settled || frame.status() == null || frame.terminal() != null
                            || call.started.action() != frame.action()
                            || !Objects.equals(call.started.grant(), frame.grant())
                            || !Objects.equals(call.started.target(), frame.target())
                            || !Objects.equals(call.started.expected(), frame.expected()))
                        throw new IllegalArgumentException("Invalid call settlement");
                    call.settled = true;
                    call.settlement = frame;
                }
                case CALL_REJECTED -> {
                    if (frame.status() == null || frame.terminal() != null)
                        throw new IllegalArgumentException("Invalid call rejection");
                }
                case RUN_FINISHED -> {
                    if (run.finished || frame.terminal() == null || frame.call() != null
                            || frame.grant() != null || frame.action() != null || frame.status() != null)
                        throw new IllegalArgumentException("Invalid run finish");
                    run.finished = true;
                    run.terminal = frame.terminal();
                }
                case RUN_OPENED -> throw new IllegalArgumentException("Duplicate run opening");
            }
        }

        RecoveryReport report(long bytes, String damage) {
            List<RunReview> review = new ArrayList<>();
            int count = 0;
            boolean truncated = false;
            for (RunState run : runs.values()) {
                List<CallReview> calls = new ArrayList<>();
                for (CallState call : run.calls.values()) {
                    Frame settled = call.settlement;
                    boolean uncertain = settled != null
                            && (settled.status() == IsolatedCapabilityBroker.Status.AUDIT_UNCERTAIN
                            || (call.started.action() == IsolatedCapabilityBroker.Action.EDIT
                                || call.started.action() == IsolatedCapabilityBroker.Action.WRITE)
                            && settled.status() == IsolatedCapabilityBroker.Status.COMMIT_UNCERTAIN);
                    if (call.settled && !uncertain) continue;
                    if (count >= MAX_REVIEW_ITEMS) { truncated = true; break; }
                    count++;
                    calls.add(new CallReview(call.started.call(), call.started.action(), call.started.target(),
                            call.started.expected(), settled == null ? null : settled.result(),
                            settled == null ? "CALL_NOT_SETTLED" : settled.status().name()));
                }
                boolean unfinished = !run.finished;
                boolean auditUncertain = run.terminal == IsolatedCapabilityBroker.Terminal.AUDIT_UNCERTAIN;
                if (unfinished || auditUncertain || !calls.isEmpty()) {
                    if (review.size() >= MAX_REVIEW_ITEMS) { truncated = true; break; }
                    review.add(new RunReview(run.owner, run.id, unfinished, auditUncertain, AndroidJava28.copyList(calls)));
                }
                if (truncated) break;
            }
            return new RecoveryReport(bytes, damage != null, damage, bytes >= MAX_BYTES,
                    review, truncated);
        }
    }

    private static final class RunState {
        final String owner;
        final String id;
        final Map<String, CallState> calls = new LinkedHashMap<>();
        boolean finished;
        IsolatedCapabilityBroker.Terminal terminal;
        RunState(String owner, String id) { this.owner = owner; this.id = id; }
    }
    private static final class CallState {
        final Frame started;
        boolean settled;
        Frame settlement;
        CallState(Frame started) { this.started = started; }
    }

    private static final class Cursor {
        private final String source;
        private int offset;
        private boolean first = true;
        Cursor(String source) { this.source = source; }
        void take(char expected) {
            if (offset >= source.length() || source.charAt(offset++) != expected)
                throw new IllegalArgumentException("Invalid journal JSON");
        }
        boolean moreFields() { return offset < source.length() && source.charAt(offset) == ','; }
        void key(String name) {
            if (!first) take(',');
            first = false;
            if (!name.equals(quoted())) throw new IllegalArgumentException("Unexpected journal field");
            take(':');
        }
        int integer(String name) {
            long value = longNumber(name);
            if (value > Integer.MAX_VALUE) throw new IllegalArgumentException("Journal number overflow");
            return (int)value;
        }
        long longNumber(String name) {
            key(name);
            int start = offset;
            while (offset < source.length() && Character.isDigit(source.charAt(offset))) offset++;
            if (start == offset) throw new IllegalArgumentException("Invalid journal number");
            try { return Long.parseLong(source.substring(start, offset)); }
            catch (NumberFormatException invalid) { throw new IllegalArgumentException(invalid); }
        }
        String string(String name) { key(name); return nullableString(); }
        List<String> array(String name) {
            key(name);
            if (literal("null")) return null;
            take('[');
            List<String> values = new ArrayList<>();
            while (offset < source.length() && source.charAt(offset) != ']') {
                if (!values.isEmpty()) take(',');
                String value = nullableString();
                if (value == null || values.contains(value)) throw new IllegalArgumentException("Invalid action list");
                values.add(value);
            }
            take(']');
            return values;
        }
        String nullableString() { return literal("null") ? null : quoted(); }
        boolean literal(String value) {
            if (!source.startsWith(value, offset)) return false;
            offset += value.length();
            return true;
        }
        String quoted() {
            take('"');
            StringBuilder out = new StringBuilder();
            while (offset < source.length()) {
                char c = source.charAt(offset++);
                if (c == '"') return out.toString();
                if (c < 32) throw new IllegalArgumentException("Control in journal string");
                if (c != '\\') { out.append(c); continue; }
                if (offset >= source.length()) throw new IllegalArgumentException("Torn escape");
                char escape = source.charAt(offset++);
                switch (escape) {
                    case '"', '\\' -> out.append(escape);
                    case 'n' -> out.append('\n');
                    case 'r' -> out.append('\r');
                    case 't' -> out.append('\t');
                    case 'u' -> {
                        if (offset + 4 > source.length()) throw new IllegalArgumentException("Torn Unicode escape");
                        try { out.append((char)Integer.parseInt(source.substring(offset, offset + 4), 16)); }
                        catch (NumberFormatException invalid) { throw new IllegalArgumentException(invalid); }
                        offset += 4;
                    }
                    default -> throw new IllegalArgumentException("Unknown journal escape");
                }
            }
            throw new IllegalArgumentException("Torn journal string");
        }
        void done() { if (offset != source.length()) throw new IllegalArgumentException("Trailing journal bytes"); }
    }

    private static String json(IsolatedCapabilityBroker.Event event) {
        StringBuilder output = new StringBuilder(256);
        output.append("{\"v\":1,\"timeMs\":").append(System.currentTimeMillis())
            .append(",\"phase\":");
        value(output, event.phase().name());
        output.append(",\"ownerId\":"); value(output, event.ownerId());
        output.append(",\"runId\":"); value(output, event.runId());
        output.append(",\"callId\":"); value(output, event.callId());
        output.append(",\"grantId\":"); value(output, event.grantId());
        output.append(",\"target\":"); value(output, event.target());
        output.append(",\"grantActions\":");
        if (event.grantActions() == null) output.append("null");
        else {
            output.append('[');
            boolean first = true;
            for (IsolatedCapabilityBroker.Action action : IsolatedCapabilityBroker.Action.values()) {
                if (!event.grantActions().contains(action)) continue;
                if (!first) output.append(',');
                value(output, action.name());
                first = false;
            }
            output.append(']');
        }
        output.append(",\"action\":"); value(output, event.action() == null ? null : event.action().name());
        output.append(",\"status\":"); value(output, event.status() == null ? null : event.status().name());
        output.append(",\"terminal\":"); value(output, event.terminal() == null ? null : event.terminal().name());
        output.append(",\"expectedRevision\":"); value(output, event.expectedRevision());
        output.append(",\"resultRevision\":"); value(output, event.resultRevision());
        return output.append("}\n").toString();
    }

    private static void value(StringBuilder out, String value) {
        if (value == null) { out.append("null"); return; }
        out.append('"');
        for (int index = 0; index < value.length(); index++) {
            char c = value.charAt(index);
            switch (c) {
                case '"' -> out.append("\\\"");
                case '\\' -> out.append("\\\\");
                case '\n' -> out.append("\\n");
                case '\r' -> out.append("\\r");
                case '\t' -> out.append("\\t");
                default -> {
                    if (c < 32) out.append(String.format(java.util.Locale.ROOT, "\\u%04x", (int)c));
                    else out.append(c);
                }
            }
        }
        out.append('"');
    }
}
