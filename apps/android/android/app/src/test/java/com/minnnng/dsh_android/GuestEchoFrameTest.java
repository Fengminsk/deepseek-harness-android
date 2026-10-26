package com.minnnng.dsh_android;

/** Host-side admission checks for the sole diagnostic guest binding. */
public final class GuestEchoFrameTest {
    public static void main(String[] args) {
        String text = "中文 🌿 \"quote\" \\ slash\nnext";
        String request = GuestEchoFrame.requestForText(text);
        if (!GuestEchoFrame.request(request).equals(text)) throw new AssertionError("Request round trip failed");
        if (!GuestEchoFrame.brokerResult(GuestEchoFrame.brokerResultForText(text)).equals(text)) {
            throw new AssertionError("Broker result round trip failed");
        }
        if (!GuestEchoFrame.completion(GuestEchoFrame.completionForText(text)).equals(text)) {
            throw new AssertionError("Completion round trip failed");
        }
        reject(request.replace("diagnostic.echo", "fs.read"));
        reject(request.replace("\"version\":1", "\"version\":2"));
        reject(request.replace("\"input\"", "\"other\""));
        reject(request.substring(0, request.length() - 1) + ",\"extra\":true}");
        reject(request + " {}");
        reject(request.replace("中文", "\\u4e2d\\u6587"));
        reject(request.replace("next", "\\/next"));
        reject(request.replace("next", "\\uD800"));
        reject(request.replace("next", "\\x41"));
        reject(request.replace("next", "\"injected\":true"));
        reject(GuestEchoFrame.requestForText("a").replace("\"a\"", "100"));
        try {
            GuestEchoFrame.requestForText("x".repeat(GuestEchoFrame.MAX_TEXT_BYTES + 1));
            throw new AssertionError("Oversized guest text accepted");
        } catch (IllegalArgumentException expected) { /* Bounded text. */ }
        try {
            GuestEchoFrame.requestForText("\u0001".repeat(2000));
            throw new AssertionError("Oversized escaped JSON accepted");
        } catch (IllegalArgumentException expected) { /* Bounded Binder frame. */ }
        try {
            GuestEchoFrame.requestForText("\uD800");
            throw new AssertionError("Malformed surrogate accepted");
        } catch (IllegalArgumentException expected) { /* Strict UTF-8. */ }
        try {
            GuestEchoFrame.brokerResult(request);
            throw new AssertionError("Request accepted as broker result");
        } catch (IllegalArgumentException expected) { /* Message kinds are distinct. */ }
    }

    private static void reject(String raw) {
        try {
            GuestEchoFrame.request(raw);
            throw new AssertionError("Invalid guest request accepted: " + raw);
        } catch (IllegalArgumentException expected) { /* Unknown or noncanonical JSON rejected. */ }
    }
}
