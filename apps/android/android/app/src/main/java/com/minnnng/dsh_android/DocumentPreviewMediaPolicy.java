package com.minnnng.dsh_android;

import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Collections;
import java.util.Map;

/** HTTP rules for the original fileMediaUrl route; filesystem permission stays in workspaceFiles. */
public final class DocumentPreviewMediaPolicy {
    public static final String ROUTE = "/document/api/file";
    private DocumentPreviewMediaPolicy() {}

    public record Request(String path, boolean head) {}

    /** A rejected request never reaches the Session transport. */
    public static final class Rejected extends IllegalArgumentException {
        public final int status;
        public Rejected(int status, String message) { super(message); this.status = status; }
    }

    /** Whether this URL names the media route, before validating origin and query. */
    public static boolean targetsRoute(String value) {
        try { return ROUTE.equals(URI.create(value).getPath()); }
        catch (IllegalArgumentException failure) { return false; }
    }

    /** Accept only the URL produced by fileMediaUrl, with one decoded absolute Android path. */
    public static Request parse(String value, String method) {
        final URI uri;
        try { uri = URI.create(value); }
        catch (IllegalArgumentException failure) { throw new Rejected(400, "Invalid media URL"); }
        if (!"https".equals(uri.getScheme()) || !"appassets.androidplatform.net".equals(uri.getHost())
                || uri.getPort() != -1 || uri.getUserInfo() != null || !ROUTE.equals(uri.getRawPath())
                || uri.getRawFragment() != null) throw new Rejected(403, "Unsupported media origin or route");
        if (!"GET".equals(method) && !"HEAD".equals(method)) throw new Rejected(405, "Unsupported media method");
        String query = uri.getRawQuery();
        if (query == null || query.length() > 8192 * 12 || !query.startsWith("path=") || query.indexOf('&') >= 0)
            throw new Rejected(400, "Exactly one path is required");
        String path = decode(query.substring(5));
        if (path.isEmpty() || path.length() > 8192 || !path.startsWith("/") || path.startsWith("//")
                || path.chars().anyMatch(c -> c < 32 || c == 127))
            throw new Rejected(400, "Absolute file path required");
        return new Request(path, "HEAD".equals(method));
    }

    private static String decode(String source) {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream(source.length());
        for (int i = 0; i < source.length();) {
            char value = source.charAt(i);
            if (value == '%') {
                if (i + 2 >= source.length()) throw new Rejected(400, "Invalid path encoding");
                int high = Character.digit(source.charAt(i + 1), 16);
                int low = Character.digit(source.charAt(i + 2), 16);
                if (high < 0 || low < 0) throw new Rejected(400, "Invalid path encoding");
                bytes.write(high * 16 + low);
                i += 3;
            } else {
                int point = source.codePointAt(i);
                byte[] literal = (point == '+' ? " " : new String(Character.toChars(point))).getBytes(StandardCharsets.UTF_8);
                bytes.write(literal, 0, literal.length);
                i += Character.charCount(point);
            }
        }
        try {
            return StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes.toByteArray())).toString();
        } catch (CharacterCodingException failure) { throw new Rejected(400, "Invalid UTF-8 path"); }
    }

    /** Additional display cap from the original attachments.imageLimits.maxImageBytes value. */
    public static void requireSize(long bytes, long maximum) {
        if (maximum < 1 || bytes < 0) throw new Rejected(502, "Invalid media size policy");
        if (bytes > maximum) throw new Rejected(413, "File exceeds byte limit");
    }

    /** Original API isolation headers; MIME labels do not grant or refuse file permission. */
    public static Map<String, String> headers(String mimeType, Long bytes) {
        if (mimeType == null || !mimeType.matches("[A-Za-z0-9][A-Za-z0-9!#$&^_.+\\-]*/[A-Za-z0-9][A-Za-z0-9!#$&^_.+\\-]*"))
            throw new Rejected(502, "Invalid media type");
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("Cache-Control", "private, no-store");
        headers.put("X-Content-Type-Options", "nosniff");
        headers.put("Content-Security-Policy", "sandbox; default-src 'none'");
        headers.put("Content-Type", mimeType);
        if (bytes != null) {
            if (bytes < 0) throw new Rejected(502, "Invalid media length");
            headers.put("Content-Length", Long.toString(bytes));
        }
        return Collections.unmodifiableMap(headers);
    }

    /** Preserve original file refusal statuses and distinguish unavailable transport from absent files. */
    public static int statusFor(String code) {
        return switch (code) {
            case "FS_NOT_FOUND", "workspace-file/not-found" -> 404;
            case "FS_NOT_REGULAR_FILE", "FS_PERMISSION_DENIED", "FS_SANDBOX_DENIED",
                 "workspace-file/not-regular-file", "workspace-file/outside-workspace" -> 403;
            case "FS_TOO_LARGE", "workspace-file/too-large" -> 413;
            case "FS_ABORTED", "gateway/cancelled" -> 499;
            case "gateway/bad-request" -> 400;
            case "document-preview/busy", "document-preview/capacity" -> 429;
            case "document-preview/timeout" -> 504;
            case "gateway/invocation-unavailable", "document-media/disconnected" -> 503;
            default -> 500;
        };
    }
}
