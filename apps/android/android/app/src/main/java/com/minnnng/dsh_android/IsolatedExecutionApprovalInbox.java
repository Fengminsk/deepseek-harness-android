package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.function.LongSupplier;

/** App-owned, ephemeral review queue. Only trusted native code can prepare a scope. */
public final class IsolatedExecutionApprovalInbox implements AutoCloseable {
    public static final int MAX_PENDING = 32;
    public static final long REVIEW_MILLIS = 5 * 60_000L;

    public interface Decision {
        /** Persist exactly this scope before starting the one named run. */
        void approve(IsolatedExecutionPolicyOwner.Scope scope, String runId,
                     String approvalId) throws IOException;
        /** Persist revocation and stop or discard the named run. */
        void deny(String runId) throws IOException;
    }

    public static final class Review {
        private final String id;
        private final String challenge;
        private final String runId;
        private final String sessionId;
        private final long expiresAtMillis;
        private final IsolatedExecutionPolicyOwner.Scope scope;
        private final String program;
        private final String programSha256;
        private final String snapshotSha256;
        private final boolean active;

        private Review(String id, String challenge, String runId, String sessionId,
                       long expiresAtMillis, IsolatedExecutionPolicyOwner.Scope scope,
                       String program, String programSha256, String snapshotSha256,
                       boolean active) {
            this.id = id;
            this.challenge = challenge;
            this.runId = runId;
            this.sessionId = sessionId;
            this.expiresAtMillis = expiresAtMillis;
            this.scope = scope;
            this.program = program;
            this.programSha256 = programSha256;
            this.snapshotSha256 = snapshotSha256;
            this.active = active;
        }
        public String id() { return id; }
        public String challenge() { return challenge; }
        public String runId() { return runId; }
        public String sessionId() { return sessionId; }
        public long expiresAtMillis() { return expiresAtMillis; }
        public boolean active() { return active; }
        public String program() { return program; }
        public String programSha256() { return programSha256; }
        public String snapshotSha256() { return snapshotSha256; }
        public String workspacePath() {
            return scope.workspaceRoot() == null ? null : scope.workspaceRoot().toString();
        }
        public List<String> readablePaths() { return sorted(scope.readablePaths()); }
        public List<String> writablePaths() { return sorted(scope.writablePaths()); }
        public List<String> exactHosts() { return sorted(scope.exactHosts()); }
        public int fileCallLimit() { return scope.fileCallLimit(); }
        public int networkCallLimit() { return scope.networkCallLimit(); }
        public long leaseMillis() { return scope.leaseMillis(); }
        private static List<String> sorted(Set<String> entries) {
            List<String> copy = new ArrayList<>(entries);
            Collections.sort(copy);
            return Collections.unmodifiableList(copy);
        }
    }

    private static final class Entry {
        private final Review pending;
        private final Decision decision;
        private boolean active;
        private Entry(Review pending, Decision decision) {
            this.pending = pending;
            this.decision = decision;
        }
        private Review view() {
            return new Review(pending.id, pending.challenge, pending.runId,
                    pending.sessionId, pending.expiresAtMillis, pending.scope,
                    pending.program, pending.programSha256, pending.snapshotSha256, active);
        }
    }

    private final LongSupplier now;
    private final Map<String, Entry> entries = new HashMap<>();
    private boolean closed;

    public IsolatedExecutionApprovalInbox() { this(System::currentTimeMillis); }
    IsolatedExecutionApprovalInbox(LongSupplier now) { this.now = Objects.requireNonNull(now); }

    public synchronized Review prepare(String runId, IsolatedExecutionPolicyOwner.Scope scope,
                                       String program, String inputJson, int deadlineMillis,
                                       Decision decision) {
        requireOpen();
        Objects.requireNonNull(scope);
        Objects.requireNonNull(decision);
        PtcScriptEngine.validate(program, inputJson, deadlineMillis);
        IsolatedScriptWire.requireUuid(runId);
        if (scope.readablePaths().isEmpty() && scope.exactHosts().isEmpty())
            throw new IllegalArgumentException("A review must describe a capability");
        if (entries.size() >= MAX_PENDING) throw new IllegalStateException("Review queue is full");
        if (entries.values().stream().anyMatch(entry -> entry.pending.runId.equals(runId)))
            throw new IllegalArgumentException("Run already has an approval request");
        long issued = now.getAsLong();
        String programSha256 = hex(digest().digest(program.getBytes(StandardCharsets.UTF_8)));
        String snapshotSha256 = snapshotDigest(runId, scope, program, inputJson, deadlineMillis);
        Review review = new Review(UUID.randomUUID().toString(), UUID.randomUUID().toString(),
                runId, scope.sessionId(), Math.addExact(issued, REVIEW_MILLIS), scope,
                program, programSha256, snapshotSha256, false);
        entries.put(review.id, new Entry(review, decision));
        return review;
    }

    public synchronized List<Review> list() {
        if (closed) return AndroidJava28.listOf();
        expire();
        List<Review> snapshot = new ArrayList<>();
        for (Entry entry : entries.values()) snapshot.add(entry.view());
        snapshot.sort(Comparator.comparing(Review::id));
        return AndroidJava28.copyList(snapshot);
    }

    /** The caller must have shown the native confirmation for this exact snapshot. */
    public synchronized void approve(String id, String challenge, String snapshotSha256) throws IOException {
        requireOpen();
        Entry entry = exact(id, challenge);
        if (!entry.pending.snapshotSha256.equals(snapshotSha256))
            throw new IllegalArgumentException("Approval snapshot changed or expired");
        if (entry.active) throw new IllegalStateException("Already approved");
        entries.remove(id); // A failed or uncertain commit must never be retried.
        try {
            entry.decision.approve(entry.pending.scope, entry.pending.runId,
                    UUID.randomUUID().toString());
            entry.active = true;
            entries.put(id, entry);
        } catch (IOException | RuntimeException failure) {
            try { entry.decision.deny(entry.pending.runId); }
            catch (Exception close) { failure.addSuppressed(close); }
            throw failure;
        }
    }

    public synchronized void deny(String id, String challenge) throws IOException {
        requireOpen();
        Entry entry = exact(id, challenge);
        entries.remove(id); // Failure is uncertain; never show the same actionable request again.
        entry.decision.deny(entry.pending.runId);
    }

    private Entry exact(String id, String challenge) {
        expire();
        Entry entry = entries.get(id);
        if (entry == null || !entry.pending.challenge.equals(challenge))
            throw new IllegalArgumentException("Approval request changed or expired");
        return entry;
    }

    private static String snapshotDigest(String runId, IsolatedExecutionPolicyOwner.Scope scope,
                                         String program, String inputJson, int deadlineMillis) {
        MessageDigest digest = digest();
        append(digest, "isolated-approval-v1");
        append(digest, runId);
        append(digest, scope.ownerId());
        append(digest, scope.sessionId());
        append(digest, Long.toString(scope.version()));
        append(digest, scope.appPrivateRoot() == null ? "" : scope.appPrivateRoot().toString());
        append(digest, scope.workspaceRoot() == null ? "" : scope.workspaceRoot().toString());
        appendSet(digest, scope.readablePaths());
        appendSet(digest, scope.writablePaths());
        appendSet(digest, scope.exactHosts());
        append(digest, Integer.toString(scope.fileCallLimit()));
        append(digest, Integer.toString(scope.networkCallLimit()));
        append(digest, Long.toString(scope.leaseMillis()));
        append(digest, Integer.toString(deadlineMillis));
        append(digest, program);
        append(digest, inputJson);
        return hex(digest.digest());
    }

    private static void appendSet(MessageDigest digest, Set<String> values) {
        append(digest, Integer.toString(values.size()));
        values.stream().sorted().forEach(value -> append(digest, value));
    }

    private static void append(MessageDigest digest, String value) {
        byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
        digest.update(ByteBuffer.allocate(4).putInt(bytes.length).array());
        digest.update(bytes);
    }

    private static MessageDigest digest() {
        try { return MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
    }

    private static String hex(byte[] bytes) {
        return ImageDigestHex.encode(bytes);
    }

    private void expire() {
        long clock = now.getAsLong();
        var cursor = entries.entrySet().iterator();
        while (cursor.hasNext()) {
            Entry entry = cursor.next().getValue();
            long limit = entry.pending.expiresAtMillis +
                    (entry.active ? entry.pending.scope.leaseMillis() : 0);
            if (clock < limit) continue;
            cursor.remove();
            try { entry.decision.deny(entry.pending.runId); }
            catch (Exception ignored) { /* Failed durable revocation stays closed on recovery. */ }
        }
    }

    private void requireOpen() {
        if (closed) throw new IllegalStateException("Approval inbox is closed");
    }

    @Override public synchronized void close() {
        closed = true;
        for (Entry entry : entries.values()) {
            try { entry.decision.deny(entry.pending.runId); }
            catch (Exception ignored) { /* Restart restores a denied durable policy. */ }
        }
        entries.clear();
    }
}
