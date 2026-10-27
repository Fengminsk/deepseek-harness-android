package com.minnnng.dsh_android;

import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Objects;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Optional bounded HTTPS mailbox for a dedicated VM block mapping. No socket or App file
 * handle is given to the guest. The trusted caller supplies the mapping bound to this lease.
 * poll() must run between interpreter steps on that interpreter's thread, never concurrently
 * with native block writes. Android isolated-Service/Binder admission is not implemented here.
 * Run cancellation must call close() (or revoke its lease) to close an in-flight socket;
 * setting the VM's cancellation flag alone is observed on the next interpreter callback.
 */
final class LinuxVmHttpsMailbox implements AutoCloseable {
    static final int REQUEST_BYTES = 4096;
    static final int RESPONSE_BYTES = 131072;
    static final int DISK_BYTES = REQUEST_BYTES + RESPONSE_BYTES;
    static final int SECTOR_BYTES = 512;
    static final int MAX_BODY_BYTES = 65536;
    static final int MAGIC = 0x4453484d; // DSHM
    private final ByteBuffer disk;
    private final IsolatedExecutionPolicyOwner.Lease lease;
    private final IsolatedNetworkJournal journal;
    private final IsolatedNetworkBroker broker;
    private final AtomicBoolean vmCancelled;
    private final AtomicBoolean closed = new AtomicBoolean();
    private long pollThread;
    private int sequence;

    LinuxVmHttpsMailbox(ByteBuffer disk, IsolatedExecutionPolicyOwner.Lease lease,
                        IsolatedNetworkJournal journal,
                        IsolatedNetworkBroker.DeadlineResolver resolver,
                        IsolatedNetworkBroker.PinnedTransport transport, AtomicBoolean vmCancelled) {
        if (!disk.isDirect() || disk.isReadOnly() || disk.capacity() != DISK_BYTES)
            throw new IllegalArgumentException("Invalid VM HTTPS mailbox mapping");
        this.disk = disk.duplicate().order(ByteOrder.BIG_ENDIAN);
        this.lease = Objects.requireNonNull(lease);
        this.journal = Objects.requireNonNull(journal);
        this.vmCancelled = Objects.requireNonNull(vmCancelled);
        if (!lease.active(lease.policy().version()) || lease.policy().networkCallLimit() < 1)
            throw new IllegalArgumentException("VM HTTPS requires an active network lease");
        broker = new IsolatedNetworkBroker(new IsolatedNetworkBroker.Policy(lease.policy().exactHosts()),
                resolver, transport, journal, IsolatedNetworkBroker.MAX_DURATION_MILLIS,
                MAX_BODY_BYTES, lease.deadlineNanos());
        lease.onRevoked(this::close);
    }

    /** One complete request per sequence; an invalid or replayed frame retires the capability. */
    void poll() {
        long thread = Thread.currentThread().getId();
        if (pollThread == 0) pollThread = thread;
        if (pollThread != thread) throw new IllegalStateException("VM mailbox polled on another thread");
        if (!active()) { close(); return; }
        int next = disk.getInt(8);
        if (next == sequence) return;
        try {
            if (next != sequence + 1 || next > lease.policy().networkCallLimit()
                    || next > IsolatedNetworkBroker.MAX_CALLS || disk.getInt(0) != MAGIC
                    || disk.getInt(4) != 1) throw new IOException("Invalid VM HTTPS sequence");
            int size = disk.getInt(12);
            if (size < 73 || size > 72 + IsolatedNetworkBroker.MAX_URL_BYTES)
                throw new IOException("Invalid VM HTTPS request length");
            byte[] expected = read(16, 32), payload = read(SECTOR_BYTES, size);
            if (!MessageDigest.isEqual(expected, sha256(payload))) throw new IOException("Invalid mailbox digest");
            String run = ascii(payload, 0, 36), call = ascii(payload, 36, 36);
            if (!lease.runId().equals(run) || !UUID.fromString(call).toString().equals(call))
                throw new IOException("VM HTTPS run or call changed");
            String url = ascii(payload, 72, size - 72);
            sequence = next;
            IsolatedNetworkBroker.Result result = broker.get(call, url);
            if (!active()) { close(); return; }
            IsolatedNetworkJournal.Entry entry = journal.read(call);
            if (entry == null || entry.state() != IsolatedNetworkJournal.State.TERMINAL
                    || entry.status() != result.status()
                    || result.status() == IsolatedNetworkBroker.Status.REPLAY_DENIED
                    || result.status() == IsolatedNetworkBroker.Status.AUDIT_UNAVAILABLE
                    || result.status() == IsolatedNetworkBroker.Status.AUDIT_FULL
                    || result.status() == IsolatedNetworkBroker.Status.AUDIT_UNCERTAIN)
                throw new IOException("VM HTTPS result has no committed audit");
            byte[] reply = encode(run, call, result);
            if (!active()) { close(); return; }
            put(REQUEST_BYTES + SECTOR_BYTES, reply);
            put(REQUEST_BYTES + 16, sha256(reply));
            disk.putInt(REQUEST_BYTES, MAGIC);
            disk.putInt(REQUEST_BYTES + 4, 1);
            disk.putInt(REQUEST_BYTES + 12, reply.length);
            // Last write commits the response; native execution resumes after poll returns.
            disk.putInt(REQUEST_BYTES + 8, sequence);
        } catch (IOException | IllegalArgumentException invalid) {
            close();
        }
    }

    private boolean active() {
        return !closed.get() && !vmCancelled.get() && lease.active(lease.policy().version());
    }

    @Override public void close() {
        if (closed.compareAndSet(false, true)) {
            vmCancelled.set(true);
            broker.revoke();
        }
    }

    private byte[] read(int offset, int size) {
        byte[] bytes = new byte[size];
        ByteBuffer view = disk.duplicate(); view.position(offset); view.get(bytes);
        return bytes;
    }

    private void put(int offset, byte[] bytes) {
        ByteBuffer view = disk.duplicate(); view.position(offset); view.put(bytes);
    }

    private static String ascii(byte[] bytes, int offset, int size) throws IOException {
        for (int i = offset; i < offset + size; i++) {
            if (bytes[i] < 32 || bytes[i] > 126) throw new IOException("Non-ASCII mailbox field");
        }
        return new String(bytes, offset, size, StandardCharsets.US_ASCII);
    }

    static byte[] sha256(byte[] bytes) {
        try { return MessageDigest.getInstance("SHA-256").digest(bytes); }
        catch (NoSuchAlgorithmException error) { throw new IllegalStateException(error); }
    }

    private static byte[] encode(String run, String call, IsolatedNetworkBroker.Result result)
            throws IOException {
        byte[] url = (result.finalUrl() == null ? "" : result.finalUrl()).getBytes(StandardCharsets.US_ASCII);
        byte[] type = (result.contentType() == null ? "" : result.contentType()).getBytes(StandardCharsets.UTF_8);
        byte[] body = result.body();
        if (url.length > IsolatedNetworkBroker.MAX_URL_BYTES || type.length > 1024
                || body.length > MAX_BODY_BYTES) throw new IOException("Oversized mailbox response");
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        DataOutputStream out = new DataOutputStream(bytes);
        out.writeBytes(run); out.writeBytes(call);
        out.writeByte(result.status().ordinal()); out.writeShort(result.statusCode());
        out.writeShort(url.length); out.writeShort(type.length); out.writeInt(body.length);
        out.write(url); out.write(type); out.write(body);
        return bytes.toByteArray();
    }
}
