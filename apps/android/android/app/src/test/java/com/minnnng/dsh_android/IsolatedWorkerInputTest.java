package com.minnnng.dsh_android;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

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
        check(IsolatedWorkerInput.readUtf8(new ByteArrayInputStream("中文\r\ntext".getBytes(StandardCharsets.UTF_8))).equals("中文\r\ntext"), "UTF-8 round trip");
        check(IsolatedWorkerInput.readUtf8(new ByteArrayInputStream(new byte[IsolatedWorkerInput.MAX_TEXT_BYTES])).length() == IsolatedWorkerInput.MAX_TEXT_BYTES, "exact text limit rejected");
        rejectsText(new byte[IsolatedWorkerInput.MAX_TEXT_BYTES + 1]);
        rejectsText(new byte[] {(byte) 0xc3, (byte) 0x28});
        Thread.currentThread().interrupt();
        try { rejectsText(new byte[1]); }
        finally { Thread.interrupted(); }
        System.out.println("IsolatedWorkerInput: descriptor digest, strict UTF-8, limits and interruption passed");
    }

    private static void rejectsText(byte[] input) throws Exception {
        try { IsolatedWorkerInput.readUtf8(new ByteArrayInputStream(input)); }
        catch (IOException expected) { return; }
        throw new AssertionError("worker text unexpectedly accepted");
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
