package com.minnnng.dsh_android;

import java.net.URI;
import java.util.Set;

/** The packaged document shell alone receives the Session-scoped native bridge. */
public final class DocumentPreviewPolicy {
    public static final String ORIGIN = "https://appassets.androidplatform.net";
    public static final String ENTRY = ORIGIN + "/document/index.html";
    private DocumentPreviewPolicy() {}

    public static boolean trustedOrigin(String value, boolean mainFrame) {
        return mainFrame && ORIGIN.equals(value);
    }

    public static boolean asset(String value) {
        try {
            URI uri = URI.create(value);
            if (!"https".equals(uri.getScheme()) || !"appassets.androidplatform.net".equals(uri.getHost())
                    || uri.getPort() != -1 || uri.getUserInfo() != null || uri.getQuery() != null) return false;
            String path = uri.getPath();
            if (path == null || !path.startsWith("/document/") || path.contains("\\") || path.indexOf('\0') >= 0) return false;
            for (String segment : path.split("/")) if (segment.equals(".") || segment.equals("..")) return false;
            return !path.substring("/document/".length()).isEmpty();
        } catch (IllegalArgumentException failure) { return false; }
    }

    public static boolean callable(String namespace, String method) {
        return namespace.equals("workspaceFiles") && Set.of("stat", "read", "readBytes", "list").contains(method)
            || namespace.equals("officeToPdf") && Set.of("render", "generation").contains(method);
    }

    public static boolean external(String value) {
        if (value == null || value.length() > 8192) return false;
        try {
            URI uri = URI.create(value);
            return ("https".equalsIgnoreCase(uri.getScheme()) || "http".equalsIgnoreCase(uri.getScheme()))
                && uri.getHost() != null && !uri.getHost().isEmpty() && uri.getUserInfo() == null
                && uri.getPort() >= -1 && uri.getPort() <= 65535;
        } catch (IllegalArgumentException failure) { return false; }
    }

    public static boolean identity(String value) {
        return value != null && !value.isEmpty() && value.length() <= 96
            && value.chars().allMatch(c -> c >= 33 && c <= 126);
    }
}
