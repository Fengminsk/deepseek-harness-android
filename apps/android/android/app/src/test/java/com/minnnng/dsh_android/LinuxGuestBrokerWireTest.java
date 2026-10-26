package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Arrays;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.BooleanSupplier;

/** Host-only protocol checks. No native launcher or Android Binder is involved. */
public final class LinuxGuestBrokerWireTest {
    private static final String RUN = "01234567-89ab-cdef-0123-456789abcdef";
    private static final String OTHER_RUN = "abcdefab-cdef-abcd-efab-cdefabcdefab";
    private static final String CALL_A = "11111111-1111-1111-1111-111111111111";
    private static final String CALL_B = "22222222-2222-2222-2222-222222222222";
    private static final int GUEST_UID = 50000;
    private static final int APP_UID = 10000;

    private static final class Fixture implements AutoCloseable {
        final AtomicLong now = new AtomicLong(1_000_000_000L);
        final Path privateRoot;
        final Path workspace;
        final IsolatedExecutionPolicyOwner owner;
        final LinuxGuestSandboxPolicy policy;
        final LinuxGuestLaunchSession session;
        final LinuxGuestBrokerWire wire;

        Fixture() throws IOException {
            privateRoot = Files.createTempDirectory(Paths.get(System.getProperty(
                "dsh.test.cache", System.getProperty("java.io.tmpdir"))), "guest-wire-");
            workspace = Files.createDirectory(privateRoot.resolve("workspace"));
            owner = new IsolatedExecutionPolicyOwner("owner", RUN,
                (run, scope) -> { }, (before, after) -> { }, now::get);
            owner.replace(IsolatedExecutionPolicyOwner.Scope.granted("owner", RUN, 2,
                privateRoot, workspace, names("notes.txt"), names("notes.txt"),
                names("example.com"), 3, 2, 30_000));
            policy = LinuxGuestSandboxPolicy.fromLease(owner.admit(RUN));
            session = new LinuxGuestLaunchSession(policy, LinuxImageLeaseOwner.SHA256,
                "a".repeat(64), "b".repeat(64), 5_000, now::get);
            require(session.guestConnected(RUN, GUEST_UID, GUEST_UID, APP_UID,
                LinuxImageLeaseOwner.SHA256, "a".repeat(64), "b".repeat(64)));
            wire = new LinuxGuestBrokerWire(policy, session);
        }

        @Override public void close() throws IOException {
            wire.close();
            session.close();
            owner.close();
            Files.delete(workspace);
            Files.delete(privateRoot);
        }
    }

    public static void main(String[] args) throws Exception {
        authorizedRequestAndAuditedReply();
        malformedFramesFailClosed();
        wrongIdentityAndScopeFailClosed();
        repliesNeedPendingAuditedCall();
        budgetsAndLateFramesFailClosed();
        fileDispatchUsesAuditedExactGrants();
        fileDispatchRejectsUncertainAuditAndChangedPages();
        System.out.println("LinuxGuestBrokerWireTest passed");
    }

    private static void authorizedRequestAndAuditedReply() throws Exception {
        try (Fixture fixture = new Fixture()) {
            LinuxGuestBrokerWire.Request request = fixture.wire.admitRequest(
                frame(RUN, CALL_A, 1, text("/workspace/notes.txt")), GUEST_UID);
            require(request != null && request.operation() == LinuxGuestBrokerWire.Operation.FILE_READ);
            require(request.callId().equals(CALL_A));
            require(request.target().equals("/workspace/notes.txt"));
            require(fixture.wire.pendingCount() == 1);
            require(fixture.wire.ownsPending(request));
            byte[] reply = fixture.wire.complete(request, true, true, text("ok"));
            require(reply != null && reply.length == LinuxGuestBrokerWire.HEADER_BYTES + 2);
            require(!fixture.wire.ownsPending(request));
            require((reply[5] & 0xff) == 0x81 && fixture.wire.pendingCount() == 0);
            require(new String(Arrays.copyOfRange(reply, reply.length - 2, reply.length),
                StandardCharsets.US_ASCII).equals("ok"));

            request = fixture.wire.admitRequest(frame(RUN, CALL_B, 4, text("https://example.com/")), GUEST_UID);
            require(request != null && request.operation() == LinuxGuestBrokerWire.Operation.HTTPS_HOST);
            reply = fixture.wire.complete(request, true, false, text("denied"));
            require(reply != null && (reply[5] & 0xff) == 0x82);
            require(fixture.session.failure() == null);
            byte[] trace = (traceFrame(1, "ROOT", 100, 0)
                + traceFrame(2, "ARM", 100, LinuxTraceeRetirementLedger.REQUIRED_OPTIONS)
                + traceFrame(3, "REAP", 100, 0)
                + traceFrame(4, "DRAIN", 0, 0)).getBytes(StandardCharsets.US_ASCII);
            require(fixture.session.acceptTrace(trace, 0, trace.length));
            require(fixture.session.traceEnded(true, true, 0));
            require(fixture.session.markDurableSuccess());
            require(fixture.session.markPublicationCommitted());
            require(fixture.wire.admitRequest(frame(RUN, callId(3), 1,
                text("/workspace/notes.txt")), GUEST_UID) == null);
            require(fixture.session.mayPublishSuccess());
        }
    }

    private static void malformedFramesFailClosed() throws Exception {
        byte[] good = frame(RUN, CALL_A, 1, text("/workspace/notes.txt"));
        byte[][] cases = {
            new byte[0], flip(good, 0, (byte) 'X'), flip(good, 4, (byte) 1),
            flip(good, 5, (byte) 127), flip(good, 6, (byte) 1),
            Arrays.copyOf(good, good.length - 1), append(good, (byte) 0),
            flip(good, good.length - 1, (byte) 0),
            flip(good, good.length - 3, (byte) 1),
            frame(RUN, CALL_A, 1, new byte[] {(byte) 0xc3, (byte) 0x28}),
            frame(RUN.toUpperCase(), CALL_A, 1, text("/workspace/notes.txt")),
            frame(RUN, "abcdefab-cdef-abcd-efab-cdefabcdefab".toUpperCase(),
                1, text("/workspace/notes.txt")),
            frame(RUN, CALL_A, 1, new byte[0]),
            frame(RUN, CALL_A, 1, new byte[LinuxGuestBrokerWire.MAX_TARGET_BYTES + 1]),
        };
        for (byte[] input : cases) {
            try (Fixture fixture = new Fixture()) {
                require(fixture.wire.admitRequest(input, GUEST_UID) == null);
                require(fixture.session.failure() != null);
                require(fixture.wire.admitRequest(good, GUEST_UID) == null);
            }
        }
    }

    private static void wrongIdentityAndScopeFailClosed() throws Exception {
        try (Fixture fixture = new Fixture()) {
            require(fixture.wire.admitRequest(frame(RUN, CALL_A, 1,
                text("/workspace/notes.txt")), GUEST_UID + 1) == null);
            require(fixture.session.failure() != null);
        }
        byte[][] cases = {
            frame(OTHER_RUN, CALL_A, 1, text("/workspace/notes.txt")),
            frame(RUN, CALL_A, 1, text("/workspace/../secrets")),
            frame(RUN, CALL_A, 3, text("/workspace/.git/config")),
            frame(RUN, CALL_A, 4, text("https://other.example.com/")),
            frame(RUN, CALL_A, 4, text("example.com")),
            frame(RUN, CALL_A, 4, text("https://example.com/#fragment")),
            frame(RUN, CALL_A, 4, text("https://example.com/你好")),
        };
        for (byte[] input : cases) {
            try (Fixture fixture = new Fixture()) {
                require(fixture.wire.admitRequest(input, GUEST_UID) == null);
                require(fixture.session.failure() != null);
            }
        }
        try (Fixture fixture = new Fixture()) {
            fixture.owner.revoke(RUN);
            require(fixture.wire.admitRequest(frame(RUN, CALL_A, 1,
                text("/workspace/notes.txt")), GUEST_UID) == null);
            require(fixture.session.failure() != null);
        }
    }

    private static void repliesNeedPendingAuditedCall() throws Exception {
        try (Fixture fixture = new Fixture()) {
            LinuxGuestBrokerWire.Request request = fixture.wire.admitRequest(frame(RUN,
                CALL_A, 2, text("/workspace/notes.txt")), GUEST_UID);
            require(request != null);
            require(fixture.wire.complete(request, false, true, text("x")) == null);
            require(fixture.session.failure() != null);
        }
        try (Fixture fixture = new Fixture()) {
            LinuxGuestBrokerWire.Request request = fixture.wire.admitRequest(frame(RUN,
                CALL_A, 3, text("/workspace/notes.txt")), GUEST_UID);
            require(request != null);
            require(fixture.wire.complete(request, true, true,
                new byte[LinuxGuestBrokerWire.MAX_REPLY_BYTES + 1]) == null);
            require(fixture.session.failure() != null);
        }
        try (Fixture fixture = new Fixture()) {
            LinuxGuestBrokerWire.Request request = fixture.wire.admitRequest(frame(RUN,
                CALL_A, 1, text("/workspace/notes.txt")), GUEST_UID);
            require(fixture.wire.complete(request, true, true, text("ok")) != null);
            require(fixture.wire.complete(request, true, true, text("ok")) == null);
            require(fixture.session.failure() != null);
        }
        try (Fixture fixture = new Fixture()) {
            require(fixture.wire.admitRequest(frame(RUN, CALL_A, 1,
                text("/workspace/notes.txt")), GUEST_UID) != null);
            require(fixture.wire.admitRequest(frame(RUN, CALL_A, 1,
                text("/workspace/notes.txt")), GUEST_UID) == null);
            require(fixture.session.failure() != null);
        }
    }

    private static void budgetsAndLateFramesFailClosed() throws Exception {
        try (Fixture fixture = new Fixture()) {
            for (int count = 1; count <= 3; count++) {
                String call = callId(count);
                LinuxGuestBrokerWire.Request request = fixture.wire.admitRequest(
                    frame(RUN, call, 1, text("/workspace/notes.txt")), GUEST_UID);
                require(request != null);
                require(fixture.wire.complete(request, true, true, text("ok")) != null);
            }
            require(fixture.wire.admitRequest(frame(RUN, callId(4), 1,
                text("/workspace/notes.txt")), GUEST_UID) == null);
            require(fixture.session.failure() != null);
        }
        try (Fixture fixture = new Fixture()) {
            fixture.now.addAndGet(5_000_000_000L);
            require(fixture.wire.admitRequest(frame(RUN, CALL_A, 1,
                text("/workspace/notes.txt")), GUEST_UID) == null);
            require(fixture.session.failure() != null);
        }
        try (Fixture fixture = new Fixture()) {
            fixture.session.cancel();
            require(fixture.wire.admitRequest(frame(RUN, CALL_A, 1,
                text("/workspace/notes.txt")), GUEST_UID) == null);
        }
    }

    private static final class Workspace implements IsolatedCapabilityBroker.WorkspaceOps {
        String revision = "a".repeat(64);
        String text = "hello world";
        int reads;
        int searches;
        int edits;
        boolean uncertainEdit;

        @Override public IsolatedCapabilityBroker.ReadData read(String filename,
                BooleanSupplier cancelled) {
            require(filename.equals("notes.txt") && !cancelled.getAsBoolean());
            reads++;
            return new IsolatedCapabilityBroker.ReadData(revision, text);
        }
        @Override public IsolatedCapabilityBroker.SearchData search(String filename,
                String query, int maxMatches, BooleanSupplier cancelled) {
            require(filename.equals("notes.txt") && query.equals("x") && maxMatches == 2
                && !cancelled.getAsBoolean());
            searches++;
            return new IsolatedCapabilityBroker.SearchData(revision,
                List.of(new IsolatedCapabilityBroker.Hit(1, 1, "hello")), false);
        }
        @Override public IsolatedCapabilityBroker.EditData edit(String filename,
                String expectedRevision, String needle, String replacement,
                int maxReplacements, BooleanSupplier cancelled) throws IOException {
            require(filename.equals("notes.txt") && expectedRevision.equals("missing")
                && needle.equals("x") && replacement.equals("y")
                && maxReplacements == 1 && !cancelled.getAsBoolean());
            edits++;
            if (uncertainEdit)
                throw new IsolatedCapabilityBroker.CommitOutcomeUnknown(new IOException("lost receipt"));
            return new IsolatedCapabilityBroker.EditData("missing", revision, 11);
        }
    }

    private static void fileDispatchUsesAuditedExactGrants() throws Exception {
        try (Fixture fixture = new Fixture()) {
            Workspace workspace = new Workspace();
            List<IsolatedCapabilityBroker.Event> audit = new ArrayList<>();
            LinuxGuestFileBrokerDispatch dispatch = new LinuxGuestFileBrokerDispatch(
                fixture.policy, fixture.wire, workspace, audit::add);
            LinuxGuestBrokerWire.Request read = fixture.wire.admitRequest(
                frame(RUN, CALL_A, 1, text("/workspace/notes.txt")), GUEST_UID);
            require(read != null && read.offset() == 0 && read.maxBytes() == 100);
            byte[] readReply = dispatch.dispatch(read);
            require(readReply != null && (readReply[5] & 0xff) == 0x81 && workspace.reads == 1);
            ByteBuffer body = ByteBuffer.wrap(readReply, LinuxGuestBrokerWire.HEADER_BYTES,
                readReply.length - LinuxGuestBrokerWire.HEADER_BYTES).order(ByteOrder.BIG_ENDIAN);
            int revLen = Byte.toUnsignedInt(body.get());
            body.position(body.position() + revLen);
            require(body.getInt() == 11 && body.getInt() == 0 && body.getShort() == 11);
            byte[] chunk = new byte[11];
            body.get(chunk);
            require(new String(chunk, StandardCharsets.UTF_8).equals("hello world"));
            require(dispatch.dispatch(read) == null && workspace.reads == 1);

            LinuxGuestBrokerWire.Request search = fixture.wire.admitRequest(
                frame(RUN, CALL_B, 2, text("/workspace/notes.txt")), GUEST_UID);
            require(search != null && search.query().equals("x"));
            require(dispatch.dispatch(search) != null && workspace.searches == 1);
            LinuxGuestBrokerWire.Request edit = fixture.wire.admitRequest(
                frame(RUN, callId(3), 3, text("/workspace/notes.txt")), GUEST_UID);
            require(edit != null && edit.expectedRevision().equals("missing"));
            require(dispatch.dispatch(edit) != null && workspace.edits == 1);
            require(audit.stream().filter(e -> e.phase() ==
                IsolatedCapabilityBroker.Phase.CALL_SETTLED).count() == 3);
            require(audit.stream().filter(e -> e.phase() ==
                IsolatedCapabilityBroker.Phase.RUN_FINISHED).count() == 3);
            require(audit.stream().noneMatch(e -> e.target() != null
                && e.target().startsWith("/workspace/")));
        }
    }

    private static void fileDispatchRejectsUncertainAuditAndChangedPages() throws Exception {
        try (Fixture fixture = new Fixture()) {
            Workspace workspace = new Workspace();
            LinuxGuestFileBrokerDispatch dispatch = new LinuxGuestFileBrokerDispatch(
                fixture.policy, fixture.wire, workspace, event -> {
                    if (event.phase() == IsolatedCapabilityBroker.Phase.CALL_SETTLED)
                        throw new IOException("journal unavailable");
                });
            LinuxGuestBrokerWire.Request request = fixture.wire.admitRequest(
                frame(RUN, CALL_A, 1, text("/workspace/notes.txt")), GUEST_UID);
            require(dispatch.dispatch(request) == null && workspace.reads == 1);
            require(fixture.session.failure() != null);
        }
        try (Fixture fixture = new Fixture()) {
            Workspace workspace = new Workspace();
            LinuxGuestFileBrokerDispatch dispatch = new LinuxGuestFileBrokerDispatch(
                fixture.policy, fixture.wire, workspace, event -> { });
            LinuxGuestBrokerWire.Request request = fixture.wire.admitRequest(
                readFrame(CALL_A, "b".repeat(64), 3, 3), GUEST_UID);
            byte[] result = dispatch.dispatch(request);
            require(result != null && (result[5] & 0xff) == 0x82
                && new String(Arrays.copyOfRange(result,
                    LinuxGuestBrokerWire.HEADER_BYTES, result.length), StandardCharsets.US_ASCII)
                    .equals("STALE"));
        }
        try (Fixture fixture = new Fixture()) {
            Workspace workspace = new Workspace();
            workspace.uncertainEdit = true;
            List<IsolatedCapabilityBroker.Event> audit = new ArrayList<>();
            LinuxGuestFileBrokerDispatch dispatch = new LinuxGuestFileBrokerDispatch(
                fixture.policy, fixture.wire, workspace, audit::add);
            LinuxGuestBrokerWire.Request request = fixture.wire.admitRequest(
                frame(RUN, CALL_A, 3, text("/workspace/notes.txt")), GUEST_UID);
            require(dispatch.dispatch(request) == null && workspace.edits == 1);
            require(fixture.session.failure() != null);
            require(audit.stream().anyMatch(e -> e.phase() ==
                IsolatedCapabilityBroker.Phase.CALL_SETTLED
                && e.status() == IsolatedCapabilityBroker.Status.COMMIT_UNCERTAIN));
        }
    }

    private static byte[] readFrame(String callId, String revision, int offset, int length) {
        byte[] path = text("/workspace/notes.txt");
        byte[] rev = text(revision);
        byte[] body = ByteBuffer.allocate(2 + path.length + 2 + rev.length + 6)
            .order(ByteOrder.BIG_ENDIAN).putShort((short) path.length).put(path)
            .putShort((short) rev.length).put(rev).putInt(offset).putShort((short) length).array();
        ByteBuffer frame = ByteBuffer.allocate(LinuxGuestBrokerWire.HEADER_BYTES + body.length)
            .order(ByteOrder.BIG_ENDIAN).putInt(0x44534842)
            .put((byte) LinuxGuestBrokerWire.VERSION).put((byte) 1).putShort((short) 0)
            .put(text(RUN)).put(text(callId)).putShort((short) body.length).put(body);
        return frame.array();
    }

    private static byte[] frame(String runId, String callId, int opcode, byte[] target) {
        byte[] body = target;
        if (opcode >= 1 && opcode <= 3) {
            byte[] extra = opcode == 1
                ? ByteBuffer.allocate(2 + 7 + 4 + 2).order(ByteOrder.BIG_ENDIAN)
                    .putShort((short) 7).put(text("missing")).putInt(0).putShort((short) 100).array()
                : opcode == 2
                    ? ByteBuffer.allocate(2 + 1 + 2).order(ByteOrder.BIG_ENDIAN)
                        .putShort((short) 1).put((byte) 'x').putShort((short) 2).array()
                    : ByteBuffer.allocate(2 + 7 + 2 + 1 + 2 + 1 + 2)
                        .order(ByteOrder.BIG_ENDIAN).putShort((short) 7).put(text("missing"))
                        .putShort((short) 1).put((byte) 'x')
                        .putShort((short) 1).put((byte) 'y').putShort((short) 1).array();
            body = ByteBuffer.allocate(2 + target.length + extra.length)
                .order(ByteOrder.BIG_ENDIAN).putShort((short) target.length)
                .put(target).put(extra).array();
        }
        ByteBuffer bytes = ByteBuffer.allocate(LinuxGuestBrokerWire.HEADER_BYTES + body.length)
            .order(ByteOrder.BIG_ENDIAN);
        bytes.putInt(0x44534842).put((byte) LinuxGuestBrokerWire.VERSION)
            .put((byte) opcode).putShort((short) 0);
        bytes.put(runId.getBytes(StandardCharsets.US_ASCII));
        bytes.put(callId.getBytes(StandardCharsets.US_ASCII));
        bytes.putShort((short) body.length).put(body);
        return bytes.array();
    }

    private static byte[] flip(byte[] source, int index, byte value) {
        byte[] copy = source.clone();
        copy[index] = value;
        return copy;
    }

    private static byte[] append(byte[] source, byte value) {
        byte[] copy = Arrays.copyOf(source, source.length + 1);
        copy[copy.length - 1] = value;
        return copy;
    }

    private static byte[] text(String value) { return value.getBytes(StandardCharsets.UTF_8); }
    private static String traceFrame(int sequence, String event, int first, int second) {
        return "DSH_TRACE_V1\t" + RUN + "\t" + sequence + "\t" + event
            + "\t" + first + "\t" + second + "\n";
    }
    private static Set<String> names(String value) { return new HashSet<>(Arrays.asList(value)); }
    private static String callId(int number) {
        return String.format("%08d-1111-1111-1111-111111111111", number);
    }
    private static void require(boolean condition) {
        if (!condition) throw new AssertionError("Linux guest broker wire expectation failed");
    }

    private LinuxGuestBrokerWireTest() { }
}
