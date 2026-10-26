package com.minnnng.dsh_android;

import java.net.IDN;
import java.net.URI;
import java.net.URISyntaxException;
import java.util.Locale;

/**
 * Syntax-only preflight for a future document-resource adapter. It never grants
 * network access: WebView currently returns 403 for every non-packaged URL.
 * In particular, a false isForMainFrame value also describes iframe requests.
 */
public final class DocumentRemoteResourcePolicy {
    public static final int MAX_URL_LENGTH = 8192;
    public static final int MAX_REDIRECTS = 4;
    public static final int MAX_RESOURCE_BYTES = 4 * 1024 * 1024;

    private DocumentRemoteResourcePolicy() {}

    /** A candidate still requires resource-type, network, origin and user-policy checks. */
    public static URI candidate(String value, String method, boolean mainFrame) {
        return !mainFrame && "GET".equals(method) ? httpsUrl(value) : null;
    }

    /** Validate every redirect target before any future transport follows it. */
    public static URI redirect(URI current, String location, int alreadyFollowed) {
        if (current == null || location == null || location.length() > MAX_URL_LENGTH
                || alreadyFollowed >= MAX_REDIRECTS) return null;
        try {
            return httpsUrl(current.resolve(new URI(location)).toString());
        } catch (URISyntaxException | IllegalArgumentException failure) {
            return null;
        }
    }

    private static URI httpsUrl(String value) {
        if (value == null || value.length() > MAX_URL_LENGTH) return null;
        try {
            URI uri = new URI(value);
            String host = uri.getHost();
            if (!"https".equalsIgnoreCase(uri.getScheme()) || host == null
                    || uri.getUserInfo() != null || uri.getRawFragment() != null
                    || uri.getPort() == 0 || uri.getPort() > 65535) return null;
            String ascii = IDN.toASCII(host, IDN.USE_STD3_ASCII_RULES).toLowerCase(Locale.ROOT);
            if (ascii.isEmpty() || ascii.length() > 253 || ascii.endsWith(".")
                    || !ascii.contains(".") || ascii.equals("appassets.androidplatform.net")
                    || ascii.endsWith(".localhost") || ascii.endsWith(".local")
                    || ascii.matches("[0-9.]+") || ascii.contains(":")) return null;
            return uri;
        } catch (URISyntaxException | IllegalArgumentException failure) {
            return null;
        }
    }
}
