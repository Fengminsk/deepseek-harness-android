package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

/** Host-only Binder admission seam tests; Android Message.sendingUid is tested on device later. */
public final class LinuxGuestBinderBridgeTest {
    private static final String RUN = "01234567-89ab-cdef-0123-456789abcdef";
    private static final String CALL = "11111111-1111-1111-1111-111111111111";
    private static final int APP_UID = 10000;
    private static final int GUEST_UID = 50000;
    private static final String IMAGE = LinuxImageLeaseOwner.SHA256;
    private static final String LAUNCHER = "a".repeat(64);
    private static final String LOADER = "b".repeat(64);

    private static final class Fixture implements AutoCloseable {
        final Path root;
        final Path workspace;
        final IsolatedExecutionPolicyOwner owner;
        final LinuxGuestLaunchSession session;
        final LinuxGuestBrokerWire wire;
        final LinuxGuestBinderBridge bridge;
        final AtomicInteger fileCalls = new AtomicInteger();
        final AtomicInteger networkCalls = new AtomicInteger();
        final AtomicInteger closedNetwork = new AtomicInteger();

        Fixture() throws IOException { this(false); }

        Fixture(boolean revokeDuringFile) throws IOException {
            root = Files.createTempDirectory(Paths.get(System.getProperty("dsh.test.cache",
                    System.getProperty("java.io.tmpdir"))), "linux-binder-");
            workspace = Files.createDirectory(root.resolve("workspace"));
            AtomicLong time = new AtomicLong(1_000_000_000L);
            owner = new IsolatedExecutionPolicyOwner("owner", RUN,
                    (run, scope) -> { }, (before, after) -> { }, time::get);
            owner.replace(IsolatedExecutionPolicyOwner.Scope.granted("owner", RUN, 2,
                    root, workspace, Set.of("notes.txt"), Set.of(), Set.of("example.com"),
                    3, 2, 30_000));
            LinuxGuestSandboxPolicy policy = LinuxGuestSandboxPolicy.fromLease(owner.admit(RUN));
            session = new LinuxGuestLaunchSession(policy, IMAGE, LAUNCHER, LOADER, 5_000,
                    time::get);
            wire = new LinuxGuestBrokerWire(policy, session);
            bridge = new LinuxGuestBinderBridge(RUN, session, wire,
                    request -> {
                        fileCalls.incrementAndGet();
                        if (revokeDuringFile) owner.revoke(RUN);
                        return wire.complete(request, true, true,
                                "file".getBytes(StandardCharsets.US_ASCII));
                    },
                    request -> {
                        networkCalls.incrementAndGet();
                        return wire.complete(request, true, true,
                                "network".getBytes(StandardCharsets.US_ASCII));
                    }, closedNetwork::incrementAndGet, IMAGE, LAUNCHER, LOADER);
        }

        @Override public void close() throws IOException {
            bridge.close();
            owner.close();
            Files.delete(workspace);
            Files.delete(root);
        }
    }

    public static void main(String[] args) throws Exception {
        helloThenDispatchesOnlyAdmittedFrames();
        identityAndOrderingFailureRetireChannel();
        malformedFrameAndLeaseRevocationRetireChannel();
        revocationDuringDispatchDropsReply();
        System.out.println("LinuxGuestBinderBridgeTest passed");
    }

    private static void helloThenDispatchesOnlyAdmittedFrames() throws Exception {
        try (Fixture f = new Fixture()) {
            check(f.bridge.hello(RUN, GUEST_UID, GUEST_UID, APP_UID, true));
            byte[] reply = f.bridge.frame(RUN, GUEST_UID,
                    frame(CALL, 1, readPayload("/workspace/notes.txt")));
            check(reply != null && reply[5] == (byte) 0x81 && f.fileCalls.get() == 1);
            check(f.bridge.active());
            byte[] network = f.bridge.frame(RUN, GUEST_UID,
                    frame("22222222-2222-2222-2222-222222222222", 4,
                            "https://example.com/".getBytes(StandardCharsets.US_ASCII)));
            check(network != null && network[5] == (byte) 0x81 && f.networkCalls.get() == 1);
            check(f.bridge.hello(RUN, GUEST_UID, GUEST_UID, APP_UID, true) == false);
            check(!f.bridge.active() && f.closedNetwork.get() == 1);
        }
    }

    private static void identityAndOrderingFailureRetireChannel() throws Exception {
        try (Fixture f = new Fixture()) {
            check(f.bridge.frame(RUN, GUEST_UID,
                    frame(CALL, 1, readPayload("/workspace/notes.txt"))) == null);
            check(!f.bridge.hello(RUN, GUEST_UID, GUEST_UID, APP_UID, true));
        }
        for (int variant = 0; variant < 4; variant++) {
            try (Fixture f = new Fixture()) {
                boolean accepted = switch (variant) {
                    case 0 -> f.bridge.hello(RUN, APP_UID, APP_UID, APP_UID, true);
                    case 1 -> f.bridge.hello(RUN, GUEST_UID, GUEST_UID + 1, APP_UID, true);
                    case 2 -> f.bridge.hello(RUN, GUEST_UID, GUEST_UID, APP_UID, false);
                    default -> f.bridge.hello("abcdefab-cdef-abcd-efab-cdefabcdefab",
                            GUEST_UID, GUEST_UID, APP_UID, true);
                };
                check(!accepted && !f.bridge.active());
            }
        }
        try (Fixture f = new Fixture()) {
            check(f.bridge.hello(RUN, GUEST_UID, GUEST_UID, APP_UID, true));
            check(f.bridge.frame(RUN, GUEST_UID + 1,
                    frame(CALL, 1, readPayload("/workspace/notes.txt"))) == null);
            check(f.fileCalls.get() == 0 && !f.bridge.active());
        }
    }

    private static void malformedFrameAndLeaseRevocationRetireChannel() throws Exception {
        try (Fixture f = new Fixture()) {
            check(f.bridge.hello(RUN, GUEST_UID, GUEST_UID, APP_UID, true));
            check(f.bridge.frame(RUN, GUEST_UID, new byte[LinuxGuestBrokerWire.MAX_REQUEST_BYTES + 1]) == null);
            check(f.fileCalls.get() == 0 && !f.bridge.active());
        }
        try (Fixture f = new Fixture()) {
            check(f.bridge.hello(RUN, GUEST_UID, GUEST_UID, APP_UID, true));
            byte[] malformed = frame(CALL, 1, readPayload("/workspace/notes.txt"));
            malformed[0] = 0;
            check(f.bridge.frame(RUN, GUEST_UID, malformed) == null);
            check(f.fileCalls.get() == 0 && !f.bridge.active());
        }
        try (Fixture f = new Fixture()) {
            check(f.bridge.hello(RUN, GUEST_UID, GUEST_UID, APP_UID, true));
            f.owner.revoke(RUN);
            check(f.bridge.frame(RUN, GUEST_UID,
                    frame(CALL, 1, readPayload("/workspace/notes.txt"))) == null);
            check(f.fileCalls.get() == 0 && !f.bridge.active());
        }
    }

    private static void revocationDuringDispatchDropsReply() throws Exception {
        try (Fixture f = new Fixture(true)) {
            check(f.bridge.hello(RUN, GUEST_UID, GUEST_UID, APP_UID, true));
            check(f.bridge.frame(RUN, GUEST_UID,
                    frame(CALL, 1, readPayload("/workspace/notes.txt"))) == null);
            check(f.fileCalls.get() == 1 && !f.bridge.active());
        }
    }

    private static byte[] readPayload(String path) {
        byte[] name = path.getBytes(StandardCharsets.UTF_8);
        byte[] revision = IsolatedWorkerWriteback.MISSING.getBytes(StandardCharsets.US_ASCII);
        return ByteBuffer.allocate(2 + name.length + 2 + revision.length + 6)
                .order(ByteOrder.BIG_ENDIAN).putShort((short) name.length).put(name)
                .putShort((short) revision.length).put(revision)
                .putInt(0).putShort((short) 128).array();
    }

    private static byte[] frame(String callId, int opcode, byte[] body) {
        return ByteBuffer.allocate(LinuxGuestBrokerWire.HEADER_BYTES + body.length)
                .order(ByteOrder.BIG_ENDIAN).putInt(0x44534842)
                .put((byte) LinuxGuestBrokerWire.VERSION).put((byte) opcode).putShort((short) 0)
                .put(RUN.getBytes(StandardCharsets.US_ASCII))
                .put(callId.getBytes(StandardCharsets.US_ASCII))
                .putShort((short) body.length).put(body).array();
    }

    private static void check(boolean value) { if (!value) throw new AssertionError(); }
}
