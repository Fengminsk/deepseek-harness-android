package com.minnnng.dsh_android;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicBoolean;

/** HTTP CONNECT through an App-selected loopback proxy to one validated public IPv4. */
final class LocalHttpConnectTunnel {
    private LocalHttpConnectTunnel() { }

    // The caller owns socket registration and its deadline closer before entering here.
    static void open(Socket socket, int port, Inet4Address destination, long deadline,
                     AtomicBoolean cancelled) throws IOException {
        if (port < 1 || port > 65535 || !IsolatedNetworkBroker.isPublicIpv4(destination))
            throw new IOException("Invalid local proxy route");
        check(deadline, cancelled);
        socket.connect(new InetSocketAddress(InetAddress.getByAddress(new byte[] {127, 0, 0, 1}),
                port), IsolatedNetworkBroker.PinnedTlsTransport.positiveIoTimeout(deadline));
        String authority = destination.getHostAddress() + ":443";
        byte[] request = ("CONNECT " + authority + " HTTP/1.1\r\nHost: " + authority
                + "\r\n\r\n").getBytes(StandardCharsets.US_ASCII);
        check(deadline, cancelled);
        socket.getOutputStream().write(request);
        socket.getOutputStream().flush();
        InputStream input = socket.getInputStream();
        int[] budget = {8192};
        String status = line(socket, input, deadline, cancelled, budget);
        if (!status.matches("HTTP/1\\.[01] 200(?: [\\x20-\\x7e]*)?"))
            throw new IOException("Local HTTP proxy refused CONNECT");
        for (String header; !(header = line(socket, input, deadline, cancelled, budget)).isEmpty();) {
            int colon = header.indexOf(':');
            if (colon < 1 || !header.substring(0, colon).matches("[!#$%&'*+.^_`|~0-9A-Za-z-]+"))
                throw new IOException("Invalid local proxy header");
            String name = header.substring(0, colon);
            String value = header.substring(colon + 1).trim();
            if (name.equalsIgnoreCase("Transfer-Encoding")
                    || (name.equalsIgnoreCase("Content-Length") && !value.equals("0")))
                throw new IOException("Unexpected local proxy response body");
        }
        check(deadline, cancelled);
    }

    private static void check(long deadline, AtomicBoolean cancelled) throws IOException {
        if (cancelled.get()) throw new IOException("Network capability was revoked");
        IsolatedNetworkBroker.PinnedTlsTransport.positiveIoTimeout(deadline);
    }

    private static String line(Socket socket, InputStream input, long deadline,
                               AtomicBoolean cancelled, int[] budget) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        boolean carriage = false;
        while (true) {
            check(deadline, cancelled);
            socket.setSoTimeout(IsolatedNetworkBroker.PinnedTlsTransport.positiveIoTimeout(deadline));
            if (--budget[0] < 0 || bytes.size() > 4096) throw new IOException("Proxy headers too large");
            int next = input.read();
            if (carriage && next == '\n') return bytes.toString(StandardCharsets.US_ASCII.name());
            if (next < 0 || carriage || next == '\n' || (next < 32 && next != '\r' && next != '\t') || next > 126)
                throw new IOException("Invalid local proxy response");
            if (next == '\r') carriage = true;
            else bytes.write(next);
        }
    }
}
