package com.minnnng.dsh_android;

import java.io.IOException;
import java.net.InetAddress;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Comparator;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/** Host acceptance for guest HTTPS mediation; no Android network or native guest is started. */
public final class LinuxGuestHttpsDispatchTest {
    private static final String RUN = "01234567-89ab-cdef-0123-456789abcdef";
    private static final String CALL = "11111111-1111-1111-1111-111111111111";
    private static final int GUEST_UID = 50000;
    private static final int APP_UID = 10000;

    private static final class Fixture implements AutoCloseable {
        final Path root;
        final IsolatedExecutionPolicyOwner owner;
        final IsolatedExecutionPolicyOwner.Lease lease;
        final LinuxGuestSandboxPolicy policy;
        final LinuxGuestLaunchSession session;
        final LinuxGuestBrokerWire wire;

        Fixture() throws Exception {
            root = Files.createTempDirectory(Paths.get(System.getProperty("dsh.test.cache",
                    System.getProperty("java.io.tmpdir"))), "guest-https-");
            Path workspace = Files.createDirectory(root.resolve("workspace"));
            owner = new IsolatedExecutionPolicyOwner("owner", RUN,
                    (run, scope) -> { }, (before, after) -> { });
            owner.replace(IsolatedExecutionPolicyOwner.Scope.granted("owner", RUN, 2,
                    root, workspace, Set.of(), Set.of(), Set.of("example.com"), 0, 2, 30_000));
            lease = owner.admit(RUN);
            policy = LinuxGuestSandboxPolicy.fromLease(lease);
            session = new LinuxGuestLaunchSession(policy, LinuxImageLeaseOwner.SHA256,
                    "a".repeat(64), "b".repeat(64), 5_000, System::nanoTime);
            check(session.guestConnected(RUN, GUEST_UID, GUEST_UID, APP_UID,
                    LinuxImageLeaseOwner.SHA256, "a".repeat(64), "b".repeat(64)));
            wire = new LinuxGuestBrokerWire(policy, session);
        }

        IsolatedNetworkJournal journal(IsolatedNetworkJournal.DirectorySync sync) throws Exception {
            return new IsolatedNetworkJournal(root, sync);
        }

        LinuxGuestBrokerWire.Request request(String url) {
            return wire.admitRequest(frame(url), GUEST_UID);
        }

        LinuxGuestHttpsDispatch dispatch(IsolatedNetworkJournal journal,
                                         IsolatedNetworkBroker.PinnedTransport transport) {
            IsolatedNetworkBroker.DeadlineResolver resolver = (host, deadline, cancelled) ->
                    new IsolatedNetworkBroker.Resolution(new InetAddress[] {
                            InetAddress.getByAddress(new byte[] {93, (byte) 184, (byte) 216, 34})
                    }, java.net.Socket::new);
            return new LinuxGuestHttpsDispatch(policy, wire, lease, journal, resolver, transport);
        }

        @Override public void close() throws Exception {
            wire.close();
            session.close();
            owner.close();
            try (var files = Files.walk(root)) {
                for (Path path : files.sorted(Comparator.reverseOrder()).toList())
                    Files.deleteIfExists(path);
            }
        }
    }

    public static void main(String[] args) throws Exception {
        auditedSuccessIncludesBoundedResult();
        redirectOutsideExactHostIsDenied();
        uncertainAuditCancelsWithoutReply();
        cancelledLeaseCannotDispatch();
        revocationDuringTransportSuppressesReply();
        foreignRequestCannotTriggerNetwork();
        malformedUrlIsDeniedAtWireAdmission();
        oversizedReplyNeverEscapes();
        System.out.println("LinuxGuestHttpsDispatchTest passed");
    }

    private static void auditedSuccessIncludesBoundedResult() throws Exception {
        try (Fixture f = new Fixture()) {
            IsolatedNetworkJournal journal = f.journal(directory -> { });
            AtomicInteger fetched = new AtomicInteger();
            try (LinuxGuestHttpsDispatch dispatch = f.dispatch(journal,
                    (uri, ip, route, deadline, cancelled) -> {
                        check(uri.toASCIIString().equals("https://example.com/path?q=1"));
                        fetched.incrementAndGet();
                        return new IsolatedNetworkBroker.Hop(200, null, "text/plain",
                                "hello".getBytes(StandardCharsets.UTF_8));
                    })) {
                byte[] wire = dispatch.dispatch(f.request("https://example.com/path?q=1"));
                check(wire != null && (wire[5] & 0xff) == 0x81 && fetched.get() == 1);
                check(journal.read(CALL).state() == IsolatedNetworkJournal.State.TERMINAL);
                check(journal.read(CALL).status() == IsolatedNetworkBroker.Status.OK);
                ByteBuffer payload = ByteBuffer.wrap(wire, LinuxGuestBrokerWire.HEADER_BYTES,
                        wire.length - LinuxGuestBrokerWire.HEADER_BYTES).order(ByteOrder.BIG_ENDIAN);
                check(payload.getInt() == 0x44534848 && payload.get() == 1);
                check(payload.get() == (byte) IsolatedNetworkBroker.Status.OK.ordinal());
                check(payload.getShort() == 200 && payload.get() == 0);
                int urlSize = Short.toUnsignedInt(payload.getShort());
                int typeSize = Short.toUnsignedInt(payload.getShort());
                int bodySize = Short.toUnsignedInt(payload.getShort());
                byte[] url = new byte[urlSize], type = new byte[typeSize], body = new byte[bodySize];
                payload.get(url).get(type).get(body);
                check(new String(url, StandardCharsets.US_ASCII).equals("https://example.com/path?q=1"));
                check(new String(type, StandardCharsets.UTF_8).equals("text/plain"));
                check(new String(body, StandardCharsets.UTF_8).equals("hello"));
            }
        }
    }

    private static void redirectOutsideExactHostIsDenied() throws Exception {
        try (Fixture f = new Fixture()) {
            IsolatedNetworkJournal journal = f.journal(directory -> { });
            AtomicInteger fetched = new AtomicInteger();
            try (LinuxGuestHttpsDispatch dispatch = f.dispatch(journal,
                    (uri, ip, route, deadline, cancelled) -> {
                        fetched.incrementAndGet();
                        return new IsolatedNetworkBroker.Hop(302,
                                "https://other.example.com/private", "text/plain", new byte[0]);
                    })) {
                byte[] reply = dispatch.dispatch(f.request("https://example.com/start"));
                check(reply != null && (reply[5] & 0xff) == 0x82 && fetched.get() == 1);
                check(journal.read(CALL).status() == IsolatedNetworkBroker.Status.POLICY_DENIED);
            }
        }
    }

    private static void uncertainAuditCancelsWithoutReply() throws Exception {
        try (Fixture f = new Fixture()) {
            AtomicInteger syncs = new AtomicInteger();
            IsolatedNetworkJournal journal = f.journal(directory -> {
                if (syncs.incrementAndGet() == 3) throw new IOException("finish sync uncertain");
            });
            try (LinuxGuestHttpsDispatch dispatch = f.dispatch(journal,
                    (uri, ip, route, deadline, cancelled) ->
                            new IsolatedNetworkBroker.Hop(200, null, "text/plain", new byte[1]))) {
                check(dispatch.dispatch(f.request("https://example.com/")) == null);
                check(f.session.failure() != null);
            }
        }
    }

    private static void cancelledLeaseCannotDispatch() throws Exception {
        try (Fixture f = new Fixture()) {
            IsolatedNetworkJournal journal = f.journal(directory -> { });
            AtomicInteger fetched = new AtomicInteger();
            try (LinuxGuestHttpsDispatch dispatch = f.dispatch(journal,
                    (uri, ip, route, deadline, cancelled) -> {
                        fetched.incrementAndGet();
                        return new IsolatedNetworkBroker.Hop(200, null, "text/plain", new byte[1]);
                    })) {
                LinuxGuestBrokerWire.Request request = f.request("https://example.com/");
                f.owner.revoke(RUN);
                check(dispatch.dispatch(request) == null && fetched.get() == 0);
            }
        }
    }

    private static void oversizedReplyNeverEscapes() throws Exception {
        try (Fixture f = new Fixture()) {
            IsolatedNetworkJournal journal = f.journal(directory -> { });
            try (LinuxGuestHttpsDispatch dispatch = f.dispatch(journal,
                    (uri, ip, route, deadline, cancelled) ->
                            new IsolatedNetworkBroker.Hop(200, null, "text/plain", new byte[1537]))) {
                byte[] reply = dispatch.dispatch(f.request("https://example.com/"));
                check(reply != null && (reply[5] & 0xff) == 0x82);
                check(journal.read(CALL).status() == IsolatedNetworkBroker.Status.RESPONSE_TOO_LARGE);
            }
        }
    }

    private static void foreignRequestCannotTriggerNetwork() throws Exception {
        try (Fixture first = new Fixture(); Fixture second = new Fixture()) {
            IsolatedNetworkJournal journal = first.journal(directory -> { });
            AtomicInteger fetched = new AtomicInteger();
            try (LinuxGuestHttpsDispatch dispatch = first.dispatch(journal,
                    (uri, ip, route, deadline, cancelled) -> {
                        fetched.incrementAndGet();
                        return new IsolatedNetworkBroker.Hop(200, null, "text/plain", new byte[1]);
                    })) {
                check(dispatch.dispatch(second.request("https://example.com/")) == null);
                check(fetched.get() == 0 && first.session.failure() != null);
            }
        }
    }

    private static void malformedUrlIsDeniedAtWireAdmission() throws Exception {
        for (String url : new String[] {"http://example.com/path",
                "https://example.com.evil.org/path", "https://example.com@evil.com/",
                "https://example.com/#fragment"}) {
            try (Fixture f = new Fixture()) {
                check(f.request(url) == null);
                check(f.session.failure() != null);
            }
        }
    }

    private static void revocationDuringTransportSuppressesReply() throws Exception {
        try (Fixture f = new Fixture()) {
            IsolatedNetworkJournal journal = f.journal(directory -> { });
            CountDownLatch entered = new CountDownLatch(1);
            CountDownLatch release = new CountDownLatch(1);
            AtomicReference<byte[]> reply = new AtomicReference<>();
            AtomicReference<Throwable> failure = new AtomicReference<>();
            try (LinuxGuestHttpsDispatch dispatch = f.dispatch(journal,
                    (uri, ip, route, deadline, cancelled) -> {
                        entered.countDown();
                        try {
                            if (!release.await(3, TimeUnit.SECONDS)) throw new IOException("timeout");
                        } catch (InterruptedException interrupted) {
                            Thread.currentThread().interrupt();
                            throw new IOException("interrupted", interrupted);
                        }
                        return new IsolatedNetworkBroker.Hop(200, null, "text/plain", new byte[1]);
                    })) {
                LinuxGuestBrokerWire.Request request = f.request("https://example.com/");
                Thread task = new Thread(() -> {
                    try { reply.set(dispatch.dispatch(request)); }
                    catch (Throwable error) { failure.set(error); }
                }, "guest-https-acceptance");
                task.start();
                check(entered.await(3, TimeUnit.SECONDS));
                f.owner.revoke(RUN);
                release.countDown();
                task.join(3000);
                check(!task.isAlive() && failure.get() == null && reply.get() == null);
                check(f.session.failure() != null);
            } finally { release.countDown(); }
        }
    }

    private static byte[] frame(String url) {
        byte[] target = url.getBytes(StandardCharsets.US_ASCII);
        ByteBuffer bytes = ByteBuffer.allocate(LinuxGuestBrokerWire.HEADER_BYTES + target.length)
                .order(ByteOrder.BIG_ENDIAN);
        bytes.putInt(0x44534842).put((byte) LinuxGuestBrokerWire.VERSION).put((byte) 4)
                .putShort((short) 0).put(RUN.getBytes(StandardCharsets.US_ASCII))
                .put(CALL.getBytes(StandardCharsets.US_ASCII))
                .putShort((short) target.length).put(target);
        return bytes.array();
    }

    private static void check(boolean value) {
        if (!value) throw new AssertionError("Linux guest HTTPS dispatch assertion failed");
    }
}
