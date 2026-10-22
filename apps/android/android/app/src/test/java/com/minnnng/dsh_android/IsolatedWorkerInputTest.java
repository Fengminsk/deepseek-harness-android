package com.minnnng.dsh_android;

import java.io.ByteArrayInputStream;
import java.io.IOException;

public final class IsolatedWorkerInputTest {
    public static void main(String[] args) throws Exception {
        var empty = IsolatedWorkerInput.digest(new ByteArrayInputStream(new byte[0]));
        check(empty.bytes() == 0, "empty descriptor length");
        check(empty.sha256().equals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"), "empty digest");
        byte[] limit = new byte[IsolatedWorkerInput.MAX_BYTES];
        var exact = IsolatedWorkerInput.digest(new ByteArrayInputStream(limit));
        check(exact.bytes() == limit.length && exact.sha256().length() == 64, "exact limit rejected");
        rejects(new byte[IsolatedWorkerInput.MAX_BYTES + 1]);
        Thread.currentThread().interrupt();
        try { rejects(new byte[1]); }
        finally { Thread.interrupted(); }
        System.out.println("IsolatedWorkerInput: empty, exact limit, overflow and interruption passed");
    }

    private static void rejects(byte[] input) throws Exception {
        try { IsolatedWorkerInput.digest(new ByteArrayInputStream(input)); }
        catch (IOException expected) { return; }
        throw new AssertionError("worker input unexpectedly accepted");
    }

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
}
