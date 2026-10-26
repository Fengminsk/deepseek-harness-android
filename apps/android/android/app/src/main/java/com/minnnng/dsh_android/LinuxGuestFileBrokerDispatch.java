package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;

/** App-side file dispatch for a previously admitted native-guest request. */
final class LinuxGuestFileBrokerDispatch {
    private static final String PREFIX = "/workspace/";

    private final LinuxGuestSandboxPolicy policy;
    private final LinuxGuestBrokerWire wire;
    private final IsolatedCapabilityBroker.WorkspaceOps workspace;
    private final IsolatedCapabilityBroker.AuditSink audit;
    private final Set<String> inFlight = new HashSet<>();

    LinuxGuestFileBrokerDispatch(LinuxGuestSandboxPolicy policy, LinuxGuestBrokerWire wire,
                                 IsolatedCapabilityBroker.WorkspaceOps workspace,
                                 IsolatedCapabilityBroker.AuditSink audit) {
        this.policy = Objects.requireNonNull(policy);
        this.wire = Objects.requireNonNull(wire);
        this.workspace = Objects.requireNonNull(workspace);
        this.audit = Objects.requireNonNull(audit);
    }

    /** The caller must have obtained the sender UID from Binder before wire admission. */
    byte[] dispatch(LinuxGuestBrokerWire.Request request) {
        if (!policy.active()) return abort();
        if (request == null || request.operation() == LinuxGuestBrokerWire.Operation.HTTPS_HOST
                || !wire.ownsPending(request)) return null;
        synchronized (inFlight) {
            if (!inFlight.add(request.callId())) return null;
        }
        IsolatedCapabilityBroker broker = null;
        try {
            IsolatedCapabilityBroker.Action action = switch (request.operation()) {
                case FILE_READ -> IsolatedCapabilityBroker.Action.READ;
                case FILE_SEARCH -> IsolatedCapabilityBroker.Action.SEARCH;
                case FILE_EDIT -> IsolatedCapabilityBroker.Action.EDIT;
                default -> throw new IllegalArgumentException("Not a file operation");
            };
            if (!request.target().startsWith(PREFIX)
                    || !policy.permitsBrokeredFile(request.target(), action)) return abort();
            String relative = request.target().substring(PREFIX.length());
            IsolatedCapabilityBroker.GrantSpec grant =
                    new IsolatedCapabilityBroker.GrantSpec(relative, AndroidJava28.setOf(action));
            IsolatedCapabilityBroker.SandboxPolicy exact = action == IsolatedCapabilityBroker.Action.EDIT
                    ? new IsolatedCapabilityBroker.SandboxPolicy(
                            AndroidJava28.setOf(relative), AndroidJava28.setOf(relative))
                    : IsolatedCapabilityBroker.SandboxPolicy.readOnly(AndroidJava28.setOf(relative));
            // Each wire call gets one exact App-side grant. The opaque handle and App path
            // never appear in the guest frame or broker reply.
            IsolatedCapabilityBroker.WorkspaceOps checkedWorkspace = new IsolatedCapabilityBroker.WorkspaceOps() {
                @Override public IsolatedCapabilityBroker.ReadData read(String filename,
                        java.util.function.BooleanSupplier cancelled) throws Exception {
                    IsolatedCapabilityBroker.ReadData data = workspace.read(filename, cancelled);
                    if (!request.expectedRevision().equals(IsolatedWorkerWriteback.MISSING)
                            && !request.expectedRevision().equals(data.revision()))
                        throw new IsolatedCapabilityBroker.StaleRevision();
                    return data;
                }
                @Override public IsolatedCapabilityBroker.SearchData search(String filename,
                        String query, int maxMatches,
                        java.util.function.BooleanSupplier cancelled) throws Exception {
                    return workspace.search(filename, query, maxMatches, cancelled);
                }
                @Override public IsolatedCapabilityBroker.EditData edit(String filename,
                        String expectedRevision, String needle, String replacement,
                        int maxReplacements,
                        java.util.function.BooleanSupplier cancelled) throws Exception {
                    return workspace.edit(filename, expectedRevision, needle,
                            replacement, maxReplacements, cancelled);
                }
            };
            broker = new IsolatedCapabilityBroker(
                    "linux:" + policy.runId(), checkedWorkspace, audit, List.of(grant), exact, 60_000);
            String handle = broker.handles().get(0).id();
            IsolatedCapabilityBroker.Call call = switch (action) {
                case READ -> IsolatedCapabilityBroker.Call.read(broker.runId(), request.callId(), handle);
                case SEARCH -> IsolatedCapabilityBroker.Call.search(broker.runId(), request.callId(),
                        handle, request.query(), request.maxMatches());
                case EDIT -> IsolatedCapabilityBroker.Call.edit(broker.runId(), request.callId(),
                        handle, request.expectedRevision(), request.needle(),
                        request.replacement(), request.maxReplacements());
                case WRITE -> throw new IllegalArgumentException("Linux guest wire does not grant full writes");
            };
            IsolatedCapabilityBroker.CallResult result = broker.execute(call,
                    () -> !policy.active() || !wire.ownsPending(request));
            if (result.status() == IsolatedCapabilityBroker.Status.AUDIT_UNCERTAIN
                    || result.status() == IsolatedCapabilityBroker.Status.COMMIT_UNCERTAIN
                    || result.status() == IsolatedCapabilityBroker.Status.CANCELLED
                    || result.status() == IsolatedCapabilityBroker.Status.EXPIRED
                    || !policy.active()) {
                broker.fail();
                return abort();
            }
            boolean success = result.status() == IsolatedCapabilityBroker.Status.OK;
            byte[] body = success ? successBody(request, result)
                    : result.status().name().getBytes(StandardCharsets.US_ASCII);
            if (broker.complete() != IsolatedCapabilityBroker.Terminal.COMPLETED
                    || broker.auditUncertain() || !policy.active()) return abort();
            return wire.complete(request, true, success, body);
        } catch (IOException | RuntimeException failure) {
            // An edit may already have committed. No unaudited or ambiguous result may
            // cross the wire; the caller must inspect the workspace before retrying.
            if (broker != null) broker.fail();
            return abort();
        } finally {
            synchronized (inFlight) { inFlight.remove(request.callId()); }
        }
    }

    private byte[] abort() { wire.close(); return null; }

    private static byte[] successBody(LinuxGuestBrokerWire.Request request,
                                      IsolatedCapabilityBroker.CallResult result) {
        if (result.read() != null) {
            IsolatedCapabilityBroker.ReadData read = result.read();
            byte[] source = read.text().getBytes(StandardCharsets.UTF_8);
            int offset = request.offset();
            if (offset > source.length) throw new IllegalArgumentException("Read offset beyond file");
            int count = Math.min(request.maxBytes(), source.length - offset);
            byte[] revision = read.revision().getBytes(StandardCharsets.US_ASCII);
            ByteBuffer body = ByteBuffer.allocate(1 + revision.length + 4 + 4 + 2 + count)
                    .order(ByteOrder.BIG_ENDIAN);
            body.put((byte) revision.length).put(revision).putInt(source.length)
                    .putInt(offset).putShort((short) count).put(source, offset, count);
            return body.array();
        }
        if (result.search() != null) {
            IsolatedCapabilityBroker.SearchData search = result.search();
            byte[] revision = search.revision().getBytes(StandardCharsets.US_ASCII);
            ByteBuffer body = ByteBuffer.allocate(LinuxGuestBrokerWire.MAX_REPLY_BYTES)
                    .order(ByteOrder.BIG_ENDIAN);
            body.put((byte) revision.length).put(revision);
            int countAt = body.position();
            body.putShort((short) 0);
            int truncatedAt = body.position();
            body.put((byte) 0);
            int count = 0;
            for (IsolatedCapabilityBroker.Hit hit : search.hits()) {
                byte[] preview = hit.preview().getBytes(StandardCharsets.UTF_8);
                if (body.remaining() < 4 + 4 + 2 + preview.length) break;
                body.putInt(hit.line()).putInt(hit.column()).putShort((short) preview.length)
                        .put(preview);
                count++;
            }
            body.putShort(countAt, (short) count);
            body.put(truncatedAt, (byte) (search.truncated() || count < search.hits().size() ? 1 : 0));
            byte[] encoded = new byte[body.position()];
            body.flip();
            body.get(encoded);
            return encoded;
        }
        IsolatedCapabilityBroker.EditData edit = Objects.requireNonNull(result.edit());
        byte[] previous = edit.previousRevision().getBytes(StandardCharsets.US_ASCII);
        byte[] revision = edit.revision().getBytes(StandardCharsets.US_ASCII);
        return ByteBuffer.allocate(1 + previous.length + 1 + revision.length + 4)
                .order(ByteOrder.BIG_ENDIAN)
                .put((byte) previous.length).put(previous)
                .put((byte) revision.length).put(revision).putInt(edit.bytes()).array();
    }

}
