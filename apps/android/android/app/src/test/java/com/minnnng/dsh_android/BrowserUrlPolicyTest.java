package com.minnnng.dsh_android;

/** Host policy checks; WebView navigation and renderer teardown need a device. */
public final class BrowserUrlPolicyTest {
    private static void accepted(String input, Integer port, String host, String expected) {
        String actual = BrowserUrlPolicy.parse(input, port, host);
        if (!actual.equals(expected)) throw new AssertionError(input + ": " + actual);
    }
    private static void refused(String input, Integer port, String host) {
        try {
            BrowserUrlPolicy.parse(input, port, host);
            throw new AssertionError("Accepted " + input);
        } catch (IllegalArgumentException expected) {
            // A refusal is the intended policy result.
        }
    }
    public static void main(String[] args) {
        accepted("example.org", 3080, "127.0.0.1", "https://example.org");
        accepted("https://example.org/path?q=1#top", 3080, "127.0.0.1",
            "https://example.org/path?q=1#top");
        accepted("http://example.org:8080/", null, null, "http://example.org:8080/");
        for (String value : new String[] {
            "", "file:///sdcard/private.txt", "content://settings/foo",
            "data:text/html,hello", "javascript:alert(1)", "blob:https://example.org/id",
            "https://user:secret@example.org/", "https://appassets.androidplatform.net/document/",
            "http://127.0.0.1:3080/", "http://localhost:3080/",
            "http://0.0.0.0:3080/", "http://192.168.1.20:3080/",
            "http://192.168.1.20:4040/", "http://10.0.0.1/",
            "https://[::1]/", "http://2130706433/", "localhost:4040",
            "http://printer.local/", "http://server.home.arpa/",
            "http://example.org/%00 bad", "https://example.org/\nother",
        }) refused(value, 3080, "192.168.1.20");
        refused("http://localhost:4040/", null, null);
        refused("http://127.0.0.1:3080/", null, null);
        refused("http://localhost:3080/", 0, null);
        refused("https://example.org/", 3080, "example.org");
    }
}
