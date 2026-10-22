package com.minnnng.dsh_android;

/** Host-executable boundary checks; actual WebView execution is a separate device gate. */
public final class DocumentPreviewPolicyTest {
    private static void check(boolean value, String label) { if (!value) throw new AssertionError(label); }
    public static void main(String[] args) {
        String origin = DocumentPreviewPolicy.ORIGIN;
        check(DocumentPreviewPolicy.trustedOrigin(origin, true), "packaged main frame");
        check(!DocumentPreviewPolicy.trustedOrigin(origin, false), "same-origin iframe cannot acquire bridge");
        for (String value : new String[]{"null", "file://", "https://example.com", origin + "/", origin + ":443", origin + ".evil"}) {
            check(!DocumentPreviewPolicy.trustedOrigin(value, true), "untrusted bridge: " + value);
        }
        check(DocumentPreviewPolicy.asset(DocumentPreviewPolicy.ENTRY), "entry asset");
        check(DocumentPreviewPolicy.asset(origin + "/document/assets/pdf.worker.js"), "worker asset");
        for (String value : new String[]{
            origin + "/document/../runtime/runtime.zip", origin + "/document/%2e%2e/runtime/runtime.zip",
            origin + "/document/%5c..%5cruntime.zip", origin + "/document/%00secret", origin + "/document/",
            origin + "/runtime/runtime.zip", origin + "/document/index.html?url=file:///data/private",
            "http://appassets.androidplatform.net/document/index.html", "https://attacker@appassets.androidplatform.net/document/index.html",
            "https://appassets.androidplatform.net:443/document/index.html", "file:///android_asset/document-preview/index.html",
            "https://example.com/document/index.html", "blob:" + origin + "/document/index.html",
        }) check(!DocumentPreviewPolicy.asset(value), "untrusted asset: " + value);
        check(DocumentPreviewPolicy.callable("workspaceFiles", "readBytes"), "binary read");
        check(DocumentPreviewPolicy.callable("officeToPdf", "render"), "original conversion");
        for (String namespace : new String[]{"session", "commands", "settings", "credentials", "pluginManager"}) {
            check(!DocumentPreviewPolicy.callable(namespace, "execute"), "no arbitrary namespace");
        }
        check(!DocumentPreviewPolicy.callable("workspaceFiles", "write"), "no mutation");
        check(DocumentPreviewPolicy.external("https://example.com/read?q=1#part"), "external https link");
        check(DocumentPreviewPolicy.external("http://localhost:3080/read"), "external http link");
        for (String value : new String[]{"file:///data/private", "intent://target", "javascript:alert(1)",
                "https:///missing-host", "https://user:secret@example.com/read", "https://example.com:65536", "//example.com"}) {
            check(!DocumentPreviewPolicy.external(value), "invalid external link");
        }
        check(DocumentPreviewPolicy.identity("read-1"), "request identity");
        for (String value : new String[]{"", "with space", "newline\n", "a".repeat(97)}) {
            check(!DocumentPreviewPolicy.identity(value), "invalid identity");
        }
        System.out.println("Document preview origin, asset, operation and frame policy checks passed");
    }
}
