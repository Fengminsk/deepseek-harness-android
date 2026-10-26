package com.minnnng.dsh_android;

import java.util.UUID;

public final class IsolatedScriptWireTest {
    public static void main(String[] args) {
        String run = UUID.randomUUID().toString();
        String nonce = UUID.randomUUID().toString();
        new IsolatedScriptWire.Request(run, nonce, "(x) => x", "{}", 1000);
        // The App controller, rather than this transport value, chooses the
        // execution class. Binder must carry its bounded workflow deadline.
        new IsolatedScriptWire.Request(run, nonce, "(x) => x", "{}",
                PtcScriptEngine.MAX_WORKFLOW_DEADLINE_MILLIS);
        new IsolatedScriptWire.Reply(run, nonce, PtcScriptEngine.Status.COMPLETED, "{}", null);
        new IsolatedScriptWire.HostRequest(run, nonce, 1, "{}");
        new IsolatedScriptWire.HostReply(run, nonce, 1, "{\"status\":\"OK\"}");
        String escapedRead = "{\"status\":\"OK\",\"read\":{\"revision\":\""
                + "a".repeat(64) + "\",\"text\":\""
                + "\\u0000".repeat(IsolatedWorkerInput.MAX_TEXT_BYTES) + "\"}}";
        if (IsolatedScriptWire.utf8Bytes(escapedRead) <= 128 * 1024)
            throw new AssertionError("Worst-case JSON escape fixture is too small");
        new IsolatedScriptWire.HostReply(run, nonce, 2, escapedRead);
        rejects(() -> new IsolatedScriptWire.Request(run.toUpperCase(), nonce, "(x) => x", "{}", 1000));
        rejects(() -> new IsolatedScriptWire.Request(run, nonce, "(x) => x", "{}", 0));
        rejects(() -> new IsolatedScriptWire.Request(run, nonce, "(x) => x", "{}",
                PtcScriptEngine.MAX_WORKFLOW_DEADLINE_MILLIS + 1));
        rejects(() -> new IsolatedScriptWire.Reply(run, nonce, PtcScriptEngine.Status.COMPLETED, null, null));
        rejects(() -> new IsolatedScriptWire.Reply(run, nonce, PtcScriptEngine.Status.SCRIPT_ERROR, "{}", null));
        rejects(() -> new IsolatedScriptWire.Reply(run, nonce, PtcScriptEngine.Status.SCRIPT_ERROR,
                null, "x".repeat(IsolatedScriptWire.MAX_DETAIL_BYTES + 1)));
        rejects(() -> IsolatedScriptWire.utf8Bytes("\ud800"));
        rejects(() -> new IsolatedScriptWire.HostRequest(run, nonce, 0, "{}"));
        rejects(() -> new IsolatedScriptWire.HostRequest(run, nonce,
                IsolatedScriptWire.MAX_HOST_CALLS + 1, "{}"));
        rejects(() -> new IsolatedScriptWire.HostRequest(run, nonce, 1,
                "x".repeat(PtcScriptEngine.MAX_HOST_REQUEST_BYTES + 1)));
        rejects(() -> new IsolatedScriptWire.HostReply(run, nonce, 1,
                "x".repeat(PtcScriptEngine.MAX_HOST_REPLY_BYTES + 1)));
    }

    private static void rejects(Runnable call) {
        try { call.run(); }
        catch (IllegalArgumentException expected) { return; }
        throw new AssertionError("Invalid isolated script wire value was accepted");
    }
}
