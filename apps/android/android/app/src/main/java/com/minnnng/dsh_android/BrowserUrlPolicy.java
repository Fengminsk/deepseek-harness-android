package com.minnnng.dsh_android;

import java.net.URI;
import java.net.URISyntaxException;
import java.util.Locale;

/** Direct addresses handed to an external browser exclude application/device-local origins. */
public final class BrowserUrlPolicy {
    private BrowserUrlPolicy() {}
    public static final int MAX_LENGTH = 16 * 1024;

    public static String parse(String input, Integer applicationPort, String applicationHost) {
        if (input == null) throw new IllegalArgumentException("empty");
        String value = input.trim();
        if (value.isEmpty()) throw new IllegalArgumentException("empty");
        if (value.length() > MAX_LENGTH || value.chars().anyMatch(c -> c <= 0x20 || c == 0x7f))
            throw new IllegalArgumentException("invalid");
        boolean explicit = value.matches("(?s)^[A-Za-z][A-Za-z0-9+.-]*:(?![0-9]+(?:[/?#]|$)).*");
        String candidate = explicit ? value : "https://" + value;
        try {
            URI uri = new URI(candidate).normalize();
            String scheme = uri.getScheme();
            if (!"http".equalsIgnoreCase(scheme) && !"https".equalsIgnoreCase(scheme))
                throw new IllegalArgumentException("protocol");
            if (uri.getRawUserInfo() != null) throw new IllegalArgumentException("credentials");
            String host = uri.getHost();
            if (host == null || host.isBlank()) throw new IllegalArgumentException("invalid");
            String normalizedHost = host.toLowerCase(Locale.ROOT).replaceFirst("[.]+$", "");
            // No in-process WebView loads remote content: Custom Tabs owns redirects.
            // Reject direct local/numeric authorities even when the listener is disabled.
            boolean local = normalizedHost.equals("localhost")
                || normalizedHost.endsWith(".localhost")
                || normalizedHost.endsWith(".local")
                || normalizedHost.endsWith(".lan")
                || normalizedHost.endsWith(".internal")
                || normalizedHost.endsWith(".home.arpa")
                || normalizedHost.equals("localdomain")
                || normalizedHost.endsWith(".localdomain")
                || normalizedHost.matches("[0-9.]+")
                || normalizedHost.matches("(?i)0x[0-9a-f]+")
                || normalizedHost.contains(":");
            boolean appHost = applicationHost != null
                && normalizedHost.equals(applicationHost.toLowerCase(Locale.ROOT));
            if (normalizedHost.equals("appassets.androidplatform.net") || local || appHost)
                throw new IllegalArgumentException("application-origin");
            return uri.toASCIIString();
        } catch (URISyntaxException failure) {
            throw new IllegalArgumentException("invalid", failure);
        }
    }
}
