package com.minnnng.dsh_android;

import java.io.IOException;
import java.util.Objects;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

/** App-owned HTTPS capability. No lease, DNS, socket, journal or App path crosses into the guest. */
final class LinuxVmHttpsBrokerExchange implements LinuxVmHttpsExchange {
    private final IsolatedExecutionPolicyOwner.Lease lease;
    private final IsolatedNetworkJournal journal;
    private final IsolatedNetworkBroker broker;
    private final AtomicBoolean closed = new AtomicBoolean();
    private final AtomicBoolean inFlight = new AtomicBoolean();
    private final AtomicInteger sequence = new AtomicInteger();

    LinuxVmHttpsBrokerExchange(IsolatedExecutionPolicyOwner.Lease lease, IsolatedNetworkJournal journal,
            IsolatedNetworkBroker.DeadlineResolver resolver, IsolatedNetworkBroker.PinnedTransport transport) {
        this.lease = Objects.requireNonNull(lease);
        this.journal = Objects.requireNonNull(journal);
        if (!lease.active(lease.policy().version()) || lease.policy().networkCallLimit() < 1)
            throw new IllegalArgumentException("VM HTTPS requires an active network lease");
        broker = new IsolatedNetworkBroker(new IsolatedNetworkBroker.Policy(lease.policy().exactHosts()),
                resolver, transport, journal, IsolatedNetworkBroker.MAX_DURATION_MILLIS,
                LinuxVmHttpsMailbox.MAX_BODY_BYTES, lease.deadlineNanos());
        lease.onRevoked(this::close);
    }

    @Override public byte[] request(int next, String run, String call, String url) throws IOException {
        if (!inFlight.compareAndSet(false, true)) {
            close(); throw new IOException("Concurrent Linux HTTPS calls are not permitted");
        }
        try {
            if (!active() || !lease.runId().equals(run) || !UUID.fromString(call).toString().equals(call)
                    || next < 1 || next > lease.policy().networkCallLimit()
                    || !sequence.compareAndSet(next - 1, next)
                    || url == null || url.isEmpty() || url.length() > IsolatedNetworkBroker.MAX_URL_BYTES
                    || !url.chars().allMatch(c -> c >= 32 && c <= 126))
                throw new IOException("Linux HTTPS request identity or budget rejected");
            IsolatedNetworkBroker.Result result = broker.get(call, url);
            IsolatedNetworkJournal.Entry entry = journal.read(call);
            if (!active() || !call.equals(result.auditId()) || entry == null
                    || entry.state() != IsolatedNetworkJournal.State.TERMINAL || entry.status() != result.status()
                    || result.status().ordinal() >= IsolatedNetworkBroker.Status.AUDIT_UNAVAILABLE.ordinal())
                throw new IOException("Linux HTTPS result has no confirmed audit");
            return LinuxVmHttpsMailbox.encode(run, call, result);
        } catch (IOException | IllegalArgumentException failure) {
            close(); throw new IOException("Linux HTTPS exchange retired", failure);
        } finally { inFlight.set(false); }
    }

    @Override public boolean active() { return !closed.get() && lease.active(lease.policy().version()); }
    @Override public void close() { if (closed.compareAndSet(false, true)) broker.revoke(); }
}
