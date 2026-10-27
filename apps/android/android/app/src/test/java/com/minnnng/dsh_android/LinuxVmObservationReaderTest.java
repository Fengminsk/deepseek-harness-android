package com.minnnng.dsh_android;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicInteger;

public final class LinuxVmObservationReaderTest {
    private static int passed;
    public static void main(String[] args) throws Exception {
        AtomicInteger closes = new AtomicInteger();
        String result = LinuxVmObservationReader.read(() -> bytes("observed", closes), 1000, 1000);
        if (!result.equals("observed") || closes.get() != 1) throw new AssertionError("Normal reader did not close");
        passed++;

        CountDownLatch read = new CountDownLatch(1);
        AtomicInteger blockedCloses = new AtomicInteger();
        InputStream blocked = new InputStream() {
            @Override public int read() { await(read); return -1; }
            @Override public void close() { blockedCloses.incrementAndGet(); read.countDown(); }
        };
        refuses(() -> LinuxVmObservationReader.read(() -> blocked, 50, 1000), "cleanup confirmed");
        if (blockedCloses.get() != 1) throw new AssertionError("Timed-out reader descriptor was not closed once");

        CountDownLatch open = new CountDownLatch(1);
        AtomicInteger lateCloses = new AtomicInteger();
        Thread release = new Thread(() -> { try { Thread.sleep(150); } catch (InterruptedException error) {
            throw new AssertionError(error); } open.countDown(); });
        release.start();
        try {
            refuses(() -> LinuxVmObservationReader.read(() -> { await(open); return bytes("late", lateCloses); },
                    20, 1000), "cleanup confirmed");
            if (lateCloses.get() != 1) throw new AssertionError("Late descriptor was not closed");
        } finally { open.countDown(); release.join(); }

        refuses(() -> LinuxVmObservationReader.read(() -> new ByteArrayInputStream(new byte[2 * 1024 * 1024 + 1]),
                1000, 1000), "cleanup confirmed");
        refuses(() -> LinuxVmObservationReader.read(() -> { throw new IOException("dispatch failed"); },
                1000, 1000), "cleanup confirmed");
        refuses(() -> LinuxVmObservationReader.read(() -> new ByteArrayInputStream(new byte[0]) {
            @Override public void close() throws IOException { throw new IOException("close failed"); }
        }, 1000, 1000), "close is unconfirmed");

        // A dispatch which ignores interruption beyond the join bound remains unknown.
        CountDownLatch stalled = new CountDownLatch(1), lateClosed = new CountDownLatch(1);
        try {
            refuses(() -> LinuxVmObservationReader.read(() -> { await(stalled); return new ByteArrayInputStream(new byte[0]) {
                @Override public void close() { lateClosed.countDown(); }
            }; }, 20, 20), "retirement is unconfirmed");
        } finally {
            stalled.countDown();
            if (!lateClosed.await(2, java.util.concurrent.TimeUnit.SECONDS)) throw new AssertionError("Unconfirmed late descriptor leaked");
        }
        CountDownLatch allowClose = new CountDownLatch(1), finishRead = new CountDownLatch(1), didClose = new CountDownLatch(1);
        try {
            refuses(() -> LinuxVmObservationReader.read(() -> new InputStream() {
                @Override public int read() { await(finishRead); return -1; }
                @Override public void close() { await(allowClose); finishRead.countDown(); didClose.countDown(); }
            }, 20, 20), "retirement is unconfirmed");
        } finally {
            allowClose.countDown();
            if (!didClose.await(2, java.util.concurrent.TimeUnit.SECONDS)) throw new AssertionError("Descriptor closer did not finish");
        }
        System.out.println("LinuxVmObservationReader: " + passed + " actual-thread host checks passed; Android pipe behavior unverified");
    }
    private interface Checked { void run() throws Exception; }
    private static void refuses(Checked action, String detail) throws Exception {
        try { action.run(); throw new AssertionError("Failed observation accepted"); }
        catch (IOException expected) {
            if (!expected.getMessage().contains(detail)) throw new AssertionError(expected);
            passed++;
        }
    }
    private static InputStream bytes(String value, AtomicInteger closes) {
        return new ByteArrayInputStream(value.getBytes(java.nio.charset.StandardCharsets.UTF_8)) {
            @Override public void close() { closes.incrementAndGet(); }
        };
    }
    private static void await(CountDownLatch latch) {
        boolean interrupted = false;
        while (true) try { latch.await(); break; }
        catch (InterruptedException ignored) { interrupted = true; }
        if (interrupted) Thread.currentThread().interrupt();
    }
}
