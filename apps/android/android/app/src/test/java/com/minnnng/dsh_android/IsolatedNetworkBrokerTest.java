package com.minnnng.dsh_android;

import java.io.IOException;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.SocketAddress;
import java.net.URI;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.charset.StandardCharsets;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/** Host-only policy/connection contract tests; no device network is contacted. */
public final class IsolatedNetworkBrokerTest {
    private static Path auditRoot;
    private static IsolatedNetworkJournal journal() {
        try { return new IsolatedNetworkJournal(auditRoot, ignored -> {}); }
        catch (IOException error) { throw new AssertionError("Network test audit unavailable", error); }
    }
    private static InetAddress ip(String value) throws IOException { return InetAddress.getByName(value); }
    private static IsolatedNetworkBroker.Resolution resolved(InetAddress... addresses) {
        return new IsolatedNetworkBroker.Resolution(addresses,
                () -> { throw new AssertionError("Mock transport must not open a socket"); });
    }
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
    private static IsolatedNetworkBroker broker(Set<String> hosts,
            IsolatedNetworkBroker.DeadlineResolver dns,
            IsolatedNetworkBroker.PinnedTransport transport) {
        return hosts.isEmpty()
                ? new IsolatedNetworkBroker(new IsolatedNetworkBroker.Policy(hosts), dns, transport)
                : new IsolatedNetworkBroker(new IsolatedNetworkBroker.Policy(hosts), dns,
                        transport, journal());
    }
    private static IsolatedNetworkBroker.PinnedTransport ok(AtomicInteger calls) {
        return (uri, address, route, deadline, cancelled) -> {
            calls.incrementAndGet();
            check(uri.getHost().equals("api.example.org"), "Wrong hostname");
            check(address.getHostAddress().equals("8.8.8.8"), "Pinned address changed");
            return new IsolatedNetworkBroker.Hop(200, null, "text/plain",
                    "safe".getBytes(StandardCharsets.UTF_8));
        };
    }
    private static void urlDenials() throws Exception {
        for (String host : new String[]{"127.0.0.1", "localhost", "app.local",
                "gateway.lan", "host.home.arpa", "*.example.org", "API.EXAMPLE.ORG"}) {
            try {
                new IsolatedNetworkBroker.Policy(Set.of(host));
                throw new AssertionError("Unsafe allowlist host admitted: " + host);
            } catch (IllegalArgumentException expected) { /* exact public DNS hosts only */ }
        }
        String[] denied = {
                "http://api.example.org/x", "https://127.0.0.1/", "https://[::1]/",
                "https://localhost/", "https://localhost.example.org/", "https://example.local/",
                "https://u:p@api.example.org/", "https://api.example.org:8080/",
                "https://API.EXAMPLE.ORG/", "https://api.example.org/x#token",
                "https://api.example.org\\@127.0.0.1/", "https://api.example.org/\r\nX: y",
        };
        AtomicInteger calls = new AtomicInteger();
        var candidate = broker(Set.of("api.example.org"), (host, deadline, cancelled) -> {
            calls.incrementAndGet(); return resolved(ip("8.8.8.8"));
        }, ok(new AtomicInteger()));
        for (String url : denied) {
            check(candidate.get(UUID.randomUUID().toString(), url).status() == IsolatedNetworkBroker.Status.POLICY_DENIED,
                    "Expected URL denial: " + url);
        }
        check(calls.get() == 0, "Denied URL resolved DNS");
        String huge = "https://api.example.org/" + "a".repeat(IsolatedNetworkBroker.MAX_URL_BYTES);
        check(candidate.get(UUID.randomUUID().toString(), huge).status() == IsolatedNetworkBroker.Status.POLICY_DENIED,
                "Unbounded URL admitted");
        check(calls.get() == 0, "Unbounded URL resolved DNS");
    }
    private static void dnsDenials() throws Exception {
        String[] privateAddresses = {
                "0.0.0.1", "10.0.0.1", "100.64.0.1", "127.0.0.1", "169.254.169.254",
                "172.16.0.1", "192.0.0.1", "192.0.2.1", "192.88.99.1",
                "192.31.196.1", "192.52.193.1", "192.168.1.1", "192.175.48.1",
                "198.18.0.1", "198.51.100.1", "203.0.113.1",
                "224.0.0.1", "240.0.0.1", "255.255.255.255",
        };
        AtomicInteger transportCalls = new AtomicInteger();
        for (String address : privateAddresses) {
            var candidate = broker(Set.of("api.example.org"),
                    (host, deadline, cancelled) -> resolved(ip("8.8.8.8"), ip(address)),
                    ok(transportCalls));
            check(candidate.get(UUID.randomUUID().toString(), "https://api.example.org/").status()
                            == IsolatedNetworkBroker.Status.POLICY_DENIED,
                    "Non-public DNS address admitted: " + address);
        }
        var ipv6 = broker(Set.of("api.example.org"),
                (host, deadline, cancelled) -> resolved(ip("2001:4860:4860::8888")),
                ok(transportCalls));
        check(ipv6.get(UUID.randomUUID().toString(), "https://api.example.org/").status()
                == IsolatedNetworkBroker.Status.POLICY_DENIED, "IPv6-only DNS admitted");
        check(transportCalls.get() == 0, "Transport invoked after bad DNS");
        try {
            new IsolatedNetworkBroker.PinnedTlsTransport().fetch(
                    URI.create("https://api.example.org/"), (Inet4Address) ip("127.0.0.1"),
                    () -> { throw new AssertionError("Unsafe address opened a socket"); },
                    System.nanoTime() + 1_000_000_000L, new AtomicBoolean());
            throw new AssertionError("Direct transport accepted loopback address");
        } catch (IOException expected) { /* no socket opened */ }
    }
    private static void redirectsAndPinning() throws Exception {
        AtomicInteger calls = new AtomicInteger();
        AtomicInteger resolutions = new AtomicInteger();
        IsolatedNetworkBroker.RouteSocketFactory firstRoute =
                () -> { throw new AssertionError("First route opened by mock transport"); };
        IsolatedNetworkBroker.RouteSocketFactory secondRoute =
                () -> { throw new AssertionError("Second route opened by mock transport"); };
        var allowed = broker(Set.of("api.example.org", "cdn.example.org"),
                (host, deadline, cancelled) -> {
                    resolutions.incrementAndGet();
                    return new IsolatedNetworkBroker.Resolution(
                            new InetAddress[]{ip("8.8.8.8")},
                            host.equals("api.example.org") ? firstRoute : secondRoute);
                }, (uri, address, route, deadline, cancelled) -> {
                    calls.incrementAndGet();
                    check(address.getHostAddress().equals("8.8.8.8"), "Unpinned transport");
                    if (uri.getHost().equals("api.example.org")) {
                        check(route == firstRoute, "Initial hop lost its DNS network route");
                        return new IsolatedNetworkBroker.Hop(302,
                                "https://cdn.example.org/data", null, new byte[0]);
                    }
                    check(route == secondRoute, "Redirect reused the previous DNS network route");
                    return new IsolatedNetworkBroker.Hop(200, null, "text/plain", new byte[]{1});
                });
        var result = allowed.get(UUID.randomUUID().toString(), "https://api.example.org/start");
        check(result.status() == IsolatedNetworkBroker.Status.OK && result.redirects() == 1,
                "Allowlisted redirect failed");
        check(calls.get() == 2 && resolutions.get() == 2, "Each hop must resolve and pin");

        String[] denied = {
                "http://cdn.example.org/data", "https://other.example.org/",
                "https://127.0.0.1/", "https://u:p@cdn.example.org/",
        };
        for (String location : denied) {
            AtomicInteger redirectedDns = new AtomicInteger();
            var blocked = broker(Set.of("api.example.org", "cdn.example.org"),
                    (host, deadline, cancelled) -> { redirectedDns.incrementAndGet();
                        return resolved(ip("8.8.8.8")); },
                    (uri, address, route, deadline, cancelled) ->
                            new IsolatedNetworkBroker.Hop(302, location, null, new byte[0]));
            check(blocked.get(UUID.randomUUID().toString(), "https://api.example.org/").status()
                            == IsolatedNetworkBroker.Status.POLICY_DENIED,
                    "Redirect escaped policy: " + location);
            check(redirectedDns.get() == 1, "Denied redirect resolved DNS");
        }
        AtomicInteger reboundTransport = new AtomicInteger();
        var rebinding = broker(Set.of("api.example.org", "cdn.example.org"),
                (host, deadline, cancelled) -> resolved(
                        ip(host.equals("api.example.org") ? "8.8.8.8" : "127.0.0.1")),
                (uri, address, route, deadline, cancelled) -> {
                    reboundTransport.incrementAndGet();
                    return new IsolatedNetworkBroker.Hop(302,
                            "https://cdn.example.org/data", null, new byte[0]);
                });
        check(rebinding.get(UUID.randomUUID().toString(), "https://api.example.org/").status()
                == IsolatedNetworkBroker.Status.POLICY_DENIED, "Redirect DNS rebinding admitted");
        check(reboundTransport.get() == 1, "Rebound destination reached transport");
    }
    private static void transportUsesResolvedRoute() throws Exception {
        AtomicInteger routesOpened = new AtomicInteger();
        AtomicInteger connects = new AtomicInteger();
        IsolatedNetworkBroker.RouteSocketFactory route = () -> {
            routesOpened.incrementAndGet();
            return new Socket() {
                @Override public void connect(SocketAddress endpoint, int timeout)
                        throws IOException {
                    connects.incrementAndGet();
                    check(endpoint instanceof InetSocketAddress, "Expected pinned IP endpoint");
                    InetSocketAddress target = (InetSocketAddress) endpoint;
                    check(target.getAddress().getHostAddress().equals("8.8.8.8")
                            && target.getPort() == 443, "Transport resolved a new destination");
                    check(timeout > 0, "Connect lost its deadline");
                    throw new IOException("Synthetic route stopped before network I/O");
                }
            };
        };
        var resolved = new IsolatedNetworkBroker.Resolution(
                new InetAddress[]{ip("8.8.8.8")}, route);
        InetAddress[] exposed = resolved.addresses();
        exposed[0] = ip("127.0.0.1");
        check(resolved.addresses()[0].getHostAddress().equals("8.8.8.8"),
                "DNS answer array remained mutable after resolution");
        try {
            new IsolatedNetworkBroker.PinnedTlsTransport().fetch(
                    URI.create("https://api.example.org/"),
                    (Inet4Address) resolved.addresses()[0], resolved.route(),
                    System.nanoTime() + TimeUnit.SECONDS.toNanos(2), new AtomicBoolean());
            throw new AssertionError("Synthetic route unexpectedly completed HTTP");
        } catch (IOException expected) { /* fake route terminates before TLS */ }
        check(routesOpened.get() == 1 && connects.get() == 1,
                "Transport bypassed the selected Network's socket route");
    }
    private static void defaultRouteChangeCannotReplaceResolvedRoute() throws Exception {
        IsolatedNetworkBroker.RouteSocketFactory original =
                () -> { throw new AssertionError("Mock route should not open"); };
        IsolatedNetworkBroker.RouteSocketFactory replacement =
                () -> { throw new AssertionError("Replacement route should not open"); };
        AtomicReference<IsolatedNetworkBroker.RouteSocketFactory> processDefault =
                new AtomicReference<>(original);
        var candidate = broker(Set.of("api.example.org"), (host, deadline, cancelled) -> {
            IsolatedNetworkBroker.RouteSocketFactory selected = processDefault.get();
            processDefault.set(replacement);
            return new IsolatedNetworkBroker.Resolution(
                    new InetAddress[]{ip("8.8.8.8")}, selected);
        }, (uri, address, route, deadline, cancelled) -> {
            check(processDefault.get() == replacement, "Default route did not switch");
            check(route == original, "Default switch replaced the DNS-selected route");
            return new IsolatedNetworkBroker.Hop(200, null, null, new byte[0]);
        });
        check(candidate.get(UUID.randomUUID().toString(), "https://api.example.org/").status() == IsolatedNetworkBroker.Status.OK,
                "Network-switch simulation failed");
    }
    private static void routeOpenDeadlineReclaimsLateSocket() throws Exception {
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        CountDownLatch lateSocketClosed = new CountDownLatch(1);
        AtomicReference<Throwable> failure = new AtomicReference<>();
        Socket delayed = new Socket() {
            @Override public synchronized void close() throws IOException {
                lateSocketClosed.countDown();
                super.close();
            }
        };
        IsolatedNetworkBroker.RouteSocketFactory delayedRoute = () -> {
            entered.countDown();
            for (;;) {
                try { release.await(); break; }
                catch (InterruptedException ignored) { /* simulate a stuck Android route call */ }
            }
            return delayed;
        };
        Thread caller = new Thread(() -> {
            try {
                new IsolatedNetworkBroker.PinnedTlsTransport().fetch(
                        URI.create("https://api.example.org/"),
                        (Inet4Address) uncheckedIp("8.8.8.8"), delayedRoute,
                        System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(250),
                        new AtomicBoolean());
                failure.set(new AssertionError("Stalled route unexpectedly connected"));
            } catch (Throwable error) {
                failure.set(error);
            }
        }, "network-route-deadline-test");
        caller.setDaemon(true);
        caller.start();
        try {
            check(entered.await(1, TimeUnit.SECONDS), "Route factory never started");
            caller.join(1_000);
            check(!caller.isAlive(), "Stalled route blocked beyond the call deadline");
            check(failure.get() instanceof SocketTimeoutException,
                    "Stalled route did not return a deadline error: " + failure.get());
        } finally {
            release.countDown();
        }
        check(lateSocketClosed.await(1, TimeUnit.SECONDS),
                "Socket returned after the deadline was not closed");
    }
    private static InetAddress uncheckedIp(String address) {
        try { return ip(address); }
        catch (IOException error) { throw new AssertionError(error); }
    }
    private static void lifecycleAndBounds() throws Exception {
        AtomicInteger resolverCalls = new AtomicInteger();
        var off = broker(Set.of(), (host, deadline, cancelled) -> {
            resolverCalls.incrementAndGet(); return resolved(ip("8.8.8.8"));
        }, ok(new AtomicInteger()));
        check(off.get(UUID.randomUUID().toString(), "https://api.example.org/").status()
                == IsolatedNetworkBroker.Status.POLICY_DENIED, "Off policy admitted HTTP");
        check(resolverCalls.get() == 0, "Off policy resolved DNS");
        AtomicInteger calls = new AtomicInteger();
        var candidate = broker(Set.of("api.example.org"),
                (host, deadline, cancelled) -> resolved(ip("8.8.8.8")), ok(calls));
        for (int i = 0; i < IsolatedNetworkBroker.MAX_CALLS; i++)
            check(candidate.get(UUID.randomUUID().toString(), "https://api.example.org/").status()
                    == IsolatedNetworkBroker.Status.OK, "Bounded call failed");
        check(candidate.get(UUID.randomUUID().toString(), "https://api.example.org/").status()
                == IsolatedNetworkBroker.Status.POLICY_DENIED, "Call quota bypassed");
        check(calls.get() == IsolatedNetworkBroker.MAX_CALLS, "Over-budget transport invoked");
        candidate.revoke();
        check(candidate.get(UUID.randomUUID().toString(), "https://api.example.org/").status()
                == IsolatedNetworkBroker.Status.CANCELLED, "Revoked broker admitted HTTP");
        var oversized = broker(Set.of("api.example.org"),
                (host, deadline, cancelled) -> resolved(ip("8.8.8.8")),
                (uri, address, route, deadline, cancelled) -> new IsolatedNetworkBroker.Hop(
                        200, null, null, new byte[IsolatedNetworkBroker.MAX_RESPONSE_BYTES + 1]));
        check(oversized.get(UUID.randomUUID().toString(), "https://api.example.org/").status()
                == IsolatedNetworkBroker.Status.RESPONSE_TOO_LARGE,
                "Oversized response misreported as a policy denial");
    }
    private static void deadlineAfterRedirect() throws Exception {
        AtomicInteger transportCalls = new AtomicInteger();
        var candidate = new IsolatedNetworkBroker(
                new IsolatedNetworkBroker.Policy(Set.of("api.example.org", "cdn.example.org")),
                (host, deadline, cancelled) -> resolved(ip("8.8.8.8")),
                (uri, address, route, deadline, cancelled) -> {
                    transportCalls.incrementAndGet();
                    check(uri.getHost().equals("api.example.org"),
                            "Expired redirect reached a second host");
                    while (IsolatedNetworkBroker.remainingMillis(deadline) > 0)
                        Thread.onSpinWait();
                    return new IsolatedNetworkBroker.Hop(302,
                            "https://cdn.example.org/next", null, new byte[0]);
                }, journal(), 20);
        check(candidate.get(UUID.randomUUID().toString(), "https://api.example.org/start").status()
                == IsolatedNetworkBroker.Status.DEADLINE_EXCEEDED,
                "Expired redirect misreported as a policy denial");
        check(transportCalls.get() == 1, "Expired redirect performed another request");
        try {
            new IsolatedNetworkBroker(new IsolatedNetworkBroker.Policy(Set.of("api.example.org")),
                    (host, deadline, cancelled) -> resolved(ip("8.8.8.8")),
                    ok(new AtomicInteger()), journal(),
                    IsolatedNetworkBroker.MAX_DURATION_MILLIS + 1);
            throw new AssertionError("Call deadline exceeded the maximum");
        } catch (IllegalArgumentException expected) { /* deadline is capped */ }
    }
    private static void transportDeadlineCannotBecomeInfinite() throws Exception {
        try {
            IsolatedNetworkBroker.PinnedTlsTransport.positiveIoTimeout(System.nanoTime() - 1);
            throw new AssertionError("Expired TLS read admitted SO_TIMEOUT=0");
        } catch (SocketTimeoutException expected) { /* zero means infinite in Socket API */ }
        check(IsolatedNetworkBroker.PinnedTlsTransport.positiveIoTimeout(
                System.nanoTime() + TimeUnit.SECONDS.toNanos(4)) == 2_000,
                "TLS read timeout exceeds the bounded slice");

        final class ObservedSocket extends Socket {
            final CountDownLatch closed = new CountDownLatch(1);
            @Override public synchronized void close() throws IOException { closed.countDown(); }
        }
        ObservedSocket timedOut = new ObservedSocket();
        try (var guard = new IsolatedNetworkBroker.PinnedTlsTransport.DeadlineSocketCloser(
                timedOut, System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(40))) {
            check(timedOut.closed.await(2, TimeUnit.SECONDS),
                    "Write/handshake deadline did not close underlying TCP socket");
        }
        ObservedSocket completed = new ObservedSocket();
        try (var guard = new IsolatedNetworkBroker.PinnedTlsTransport.DeadlineSocketCloser(
                completed, System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(150))) {
            // A completed request must remove its scheduled abort.
        }
        check(!completed.closed.await(250, TimeUnit.MILLISECONDS),
                "Completed request retained a deadline close task");
        try {
            new IsolatedNetworkBroker.PinnedTlsTransport.DeadlineSocketCloser(
                    new ObservedSocket(), System.nanoTime() - 1);
            throw new AssertionError("Expired transport admitted a blocking operation");
        } catch (SocketTimeoutException expected) { /* fail closed */ }
    }
    private static void auditFailuresAndReplay() throws Exception {
        AtomicInteger dns = new AtomicInteger();
        var failedAdmission = new IsolatedNetworkJournal(auditRoot, directory -> {
            if (directory.endsWith("isolated-network-calls"))
                throw new IOException("Injected admission sync failure");
        });
        var noNetwork = new IsolatedNetworkBroker(
                new IsolatedNetworkBroker.Policy(Set.of("api.example.org")),
                (host, deadline, cancelled) -> {
                    dns.incrementAndGet(); return resolved(ip("8.8.8.8"));
                }, ok(new AtomicInteger()), failedAdmission);
        String deniedId = UUID.randomUUID().toString();
        check(noNetwork.get(deniedId, "https://api.example.org/").status()
                == IsolatedNetworkBroker.Status.AUDIT_UNAVAILABLE,
                "Audit admission failure did not fail before network I/O");
        check(dns.get() == 0, "DNS ran without durable admission");
        check(noNetwork.get(deniedId, "https://api.example.org/").status()
                == IsolatedNetworkBroker.Status.REPLAY_DENIED,
                "Uncertain admission replayed the same call ID");

        AtomicInteger syncs = new AtomicInteger();
        var terminalSyncFailure = new IsolatedNetworkJournal(auditRoot, directory -> {
            if (directory.endsWith("isolated-network-calls") && syncs.incrementAndGet() == 2)
                throw new IOException("Injected terminal sync failure");
        });
        AtomicInteger sends = new AtomicInteger();
        var uncertain = new IsolatedNetworkBroker(
                new IsolatedNetworkBroker.Policy(Set.of("api.example.org")),
                (host, deadline, cancelled) -> resolved(ip("8.8.8.8")),
                ok(sends), terminalSyncFailure);
        String sentId = UUID.randomUUID().toString();
        check(uncertain.get(sentId, "https://api.example.org/").status()
                == IsolatedNetworkBroker.Status.AUDIT_UNCERTAIN,
                "Terminal sync failure published a network result");
        check(sends.get() == 1, "Audit failure fixture did not reach transport once");
        check(uncertain.get(sentId, "https://api.example.org/").status()
                == IsolatedNetworkBroker.Status.REPLAY_DENIED && sends.get() == 1,
                "Uncertain network effect was replayed");
        check(uncertain.get("https://api.example.org/").status()
                == IsolatedNetworkBroker.Status.AUDIT_UNAVAILABLE,
                "One-argument method bypassed the stable call ID");

        Path quotaParent = Files.createDirectory(auditRoot.resolve("quota-broker"));
        var bounded = new IsolatedNetworkJournal(quotaParent, ignored -> {}, 1, 4096);
        AtomicInteger quotaDns = new AtomicInteger();
        var quotaBroker = new IsolatedNetworkBroker(
                new IsolatedNetworkBroker.Policy(Set.of("api.example.org")),
                (host, deadline, cancelled) -> {
                    quotaDns.incrementAndGet(); return resolved(ip("8.8.8.8"));
                }, ok(new AtomicInteger()), bounded);
        quotaBroker.get(UUID.randomUUID().toString(), "https://api.example.org/");
        int beforeFull = quotaDns.get();
        check(quotaBroker.get(UUID.randomUUID().toString(), "https://api.example.org/").status()
                == IsolatedNetworkBroker.Status.AUDIT_FULL,
                "Audit capacity did not return its distinct fail-closed status");
        check(quotaDns.get() == beforeFull, "DNS ran after audit capacity was exhausted");
    }

    private static void policyRevocationBetweenDnsAndWrite() throws Exception {
        String ownerId = "network.task";
        String sessionId = UUID.randomUUID().toString();
        var owner = new IsolatedExecutionPolicyOwner(ownerId, sessionId,
                (runId, scope) -> {}, (before, after) -> {});
        owner.replace(IsolatedExecutionPolicyOwner.Scope.granted(ownerId, sessionId, 2,
                null, null, Set.of(), Set.of(), Set.of("api.example.org"), 0, 1, 10_000));
        var lease = owner.admit(UUID.randomUUID().toString());
        AtomicInteger transportCalls = new AtomicInteger();
        var audit = journal();
        var candidate = new IsolatedNetworkBroker(
                new IsolatedNetworkBroker.Policy(lease.policy().exactHosts()),
                (host, deadline, cancelled) -> {
                    owner.revoke(lease.runId());
                    check(cancelled.get(), "Lease revocation returned before network cancellation");
                    return resolved(ip("8.8.8.8"));
                }, ok(transportCalls), audit, IsolatedNetworkBroker.MAX_DURATION_MILLIS,
                IsolatedNetworkBroker.MAX_RESPONSE_BYTES, lease.deadlineNanos());
        lease.onRevoked(candidate::revoke);
        String callId = UUID.randomUUID().toString();
        check(candidate.get(callId, "https://api.example.org/data").status()
                        == IsolatedNetworkBroker.Status.CANCELLED,
                "A revoked lease was admitted after DNS");
        check(transportCalls.get() == 0, "Network request was written after lease revocation");
        var entry = audit.read(callId);
        check(entry.state() == IsolatedNetworkJournal.State.TERMINAL
                        && entry.status() == IsolatedNetworkBroker.Status.CANCELLED
                        && !entry.transportEntered(),
                "Revoked pre-write call lacked a precise terminal audit record");

        AtomicInteger expiredDns = new AtomicInteger();
        var expired = new IsolatedNetworkBroker(
                new IsolatedNetworkBroker.Policy(Set.of("api.example.org")),
                (host, deadline, cancelled) -> {
                    expiredDns.incrementAndGet(); return resolved(ip("8.8.8.8"));
                }, ok(transportCalls), journal(), IsolatedNetworkBroker.MAX_DURATION_MILLIS,
                IsolatedNetworkBroker.MAX_RESPONSE_BYTES, System.nanoTime() - 1);
        check(expired.get(UUID.randomUUID().toString(), "https://api.example.org/data").status()
                        == IsolatedNetworkBroker.Status.POLICY_DENIED
                        && expiredDns.get() == 0,
                "Expired policy deadline reached DNS or transport");
    }

    private static void revokeClosesActiveSocket() throws Exception {
        CountDownLatch connected = new CountDownLatch(1);
        CountDownLatch closed = new CountDownLatch(1);
        AtomicInteger closes = new AtomicInteger();
        Socket fake = new Socket() {
            @Override public void connect(SocketAddress endpoint, int timeout) throws IOException {
                connected.countDown();
                try {
                    if (!closed.await(3, TimeUnit.SECONDS))
                        throw new IOException("Revocation never closed active TCP");
                } catch (InterruptedException error) {
                    Thread.currentThread().interrupt();
                    throw new IOException("Synthetic TCP interrupted", error);
                }
                throw new IOException("Synthetic TCP closed");
            }
            @Override public synchronized void close() throws IOException {
                closes.incrementAndGet();
                closed.countDown();
                super.close();
            }
        };
        // The route factory is carried by the DNS answer, not a process-default socket.
        var withRoute = new IsolatedNetworkBroker(
                new IsolatedNetworkBroker.Policy(Set.of("api.example.org")),
                (host, deadline, cancelled) -> new IsolatedNetworkBroker.Resolution(
                        new InetAddress[]{ip("8.8.8.8")}, () -> fake),
                new IsolatedNetworkBroker.PinnedTlsTransport(), journal());
        AtomicReference<IsolatedNetworkBroker.Result> observed = new AtomicReference<>();
        Thread caller = new Thread(() -> observed.set(withRoute.get(UUID.randomUUID().toString(),
                "https://api.example.org/")), "network-revoke-test");
        caller.setDaemon(true);
        caller.start();
        try {
            check(connected.await(2, TimeUnit.SECONDS), "Route never reached active TCP connect");
            withRoute.revoke();
            withRoute.revoke();
            caller.join(1_000);
            check(!caller.isAlive() && observed.get() != null
                    && observed.get().status() == IsolatedNetworkBroker.Status.CANCELLED,
                    "Revocation did not abort and audit the active call");
            check(closes.get() >= 1, "Active TCP socket was not closed");
        } finally { withRoute.revoke(); }
    }

    private static void revokeReclaimsLateRouteSocket() throws Exception {
        CountDownLatch started = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        CountDownLatch reclaimed = new CountDownLatch(1);
        Socket delayed = new Socket() {
            @Override public synchronized void close() throws IOException {
                reclaimed.countDown();
                super.close();
            }
        };
        IsolatedNetworkBroker.RouteSocketFactory route = () -> {
            started.countDown();
            for (;;) {
                try { release.await(); break; }
                catch (InterruptedException ignored) { /* Simulate a platform route call that ignores it. */ }
            }
            return delayed;
        };
        var candidate = new IsolatedNetworkBroker(
                new IsolatedNetworkBroker.Policy(Set.of("api.example.org")),
                (host, deadline, cancelled) -> new IsolatedNetworkBroker.Resolution(
                        new InetAddress[]{ip("8.8.8.8")}, route),
                new IsolatedNetworkBroker.PinnedTlsTransport(), journal());
        AtomicReference<IsolatedNetworkBroker.Result> outcome = new AtomicReference<>();
        Thread caller = new Thread(() -> outcome.set(candidate.get(UUID.randomUUID().toString(),
                "https://api.example.org/")), "network-late-route-revoke-test");
        caller.setDaemon(true);
        caller.start();
        try {
            check(started.await(2, TimeUnit.SECONDS), "Route open never started");
            candidate.revoke();
            caller.join(1_000);
            check(!caller.isAlive() && outcome.get() != null
                    && outcome.get().status() == IsolatedNetworkBroker.Status.CANCELLED,
                    "Revoked route kept caller waiting");
        } finally { release.countDown(); candidate.revoke(); }
        check(reclaimed.await(1, TimeUnit.SECONDS),
                "Socket returned after revocation was not closed");
    }
    private static void guestResponseCeilingIsAudited() throws Exception {
        final int guestLimit = 64 * 1024;
        var audit = journal();
        var broker = new IsolatedNetworkBroker(
                new IsolatedNetworkBroker.Policy(Set.of("api.example.org")),
                (host, deadline, cancelled) -> resolved(ip("8.8.8.8")),
                (uri, address, route, deadline, cancelled) ->
                        new IsolatedNetworkBroker.Hop(200, null, "application/octet-stream",
                                new byte[guestLimit + 1]),
                audit, 1000, guestLimit);
        String callId = UUID.randomUUID().toString();
        var result = broker.get(callId, "https://api.example.org/data");
        check(result.status() == IsolatedNetworkBroker.Status.RESPONSE_TOO_LARGE
                        && result.body().length == 0,
                "Guest response exceeded its Binder budget");
        var entry = audit.read(callId);
        check(entry.state() == IsolatedNetworkJournal.State.TERMINAL
                        && entry.status() == IsolatedNetworkBroker.Status.RESPONSE_TOO_LARGE
                        && entry.transportEntered(),
                "Guest size refusal was not durably audited");
    }
    private static void uncheckedTransportFailureSettlesUncertainAndRevokes() throws Exception {
        var audit = journal();
        AtomicInteger entered = new AtomicInteger();
        var broker = new IsolatedNetworkBroker(
                new IsolatedNetworkBroker.Policy(Set.of("api.example.org")),
                (host, deadline, cancelled) -> resolved(ip("8.8.8.8")),
                (uri, address, route, deadline, cancelled) -> {
                    entered.incrementAndGet();
                    throw new IllegalStateException("Injected failure after network entry");
                }, audit, 1000);
        String callId = UUID.randomUUID().toString();
        var result = broker.get(callId, "https://api.example.org/data");
        check(result.status() == IsolatedNetworkBroker.Status.AUDIT_UNCERTAIN
                        && result.body().length == 0,
                "Unchecked transport failure was published as a clean result");
        var entry = audit.read(callId);
        check(entry.state() == IsolatedNetworkJournal.State.TERMINAL
                        && entry.status() == IsolatedNetworkBroker.Status.AUDIT_UNCERTAIN
                        && entry.transportEntered(),
                "Unchecked failure left a network effect without durable uncertain settlement");
        check(broker.get(callId, "https://api.example.org/data").status()
                        == IsolatedNetworkBroker.Status.REPLAY_DENIED,
                "Unchecked network effect replayed its call ID");
        String freshId = UUID.randomUUID().toString();
        check(broker.get(freshId, "https://api.example.org/data").status()
                        == IsolatedNetworkBroker.Status.CANCELLED
                        && entered.get() == 1,
                "Uncertain transport failure did not revoke future network I/O");
        check(audit.read(freshId).state() == IsolatedNetworkJournal.State.TERMINAL,
                "Revoked follow-up call was not audited");
    }
    public static void main(String[] args) throws Exception {
        auditRoot = Files.createTempDirectory("isolated-network-broker-");
        try {
            urlDenials(); dnsDenials(); redirectsAndPinning(); lifecycleAndBounds();
            deadlineAfterRedirect(); transportDeadlineCannotBecomeInfinite();
            transportUsesResolvedRoute(); defaultRouteChangeCannotReplaceResolvedRoute();
            routeOpenDeadlineReclaimsLateSocket();
            auditFailuresAndReplay(); revokeClosesActiveSocket();
            policyRevocationBetweenDnsAndWrite();
            revokeReclaimsLateRouteSocket();
            guestResponseCeilingIsAudited();
            uncheckedTransportFailureSettlesUncertainAndRevokes();
            System.out.println("IsolatedNetworkBrokerTest PASS");
        } finally {
            if (!auditRoot.toAbsolutePath().normalize().getParent().equals(
                    Path.of(System.getProperty("java.io.tmpdir")).toAbsolutePath().normalize()))
                throw new AssertionError("Refusing to remove unrelated audit test files");
            try (var files = Files.walk(auditRoot)) {
                files.sorted(java.util.Comparator.reverseOrder()).forEach(path -> {
                    try { Files.delete(path); }
                    catch (IOException error) { throw new java.io.UncheckedIOException(error); }
                });
            }
        }
    }
}
