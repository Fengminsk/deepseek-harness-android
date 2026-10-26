package com.minnnng.dsh_android;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ConnectException;
import java.net.NoRouteToHostException;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.URI;
import java.net.URISyntaxException;
import java.net.UnknownHostException;
import java.nio.file.FileAlreadyExistsException;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.ScheduledThreadPoolExecutor;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Future;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.SynchronousQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicBoolean;
import javax.net.ssl.SNIHostName;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocket;

/**
 * Trusted-App-side, opt-in HTTP capability for an isolated guest. The caller must supply a deadline-bounded DNS resolver;
 * Java's blocking getAllByName is intentionally not a production default.
 */
public final class IsolatedNetworkBroker {
    public static final int MAX_URL_BYTES = 2048;
    public static final int MAX_RESPONSE_BYTES = 1024 * 1024;
    public static final int MAX_REDIRECTS = 3;
    public static final int MAX_CALLS = 64;
    public static final int MAX_DURATION_MILLIS = 10_000;
    public static final int MAX_LEASE_MILLIS = 5 * 60_000;
    private static final int IO_SLICE_MILLIS = 2_000;
    private static final int MAX_HEADER_BYTES = 32 * 1024;
    private static final int MAX_LINE_BYTES = 8 * 1024;

    public enum Status {
        OK, POLICY_DENIED, NETWORK_OFFLINE, DEADLINE_EXCEEDED, RESPONSE_TOO_LARGE,
        FAILED, CANCELLED, AUDIT_UNAVAILABLE, AUDIT_FULL, AUDIT_UNCERTAIN, REPLAY_DENIED
    }

    private static final class ResponseTooLargeException extends IllegalArgumentException {
        ResponseTooLargeException(String message) { super(message); }
    }

    /** Exact ASCII DNS names only. An empty policy denies all guest HTTP. */
    public record Policy(Set<String> exactHosts) {
        public Policy {
            Objects.requireNonNull(exactHosts);
            if (exactHosts.size() > 32) throw new IllegalArgumentException("Too many network hosts");
            Set<String> normalized = new HashSet<>();
            for (String host : exactHosts) {
                String value = validatedHost(host);
                if (!value.equals(host)) throw new IllegalArgumentException("Host must be normalized");
                normalized.add(value);
            }
            exactHosts = AndroidJava28.copySet(normalized);
        }
        public static Policy off() { return new Policy(AndroidJava28.setOf()); }
        boolean permits(String host) { return exactHosts.contains(host); }
    }

    /** Creates a direct socket already bound to the network used for the matching DNS query. */
    public interface RouteSocketFactory {
        Socket createSocket() throws IOException;
    }

    /** DNS answers and their route form one immutable result; redirects obtain a new result. */
    public record Resolution(InetAddress[] addresses, RouteSocketFactory route) {
        public Resolution {
            if (addresses == null || addresses.length == 0 || addresses.length > 32
                    || route == null) throw new IllegalArgumentException("Invalid DNS route");
            addresses = addresses.clone();
            for (InetAddress address : addresses)
                if (address == null) throw new IllegalArgumentException("Null DNS answer");
        }
        @Override public InetAddress[] addresses() { return addresses.clone(); }
    }

    /** A resolver must honor the monotonic deadline and return a socket route for the selected Network. */
    public interface DeadlineResolver {
        Resolution resolve(String host, long deadlineNanos, AtomicBoolean cancelled)
                throws IOException;
    }

    /** Transport receives one pinned address and its DNS Network route; it must not resolve again. */
    public interface PinnedTransport {
        Hop fetch(URI uri, Inet4Address address, RouteSocketFactory route,
                  long deadlineNanos, AtomicBoolean cancelled)
                throws IOException;
    }

    public record Hop(int statusCode, String location, String contentType, byte[] body) {
        public Hop {
            if (statusCode < 100 || statusCode > 599 || body == null)
                throw new IllegalArgumentException("Invalid HTTP response");
            if (body.length > MAX_RESPONSE_BYTES)
                throw new ResponseTooLargeException("Unbounded HTTP response body");
            body = body.clone();
        }
        @Override public byte[] body() { return body.clone(); }
    }
    public record Result(Status status, int statusCode, String finalUrl, String contentType,
                         byte[] body, int redirects, String auditId) {
        public Result {
            body = body == null ? new byte[0] : body.clone();
        }
        @Override public byte[] body() { return body.clone(); }
    }

    private final Policy policy;
    private final DeadlineResolver resolver;
    private final PinnedTransport transport;
    private final IsolatedNetworkJournal journal;
    private final int callDeadlineMillis;
    private final int maxResponseBytes;
    private final AtomicBoolean cancelled = new AtomicBoolean();
    private final long leaseDeadlineNanos;
    private int calls;

    public IsolatedNetworkBroker(Policy policy, DeadlineResolver resolver, PinnedTransport transport) {
        this(policy, resolver, transport, null, MAX_DURATION_MILLIS);
    }

    public IsolatedNetworkBroker(Policy policy, DeadlineResolver resolver, PinnedTransport transport,
                                 IsolatedNetworkJournal journal) {
        this(policy, resolver, transport, journal, MAX_DURATION_MILLIS);
    }

    /** A shorter deadline may be used by callers; no caller can exceed the ten-second ceiling. */
    IsolatedNetworkBroker(Policy policy, DeadlineResolver resolver, PinnedTransport transport,
                          int callDeadlineMillis) {
        this(policy, resolver, transport, null, callDeadlineMillis);
    }

    IsolatedNetworkBroker(Policy policy, DeadlineResolver resolver, PinnedTransport transport,
                          IsolatedNetworkJournal journal, int callDeadlineMillis) {
        this(policy, resolver, transport, journal, callDeadlineMillis, MAX_RESPONSE_BYTES);
    }

    /** A guest may use a smaller response ceiling than the transport's one MiB safety ceiling. */
    IsolatedNetworkBroker(Policy policy, DeadlineResolver resolver, PinnedTransport transport,
                          IsolatedNetworkJournal journal, int callDeadlineMillis,
                          int maxResponseBytes) {
        this(policy, resolver, transport, journal, callDeadlineMillis, maxResponseBytes,
                System.nanoTime() + MAX_LEASE_MILLIS * 1_000_000L);
    }

    /** The active App policy can shorten the network deadline below the broker ceiling. */
    IsolatedNetworkBroker(Policy policy, DeadlineResolver resolver, PinnedTransport transport,
                          IsolatedNetworkJournal journal, int callDeadlineMillis,
                          int maxResponseBytes, long policyDeadlineNanos) {
        this.policy = Objects.requireNonNull(policy);
        this.resolver = Objects.requireNonNull(resolver);
        this.transport = Objects.requireNonNull(transport);
        if (!policy.exactHosts().isEmpty() && journal == null)
            throw new IllegalArgumentException("Allowlisted network needs a durable audit journal");
        this.journal = journal;
        if (callDeadlineMillis < 1 || callDeadlineMillis > MAX_DURATION_MILLIS)
            throw new IllegalArgumentException("Invalid call deadline");
        this.callDeadlineMillis = callDeadlineMillis;
        if (maxResponseBytes < 1 || maxResponseBytes > MAX_RESPONSE_BYTES)
            throw new IllegalArgumentException("Invalid network response ceiling");
        this.maxResponseBytes = maxResponseBytes;
        this.leaseDeadlineNanos = policyDeadlineNanos;
    }

    public void revoke() {
        cancelled.set(true);
        PinnedTlsTransport.closeActive(cancelled);
    }

    /** The single-argument form keeps the default-off policy available without an audit writer. */
    public synchronized Result get(String url) {
        if (journal != null) return failure(Status.AUDIT_UNAVAILABLE);
        return execute(url, new AtomicBoolean());
    }

    /** A stable caller-owned ID prevents an uncertain network call from being replayed. */
    public synchronized Result get(String callId, String url) {
        IsolatedNetworkJournal.requireCallId(callId);
        if (journal == null) return execute(url, new AtomicBoolean());
        String host;
        try { host = checkedUri(url).getHost(); }
        catch (IllegalArgumentException invalid) { host = ""; }
        try { journal.admit(callId, host); }
        catch (FileAlreadyExistsException replay) {
            return withAudit(failure(Status.REPLAY_DENIED), callId);
        } catch (IsolatedNetworkJournal.CapacityExceededException full) {
            return withAudit(failure(Status.AUDIT_FULL), callId);
        } catch (IOException failed) {
            return withAudit(failure(Status.AUDIT_UNAVAILABLE), callId);
        }
        AtomicBoolean transportEntered = new AtomicBoolean();
        Result outcome;
        try { outcome = execute(url, transportEntered); }
        catch (RuntimeException unexpected) {
            // The request may already have reached the server. Revoke the lease and
            // durably record uncertainty rather than leaving ADMITTED without a terminal.
            revoke();
            outcome = failure(Status.AUDIT_UNCERTAIN);
        }
        try { journal.finish(callId, outcome.status(), transportEntered.get()); }
        catch (IOException | RuntimeException uncertain) {
            revoke();
            return withAudit(failure(Status.AUDIT_UNCERTAIN), callId);
        }
        return withAudit(outcome, callId);
    }

    /** Only GET is admitted. No arbitrary headers, request body, cookies, auth or proxy are exposed. */
    private Result execute(String url, AtomicBoolean transportEntered) {
        if (cancelled.get()) return failure(Status.CANCELLED);
        if (System.nanoTime() - leaseDeadlineNanos >= 0) return failure(Status.POLICY_DENIED);
        if (calls >= MAX_CALLS) return failure(Status.POLICY_DENIED);
        calls++;
        long deadline = System.nanoTime() + callDeadlineMillis * 1_000_000L;
        if (leaseDeadlineNanos - deadline < 0) deadline = leaseDeadlineNanos;
        URI current;
        try { current = checkedUri(url); }
        catch (IllegalArgumentException e) { return failure(Status.POLICY_DENIED); }
        for (int redirects = 0; redirects <= MAX_REDIRECTS; redirects++) {
            if (cancelled.get()) return failure(Status.CANCELLED);
            if (!policy.permits(current.getHost())) return failure(Status.POLICY_DENIED);
            if (remainingMillis(deadline) <= 0) return failure(Status.DEADLINE_EXCEEDED);
            try {
                Resolution resolved = resolver.resolve(current.getHost(), deadline, cancelled);
                if (resolved == null) throw new IllegalArgumentException("Missing DNS route");
                Inet4Address pinned = checkedAddresses(resolved.addresses());
                if (cancelled.get()) return failure(Status.CANCELLED);
                if (remainingMillis(deadline) <= 0) return failure(Status.DEADLINE_EXCEEDED);
                transportEntered.set(true);
                Hop hop = transport.fetch(current, pinned, resolved.route(), deadline, cancelled);
                if (cancelled.get()) return failure(Status.CANCELLED);
                if (remainingMillis(deadline) <= 0) return failure(Status.DEADLINE_EXCEEDED);
                if (isRedirect(hop.statusCode())) {
                    if (redirects == MAX_REDIRECTS || hop.location() == null)
                        return failure(Status.POLICY_DENIED);
                    current = checkedUri(current.resolve(hop.location()));
                    continue;
                }
                if (hop.body().length > maxResponseBytes)
                    return failure(Status.RESPONSE_TOO_LARGE);
                return new Result(Status.OK, hop.statusCode(), current.toString(),
                        hop.contentType(), hop.body(), redirects, null);
            } catch (ResponseTooLargeException e) {
                return failure(Status.RESPONSE_TOO_LARGE);
            } catch (IllegalArgumentException e) {
                return failure(Status.POLICY_DENIED);
            } catch (IOException e) {
                if (cancelled.get()) return failure(Status.CANCELLED);
                if (remainingMillis(deadline) <= 0) return failure(Status.DEADLINE_EXCEEDED);
                return failure(e instanceof UnknownHostException || e instanceof ConnectException
                        || e instanceof NoRouteToHostException || e instanceof SocketTimeoutException
                        ? Status.NETWORK_OFFLINE : Status.FAILED);
            }
        }
        return failure(Status.POLICY_DENIED);
    }

    private static Result failure(Status status) {
        return new Result(status, 0, null, null, null, 0, null);
    }

    private static Result withAudit(Result result, String callId) {
        return new Result(result.status(), result.statusCode(), result.finalUrl(),
                result.contentType(), result.body(), result.redirects(), callId);
    }
    private static boolean isRedirect(int status) {
        return status == 301 || status == 302 || status == 303 || status == 307 || status == 308;
    }
    static int remainingMillis(long deadlineNanos) {
        long nanos = deadlineNanos - System.nanoTime();
        return nanos <= 0 ? 0 : (int) Math.min(MAX_DURATION_MILLIS,
                Math.max(1, (nanos + 999_999L) / 1_000_000L));
    }

    static URI checkedUri(String raw) {
        if (raw == null || raw.getBytes(StandardCharsets.UTF_8).length > MAX_URL_BYTES)
            throw new IllegalArgumentException("Unbounded URL");
        try { return checkedUri(new URI(raw)); }
        catch (URISyntaxException e) { throw new IllegalArgumentException("Invalid URL", e); }
    }
    static URI checkedUri(URI uri) {
        if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.isOpaque()
                || uri.getRawUserInfo() != null || uri.getRawFragment() != null
                || uri.getPort() != -1 && uri.getPort() != 443
                || uri.getRawAuthority() == null || uri.getHost() == null
                || uri.toString().getBytes(StandardCharsets.UTF_8).length > MAX_URL_BYTES)
            throw new IllegalArgumentException("HTTPS DNS URL required");
        for (int i = 0; i < uri.toString().length(); i++) {
            if (uri.toString().charAt(i) > 127) throw new IllegalArgumentException("Non-ASCII URL");
        }
        String host = validatedHost(uri.getHost().toLowerCase(Locale.ROOT));
        if (!host.equals(uri.getHost())) throw new IllegalArgumentException("Host must be normalized");
        if (uri.getRawPath() != null && uri.getRawPath().contains("\\"))
            throw new IllegalArgumentException("Backslash in URL");
        return uri;
    }
    static String validatedHost(String host) {
        if (host == null || host.length() < 4 || host.length() > 253
                || !host.equals(host.toLowerCase(Locale.ROOT)) || host.endsWith(".")
                || host.startsWith(".") || host.contains("..") || host.indexOf(':') >= 0
                || host.equals("localhost") || host.endsWith(".localhost")
                || host.endsWith(".local") || host.endsWith(".internal")
                || host.endsWith(".localdomain") || host.endsWith(".lan")
                || host.endsWith(".home.arpa")
                || host.endsWith(".test") || host.endsWith(".invalid")
                || host.endsWith(".example") || host.matches("[0-9.]+"))
            throw new IllegalArgumentException("Unsafe host");
        String[] labels = host.split("\\.");
        if (labels.length < 2) throw new IllegalArgumentException("DNS name required");
        for (String label : labels) {
            if (label.isEmpty() || label.length() > 63 || label.startsWith("-")
                    || label.endsWith("-") || !label.matches("[a-z0-9-]+"))
                throw new IllegalArgumentException("Unsafe DNS label");
        }
        // Reject dotted-quad variants and hosts with all-numeric final labels.
        if (labels[labels.length - 1].matches("[0-9]+"))
            throw new IllegalArgumentException("Numeric TLD");
        return host;
    }

    static Inet4Address checkedAddresses(InetAddress[] answers) {
        if (answers == null || answers.length == 0 || answers.length > 32)
            throw new IllegalArgumentException("No bounded DNS answer");
        Inet4Address selected = null;
        for (InetAddress answer : answers) {
            // IPv6 is deliberately unsupported in this first version. Never connect to it.
            if (!(answer instanceof Inet4Address v4)) continue;
            if (!isPublicIpv4(v4)) throw new IllegalArgumentException("Non-public DNS answer");
            if (selected == null) selected = v4;
        }
        if (selected == null) throw new IllegalArgumentException("No public IPv4 answer");
        return selected;
    }

    static boolean isPublicIpv4(Inet4Address address) {
        byte[] b = address.getAddress();
        int a = b[0] & 255, c = b[1] & 255, d = b[2] & 255;
        if (a == 0 || a == 10 || a == 127 || a >= 224) return false;
        if (a == 100 && c >= 64 && c <= 127) return false;
        if (a == 169 && c == 254) return false;
        if (a == 172 && c >= 16 && c <= 31) return false;
        if (a == 192 && (c == 0 && (d == 0 || d == 2) || c == 31 && d == 196
                || c == 52 && d == 193 || c == 88 && d == 99
                || c == 168 || c == 175 && d == 48)) return false;
        if (a == 198 && (c == 18 || c == 19 || c == 51 && d == 100)) return false;
        if (a == 203 && c == 0 && d == 113) return false;
        return !address.isAnyLocalAddress() && !address.isLoopbackAddress()
                && !address.isLinkLocalAddress() && !address.isSiteLocalAddress()
                && !address.isMulticastAddress();
    }

    /** Network-bound pinned TCP/TLS, no ProxySelector or second DNS lookup, HTTP/1.1 only. */
    public static final class PinnedTlsTransport implements PinnedTransport {
        private static final ScheduledThreadPoolExecutor DEADLINE_CLOSER = deadlineCloser();
        private static final ThreadPoolExecutor ROUTE_OPENER = routeOpener();
        private static final ConcurrentHashMap<AtomicBoolean, Socket> ACTIVE = new ConcurrentHashMap<>();
        private final int maxBodyBytes;

        public PinnedTlsTransport() { this(MAX_RESPONSE_BYTES); }

        /** Stop reading at the guest's response ceiling rather than buffering the broker maximum. */
        public PinnedTlsTransport(int maxBodyBytes) {
            if (maxBodyBytes < 1 || maxBodyBytes > MAX_RESPONSE_BYTES)
                throw new IllegalArgumentException("Invalid transport response ceiling");
            this.maxBodyBytes = maxBodyBytes;
        }

        private static void closeActive(AtomicBoolean cancellation) {
            Socket socket = ACTIVE.remove(cancellation);
            if (socket != null) try { socket.close(); }
            catch (IOException ignored) { /* Closing is idempotent during retirement. */ }
        }

        private static void register(AtomicBoolean cancellation, Socket socket) throws IOException {
            if (cancellation.get()) throw new IOException("Network capability was revoked");
            if (ACTIVE.putIfAbsent(cancellation, socket) != null)
                throw new IOException("A network call is already active");
            if (cancellation.get()) closeActive(cancellation);
            if (cancellation.get()) throw new IOException("Network capability was revoked");
        }

        private static ThreadPoolExecutor routeOpener() {
            ThreadPoolExecutor executor = new ThreadPoolExecutor(1, 1, 30,
                    TimeUnit.SECONDS, new SynchronousQueue<>(), task -> {
                Thread thread = new Thread(task, "isolated-network-route-open");
                thread.setDaemon(true);
                return thread;
            }, new ThreadPoolExecutor.AbortPolicy());
            executor.allowCoreThreadTimeOut(true);
            return executor;
        }

        private static ScheduledThreadPoolExecutor deadlineCloser() {
            ScheduledThreadPoolExecutor executor = new ScheduledThreadPoolExecutor(1, task -> {
                Thread thread = new Thread(task, "isolated-network-deadline");
                thread.setDaemon(true);
                return thread;
            });
            executor.setRemoveOnCancelPolicy(true);
            return executor;
        }

        /** A zero SO_TIMEOUT means infinite; reject an expired deadline before every blocking step. */
        static int positiveIoTimeout(long deadlineNanos) throws IOException {
            int left = remainingMillis(deadlineNanos);
            if (left <= 0) throw new SocketTimeoutException("Deadline expired");
            return Math.min(left, IO_SLICE_MILLIS);
        }

        /** Closing the underlying TCP socket also bounds SSLSocket writes, which ignore SO_TIMEOUT. */
        static final class DeadlineSocketCloser implements AutoCloseable {
            private final ScheduledFuture<?> timeout;

            DeadlineSocketCloser(Socket socket, long deadlineNanos) throws IOException {
                Objects.requireNonNull(socket);
                int left = remainingMillis(deadlineNanos);
                if (left <= 0) throw new SocketTimeoutException("Deadline expired");
                timeout = DEADLINE_CLOSER.schedule(() -> {
                    try { socket.close(); } catch (IOException ignored) { /* already closed */ }
                }, left, TimeUnit.MILLISECONDS);
            }

            @Override public void close() { timeout.cancel(false); }
        }

        /** Closes a socket returned after its caller timed out or stopped waiting. */
        private static final class SocketDelivery {
            private Socket socket;
            private boolean abandoned;

            synchronized void offer(Socket delivered) throws IOException {
                if (abandoned) {
                    if (delivered != null) delivered.close();
                } else {
                    socket = delivered;
                }
            }

            synchronized Socket claim() {
                Socket claimed = socket;
                socket = null;
                return claimed;
            }

            synchronized void abandon() {
                abandoned = true;
                if (socket != null) {
                    try { socket.close(); } catch (IOException ignored) { /* best effort */ }
                    socket = null;
                }
            }
        }

        /** Bound socket creation can enter Android code; bound the caller wait and reclaim late sockets. */
        static Socket openRouteSocket(RouteSocketFactory route, long deadlineNanos,
                                      AtomicBoolean cancelled)
                throws IOException {
            int left = remainingMillis(deadlineNanos);
            if (left <= 0) throw new SocketTimeoutException("Deadline before route open");
            if (cancelled.get()) throw new IOException("Network capability was revoked");
            SocketDelivery delivery = new SocketDelivery();
            Future<?> opener;
            try {
                opener = ROUTE_OPENER.submit(() -> {
                    try { delivery.offer(route.createSocket()); }
                    catch (IOException error) { throw new java.io.UncheckedIOException(error); }
                });
            } catch (RejectedExecutionException error) {
                throw new IOException("Network route opener unavailable", error);
            }
            boolean claimed = false;
            try {
                while (true) {
                    if (cancelled.get()) throw new IOException("Network capability was revoked");
                    left = remainingMillis(deadlineNanos);
                    if (left <= 0) throw new SocketTimeoutException("Network route open deadline exceeded");
                    try { opener.get(Math.min(left, 50), TimeUnit.MILLISECONDS); break; }
                    catch (TimeoutException tick) { /* Check cancellation and the deadline again. */ }
                }
                Socket socket = delivery.claim();
                if (socket == null) throw new IOException("Network route returned no socket");
                claimed = true;
                if (cancelled.get()) {
                    socket.close();
                    throw new IOException("Network capability was revoked");
                }
                if (remainingMillis(deadlineNanos) <= 0) {
                    socket.close();
                    throw new SocketTimeoutException("Deadline after route open");
                }
                return socket;
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new IOException("Network route open interrupted", error);
            } catch (ExecutionException error) {
                Throwable cause = error.getCause();
                if (cause instanceof java.io.UncheckedIOException wrapped) throw wrapped.getCause();
                throw new IOException("Network route open failed", cause);
            } finally {
                if (!claimed) {
                    delivery.abandon();
                    opener.cancel(true);
                }
            }
        }

        @Override public Hop fetch(URI uri, Inet4Address address, RouteSocketFactory route,
                                   long deadlineNanos,
                                   AtomicBoolean cancelled) throws IOException {
            if (!isPublicIpv4(address) || route == null || cancelled.get())
                throw new IOException("Denied connection");
            positiveIoTimeout(deadlineNanos);
            try (Socket tcp = openRouteSocket(route, deadlineNanos, cancelled)) {
                register(cancelled, tcp);
                try (DeadlineSocketCloser deadlineCloser =
                             new DeadlineSocketCloser(tcp, deadlineNanos)) {
                if (cancelled.get()) throw new IOException("Cancelled before connect");
                tcp.connect(new InetSocketAddress(address, 443), positiveIoTimeout(deadlineNanos));
                tcp.setSoTimeout(positiveIoTimeout(deadlineNanos));
                SSLContext context;
                try {
                    context = SSLContext.getInstance("TLS");
                    context.init(new javax.net.ssl.KeyManager[0], null, null);
                    // Default trust anchors; the broker supplies no client certificate.
                } catch (java.security.GeneralSecurityException e) {
                    throw new IOException("TLS unavailable", e);
                }
                try (SSLSocket tls = (SSLSocket) context.getSocketFactory()
                        .createSocket(tcp, uri.getHost(), 443, false)) {
                    tls.setSoTimeout(positiveIoTimeout(deadlineNanos));
                    SSLParameters parameters = tls.getSSLParameters();
                    parameters.setEndpointIdentificationAlgorithm("HTTPS");
                    parameters.setServerNames(AndroidJava28.listOf(new SNIHostName(uri.getHost())));
                    tls.setSSLParameters(parameters);
                    tls.startHandshake();
                    if (cancelled.get() || remainingMillis(deadlineNanos) <= 0)
                        throw new IOException("Cancelled or timed out");
                    String path = uri.getRawPath();
                    if (path == null || path.isEmpty()) path = "/";
                    if (uri.getRawQuery() != null) path += "?" + uri.getRawQuery();
                    String request = "GET " + path + " HTTP/1.1\r\nHost: " + uri.getHost()
                            + "\r\nConnection: close\r\nAccept: */*\r\nAccept-Encoding: identity\r\n"
                            + "User-Agent: PocketHarness-IsolatedNetwork/1\r\n\r\n";
                    OutputStream out = tls.getOutputStream();
                    if (cancelled.get()) throw new IOException("Cancelled");
                    positiveIoTimeout(deadlineNanos);
                    out.write(request.getBytes(StandardCharsets.US_ASCII));
                    out.flush();
                    return readResponse(tls, deadlineNanos, cancelled);
                }
                } finally { ACTIVE.remove(cancelled, tcp); }
            }
        }

        private Hop readResponse(SSLSocket socket, long deadline, AtomicBoolean cancelled)
                throws IOException {
            InputStream in = socket.getInputStream();
            int[] budget = {MAX_HEADER_BYTES};
            String statusLine = line(socket, in, deadline, cancelled, budget);
            if (!statusLine.matches("HTTP/1\\.[01] [1-5][0-9][0-9]( .*)?"))
                throw new IOException("Malformed HTTP status");
            int status = Integer.parseInt(statusLine.substring(9, 12));
            if (status < 200 || status == 101) throw new IOException("Unexpected HTTP response");
            String location = null, type = null;
            long length = -1;
            boolean chunked = false;
            int count = 0;
            for (String header; !(header = line(socket, in, deadline, cancelled, budget)).isEmpty();) {
                if (++count > 64) throw new ResponseTooLargeException("Too many headers");
                int colon = header.indexOf(':');
                if (colon < 1 || header.startsWith(" ") || header.startsWith("\t"))
                    throw new IOException("Malformed header");
                String key = header.substring(0, colon).toLowerCase(Locale.ROOT);
                String value = header.substring(colon + 1).trim();
                if (key.equals("location")) {
                    if (location != null) throw new IOException("Duplicate redirect");
                    location = value;
                } else if (key.equals("content-type")) {
                    type = value.length() > 256 ? null : value;
                } else if (key.equals("content-length")) {
                    if (length != -1 || !value.matches("[0-9]{1,10}"))
                        throw new IOException("Invalid content length");
                    length = Long.parseLong(value);
                } else if (key.equals("transfer-encoding")) {
                    if (chunked || !value.equalsIgnoreCase("chunked"))
                        throw new IOException("Unsupported transfer encoding");
                    chunked = true;
                }
            }
            if (chunked && length >= 0) throw new IOException("Conflicting response framing");
            if (length > maxBodyBytes)
                throw new ResponseTooLargeException("Unbounded response");
            byte[] body;
            if (status == 204 || status == 304 || isRedirect(status)) body = new byte[0];
            else if (chunked) body = readChunks(socket, in, deadline, cancelled);
            else body = readBody(socket, in, length, deadline, cancelled);
            return new Hop(status, location, type, body);
        }

        private byte[] readChunks(SSLSocket socket, InputStream in, long deadline,
                                         AtomicBoolean cancelled) throws IOException {
            ByteArrayOutputStream body = new ByteArrayOutputStream();
            int[] budget = {MAX_HEADER_BYTES};
            for (;;) {
                String sizeLine = line(socket, in, deadline, cancelled, budget);
                if (!sizeLine.matches("[0-9A-Fa-f]{1,8}")) throw new IOException("Invalid chunk size");
                long parsedSize = Long.parseLong(sizeLine, 16);
                if (parsedSize > maxBodyBytes - body.size())
                    throw new ResponseTooLargeException("Unbounded chunked body");
                int size = (int) parsedSize;
                if (size == 0) {
                    // No trailers are accepted: avoid accidental metadata/cookie exposure.
                    if (!line(socket, in, deadline, cancelled, budget).isEmpty())
                        throw new IOException("Trailers denied");
                    return body.toByteArray();
                }
                readExact(socket, in, body, size, deadline, cancelled);
                if (readByte(socket, in, deadline, cancelled) != '\r'
                        || readByte(socket, in, deadline, cancelled) != '\n')
                    throw new IOException("Malformed chunk terminator");
            }
        }

        private byte[] readBody(SSLSocket socket, InputStream in, long length,
                                       long deadline, AtomicBoolean cancelled) throws IOException {
            ByteArrayOutputStream body = new ByteArrayOutputStream();
            if (length >= 0) readExact(socket, in, body, (int) length, deadline, cancelled);
            else {
                byte[] block = new byte[8192];
                for (;;) {
                    prepareRead(socket, deadline, cancelled);
                    int n = in.read(block, 0, Math.min(block.length, maxBodyBytes + 1 - body.size()));
                    if (n == -1) break;
                    body.write(block, 0, n);
                    if (body.size() > maxBodyBytes)
                        throw new ResponseTooLargeException("Unbounded body");
                }
            }
            return body.toByteArray();
        }

        private static void readExact(SSLSocket socket, InputStream in, ByteArrayOutputStream body,
                                      int length, long deadline, AtomicBoolean cancelled) throws IOException {
            byte[] block = new byte[8192];
            int remaining = length;
            while (remaining > 0) {
                prepareRead(socket, deadline, cancelled);
                int n = in.read(block, 0, Math.min(block.length, remaining));
                if (n < 0) throw new IOException("Truncated response");
                body.write(block, 0, n);
                remaining -= n;
            }
        }
        private static String line(SSLSocket socket, InputStream in, long deadline,
                                   AtomicBoolean cancelled, int[] budget) throws IOException {
            ByteArrayOutputStream raw = new ByteArrayOutputStream();
            for (;;) {
                int b = readByte(socket, in, deadline, cancelled);
                if (--budget[0] < 0 || raw.size() > MAX_LINE_BYTES)
                    throw new ResponseTooLargeException("Unbounded HTTP headers");
                if (b == '\r') {
                    if (readByte(socket, in, deadline, cancelled) != '\n')
                        throw new IOException("Malformed HTTP line ending");
                    if (--budget[0] < 0)
                        throw new ResponseTooLargeException("Unbounded HTTP headers");
                    return new String(raw.toByteArray(), StandardCharsets.ISO_8859_1);
                }
                if (b < 32 && b != '\t' || b == 127) throw new IOException("Invalid header byte");
                raw.write(b);
            }
        }
        private static int readByte(SSLSocket socket, InputStream in, long deadline,
                                    AtomicBoolean cancelled) throws IOException {
            prepareRead(socket, deadline, cancelled);
            int value = in.read();
            if (value < 0) throw new IOException("Truncated HTTP response");
            return value;
        }
        private static void prepareRead(SSLSocket socket, long deadline,
                                        AtomicBoolean cancelled) throws IOException {
            if (cancelled.get()) throw new IOException("Cancelled");
            socket.setSoTimeout(positiveIoTimeout(deadline));
        }
    }
}
