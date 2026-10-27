package com.minnnng.dsh_android;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.InetAddress;
import java.net.Socket;
import java.net.ServerSocket;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.Base64;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/** Actual host TinyEMU + guest Python + HTTPS probe; not Android admission/device evidence. */
public final class LinuxVmNetworkHost {
    static final class Console {
        final LinuxVmConsole framed;
        final ByteArrayOutputStream raw = new ByteArrayOutputStream();
        final LinuxVmHttpsMailbox mailbox;
        Console(String command, LinuxVmHttpsMailbox mailbox) {
            framed = new LinuxVmConsole(command, true, true); this.mailbox = mailbox;
        }
        int read(byte[] bytes, int capacity) {
            mailbox.poll();
            return framed.read(bytes, capacity);
        }
        void write(byte[] bytes) {
            raw.write(bytes, 0, Math.min(bytes.length, 256 * 1024 - raw.size()));
            framed.write(bytes);
        }
    }

    private static ByteBuffer load(Path file, boolean readOnly) throws Exception {
        long size = Files.size(file);
        if (size < 1 || size > 256L * 1024 * 1024) throw new IOException("Invalid image size");
        ByteBuffer buffer = ByteBuffer.allocateDirect(Math.toIntExact(size));
        try (FileChannel channel = FileChannel.open(file, StandardOpenOption.READ)) {
            while (buffer.hasRemaining()) if (channel.read(buffer) < 0) throw new IOException("Short image");
        }
        buffer.clear(); return readOnly ? buffer.asReadOnlyBuffer() : buffer;
    }

    private static void record(Path file, String value) throws IOException {
        try (FileChannel channel = FileChannel.open(file, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)) {
            ByteBuffer bytes = StandardCharsets.UTF_8.encode(value);
            while (bytes.hasRemaining()) channel.write(bytes);
            channel.force(true);
        }
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 8) throw new IllegalArgumentException("library bios kernel disk script output proxyPort mode");
        Path output = Files.createDirectory(Path.of(args[5]));
        Path workspace = Files.createDirectory(output.resolve("host-scope"));
        String run = UUID.randomUUID().toString();
        String mode = args[7];
        if (!Set.of("live", "revoked", "wrong-host", "proxy-unavailable").contains(mode))
            throw new IllegalArgumentException("Unknown network probe mode");
        int proxyPort = Integer.parseInt(args[6]);
        if (mode.equals("proxy-unavailable")) {
            try (ServerSocket unused = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
                proxyPort = unused.getLocalPort();
            }
        }
        String script = Files.readString(Path.of(args[4]), StandardCharsets.UTF_8);
        String encoded = Base64.getEncoder().encodeToString(script.getBytes(StandardCharsets.UTF_8));
        String command = "set -eu\nprintf '%s' '" + encoded + "' | base64 -d > /tmp/dsh-fetch.py\n"
                + "python3 /tmp/dsh-fetch.py /dev/vdd " + run + " https://example.com/\n";
        System.load(Path.of(args[0]).toAbsolutePath().toString());
        ByteBuffer bios = load(Path.of(args[1]), true), kernel = load(Path.of(args[2]), true);
        ByteBuffer root = load(Path.of(args[3]), false);
        ByteBuffer disk = ByteBuffer.allocateDirect(LinuxVmHttpsMailbox.DISK_BYTES);
        AtomicBoolean cancelled = new AtomicBoolean();
        IsolatedExecutionPolicyOwner owner = new IsolatedExecutionPolicyOwner("host-probe", run,
                (id, scope) -> record(output.resolve("admission.json"), "{\"runId\":\"" + id + "\",\"version\":" + scope.version() + "}"),
                (before, after) -> record(output.resolve("policy-" + after.version() + ".txt"), after.exactHosts().toString()));
        try {
            owner.replace(IsolatedExecutionPolicyOwner.Scope.granted("host-probe", run, 2,
                    output, workspace, Set.of(), Set.of(),
                    Set.of(mode.equals("wrong-host") ? "other.example.com" : "example.com"), 0, 2, 120_000));
            IsolatedExecutionPolicyOwner.Lease lease = owner.admit(run);
            // Journal files are real and file-fsynced. Windows directory fsync is NOT claimed.
            IsolatedNetworkJournal journal = new IsolatedNetworkJournal(output, directory -> { });
            var dnsPool = Executors.newSingleThreadExecutor(r -> {
                Thread thread = new Thread(r, "host-probe-dns"); thread.setDaemon(true); return thread;
            });
            IsolatedNetworkBroker.DeadlineResolver resolver = (host, deadline, stop) -> {
                if (mode.equals("revoked")) {
                    owner.revoke(run);
                    throw new IOException("Host probe revoked the live guest request");
                }
                var pending = dnsPool.submit(() -> InetAddress.getAllByName(host));
                try {
                    while (true) {
                        if (stop.get() || System.nanoTime() >= deadline) throw new IOException("DNS cancelled or expired");
                        try { return new IsolatedNetworkBroker.Resolution(pending.get(25, TimeUnit.MILLISECONDS), Socket::new); }
                        catch (java.util.concurrent.TimeoutException tick) { /* Check the live deadline. */ }
                    }
                } catch (InterruptedException error) {
                    Thread.currentThread().interrupt(); throw new IOException(error);
                } catch (java.util.concurrent.ExecutionException error) { throw new IOException(error); }
                finally { pending.cancel(true); }
            };
            try (LinuxVmHttpsMailbox mailbox = new LinuxVmHttpsMailbox(disk, lease, journal, resolver,
                    IsolatedNetworkBroker.PinnedTlsTransport.throughLocalHttpProxy(
                            LinuxVmHttpsMailbox.MAX_BODY_BYTES, proxyPort), cancelled)) {
                Console console = new Console(command, mailbox);
                long start = System.nanoTime();
                int status = new LinuxVmEngine().run(bios, kernel, new ByteBuffer[] {root,
                        ByteBuffer.allocateDirect(128 * 1024 * 1024),
                        ByteBuffer.allocateDirect(512).asReadOnlyBuffer(), disk}, console, cancelled, 120_000);
                String text = console.framed.output();
                boolean success = status == 0 && Integer.valueOf(0).equals(console.framed.exitCode())
                        && text.contains("DSH_GUEST_HTTPS_OK");
                record(output.resolve("serial.log"), console.raw.toString(StandardCharsets.UTF_8));
                record(output.resolve("output.txt"), text);
                String report = "{\"mode\":\"" + mode + "\",\"nativeStatus\":" + status
                        + ",\"proxyPort\":" + proxyPort
                        + ",\"exitCode\":" + console.framed.exitCode() + ",\"guestHttpsSucceeded\":" + success
                        + ",\"elapsedMs\":" + (System.nanoTime() - start) / 1_000_000
                        + ",\"androidDeviceVerified\":false,\"directoryFsyncVerified\":false}";
                record(output.resolve("result.json"), report + "\n");
                System.out.println(report);
                if (mode.equals("live")) {
                    if (!success) throw new AssertionError("Guest HTTPS did not succeed");
                } else if (mode.equals("revoked")) {
                    if (status != 2 || console.framed.exitCode() != null || !cancelled.get()
                            || text.contains("DSH_GUEST_HTTPS_OK")) throw new AssertionError("Guest revocation did not retire VM");
                } else {
                    int expectedStatus = mode.equals("wrong-host") ? 1 : 2;
                    if (status != 0 || !Integer.valueOf(1).equals(console.framed.exitCode())
                            || !text.contains("\"status\":" + expectedStatus + ",\"http\":0") || success)
                        throw new AssertionError("Guest did not receive the expected audited rejection");
                }
            } finally { dnsPool.shutdownNow(); }
        } finally { owner.close(); }
    }
}

/** Separate host classpath adapter; the JNI C symbol remains unchanged. */
final class LinuxVmEngine {
    native int run(ByteBuffer bios, ByteBuffer kernel, ByteBuffer[] disks,
                   LinuxVmNetworkHost.Console console, AtomicBoolean cancelled, long timeoutMs);
}
