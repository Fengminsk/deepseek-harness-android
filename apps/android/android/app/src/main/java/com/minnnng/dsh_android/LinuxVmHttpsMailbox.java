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
 * with native block writes. The exchange can be an App-owned broker or an identity-bound IPC peer.
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
    private final String runId;
    private final int callLimit;
    private final LinuxVmHttpsExchange exchange;
    private final AtomicBoolean vmCancelled;
    private final AtomicBoolean closed = new AtomicBoolean();
    private long pollThread;
    private int sequence;

    LinuxVmHttpsMailbox(ByteBuffer disk, IsolatedExecutionPolicyOwner.Lease lease,
                        IsolatedNetworkJournal journal,
                        IsolatedNetworkBroker.DeadlineResolver resolver,
                        IsolatedNetworkBroker.PinnedTransport transport, AtomicBoolean vmCancelled) {
        this(checkedDisk(disk), lease.runId(), lease.policy().networkCallLimit(),
                new LinuxVmHttpsBrokerExchange(lease, journal, resolver, transport), vmCancelled);
    }

    LinuxVmHttpsMailbox(ByteBuffer disk, String runId, int callLimit,
                       LinuxVmHttpsExchange exchange, AtomicBoolean vmCancelled) {
        checkedDisk(disk);
        if (!UUID.fromString(runId).toString().equals(runId)
                || callLimit < 1 || callLimit > IsolatedNetworkBroker.MAX_CALLS)
            throw new IllegalArgumentException("Invalid VM HTTPS admission");
        this.disk = disk.duplicate();
        this.disk.clear();
        this.disk.order(ByteOrder.BIG_ENDIAN);
        this.runId = runId;
        this.callLimit = callLimit;
        this.exchange = Objects.requireNonNull(exchange);
        this.vmCancelled = Objects.requireNonNull(vmCancelled);
        if (!exchange.active()) { exchange.close(); throw new IllegalArgumentException("VM HTTPS exchange is inactive"); }
    }

    private static ByteBuffer checkedDisk(ByteBuffer disk) {
        if (!disk.isDirect() || disk.isReadOnly() || disk.capacity() != DISK_BYTES)
            throw new IllegalArgumentException("Invalid VM HTTPS mailbox mapping");
        return disk;
    }

    /** One complete request per sequence; an invalid or replayed frame retires the capability. */
    void poll() {
        long thread = Thread.currentThread().getId();
        if (pollThread == 0) pollThread = thread;
        if (pollThread != thread) { close(); throw new IllegalStateException("VM mailbox polled on another thread"); }
        if (!active()) { close(); return; }
        int next = disk.getInt(8);
        if (next == sequence) return;
        try {
            if (next != sequence + 1 || next > callLimit
                    || next > IsolatedNetworkBroker.MAX_CALLS || disk.getInt(0) != MAGIC
                    || disk.getInt(4) != 1) throw new IOException("Invalid VM HTTPS sequence");
            int size = disk.getInt(12);
            if (size < 73 || size > 72 + IsolatedNetworkBroker.MAX_URL_BYTES)
                throw new IOException("Invalid VM HTTPS request length");
            byte[] expected = read(16, 32), payload = read(SECTOR_BYTES, size);
            if (!MessageDigest.isEqual(expected, sha256(payload))) throw new IOException("Invalid mailbox digest");
            String run = ascii(payload, 0, 36), call = ascii(payload, 36, 36);
            if (!runId.equals(run) || !UUID.fromString(call).toString().equals(call))
                throw new IOException("VM HTTPS run or call changed");
            String url = ascii(payload, 72, size - 72);
            sequence = next;
            byte[] reply = exchange.request(next, run, call, url);
            if (!active()) { close(); return; }
            validateReply(reply, run, call);
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
        return !closed.get() && !vmCancelled.get() && exchange.active();
    }

    @Override public void close() {
        if (closed.compareAndSet(false, true)) {
            vmCancelled.set(true);
            exchange.close();
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

    static byte[] encode(String run, String call, IsolatedNetworkBroker.Result result)
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

    /** Reject corrupt, cross-run or unbounded IPC replies before publishing to the virtual disk. */
    static void validateReply(byte[] reply, String run, String call) throws IOException {
        if (reply == null || reply.length < 83 || reply.length > RESPONSE_BYTES - SECTOR_BYTES)
            throw new IOException("Invalid VM HTTPS response size");
        ByteBuffer view = ByteBuffer.wrap(reply).order(ByteOrder.BIG_ENDIAN);
        int status = Byte.toUnsignedInt(reply[72]);
        int http = Short.toUnsignedInt(view.getShort(73));
        int url = Short.toUnsignedInt(view.getShort(75));
        int type = Short.toUnsignedInt(view.getShort(77));
        int body = view.getInt(79);
        if (!ascii(reply, 0, 36).equals(run) || !ascii(reply, 36, 36).equals(call)
                || status >= IsolatedNetworkBroker.Status.AUDIT_UNAVAILABLE.ordinal()
                || url > IsolatedNetworkBroker.MAX_URL_BYTES || type > 1024 || body < 0 || body > MAX_BODY_BYTES
                || 83L + url + type + body != reply.length
                || (status == 0 ? http < 100 || http > 599 : http != 0 || body != 0))
            throw new IOException("Invalid VM HTTPS response fields");
        ascii(reply, 83, url);
    }
}
