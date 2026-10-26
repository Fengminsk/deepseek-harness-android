package com.minnnng.dsh_android;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.CharBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * Proposed native-guest control frames. This is App-owned validation and accounting only:
 * no file, socket, descriptor, native launcher, or executable is supplied by this class.
 * The caller must obtain sendingUid from Binder and broker results from the App's actual
 * audited file/HTTPS broker, never from the native guest's frame.
 */
final class LinuxGuestBrokerWire implements AutoCloseable {
    static final int VERSION = 2;
    static final int MAX_TARGET_BYTES = 2048;
    static final int MAX_REPLY_BYTES = 4096;
    static final int MAX_READ_CHUNK_BYTES = 3800;
    static final int HEADER_BYTES = 4 + 1 + 1 + 2 + 36 + 36 + 2;
    static final int MAX_REQUEST_BYTES = HEADER_BYTES + MAX_TARGET_BYTES;

    private static final int MAGIC = 0x44534842; // DSHB
    private static final int READ = 1;
    private static final int SEARCH = 2;
    private static final int EDIT = 3;
    private static final int HTTPS_HOST = 4;
    private static final int REPLY_OK = 0x81;
    private static final int REPLY_ERROR = 0x82;

    enum Operation { FILE_READ, FILE_SEARCH, FILE_EDIT, HTTPS_HOST }

    static final class Request {
        private final LinuxGuestBrokerWire owner;
        private final String callId;
        private final Operation operation;
        private final String target;
        private final int offset;
        private final int maxBytes;
        private final String query;
        private final int maxMatches;
        private final String expectedRevision;
        private final String needle;
        private final String replacement;
        private final int maxReplacements;

        private Request(LinuxGuestBrokerWire owner, Parsed parsed) {
            this.owner = owner;
            this.callId = parsed.callId;
            this.operation = parsed.operation;
            this.target = parsed.target;
            this.offset = parsed.offset;
            this.maxBytes = parsed.maxBytes;
            this.query = parsed.query;
            this.maxMatches = parsed.maxMatches;
            this.expectedRevision = parsed.expectedRevision;
            this.needle = parsed.needle;
            this.replacement = parsed.replacement;
            this.maxReplacements = parsed.maxReplacements;
        }

        String callId() { return callId; }
        Operation operation() { return operation; }
        String target() { return target; }
        int offset() { return offset; }
        int maxBytes() { return maxBytes; }
        String query() { return query; }
        int maxMatches() { return maxMatches; }
        String expectedRevision() { return expectedRevision; }
        String needle() { return needle; }
        String replacement() { return replacement; }
        int maxReplacements() { return maxReplacements; }
    }

    private final LinuxGuestSandboxPolicy policy;
    private final LinuxGuestLaunchSession session;
    private final Map<String, Request> pending = new HashMap<>();
    private boolean closed;

    LinuxGuestBrokerWire(LinuxGuestSandboxPolicy policy, LinuxGuestLaunchSession session) {
        this.policy = Objects.requireNonNull(policy);
        this.session = Objects.requireNonNull(session);
        if (!policy.active() || !session.matchesRunId(policy.runId())) {
            throw new IllegalArgumentException("Linux guest wire has no matching live run");
        }
    }

    /** A complete frame is delivered by the transport with its Binder-observed sender UID. */
    synchronized Request admitRequest(byte[] frame, int sendingUid) {
        if (closed || session.mayPublishSuccess() || !session.matchesGuestUid(sendingUid))
            return reject();
        try {
            Parsed parsed = parse(frame);
            if (!policy.runId().equals(parsed.runId)) return reject();
            Request request = new Request(this, parsed);
            if (pending.containsKey(request.callId)) return reject();
            boolean admitted;
            switch (request.operation) {
                case FILE_READ:
                    admitted = session.beginFileCall(request.callId, request.target,
                            IsolatedCapabilityBroker.Action.READ);
                    break;
                case FILE_SEARCH:
                    admitted = session.beginFileCall(request.callId, request.target,
                            IsolatedCapabilityBroker.Action.SEARCH);
                    break;
                case FILE_EDIT:
                    admitted = session.beginFileCall(request.callId, request.target,
                            IsolatedCapabilityBroker.Action.EDIT);
                    break;
                case HTTPS_HOST:
                    admitted = session.beginHttpsCall(request.callId,
                            IsolatedNetworkBroker.checkedUri(request.target).getHost());
                    break;
                default:
                    return reject();
            }
            if (!admitted) return reject();
            pending.put(request.callId, request);
            return request;
        } catch (IllegalArgumentException invalid) {
            return reject();
        }
    }

    /**
     * Encode only an already audited App-broker result. No guest-originated reply may call this.
     * A denial can be an ordinary audited result; unaudited, oversized or duplicate replies
     * cancel the entire proposed run.
     */
    synchronized byte[] complete(Request request, boolean audited, boolean success,
                                 byte[] brokerResult) {
        if (closed || session.mayPublishSuccess() || request == null || request.owner != this
                || pending.get(request.callId) != request || !audited
                || brokerResult == null || brokerResult.length > MAX_REPLY_BYTES
                || !session.matchesRunId(policy.runId())) return rejectReply();
        byte[] frame = encode(success ? REPLY_OK : REPLY_ERROR, policy.runId(),
                request.callId, brokerResult);
        if (!session.settleBrokerCall(request.callId, true)) return rejectReply();
        pending.remove(request.callId);
        return frame;
    }

    synchronized int pendingCount() { return pending.size(); }

    /** Check a current App-owned request before any broker side effect. */
    synchronized boolean ownsPending(Request request) {
        return !closed && request != null && request.owner == this
                && pending.get(request.callId) == request && policy.active()
                && !session.mayPublishSuccess();
    }

    @Override public synchronized void close() {
        if (closed) return;
        closed = true;
        pending.clear();
        if (!session.mayPublishSuccess()) session.cancel();
    }

    private Request reject() {
        close();
        return null;
    }

    private byte[] rejectReply() {
        close();
        return null;
    }

    private static final class Parsed {
        final String runId;
        final String callId;
        final Operation operation;
        final String target;
        final int offset;
        final int maxBytes;
        final String query;
        final int maxMatches;
        final String expectedRevision;
        final String needle;
        final String replacement;
        final int maxReplacements;

        Parsed(String runId, String callId, Operation operation, String target,
               int offset, int maxBytes, String query, int maxMatches,
               String expectedRevision, String needle, String replacement, int maxReplacements) {
            this.runId = runId;
            this.callId = callId;
            this.operation = operation;
            this.target = target;
            this.offset = offset;
            this.maxBytes = maxBytes;
            this.query = query;
            this.maxMatches = maxMatches;
            this.expectedRevision = expectedRevision;
            this.needle = needle;
            this.replacement = replacement;
            this.maxReplacements = maxReplacements;
        }
    }

    private static Parsed parse(byte[] frame) {
        if (frame == null || frame.length < HEADER_BYTES || frame.length > MAX_REQUEST_BYTES) {
            throw new IllegalArgumentException("Linux guest request frame length invalid");
        }
        ByteBuffer bytes = ByteBuffer.wrap(frame).order(ByteOrder.BIG_ENDIAN);
        if (bytes.getInt() != MAGIC || Byte.toUnsignedInt(bytes.get()) != VERSION) {
            throw new IllegalArgumentException("Linux guest request frame signature invalid");
        }
        int opcode = Byte.toUnsignedInt(bytes.get());
        if (bytes.getShort() != 0) throw new IllegalArgumentException("Linux guest frame flags invalid");
        byte[] runBytes = new byte[36];
        byte[] callBytes = new byte[36];
        bytes.get(runBytes);
        bytes.get(callBytes);
        String runId = asciiUuid(runBytes);
        String callId = asciiUuid(callBytes);
        int length = Short.toUnsignedInt(bytes.getShort());
        if (length < 1 || length > MAX_TARGET_BYTES || length != bytes.remaining()) {
            throw new IllegalArgumentException("Linux guest target length invalid");
        }
        ByteBuffer payload = bytes.slice().order(ByteOrder.BIG_ENDIAN);
        Operation operation;
        switch (opcode) {
            case READ: operation = Operation.FILE_READ; break;
            case SEARCH: operation = Operation.FILE_SEARCH; break;
            case EDIT: operation = Operation.FILE_EDIT; break;
            case HTTPS_HOST: operation = Operation.HTTPS_HOST; break;
            default: throw new IllegalArgumentException("Linux guest operation invalid");
        }
        if (operation == Operation.HTTPS_HOST) {
            String url = readText(payload, payload.remaining());
            if (!url.matches("[\\x21-\\x7e]+") || !url.startsWith("https://")
                    || !IsolatedNetworkBroker.checkedUri(url).toASCIIString().equals(url))
                throw new IllegalArgumentException("Linux guest HTTPS URL invalid");
            return new Parsed(runId, callId, operation, url, 0, 0,
                    null, 0, null, null, null, 0);
        }
        String path = readSizedText(payload);
        if (operation == Operation.FILE_READ) {
            String revision = readSizedText(payload);
            if (payload.remaining() != 6) throw new IllegalArgumentException("Invalid read payload");
            int offset = payload.getInt();
            int max = Short.toUnsignedInt(payload.getShort());
            if (!(revision.equals(IsolatedWorkerWriteback.MISSING) || revision.matches("[0-9a-f]{64}"))
                    || offset < 0 || max < 1 || max > MAX_READ_CHUNK_BYTES
                    || (offset > 0 && revision.equals(IsolatedWorkerWriteback.MISSING)))
                throw new IllegalArgumentException("Invalid read window");
            return new Parsed(runId, callId, operation, path, offset, max,
                    null, 0, revision, null, null, 0);
        }
        if (operation == Operation.FILE_SEARCH) {
            String query = readSizedText(payload);
            if (payload.remaining() != 2) throw new IllegalArgumentException("Invalid search payload");
            int max = Short.toUnsignedInt(payload.getShort());
            new IsolatedWorkerTextSearch.Spec(query, max);
            return new Parsed(runId, callId, operation, path, 0, 0,
                    query, max, null, null, null, 0);
        }
        String revision = readSizedText(payload);
        String needle = readSizedText(payload);
        String replacement = readSizedTextAllowEmpty(payload);
        if (payload.remaining() != 2) throw new IllegalArgumentException("Invalid edit payload");
        int max = Short.toUnsignedInt(payload.getShort());
        if (!(revision.equals(IsolatedWorkerWriteback.MISSING) || revision.matches("[0-9a-f]{64}")))
            throw new IllegalArgumentException("Invalid edit revision");
        new IsolatedWorkerTextEdit.Spec(needle, replacement, max);
        return new Parsed(runId, callId, operation, path, 0, 0,
                null, 0, revision, needle, replacement, max);
    }

    private static String readSizedText(ByteBuffer payload) {
        if (payload.remaining() < 2) throw new IllegalArgumentException("Missing field length");
        return readText(payload, Short.toUnsignedInt(payload.getShort()));
    }

    private static String readSizedTextAllowEmpty(ByteBuffer payload) {
        if (payload.remaining() < 2) throw new IllegalArgumentException("Missing field length");
        int size = Short.toUnsignedInt(payload.getShort());
        return size == 0 ? "" : readText(payload, size);
    }

    private static String readText(ByteBuffer payload, int size) {
        if (size < 1 || size > payload.remaining())
            throw new IllegalArgumentException("Invalid field length");
        byte[] raw = new byte[size];
        payload.get(raw);
        try {
            CharBuffer decoded = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(raw));
            String result = decoded.toString();
            if (!java.util.Arrays.equals(result.getBytes(StandardCharsets.UTF_8), raw))
                throw new IllegalArgumentException("Noncanonical UTF-8 field");
            return result;
        } catch (CharacterCodingException invalid) {
            throw new IllegalArgumentException("Invalid UTF-8 field", invalid);
        }
    }

    private static String asciiUuid(byte[] bytes) {
        for (byte value : bytes) {
            if (value < 0x21 || value > 0x7e) {
                throw new IllegalArgumentException("Linux guest UUID is not ASCII");
            }
        }
        String uuid = new String(bytes, StandardCharsets.US_ASCII);
        try {
            if (!UUID.fromString(uuid).toString().equals(uuid)) {
                throw new IllegalArgumentException("Linux guest UUID not canonical");
            }
        } catch (IllegalArgumentException invalid) {
            throw new IllegalArgumentException("Linux guest UUID invalid", invalid);
        }
        return uuid;
    }

    private static byte[] encode(int opcode, String runId, String callId, byte[] body) {
        ByteBuffer bytes = ByteBuffer.allocate(HEADER_BYTES + body.length).order(ByteOrder.BIG_ENDIAN);
        bytes.putInt(MAGIC).put((byte) VERSION).put((byte) opcode).putShort((short) 0);
        bytes.put(runId.getBytes(StandardCharsets.US_ASCII));
        bytes.put(callId.getBytes(StandardCharsets.US_ASCII));
        bytes.putShort((short) body.length).put(body);
        return bytes.array();
    }

}
