package com.minnnng.dsh_android;

import java.io.IOException;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

/** Deterministic loopback TCP and real journal tests; no public Internet is required. */
public final class LinuxVmNetworkHostTest {
    private static final Inet4Address PUBLIC;
    static {
        try { PUBLIC = (Inet4Address) InetAddress.getByAddress(new byte[] {93, (byte)184, (byte)216, 34}); }
        catch (IOException error) { throw new ExceptionInInitializerError(error); }
    }
    private static int tests;
    private static void check(boolean condition) { if (!condition) throw new AssertionError(); }

    private static final class Proxy implements AutoCloseable {
        final ServerSocket listener = new ServerSocket(0, 1, InetAddress.getLoopbackAddress());
        final CountDownLatch requestRead = new CountDownLatch(1);
        final CountDownLatch release = new CountDownLatch(1);
        volatile String request;
        volatile Throwable failure;
        final Thread worker;
        Proxy(String response) throws IOException {
            worker = new Thread(() -> {
                try (Socket client = listener.accept()) {
                    client.setSoTimeout(3000);
                    var bytes = new java.io.ByteArrayOutputStream();
                    while (!bytes.toString(StandardCharsets.US_ASCII).endsWith("\r\n\r\n")) {
                        int next = client.getInputStream().read();
                        if (next < 0 || bytes.size() > 2048) throw new IOException("Bad test CONNECT");
                        bytes.write(next);
                    }
                    request = bytes.toString(StandardCharsets.US_ASCII); requestRead.countDown();
                    if (response != null) client.getOutputStream().write(response.getBytes(StandardCharsets.US_ASCII));
                    release.await(3, TimeUnit.SECONDS);
                } catch (Throwable error) { failure = error; requestRead.countDown(); }
            }, "test-loopback-proxy");
            worker.setDaemon(true); worker.start();
        }
        int port() { return listener.getLocalPort(); }
        public void close() throws Exception {
            release.countDown(); listener.close(); worker.join(3500);
            if (worker.isAlive()) throw new AssertionError("Proxy worker leaked");
            if (failure != null) throw new AssertionError(failure);
        }
    }

    private static void tunnel() throws Exception {
        try (Proxy proxy = new Proxy("HTTP/1.1 200 Connection established\r\n\r\n"); Socket socket = new Socket()) {
            LocalHttpConnectTunnel.open(socket, proxy.port(), PUBLIC, System.nanoTime() + 2_000_000_000L,
                    new AtomicBoolean());
            check(proxy.request.equals("CONNECT 93.184.216.34:443 HTTP/1.1\r\nHost: 93.184.216.34:443\r\n\r\n"));
        }
        tests++;
    }

    private static void rejectedProxyReplies() throws Exception {
        for (String reply : new String[] {"HTTP/1.1 407 Proxy authentication required\r\n\r\n",
                "HTTP/1.1 200 OK\n\n", "HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n",
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
                "HTTP/1.1 200 OK\r\nX: " + "x".repeat(8200) + "\r\n\r\n",
                "HTTP/1.1 200 OK\r\n\r\nnot TLS"}) {
            try (Proxy proxy = new Proxy(reply)) {
                AtomicInteger direct = new AtomicInteger();
                try {
                    IsolatedNetworkBroker.PinnedTlsTransport.throughLocalHttpProxy(4096, proxy.port())
                            .fetch(URI.create("https://example.com/"), PUBLIC,
                                    () -> { direct.incrementAndGet(); return new Socket(); },
                                    System.nanoTime() + 1_000_000_000L, new AtomicBoolean());
                    throw new AssertionError("Invalid proxy or TLS accepted");
                } catch (IOException expected) { check(direct.get() == 0); }
            }
            tests++;
        }
    }

    private static void proxyDeadlineAndRevoke() throws Exception {
        for (boolean revoke : new boolean[] {false, true}) {
            Path root = Files.createTempDirectory(Path.of(System.getProperty("dsh.test.cache")), "tcp-");
            try (Proxy proxy = new Proxy(null)) {
                var journal = new IsolatedNetworkJournal(root, directory -> { });
                var broker = new IsolatedNetworkBroker(new IsolatedNetworkBroker.Policy(Set.of("example.com")),
                        (host, deadline, cancelled) -> new IsolatedNetworkBroker.Resolution(new InetAddress[] {PUBLIC},
                                () -> { throw new AssertionError("Proxy failure fell back to direct route"); }),
                        IsolatedNetworkBroker.PinnedTlsTransport.throughLocalHttpProxy(4096, proxy.port()),
                        journal, revoke ? 3000 : 200);
                var outcome = new java.util.concurrent.atomic.AtomicReference<IsolatedNetworkBroker.Result>();
                Thread request = new Thread(() -> outcome.set(broker.get(UUID.randomUUID().toString(), "https://example.com/")));
                request.start();
                check(proxy.requestRead.await(2, TimeUnit.SECONDS));
                if (revoke) broker.revoke();
                request.join(1500);
                check(!request.isAlive());
                check(outcome.get().status() == (revoke ? IsolatedNetworkBroker.Status.CANCELLED
                        : IsolatedNetworkBroker.Status.DEADLINE_EXCEEDED));
            }
            tests++;
        }
    }

    private static final class Fixture implements AutoCloseable {
        final String run = UUID.randomUUID().toString();
        final Path root = Files.createTempDirectory(Path.of(System.getProperty("dsh.test.cache")), "mailbox-");
        final ByteBuffer disk = ByteBuffer.allocateDirect(LinuxVmHttpsMailbox.DISK_BYTES);
        final IsolatedExecutionPolicyOwner owner;
        final IsolatedNetworkJournal journal;
        final AtomicBoolean cancelled = new AtomicBoolean();
        final AtomicInteger fetched = new AtomicInteger();
        final LinuxVmHttpsMailbox mailbox;
        final LinuxVmHttpsBrokerExchange exchange;
        Fixture(boolean revokeDuringFetch) throws Exception {
            owner = new IsolatedExecutionPolicyOwner("host-test", run, (id, policy) -> { }, (before, after) -> { });
            owner.replace(IsolatedExecutionPolicyOwner.Scope.granted("host-test", run, 2, root,
                    Files.createDirectory(root.resolve("workspace")), Set.of(), Set.of(), Set.of("example.com"), 0, 2, 30_000));
            journal = new IsolatedNetworkJournal(root, directory -> { });
            exchange = new LinuxVmHttpsBrokerExchange(owner.admit(run), journal,
                    (host, deadline, stop) -> new IsolatedNetworkBroker.Resolution(new InetAddress[] {PUBLIC}, Socket::new),
                    (uri, ip, route, deadline, stop) -> {
                        fetched.incrementAndGet();
                        if (revokeDuringFetch) owner.revoke(run);
                        return new IsolatedNetworkBroker.Hop(200, null, "text/plain", "body".getBytes(StandardCharsets.UTF_8));
                    });
            mailbox = new LinuxVmHttpsMailbox(disk, run, 2, exchange, cancelled);
        }
        void request(int sequence, String call, String requestRun, String url) {
            byte[] payload = (requestRun + call + url).getBytes(StandardCharsets.US_ASCII);
            disk.position(512); disk.put(payload);
            disk.position(16); disk.put(LinuxVmHttpsMailbox.sha256(payload));
            disk.putInt(0, LinuxVmHttpsMailbox.MAGIC); disk.putInt(4, 1);
            disk.putInt(12, payload.length); disk.putInt(8, sequence);
        }
        public void close() { mailbox.close(); owner.close(); }
    }

    private static void appExchangeChecks() throws Exception {
        for (String mode : new String[] {"wrong-run", "sequence", "replayed-call", "revoked"}) {
            try (Fixture f = new Fixture(false)) {
                String call = UUID.randomUUID().toString();
                if (mode.equals("revoked")) f.owner.revoke(f.run);
                if (mode.equals("replayed-call")) f.exchange.request(1, f.run, call, "https://example.com/");
                try {
                    f.exchange.request(mode.equals("sequence") || mode.equals("replayed-call") ? 2 : 1,
                            mode.equals("wrong-run") ? UUID.randomUUID().toString() : f.run,
                            call, "https://example.com/");
                    throw new AssertionError("App accepted invalid network admission");
                } catch (IOException expected) {
                    check(!f.exchange.active() && f.fetched.get() == (mode.equals("replayed-call") ? 1 : 0));
                }
            }
            tests++;
        }
    }

    private static void replyChecks() throws Exception {
        String run = UUID.randomUUID().toString(), call = UUID.randomUUID().toString();
        var result = new IsolatedNetworkBroker.Result(IsolatedNetworkBroker.Status.OK, 200,
                "https://example.com/", "text/plain", "body".getBytes(StandardCharsets.UTF_8), 0, call);
        byte[] good = LinuxVmHttpsMailbox.encode(run, call, result);
        LinuxVmHttpsMailbox.validateReply(good, run, call);
        for (String mode : new String[] {"run", "call", "audit", "body", "length", "url", "http"}) {
            byte[] bad = good.clone();
            switch (mode) {
                case "run" -> bad[0] ^= 1;
                case "call" -> bad[36] ^= 1;
                case "audit" -> bad[72] = 9;
                case "body" -> ByteBuffer.wrap(bad).putInt(79, 65537);
                case "length" -> bad = java.util.Arrays.copyOf(bad, bad.length - 1);
                case "url" -> bad[83] = 0;
                case "http" -> ByteBuffer.wrap(bad).putShort(73, (short) 0);
                default -> throw new AssertionError();
            }
            try { LinuxVmHttpsMailbox.validateReply(bad, run, call); throw new AssertionError(mode); }
            catch (IOException expected) { tests++; }
        }
        AtomicBoolean closed = new AtomicBoolean(), cancelled = new AtomicBoolean();
        ByteBuffer disk = ByteBuffer.allocateDirect(LinuxVmHttpsMailbox.DISK_BYTES);
        var exchange = new LinuxVmHttpsExchange() {
            public byte[] request(int sequence, String runId, String callId, String url) { return new byte[83]; }
            public boolean active() { return !closed.get(); }
            public void close() { closed.set(true); }
        };
        try (var mailbox = new LinuxVmHttpsMailbox(disk, run, 1, exchange, cancelled)) {
            byte[] payload = (run + call + "https://example.com/").getBytes(StandardCharsets.US_ASCII);
            disk.position(512); disk.put(payload); disk.position(16); disk.put(LinuxVmHttpsMailbox.sha256(payload));
            disk.putInt(0, LinuxVmHttpsMailbox.MAGIC); disk.putInt(4, 1); disk.putInt(12, payload.length); disk.putInt(8, 1);
            mailbox.poll();
            check(cancelled.get() && closed.get() && disk.getInt(4104) == 0);
        }
        tests++;
    }

    private static void closingInFlightExchange() throws Exception {
        Path root = Files.createTempDirectory(Path.of(System.getProperty("dsh.test.cache")), "exchange-");
        String run = UUID.randomUUID().toString(), call = UUID.randomUUID().toString();
        CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1);
        AtomicBoolean rejected = new AtomicBoolean();
        AtomicInteger requests = new AtomicInteger();
        var owner = new IsolatedExecutionPolicyOwner("host-test", run, (id, scope) -> { }, (before, after) -> { });
        owner.replace(IsolatedExecutionPolicyOwner.Scope.granted("host-test", run, 2, null, null,
                Set.of(), Set.of(), Set.of("example.com"), 0, 2, 30_000));
        var exchange = new LinuxVmHttpsBrokerExchange(owner.admit(run), new IsolatedNetworkJournal(root, directory -> { }),
                (host, deadline, stop) -> new IsolatedNetworkBroker.Resolution(new InetAddress[] {PUBLIC}, Socket::new),
                (uri, ip, route, deadline, stop) -> {
                    requests.incrementAndGet(); entered.countDown();
                    try { if (!release.await(3, TimeUnit.SECONDS)) throw new IOException("test barrier expired"); }
                    catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new IOException(error); }
                    return new IsolatedNetworkBroker.Hop(200, null, "text/plain", new byte[0]);
                });
        Thread thread = new Thread(() -> {
            try { exchange.request(1, run, call, "https://example.com/"); }
            catch (IOException expected) { rejected.set(true); }
        }, "test-linux-https-in-flight");
        try {
            thread.start(); check(entered.await(3, TimeUnit.SECONDS));
            try { exchange.request(2, run, UUID.randomUUID().toString(), "https://example.com/"); throw new AssertionError(); }
            catch (IOException expected) { check(!exchange.active()); }
            release.countDown(); thread.join(3500);
            check(!thread.isAlive() && rejected.get() && requests.get() == 1);
        } finally {
            exchange.close(); owner.close(); release.countDown(); thread.join(3500);
            check(!thread.isAlive());
        }
        tests++;
    }

    private static void mailboxCases() throws Exception {
        for (String mode : new String[] {"ok", "wrong-run", "wrong-host", "digest", "revoked", "during", "replay", "sequence"}) {
            try (Fixture f = new Fixture(mode.equals("during"))) {
                String call = UUID.randomUUID().toString();
                f.request(mode.equals("sequence") ? 2 : 1, call,
                        mode.equals("wrong-run") ? UUID.randomUUID().toString() : f.run,
                        mode.equals("wrong-host") ? "https://other.example.com/" : "https://example.com/");
                if (mode.equals("digest")) f.disk.put(16, (byte) (f.disk.get(16) ^ 1));
                if (mode.equals("revoked")) f.owner.revoke(f.run);
                f.mailbox.poll();
                if (mode.equals("ok") || mode.equals("replay")) {
                    check(f.disk.getInt(4104) == 1 && !f.cancelled.get() && f.fetched.get() == 1);
                    check(f.journal.read(call).state() == IsolatedNetworkJournal.State.TERMINAL);
                    if (mode.equals("replay")) {
                        f.request(2, call, f.run, "https://example.com/"); f.mailbox.poll();
                        check(f.cancelled.get() && f.disk.getInt(4104) == 1 && f.fetched.get() == 1);
                    }
                } else if (mode.equals("wrong-host")) {
                    check(f.disk.getInt(4104) == 1 && f.fetched.get() == 0);
                    check(f.journal.read(call).status() == IsolatedNetworkBroker.Status.POLICY_DENIED);
                } else {
                    check(f.cancelled.get() && f.disk.getInt(4104) == 0);
                    check(f.fetched.get() == (mode.equals("during") ? 1 : 0));
                }
            }
            tests++;
        }
    }

    public static void main(String[] args) throws Exception {
        tunnel(); rejectedProxyReplies(); proxyDeadlineAndRevoke(); mailboxCases();
        appExchangeChecks(); replyChecks(); closingInFlightExchange();
        System.out.println("LinuxVmNetworkHostTest passed: " + tests + " cases");
    }
}
