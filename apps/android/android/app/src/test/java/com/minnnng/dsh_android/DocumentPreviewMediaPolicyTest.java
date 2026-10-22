package com.minnnng.dsh_android;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.Map;

/** Host-executable requests and headers; Binder/WebView rendering have separate runtime acceptance. */
public final class DocumentPreviewMediaPolicyTest {
    private static int assertions;
    private static void check(boolean value, String label) {
        assertions++;
        if (!value) throw new AssertionError(label);
    }
    private static String address(String path) {
        return DocumentPreviewPolicy.ORIGIN + DocumentPreviewMediaPolicy.ROUTE + "?path="
            + URLEncoder.encode(path, StandardCharsets.UTF_8).replace("+", "%20");
    }
    private static void refused(String url, String method, int status) {
        try { DocumentPreviewMediaPolicy.parse(url, method); throw new AssertionError("Accepted: " + url); }
        catch (DocumentPreviewMediaPolicy.Rejected failure) { check(failure.status == status, "refusal status: " + url); }
    }
    public static void main(String[] args) {
        String origin = DocumentPreviewPolicy.ORIGIN;
        String route = origin + DocumentPreviewMediaPolicy.ROUTE;
        for (String path : new String[]{"/work/image.png", "/outside/image.svg", "/work/../shared/a.webp",
                "/work/中文 #?&=+%25.png", "/work/percent%2F.png", "/work/�.png"}) {
            var request = DocumentPreviewMediaPolicy.parse(address(path), "GET");
            check(request.path().equals(path), "single decoding preserves path");
            check(!request.head(), "GET body");
        }
        check(DocumentPreviewMediaPolicy.parse(address("/work/image.png"), "HEAD").head(), "HEAD bodyless");
        check(DocumentPreviewMediaPolicy.targetsRoute(address("/a")), "recognize query route");
        check(!DocumentPreviewMediaPolicy.targetsRoute(origin + "/document/index.html"), "assets belong to loader");
        check(!DocumentPreviewMediaPolicy.targetsRoute("%invalid"), "invalid URL is not a media route");
        for (String value : new String[]{route, route + "?", route + "?path=", route + "?other=%2Fa",
                route + "?path=%2Fa&path=%2Fb", route + "?path=%2Fa&owner=x", route + "?path=%2Fa&",
                route + "?path=relative", route + "?path=C%3A%5Cimage.png", route + "?path=%2F%2Fserver%2Ffile",
                route + "?path=%2Fa%00.png", route + "?path=%2Fa%0A.png", route + "?path=%2Fa%7F.png",
                route + "?path=%2Fa%C3%28.png", route + "?path=%2Fa%ZZ.png", address("/" + "a".repeat(8192)),
                route + "?path=%2F" + "%41".repeat(32768)})
            refused(value, "GET", 400);
        for (String value : new String[]{"http://appassets.androidplatform.net/document/api/file?path=%2Fa",
                "https://example.com/document/api/file?path=%2Fa", "https://appassets.androidplatform.net:443/document/api/file?path=%2Fa",
                "https://user@appassets.androidplatform.net/document/api/file?path=%2Fa", route + "?path=%2Fa#fragment",
                origin + "/document/api/%66ile?path=%2Fa", origin + "/document/api/file/extra?path=%2Fa"})
            refused(value, "GET", 403);
        for (String method : new String[]{"POST", "PUT", "DELETE", "get"}) refused(address("/a"), method, 405);
        DocumentPreviewMediaPolicy.requireSize(0, 1);
        DocumentPreviewMediaPolicy.requireSize(20, 20);
        try { DocumentPreviewMediaPolicy.requireSize(21, 20); throw new AssertionError("oversize accepted"); }
        catch (DocumentPreviewMediaPolicy.Rejected failure) { check(failure.status == 413, "inclusive media cap"); }
        for (long[] sizes : new long[][]{{-1, 20}, {1, 0}}) {
            try { DocumentPreviewMediaPolicy.requireSize(sizes[0], sizes[1]); throw new AssertionError("invalid size accepted"); }
            catch (DocumentPreviewMediaPolicy.Rejected failure) { check(failure.status == 502, "invalid size metadata"); }
        }
        for (String mime : new String[]{"image/svg+xml", "text/html", "image/png", "application/octet-stream"}) {
            Map<String, String> headers = DocumentPreviewMediaPolicy.headers(mime, 42L);
            check(headers.get("Content-Type").equals(mime), "MIME is not a permission allowlist");
            check(headers.get("Content-Length").equals("42"), "exact length");
            check(headers.get("Content-Security-Policy").equals("sandbox; default-src 'none'"), "active-content sandbox");
            check(headers.get("X-Content-Type-Options").equals("nosniff"), "no MIME sniffing");
            check(headers.get("Cache-Control").equals("private, no-store"), "no persistent media cache");
        }
        check(!DocumentPreviewMediaPolicy.headers("image/png", null).containsKey("Content-Length"), "unknown HEAD size stays absent");
        try { DocumentPreviewMediaPolicy.headers("image/png\r\nX-Injected: true", 1L); throw new AssertionError("header injection"); }
        catch (DocumentPreviewMediaPolicy.Rejected failure) { check(failure.status == 502, "MIME injection rejected"); }
        check(DocumentPreviewMediaPolicy.statusFor("workspace-file/not-found") == 404, "not found");
        check(DocumentPreviewMediaPolicy.statusFor("FS_SANDBOX_DENIED") == 403, "original fs authority");
        check(DocumentPreviewMediaPolicy.statusFor("workspace-file/not-regular-file") == 403, "directories rejected by original stat");
        check(DocumentPreviewMediaPolicy.statusFor("workspace-file/too-large") == 413, "original read cap");
        check(DocumentPreviewMediaPolicy.statusFor("workspace-files/outside-workspace") == 403, "private root refusal");
        check(DocumentPreviewMediaPolicy.statusFor("workspace-files/file-bytes") == 413, "private preview cap");
        check(DocumentPreviewMediaPolicy.statusFor("gateway/cancelled") == 499, "cancelled");
        check(DocumentPreviewMediaPolicy.statusFor("document-preview/timeout") == 504, "timeout");
        check(DocumentPreviewMediaPolicy.statusFor("document-media/disconnected") == 503, "disconnected");
        check(DocumentPreviewMediaPolicy.statusFor("unrecognized-provider-code") == 500, "unknown failure never disguised as absence");
        System.out.println("Document media policy: " + assertions + " assertions passed");
    }
}
