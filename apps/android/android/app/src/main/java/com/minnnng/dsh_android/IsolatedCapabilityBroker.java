package com.minnnng.dsh_android;

import java.io.IOException;
import java.io.InterruptedIOException;
import java.nio.CharBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.BooleanSupplier;
import java.util.function.LongSupplier;

/** App-owned guest capability table; it does not confine App-UID Shell or plugins. */
public final class IsolatedCapabilityBroker {
    public static final int MAX_GRANTS = 32;
    public static final int MAX_CALLS = 128;
    public static final long MAX_LEASE_MILLIS = 5 * 60_000L;

    public enum Action { READ, SEARCH, EDIT, WRITE }
    public enum Status {
        OK, DENIED, STALE, CANCELLED, EXPIRED, WORKER_DIED, FAILED,
        COMMIT_UNCERTAIN, AUDIT_UNCERTAIN
    }
    public enum Terminal { COMPLETED, CANCELLED, EXPIRED, WORKER_DIED, FAILED, AUDIT_UNCERTAIN }
    public enum Phase { RUN_OPENED, GRANT_ISSUED, CALL_STARTED, CALL_REJECTED, CALL_SETTLED, RUN_FINISHED }

    /** App-only mapping. Never serialize a GrantSpec into the guest request. */
    public record GrantSpec(String filename, Set<Action> actions) {
        public GrantSpec {
            validateRelativeName(filename != null && filename.endsWith("/")
                    ? filename.substring(0, filename.length() - 1) : filename);
            if (strictUtf8Bytes(filename) > 512)
                throw new IllegalArgumentException("Capability root exceeds name limit");
            if (actions == null || actions.isEmpty()) throw new IllegalArgumentException("Empty capability grant");
            actions = AndroidJava28.copySet(actions);
        }
        public boolean directory() { return filename.endsWith("/"); }
    }
    /**
     * App-selected, immutable path scope for one run. Paths are relative to the App-private workspace.
     * A plain path selects one file; a trailing slash selects descendants of a directory.
     * READ and SEARCH need readable scope; EDIT and WRITE additionally need writable scope.
     * Network has no broker action and cannot be granted by this policy. Prefix admission
     * does not replace anchored, no-follow file opens and revision checks in WorkspaceOps.
     */
    public record SandboxPolicy(Set<String> readablePaths, Set<String> writablePaths) {
        public SandboxPolicy {
            readablePaths = validatedPaths(readablePaths, false);
            writablePaths = validatedPaths(writablePaths, true);
            for (String writable : writablePaths) {
                if (!within(readablePaths, writable) || protectedWritePath(writable))
                    throw new IllegalArgumentException("Writable path must also be readable");
            }
        }

        public static SandboxPolicy readOnly(Set<String> readablePaths) {
            return new SandboxPolicy(readablePaths, AndroidJava28.setOf());
        }

        boolean permits(GrantSpec grant) {
            for (Action action : grant.actions()) {
                boolean permitted = switch (action) {
                    case READ, SEARCH -> within(readablePaths, grant.filename());
                    case EDIT, WRITE -> within(readablePaths, grant.filename())
                            && within(writablePaths, grant.filename())
                            && !protectedWritePath(grant.filename());
                };
                if (!permitted) return false;
            }
            return true;
        }

        private static Set<String> validatedPaths(Set<String> paths, boolean allowEmpty) {
            if (paths == null || paths.size() > MAX_GRANTS || (!allowEmpty && paths.isEmpty()))
                throw new IllegalArgumentException("Invalid sandbox path scope");
            for (String path : paths) {
                if (path == null) throw new IllegalArgumentException("Invalid sandbox path scope");
                validateRelativeName(path.endsWith("/") ? path.substring(0, path.length() - 1) : path);
                if (strictUtf8Bytes(path) > 512)
                    throw new IllegalArgumentException("Sandbox root exceeds name limit");
            }
            return AndroidJava28.copySet(paths);
        }

        private static boolean within(Set<String> roots, String target) {
            for (String root : roots) {
                if (root.endsWith("/") ? (target.equals(root) || target.startsWith(root))
                        : target.equals(root)) return true;
            }
            return false;
        }
    }
    public record GrantHandle(String id, Set<Action> actions, boolean directory) {
        public GrantHandle { actions = AndroidJava28.copySet(actions); }
        public GrantHandle(String id, Set<Action> actions) { this(id, actions, false); }
    }
    public record Event(Phase phase, String ownerId, String runId, String callId, String grantId,
                        String target, Set<Action> grantActions, Action action, Status status,
                        Terminal terminal, String expectedRevision, String resultRevision) {
        public Event { if (grantActions != null) grantActions = AndroidJava28.copySet(grantActions); }
    }
    /** The implementation must durably settle each event before returning. */
    public interface AuditSink { void record(Event event) throws IOException; }
    public interface WorkspaceOps {
        ReadData read(String filename, BooleanSupplier cancelled) throws Exception;
        SearchData search(String filename, String query, int maxMatches,
                          BooleanSupplier cancelled) throws Exception;
        EditData edit(String filename, String expectedRevision, String needle,
                      String replacement, int maxReplacements,
                      BooleanSupplier cancelled) throws Exception;
        /** Full bounded replacement; expectedRevision=missing permits only a new exact file. */
        default EditData write(String filename, String expectedRevision, String text,
                               BooleanSupplier cancelled) throws Exception {
            throw new UnsupportedOperationException("Workspace write is unavailable");
        }
    }
    /** A version mismatch is distinct from an operation failure and must not be retried blindly. */
    public static final class StaleRevision extends IOException {
        public StaleRevision() { super("Workspace revision changed"); }
    }
    /** The write may have reached the workspace; callers must inspect before retrying. */
    public static final class CommitOutcomeUnknown extends IOException {
        public CommitOutcomeUnknown(IOException cause) { super("Workspace commit outcome unknown", cause); }
    }
    public record ReadData(String revision, String text) {
        public ReadData {
            presentRevision(revision);
            boundedText(text);
        }
    }
    public record Hit(int line, int column, String preview) {
        public Hit {
            if (line < 1 || column < 1 || preview == null
                    || preview.codePointCount(0, preview.length()) > IsolatedWorkerTextSearch.MAX_PREVIEW_CHARS)
                throw new IllegalArgumentException("Invalid search hit");
        }
    }
    public record SearchData(String revision, List<Hit> hits, boolean truncated) {
        public SearchData {
            presentRevision(revision);
            if (hits == null || hits.size() > IsolatedWorkerTextSearch.MAX_MATCHES)
                throw new IllegalArgumentException("Unbounded search result");
            hits = AndroidJava28.copyList(hits);
        }
    }
    public record EditData(String previousRevision, String revision, int bytes) {
        public EditData {
            validRevision(previousRevision);
            presentRevision(revision);
            if (bytes < 0 || bytes > IsolatedWorkerInput.MAX_TEXT_BYTES)
                throw new IllegalArgumentException("Unbounded edit receipt");
        }
    }
    public record Call(String runId, String callId, String grantId, Action action,
                       String query, int maxMatches, String expectedRevision,
                       String needle, String replacement, int maxReplacements,
                       String relativePath) {
        public Call {
            Objects.requireNonNull(action);
            if (relativePath != null) validateRelativeName(relativePath);
            if (action == Action.READ) {
                if (query != null || expectedRevision != null || needle != null || replacement != null
                        || maxMatches != 0 || maxReplacements != 0)
                    throw new IllegalArgumentException("READ has unexpected arguments");
            } else if (action == Action.SEARCH) {
                new IsolatedWorkerTextSearch.Spec(query, maxMatches);
                if (expectedRevision != null || needle != null || replacement != null || maxReplacements != 0)
                    throw new IllegalArgumentException("SEARCH has unexpected arguments");
            } else if (action == Action.EDIT) {
                validRevision(expectedRevision);
                new IsolatedWorkerTextEdit.Spec(needle, replacement, maxReplacements);
                if (query != null || maxMatches != 0)
                    throw new IllegalArgumentException("EDIT has unexpected arguments");
            } else {
                validRevision(expectedRevision);
                boundedText(replacement);
                if (query != null || needle != null || maxMatches != 0 || maxReplacements != 0)
                    throw new IllegalArgumentException("WRITE has unexpected arguments");
            }
        }
        public static Call read(String runId, String callId, String grantId) {
            return new Call(runId, callId, grantId, Action.READ, null, 0, null, null, null, 0, null);
        }
        public static Call readChild(String runId, String callId, String grantId, String relativePath) {
            return new Call(runId, callId, grantId, Action.READ, null, 0, null, null, null, 0,
                    Objects.requireNonNull(relativePath));
        }
        public static Call search(String runId, String callId, String grantId, String query, int maxMatches) {
            return new Call(runId, callId, grantId, Action.SEARCH, query, maxMatches, null, null, null, 0, null);
        }
        public static Call searchChild(String runId, String callId, String grantId, String relativePath,
                                       String query, int maxMatches) {
            return new Call(runId, callId, grantId, Action.SEARCH, query, maxMatches, null, null, null, 0,
                    Objects.requireNonNull(relativePath));
        }
        public static Call edit(String runId, String callId, String grantId, String expectedRevision,
                                String needle, String replacement, int maxReplacements) {
            return new Call(runId, callId, grantId, Action.EDIT, null, 0,
                    expectedRevision, needle, replacement, maxReplacements, null);
        }
        public static Call editChild(String runId, String callId, String grantId, String relativePath,
                                     String expectedRevision, String needle, String replacement,
                                     int maxReplacements) {
            return new Call(runId, callId, grantId, Action.EDIT, null, 0,
                    expectedRevision, needle, replacement, maxReplacements,
                    Objects.requireNonNull(relativePath));
        }
        public static Call write(String runId, String callId, String grantId,
                                 String expectedRevision, String text) {
            return new Call(runId, callId, grantId, Action.WRITE, null, 0,
                    expectedRevision, null, text, 0, null);
        }
        public static Call writeChild(String runId, String callId, String grantId, String relativePath,
                                      String expectedRevision, String text) {
            return new Call(runId, callId, grantId, Action.WRITE, null, 0,
                    expectedRevision, null, text, 0, Objects.requireNonNull(relativePath));
        }
    }
    public record CallResult(Status status, ReadData read, SearchData search, EditData edit, String detail) {
        public CallResult {
            Objects.requireNonNull(status);
            if (status != Status.OK && (read != null || search != null || edit != null))
                throw new IllegalArgumentException("Failed call cannot claim successful data");
            if (status == Status.OK && ((read != null ? 1 : 0) + (search != null ? 1 : 0)
                    + (edit != null ? 1 : 0)) != 1)
                throw new IllegalArgumentException("Successful call needs one result");
        }
        static CallResult error(Status status, String detail) { return new CallResult(status, null, null, null, detail); }
    }

    private final Object gate = new Object();
    private final String ownerId;
    private final String runId = UUID.randomUUID().toString();
    private final WorkspaceOps workspace;
    private final SandboxPolicy policy;
    private final AuditSink audit;
    private final LongSupplier monotonicNanos;
    private final long deadlineNanos;
    private final Map<String, GrantSpec> grants = new LinkedHashMap<>();
    private final Set<String> usedCalls = new HashSet<>();
    private Terminal terminal;
    private boolean auditUncertain;
    private int inFlight;

    public IsolatedCapabilityBroker(String ownerId, WorkspaceOps workspace, AuditSink audit,
                                    List<GrantSpec> specs, long leaseMillis) throws IOException {
        this(ownerId, workspace, audit, specs, readOnlyFor(specs), leaseMillis, System::nanoTime);
    }

    public IsolatedCapabilityBroker(String ownerId, WorkspaceOps workspace, AuditSink audit,
                                    List<GrantSpec> specs, SandboxPolicy policy, long leaseMillis) throws IOException {
        this(ownerId, workspace, audit, specs, policy, leaseMillis, System::nanoTime);
    }

    IsolatedCapabilityBroker(String ownerId, WorkspaceOps workspace, AuditSink audit,
                             List<GrantSpec> specs, long leaseMillis,
                             LongSupplier monotonicNanos) throws IOException {
        this(ownerId, workspace, audit, specs, readOnlyFor(specs), leaseMillis, monotonicNanos);
    }

    IsolatedCapabilityBroker(String ownerId, WorkspaceOps workspace, AuditSink audit,
                             List<GrantSpec> specs, SandboxPolicy policy, long leaseMillis,
                             LongSupplier monotonicNanos) throws IOException {
        if (ownerId == null || ownerId.length() > 128 || !ownerId.matches("[A-Za-z0-9._:-]+"))
            throw new IllegalArgumentException("Capability owner must be an opaque task ID");
        this.ownerId = ownerId;
        this.workspace = Objects.requireNonNull(workspace);
        this.audit = Objects.requireNonNull(audit);
        this.policy = Objects.requireNonNull(policy);
        this.monotonicNanos = Objects.requireNonNull(monotonicNanos);
        if (specs == null || specs.isEmpty() || specs.size() > MAX_GRANTS
                || leaseMillis < 1000 || leaseMillis > MAX_LEASE_MILLIS)
            throw new IllegalArgumentException("Invalid capability lease");
        long now = monotonicNanos.getAsLong();
        deadlineNanos = now + leaseMillis * 1_000_000L;
        for (GrantSpec spec : specs) {
            Objects.requireNonNull(spec);
            if (!policy.permits(spec))
                throw new IllegalArgumentException("Capability grant exceeds sandbox path policy");
            grants.put(UUID.randomUUID().toString(), spec);
        }
        audit.record(new Event(Phase.RUN_OPENED, ownerId, runId, null, null, null, null, null, null, null, null, null));
        for (var grant : grants.entrySet()) {
            audit.record(new Event(Phase.GRANT_ISSUED, ownerId, runId, null, grant.getKey(),
                    grant.getValue().filename(), grant.getValue().actions(), null, null, null, null, null));
        }
    }

    public String runId() { return runId; }
    /** Handles retain the order of App-issued GrantSpecs without exposing their filenames. */
    public List<GrantHandle> handles() {
        synchronized (gate) {
            List<GrantHandle> result = new ArrayList<>();
            grants.forEach((id, spec) -> result.add(new GrantHandle(id, spec.actions(), spec.directory())));
            return AndroidJava28.copyList(result);
        }
    }
    public Terminal terminal() { synchronized (gate) { return terminal; } }
    public boolean auditUncertain() { synchronized (gate) { return auditUncertain; } }

    /** One call ID is consumed before dispatch; replay cannot repeat an edit. */
    public CallResult execute(Call call, BooleanSupplier callerCancelled) {
        Objects.requireNonNull(call);
        Objects.requireNonNull(callerCancelled);
        GrantSpec grant;
        String target;
        synchronized (gate) {
            if (!runId.equals(call.runId()) || !uuid(call.callId()) || !uuid(call.grantId()))
                return rejectLocked(call, Status.DENIED, "Invalid capability identity");
            if (!usedCalls.add(call.callId()))
                return rejectLocked(call, Status.DENIED, "Replayed capability call");
            if (usedCalls.size() > MAX_CALLS) {
                terminalizeLocked(Terminal.FAILED);
                return rejectLocked(call, Status.DENIED, "Capability call limit reached");
            }
            try { refreshTerminalLocked(callerCancelled); }
            catch (RuntimeException failure) {
                terminalizeLocked(Terminal.FAILED);
                return rejectLocked(call, Status.FAILED, "Capability cancellation check failed");
            }
            if (terminal != null) return rejectLocked(call, terminalStatus(), "Capability run is closed");
            grant = grants.get(call.grantId());
            if (grant == null || !grant.actions().contains(call.action()))
                return rejectLocked(call, Status.DENIED, "Capability not granted");
            try {
                target = resolveTarget(grant, call.relativePath());
                if (!policy.permits(new GrantSpec(target, AndroidJava28.setOf(call.action()))))
                    return rejectLocked(call, Status.DENIED, "Target exceeds sandbox path policy");
            } catch (IllegalArgumentException invalid) {
                return rejectLocked(call, Status.DENIED, "Invalid directory target");
            }
            try {
                audit.record(new Event(Phase.CALL_STARTED, ownerId, runId, call.callId(), call.grantId(),
                        target, null, call.action(), null, null, call.expectedRevision(), null));
                inFlight++;
            } catch (IOException | RuntimeException failure) {
                terminalizeLocked(Terminal.AUDIT_UNCERTAIN);
                return CallResult.error(Status.AUDIT_UNCERTAIN, "Call admission could not be recorded");
            }
        }
        CallResult result;
        String observedRevision = null;
        AtomicBoolean cancellationObserved = new AtomicBoolean();
        try {
            BooleanSupplier cancelled = () -> {
                if (callerCancelled.getAsBoolean() || Thread.currentThread().isInterrupted()) {
                    cancellationObserved.set(true);
                    return true;
                }
                return expired() || terminal() != null;
            };
            if (cancelled.getAsBoolean()) result = CallResult.error(Status.CANCELLED, "Capability call cancelled");
            else result = switch (call.action()) {
                case READ -> new CallResult(Status.OK, workspace.read(target, cancelled), null, null, null);
                case SEARCH -> new CallResult(Status.OK, null,
                        workspace.search(target, call.query(), call.maxMatches(), cancelled), null, null);
                case EDIT -> new CallResult(Status.OK, null, null,
                        workspace.edit(target, call.expectedRevision(), call.needle(),
                                call.replacement(), call.maxReplacements(), cancelled), null);
                case WRITE -> new CallResult(Status.OK, null, null,
                        workspace.write(target, call.expectedRevision(), call.replacement(), cancelled), null);
            };
        } catch (IsolatedWorkerWriteback.CommitUncertain failure) {
            observedRevision = failure.receipt.sha256();
            result = CallResult.error(Status.COMMIT_UNCERTAIN, "Workspace commit needs inspection before retry");
        } catch (CommitOutcomeUnknown failure) {
            result = CallResult.error(Status.COMMIT_UNCERTAIN, "Workspace commit needs inspection before retry");
        } catch (StaleRevision failure) {
            result = CallResult.error(Status.STALE, "Workspace revision changed");
        } catch (InterruptedException failure) {
            cancellationObserved.set(true);
            Thread.currentThread().interrupt();
            result = CallResult.error(writes(call.action()) ? Status.COMMIT_UNCERTAIN : Status.CANCELLED,
                    "Capability operation interrupted; inspect workspace before retrying an edit");
        } catch (InterruptedIOException failure) {
            cancellationObserved.set(true);
            Thread.currentThread().interrupt();
            result = CallResult.error(writes(call.action()) ? Status.COMMIT_UNCERTAIN : Status.CANCELLED,
                    "Capability operation interrupted; inspect workspace before retrying an edit");
        } catch (Exception failure) {
            result = CallResult.error(writes(call.action()) ? Status.COMMIT_UNCERTAIN : Status.FAILED,
                    "Capability operation failed: " + failure.getClass().getSimpleName()
                            + "; inspect workspace before retrying an edit");
        }
        synchronized (gate) {
            inFlight--;
            if (result.edit() != null) observedRevision = result.edit().revision();
            try {
                refreshTerminalLocked(() -> callerCancelled.getAsBoolean()
                        || cancellationObserved.get() || Thread.currentThread().isInterrupted());
            } catch (RuntimeException failure) {
                terminalizeLocked(Terminal.FAILED);
                result = CallResult.error(writes(call.action()) ? Status.COMMIT_UNCERTAIN : Status.FAILED,
                        "Capability cancellation check failed after execution");
            }
            if (terminal != null && result.status() != Status.COMMIT_UNCERTAIN
                    && !(terminal == Terminal.FAILED && result.status() == Status.FAILED)) {
                if (writes(call.action()) && result.status() != Status.STALE) {
                    result = CallResult.error(Status.COMMIT_UNCERTAIN,
                            "Run closed during edit; inspect workspace before retry");
                } else if (result.status() != Status.STALE) {
                    result = CallResult.error(terminalStatus(), "Run closed while capability call was in flight");
                }
            }
            try {
                audit.record(new Event(Phase.CALL_SETTLED, ownerId, runId, call.callId(), call.grantId(),
                        target, null, call.action(), result.status(), null, call.expectedRevision(),
                        observedRevision));
            } catch (IOException | RuntimeException failure) {
                auditUncertain = true;
                terminalizeLocked(Terminal.AUDIT_UNCERTAIN);
                return CallResult.error(Status.AUDIT_UNCERTAIN,
                        "Call outcome could not be recorded; inspect workspace before retry");
            }
            return result;
        }
    }

    public Terminal complete() {
        synchronized (gate) {
            if (terminal == null && inFlight != 0)
                throw new IllegalStateException("Cannot complete a run with unsettled capability calls");
            terminalizeLocked(Terminal.COMPLETED);
            return terminal;
        }
    }
    public Terminal cancel() { return terminalize(Terminal.CANCELLED); }
    public Terminal workerDied() { return terminalize(Terminal.WORKER_DIED); }
    public Terminal fail() { return terminalize(Terminal.FAILED); }
    public Terminal timeout() { return terminalize(Terminal.EXPIRED); }

    private Terminal terminalize(Terminal reason) {
        synchronized (gate) { terminalizeLocked(reason); return terminal; }
    }
    private CallResult rejectLocked(Call call, Status reason, String detail) {
        GrantSpec grant = grants.get(call.grantId());
        try {
            audit.record(new Event(Phase.CALL_REJECTED, ownerId, runId,
                    uuid(call.callId()) ? call.callId() : null,
                    uuid(call.grantId()) ? call.grantId() : null,
                    grant == null ? null : grant.filename(), null, call.action(), reason, null,
                    call.expectedRevision(), null));
        } catch (IOException | RuntimeException failure) {
            terminalizeLocked(Terminal.AUDIT_UNCERTAIN);
            return CallResult.error(Status.AUDIT_UNCERTAIN, "Call rejection could not be recorded");
        }
        return CallResult.error(reason, detail);
    }
    private void terminalizeLocked(Terminal reason) {
        if (terminal != null) return;
        terminal = reason;
        try {
            audit.record(new Event(Phase.RUN_FINISHED, ownerId, runId, null, null, null, null, null, null, reason, null, null));
        } catch (IOException | RuntimeException failure) {
            auditUncertain = true;
            terminal = Terminal.AUDIT_UNCERTAIN;
        }
    }
    private void refreshTerminalLocked(BooleanSupplier callerCancelled) {
        if (terminal == null && (callerCancelled.getAsBoolean() || Thread.currentThread().isInterrupted()))
            terminalizeLocked(Terminal.CANCELLED);
        if (terminal == null && expired()) terminalizeLocked(Terminal.EXPIRED);
    }
    private boolean expired() { return monotonicNanos.getAsLong() - deadlineNanos >= 0; }
    private Status terminalStatus() {
        return switch (terminal) {
            case COMPLETED, FAILED -> Status.DENIED;
            case CANCELLED -> Status.CANCELLED;
            case EXPIRED -> Status.EXPIRED;
            case WORKER_DIED -> Status.WORKER_DIED;
            case AUDIT_UNCERTAIN -> Status.AUDIT_UNCERTAIN;
        };
    }
    private static boolean uuid(String value) {
        if (value == null) return false;
        try { return UUID.fromString(value).toString().equals(value); }
        catch (IllegalArgumentException invalid) { return false; }
    }
    private static boolean writes(Action action) { return action == Action.EDIT || action == Action.WRITE; }
    private static void validRevision(String value) {
        if (value == null || !(value.equals(IsolatedWorkerWriteback.MISSING) || value.matches("[0-9a-f]{64}")))
            throw new IllegalArgumentException("Invalid workspace revision");
    }
    private static void presentRevision(String value) {
        validRevision(value);
        if (IsolatedWorkerWriteback.MISSING.equals(value))
            throw new IllegalArgumentException("Result cannot claim a missing revision");
    }
    private static void boundedText(String value) {
        if (value == null || strictUtf8Bytes(value) > IsolatedWorkerInput.MAX_TEXT_BYTES)
            throw new IllegalArgumentException("Unbounded capability text");
    }
    private static void validateRelativeName(String name) {
        if (name == null || name.isEmpty() || strictUtf8Bytes(name) > 512
                || name.startsWith("/") || name.contains("\\") || name.contains(":"))
            throw new IllegalArgumentException("Invalid capability target");
        String[] segments = name.split("/", -1);
        if (segments.length > 16) throw new IllegalArgumentException("Capability target exceeds depth limit");
        for (String segment : segments) {
            if (segment.isEmpty() || segment.equals(".") || segment.equals("..")
                    || strictUtf8Bytes(segment) > 180
                    || segment.codePoints().anyMatch(Character::isISOControl))
                throw new IllegalArgumentException("Invalid capability target");
        }
    }
    /** Deny edits to App control metadata even through a broader directory grant. */
    private static boolean protectedWritePath(String name) {
        for (String segment : name.split("/")) {
            if (segment.equals(".git") || segment.equals(".agents")
                    || segment.equals(".codex") || segment.equals(".aws")) return true;
        }
        return false;
    }
    /** A directory handle accepts only an explicit child; the guest never names its App root. */
    private static String resolveTarget(GrantSpec grant, String relativePath) {
        if (!grant.directory()) {
            if (relativePath != null) throw new IllegalArgumentException("Exact file has no child path");
            return grant.filename();
        }
        if (relativePath == null) throw new IllegalArgumentException("Directory child path required");
        validateRelativeName(relativePath);
        String target = grant.filename() + relativePath;
        validateRelativeName(target);
        return target;
    }
    private static SandboxPolicy readOnlyFor(List<GrantSpec> specs) {
        if (specs == null) throw new IllegalArgumentException("Missing capability grants");
        Set<String> targets = new HashSet<>();
        for (GrantSpec spec : specs) targets.add(Objects.requireNonNull(spec).filename());
        return SandboxPolicy.readOnly(targets);
    }
    private static int strictUtf8Bytes(String value) {
        try {
            return StandardCharsets.UTF_8.newEncoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .encode(CharBuffer.wrap(value)).remaining();
        } catch (CharacterCodingException invalid) {
            throw new IllegalArgumentException("Capability value is not valid UTF-8", invalid);
        }
    }
}
