package com.minnnng.dsh_android;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;

/** Native export source selection and streamed-copy checks independent of a document provider. */
public final class SessionExportFilesTest {
    public static void main(String[] args) throws Exception {
        Path directory = Files.createTempDirectory("pocket-export-files-test-");
        String id = UUID.randomUUID().toString();
        Path source = directory.resolve(id + ".zip");
        byte[] data = new byte[262145];
        for (int index = 0; index < data.length; index++) data[index] = (byte) index;
        Files.write(source, data);
        try {
            var output = new ByteArrayOutputStream();
            long copied = SessionExportFiles.copy(SessionExportFiles.source(directory.toFile(), id), output, () -> false);
            check(copied == data.length && Arrays.equals(data, output.toByteArray()), "copy changed archive bytes");
            rejects(() -> SessionExportFiles.source(directory.toFile(), "../../private"));
            rejects(() -> SessionExportFiles.source(directory.toFile(), UUID.randomUUID().toString()));
            AtomicBoolean cancelled = new AtomicBoolean();
            OutputStream broken = new OutputStream() {
                @Override public void write(int value) throws IOException { throw new IOException("provider rejected write"); }
            };
            rejects(() -> SessionExportFiles.copy(source.toFile(), broken, () -> false));
            OutputStream cancelAfterChunk = new OutputStream() {
                @Override public void write(int value) { cancelled.set(true); }
                @Override public void write(byte[] buffer, int offset, int length) { cancelled.set(true); }
            };
            rejects(() -> SessionExportFiles.copy(source.toFile(), cancelAfterChunk, cancelled::get));
            check(Arrays.equals(data, Files.readAllBytes(source)), "failed save destroyed retry source");
            System.out.println("SessionExportFiles: opaque source IDs, exact ZIP bytes, write failure and cancellation passed");
        } finally {
            Files.deleteIfExists(source);
            Files.delete(directory);
        }
    }
    private interface Checked { void run() throws Exception; }
    private static void rejects(Checked action) throws Exception {
        try { action.run(); } catch (IOException | IllegalArgumentException expected) { return; }
        throw new AssertionError("Expected source or copy failure");
    }
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
