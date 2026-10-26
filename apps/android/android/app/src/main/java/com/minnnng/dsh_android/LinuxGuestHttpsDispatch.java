package com.minnnng.dsh_android;

import java.io.IOException;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.Objects;
import java.util.concurrent.atomic.AtomicBoolean;

/** App-owned HTTPS request dispatch for an admitted Linux guest control frame. */
final class LinuxGuestHttpsDispatch implements AutoCloseable {
    private static final int MAX_BODY_BYTES = 1536;
    private static final int MAX_CONTENT_TYPE_BYTES = 256;
    private static final int MAX_TOTAL_REPLY_BYTES = 64 * 1024;
    private static final int RESULT_MAGIC = 0x44534848; // DSHH
    private final LinuxGuestSandboxPolicy policy;
    private final LinuxGuestBrokerWire wire;
    private final IsolatedExecutionPolicyOwner.Lease lease;
    private final IsolatedNetworkJournal journal;
    private final IsolatedNetworkBroker network;
    private final AtomicBoolean closed = new AtomicBoolean();
    private int replyBytes;

    LinuxGuestHttpsDispatch(LinuxGuestSandboxPolicy policy, LinuxGuestBrokerWire wire,
                            IsolatedExecutionPolicyOwner.Lease lease,
                            IsolatedNetworkJournal journal,
                            IsolatedNetworkBroker.DeadlineResolver resolver,
                            IsolatedNetworkBroker.PinnedTransport transport) {
        this.policy = Objects.requireNonNull(policy);
        this.wire = Objects.requireNonNull(wire);
        this.lease = Objects.requireNonNull(lease);
        this.journal = Objects.requireNonNull(journal);
        if (!policy.runId().equals(lease.runId()) || !policy.active()
                || !lease.active(lease.policy().version()) || policy.networkCallLimit() < 1)
            throw new IllegalArgumentException("Linux guest HTTPS has no matching live lease");
        network = new IsolatedNetworkBroker(new IsolatedNetworkBroker.Policy(
                lease.policy().exactHosts()), Objects.requireNonNull(resolver),
                Objects.requireNonNull(transport), journal,
                IsolatedNetworkBroker.MAX_DURATION_MILLIS, MAX_BODY_BYTES,
                lease.deadlineNanos());
        lease.onRevoked(this::close);
    }

    /** Returns a bounded wire reply, or null after cancelling an unsafe or uncertain run. */
    byte[] dispatch(LinuxGuestBrokerWire.Request request) {
        if (closed.get() || request == null || !wire.ownsPending(request)
                || request.operation() != LinuxGuestBrokerWire.Operation.HTTPS_HOST
                || !policy.active() || !lease.active(lease.policy().version())) {
            close();
            return null;
        }
        URI uri;
        try { uri = IsolatedNetworkBroker.checkedUri(request.target()); }
        catch (IllegalArgumentException invalid) {
            close();
            return null;
        }
        if (!policy.permitsBrokeredHttpsHost(uri.getHost())) {
            close();
            return null;
        }
        IsolatedNetworkBroker.Result result;
        try { result = network.get(request.callId(), request.target()); }
        catch (RuntimeException invalid) {
            close();
            return null;
        }
        if (closed.get() || !policy.active() || !lease.active(lease.policy().version())
                || !wire.ownsPending(request) || !isAudited(request, uri, result)) {
            close();
            return null;
        }
        byte[] payload;
        try { payload = encodeResult(result); }
        catch (IllegalArgumentException invalid) {
            close();
            return null;
        }
        synchronized (this) {
            if (closed.get() || !policy.active() || !wire.ownsPending(request)
                    || replyBytes > MAX_TOTAL_REPLY_BYTES - payload.length) {
                close();
                return null;
            }
            byte[] reply = wire.complete(request, true,
                    result.status() == IsolatedNetworkBroker.Status.OK, payload);
            if (reply == null || closed.get() || !policy.active()
                    || !lease.active(lease.policy().version())) {
                close();
                return null;
            }
            replyBytes += payload.length;
            return reply;
        }
    }

    private boolean isAudited(LinuxGuestBrokerWire.Request request, URI uri,
                              IsolatedNetworkBroker.Result result) {
        if (!request.callId().equals(result.auditId())) return false;
        switch (result.status()) {
            case AUDIT_UNAVAILABLE: case AUDIT_FULL: case AUDIT_UNCERTAIN: case REPLAY_DENIED:
                return false;
            default: break;
        }
        try {
            IsolatedNetworkJournal.Entry entry = journal.read(request.callId());
            return entry.state() == IsolatedNetworkJournal.State.TERMINAL
                    && request.callId().equals(entry.callId())
                    && uri.getHost().equals(entry.host()) && result.status() == entry.status();
        } catch (IOException | RuntimeException invalid) {
            return false;
        }
    }

    /** DSHH v1: status, HTTP code, redirect count, URL, MIME, and raw bytes. */
    static byte[] encodeResult(IsolatedNetworkBroker.Result result) {
        byte[] url = result.finalUrl() == null ? new byte[0]
                : result.finalUrl().getBytes(StandardCharsets.US_ASCII);
        byte[] type = result.contentType() == null ? new byte[0]
                : result.contentType().getBytes(StandardCharsets.UTF_8);
        byte[] body = result.body();
        if (url.length > IsolatedNetworkBroker.MAX_URL_BYTES
                || type.length > MAX_CONTENT_TYPE_BYTES || body.length > MAX_BODY_BYTES
                || result.statusCode() < 0 || result.statusCode() > 599
                || result.redirects() < 0 || result.redirects() > IsolatedNetworkBroker.MAX_REDIRECTS)
            throw new IllegalArgumentException("Linux guest HTTPS reply exceeds bounds");
        if (result.finalUrl() != null && !result.finalUrl().matches("[\\x21-\\x7e]*"))
            throw new IllegalArgumentException("Linux guest HTTPS URL is not ASCII");
        ByteBuffer out = ByteBuffer.allocate(15 + url.length + type.length + body.length)
                .order(ByteOrder.BIG_ENDIAN);
        if (out.capacity() > LinuxGuestBrokerWire.MAX_REPLY_BYTES)
            throw new IllegalArgumentException("Linux guest HTTPS reply exceeds wire limit");
        out.putInt(RESULT_MAGIC).put((byte) 1).put(statusTag(result.status()))
                .putShort((short) result.statusCode()).put((byte) result.redirects())
                .putShort((short) url.length).putShort((short) type.length)
                .putShort((short) body.length).put(url).put(type).put(body);
        return out.array();
    }

    private static byte statusTag(IsolatedNetworkBroker.Status status) {
        return switch (status) {
            case OK -> 0;
            case POLICY_DENIED -> 1;
            case NETWORK_OFFLINE -> 2;
            case DEADLINE_EXCEEDED -> 3;
            case RESPONSE_TOO_LARGE -> 4;
            case FAILED -> 5;
            case CANCELLED -> 6;
            case AUDIT_UNAVAILABLE -> 7;
            case AUDIT_FULL -> 8;
            case AUDIT_UNCERTAIN -> 9;
            case REPLAY_DENIED -> 10;
        };
    }

    @Override public void close() {
        if (!closed.compareAndSet(false, true)) return;
        network.revoke();
        wire.close();
    }
}
