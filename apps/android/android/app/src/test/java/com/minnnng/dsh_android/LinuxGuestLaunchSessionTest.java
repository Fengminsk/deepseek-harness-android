package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.atomic.AtomicLong;

/** Host-only lifecycle checks; actual Binder UID and ptrace pipe still need a phone. */
public final class LinuxGuestLaunchSessionTest {
    private static final String ID = "01234567-89ab-cdef-0123-456789abcdef";
    private static final String CALL_A = "11111111-1111-1111-1111-111111111111";
    private static final String CALL_B = "22222222-2222-2222-2222-222222222222";
    private static final String LAUNCHER = "a".repeat(64);
    private static final String LOADER = "b".repeat(64);

    private static final class Fixture implements AutoCloseable {
        final AtomicLong now = new AtomicLong(1_000_000_000L);
        final Path privateRoot;
        final Path workspace;
        final IsolatedExecutionPolicyOwner owner;
        final LinuxGuestSandboxPolicy policy;

        Fixture(boolean withBrokerScope) throws IOException {
            privateRoot = Files.createTempDirectory(Paths.get(System.getProperty(
                "dsh.test.cache", System.getProperty("java.io.tmpdir"))),
                "guest-launch-session-");
            workspace = Files.createDirectory(privateRoot.resolve("workspace"));
            owner = new IsolatedExecutionPolicyOwner("owner", ID,
                (run, scope) -> { }, (before, after) -> { }, now::get);
            if (withBrokerScope) {
                owner.replace(IsolatedExecutionPolicyOwner.Scope.granted("owner", ID, 2,
                    privateRoot, workspace, names("notes.txt"), names("notes.txt"),
                    names("example.com"), 3, 3, 30_000));
            }
            policy = LinuxGuestSandboxPolicy.fromLease(owner.admit(ID));
        }

        LinuxGuestLaunchSession session() {
            return new LinuxGuestLaunchSession(policy, LinuxImageLeaseOwner.SHA256,
                LAUNCHER, LOADER, 5_000, now::get);
        }

        @Override public void close() throws IOException {
            owner.close();
            Files.delete(workspace);
            Files.delete(privateRoot);
        }
    }

    public static void main(String[] args) throws Exception {
        completeRunNeedsDurability();
        identityAndMetadataAreOneShot();
        brokerCallsMustBeAuthorizedAndSettled();
        brokerCallsStayWithinApprovedCounts();
        outputAndTraceAreBounded();
        revocationCancellationAndDeadlineDenySuccess();
        System.out.println("LinuxGuestLaunchSessionTest passed");
    }

    private static void completeRunNeedsDurability() throws Exception {
        try (Fixture fixture = new Fixture(true);
             LinuxGuestLaunchSession session = fixture.session()) {
            require(connect(session));
            require(session.beginFileCall(CALL_A, "/workspace/notes.txt",
                IsolatedCapabilityBroker.Action.READ));
            require(session.beginHttpsCall(CALL_B, "example.com"));
            require(session.accountOutput(12));
            feed(session, trace());
            require(session.traceEnded(true, true, 0));
            require(!session.readyToPersistSuccess());
            require(session.settleBrokerCall(CALL_A, true));
            require(session.settleBrokerCall(CALL_B, true));
            require(session.readyToPersistSuccess());
            require(!session.mayPublishSuccess());
            require(session.markDurableSuccess());
            require(!session.mayPublishSuccess());
            require(session.markPublicationCommitted());
            require(session.mayPublishSuccess());
            require(session.outputBytes() == 12);
        }
    }

    private static void identityAndMetadataAreOneShot() throws Exception {
        try (Fixture fixture = new Fixture(false)) {
            try (LinuxGuestLaunchSession session = fixture.session()) {
                require(!session.guestConnected(ID, 50000, 50001, 10000,
                    LinuxImageLeaseOwner.SHA256, LAUNCHER, LOADER));
                require(!connect(session));
                require(!session.mayPublishSuccess());
            }
            try (LinuxGuestLaunchSession session = fixture.session()) {
                require(!session.guestConnected(ID, 10000, 10000, 10000,
                    LinuxImageLeaseOwner.SHA256, LAUNCHER, LOADER));
                require(!session.mayPublishSuccess());
            }
            try (LinuxGuestLaunchSession session = fixture.session()) {
                require(!session.guestConnected(ID, 50000, 50000, 10000,
                    LinuxImageLeaseOwner.SHA256, LOADER, LAUNCHER));
                require(!session.mayPublishSuccess());
            }
            try (LinuxGuestLaunchSession session = fixture.session()) {
                require(connect(session));
                require(!connect(session));
                require(!session.mayPublishSuccess());
            }
            try {
                new LinuxGuestLaunchSession(fixture.policy, "c".repeat(64),
                    LAUNCHER, LOADER, 5_000, fixture.now::get);
                throw new AssertionError("Unpinned rootfs was admitted");
            } catch (IllegalArgumentException expected) { /* expected */ }
            try {
                LinuxGuestLaunchSession.admitInstalled(fixture.policy,
                    LinuxImageLeaseOwner.SHA256, fixture.privateRoot, 5_000);
                throw new AssertionError("Missing package-installed ELF files admitted a guest run");
            } catch (IOException expected) { /* absent executable candidates fail closed */ }
        }
    }

    private static void brokerCallsMustBeAuthorizedAndSettled() throws Exception {
        try (Fixture fixture = new Fixture(true)) {
            try (LinuxGuestLaunchSession session = fixture.session()) {
                require(connect(session));
                require(!session.beginFileCall(CALL_A, "/workspace/../secret",
                    IsolatedCapabilityBroker.Action.READ));
                require(!session.mayPublishSuccess());
            }
            try (LinuxGuestLaunchSession session = fixture.session()) {
                require(connect(session));
                require(!session.beginHttpsCall(CALL_A, "other.example.com"));
                require(!session.mayPublishSuccess());
            }
            try (LinuxGuestLaunchSession session = fixture.session()) {
                require(connect(session));
                require(session.beginFileCall(CALL_A, "/workspace/notes.txt",
                    IsolatedCapabilityBroker.Action.EDIT));
                require(!session.settleBrokerCall(CALL_B, true));
                require(!session.mayPublishSuccess());
            }
            try (LinuxGuestLaunchSession session = fixture.session()) {
                require(connect(session));
                require(session.beginFileCall(CALL_A, "/workspace/notes.txt",
                    IsolatedCapabilityBroker.Action.READ));
                require(!session.settleBrokerCall(CALL_A, false));
                require(!session.mayPublishSuccess());
            }
        }
        try (Fixture fixture = new Fixture(false);
             LinuxGuestLaunchSession session = fixture.session()) {
            require(connect(session));
            require(!session.beginFileCall(CALL_A, "/workspace/notes.txt",
                IsolatedCapabilityBroker.Action.READ));
        }
    }

    private static void brokerCallsStayWithinApprovedCounts() throws Exception {
        try (Fixture fixture = new Fixture(true)) {
            try (LinuxGuestLaunchSession session = fixture.session()) {
                require(connect(session));
                for (int index = 1; index <= 3; index++) {
                    String call = callId(index);
                    require(session.beginFileCall(call, "/workspace/notes.txt",
                        IsolatedCapabilityBroker.Action.READ));
                    require(session.settleBrokerCall(call, true));
                }
                require(!session.beginFileCall(callId(4), "/workspace/notes.txt",
                    IsolatedCapabilityBroker.Action.READ));
                require(!session.mayPublishSuccess());
            }
            try (LinuxGuestLaunchSession session = fixture.session()) {
                require(connect(session));
                for (int index = 1; index <= 3; index++) {
                    String call = callId(index);
                    require(session.beginHttpsCall(call, "example.com"));
                    require(session.settleBrokerCall(call, true));
                }
                require(!session.beginHttpsCall(callId(4), "example.com"));
                require(!session.mayPublishSuccess());
            }
        }
    }

    private static void outputAndTraceAreBounded() throws Exception {
        try (Fixture fixture = new Fixture(false)) {
            try (LinuxGuestLaunchSession session = fixture.session()) {
                require(connect(session));
                require(session.accountOutput(LinuxGuestLaunchSession.MAX_OUTPUT_BYTES));
                require(!session.accountOutput(1));
                require(!session.mayPublishSuccess());
            }
            try (LinuxGuestLaunchSession session = fixture.session()) {
                require(connect(session));
                byte[] malformed = trace().replace("\t4\tDRAIN", "\t5\tDRAIN")
                    .getBytes(StandardCharsets.US_ASCII);
                require(!session.acceptTrace(malformed, 0, malformed.length));
                require(!session.readyToPersistSuccess());
            }
            try (LinuxGuestLaunchSession session = fixture.session()) {
                require(connect(session));
                feed(session, trace());
                require(!session.traceEnded(false, true, 0));
                require(!session.readyToPersistSuccess());
            }
            try (LinuxGuestLaunchSession session = fixture.session()) {
                require(connect(session));
                feed(session, trace());
                require(!session.traceEnded(true, true, 1));
                require(!session.mayPublishSuccess());
            }
        }
    }

    private static void revocationCancellationAndDeadlineDenySuccess() throws Exception {
        try (Fixture fixture = new Fixture(false)) {
            try (LinuxGuestLaunchSession session = fixture.session()) {
                require(connect(session));
                session.cancel();
                require(!session.readyToPersistSuccess());
                require(session.failure().contains("cancelled"));
            }
            try (LinuxGuestLaunchSession session = fixture.session()) {
                require(connect(session));
                fixture.now.addAndGet(5_000_000_000L);
                require(!session.accountOutput(1));
                require(!session.mayPublishSuccess());
                require(session.failure() != null);
            }
        }
        try (Fixture fixture = new Fixture(false);
             LinuxGuestLaunchSession session = fixture.session()) {
            require(connect(session));
            fixture.owner.revoke(ID);
            require(!session.readyToPersistSuccess());
            require(!session.mayPublishSuccess());
            require(session.failure() != null);
        }
    }

    private static boolean connect(LinuxGuestLaunchSession session) {
        return session.guestConnected(ID, 50000, 50000, 10000,
            LinuxImageLeaseOwner.SHA256, LAUNCHER, LOADER);
    }

    private static String trace() {
        return frame(1, "ROOT", 100, 0) +
            frame(2, "ARM", 100, LinuxTraceeRetirementLedger.REQUIRED_OPTIONS) +
            frame(3, "REAP", 100, 0) + frame(4, "DRAIN", 0, 0);
    }

    private static String frame(int sequence, String event, int first, int second) {
        return "DSH_TRACE_V1\t" + ID + "\t" + sequence + "\t" + event
            + "\t" + first + "\t" + second + "\n";
    }

    private static void feed(LinuxGuestLaunchSession session, String text) {
        byte[] bytes = text.getBytes(StandardCharsets.US_ASCII);
        require(session.acceptTrace(bytes, 0, bytes.length));
    }

    private static Set<String> names(String... values) {
        return new HashSet<>(Arrays.asList(values));
    }

    private static String callId(int number) {
        return String.format("00000000-0000-0000-0000-%012d", number);
    }

    private static void require(boolean value) {
        if (!value) throw new AssertionError("Linux guest launch lifecycle accepted invalid evidence");
    }
}
