package com.minnnng.dsh_android;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.CancellationException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

public final class DocumentTextSearchTest {
    static void check(boolean value, String reason) { if (!value) throw new AssertionError(reason); }
    static byte[] bytes(String text) { return text.getBytes(StandardCharsets.UTF_8); }
    static DocumentTextSearch.Result scan(String text, String query, boolean sensitive) throws IOException {
        return DocumentTextSearch.scan(new ByteArrayInputStream(bytes(text)), query, sensitive, 8_388_608, 200, 600, () -> {});
    }
    static void fails(Class<? extends Throwable> type, Throwing work) throws Exception {
        try { work.run(); } catch (Throwable error) { if (type.isInstance(error)) return; throw error; }
        throw new AssertionError("Expected " + type.getName());
    }
    interface Throwing { void run() throws Exception; }

    public static void main(String[] args) throws Exception {
        byte[] source = bytes("第一行\r\n第二🙂中文命中\r第三行\n末尾命中");
        var oneByte = new ByteArrayInputStream(source) {
            @Override public synchronized int read(byte[] b, int offset, int length) { return super.read(b, offset, Math.min(1, length)); }
        };
        var utf8 = DocumentTextSearch.scan(oneByte, "命中", true, source.length, 200, 600, () -> {});
        check(utf8.matches.size() == 2 && utf8.matches.get(0).lineNumber == 2 && utf8.matches.get(1).lineNumber == 4, "UTF8 and CRLF line numbers");
        check(utf8.bytesRead == source.length && utf8.matches.get(0).line.equals("第二🙂中文命中"), "Byte count and intact text");
        check(scan("abc\nAbC", "ABC", false).matchedLines == 2, "Simple case insensitive match");
        check(scan("abc\nAbC", "ABC", true).matchedLines == 0, "Case sensitive match");
        check(scan("\uD801\uDC28", "\uD801\uDC00", false).matchedLines == 1, "Supplementary letter case conversion");
        check(scan("a.b\naXb", "a.b", true).matchedLines == 1, "Query is literal, not regex");
        check(scan("", "x", true).matchedLines == 0, "Empty file completes");
        check(scan("ends\n", "ends", true).matchedLines == 1, "No duplicate final line");

        var longLine = scan("🙂".repeat(30_000) + "needle" + "尾".repeat(20_000), "needle", true);
        check(longLine.matches.size() == 1 && longLine.matches.get(0).previewTruncated, "Long line reports preview truncation");
        check(longLine.matches.get(0).line.contains("needle") && longLine.matches.get(0).line.length() <= 602, "Match-centered bounded preview");
        var repeated = scan("a".repeat(1_000_000) + "b", "a".repeat(255) + "b", true);
        check(repeated.matchedLines == 1, "Repetitive pattern is matched without whole-line retention");

        fails(DocumentTextSearch.BinaryException.class, () -> scan("needle\nthen\u0000binary", "needle", true));
        byte[] invalid = { 'n', 'e', 'e', 'd', 'l', 'e', '\n', (byte) 0xc3 };
        fails(CharacterCodingException.class, () -> DocumentTextSearch.scan(new ByteArrayInputStream(invalid), "needle", true, 99, 1, 600, () -> {}));
        fails(DocumentTextSearch.LimitException.class, () -> DocumentTextSearch.scan(new ByteArrayInputStream(bytes("needle!")), "needle", true, 6, 1, 600, () -> {}));
        var bounded = DocumentTextSearch.scan(new ByteArrayInputStream(bytes("x\nx\nx")), "x", true, 99, 1, 600, () -> {});
        check(bounded.matches.size() == 1 && bounded.matchedLines == 3, "Retention does not pretend all matched rows fit");
        AtomicBoolean granted = new AtomicBoolean(true);
        var revoke = new ByteArrayInputStream(bytes("needle")) {
            @Override public synchronized int read(byte[] b, int offset, int length) {
                int count = super.read(b, offset, length); granted.set(false); return count;
            }
        };
        fails(SecurityException.class, () -> DocumentTextSearch.scan(revoke, "needle", true, 99, 1, 600, () -> {
            if (!granted.get()) throw new SecurityException("revoked");
        }));

        AtomicInteger providerCancel = new AtomicInteger();
        DocumentSearchJob beforeStart = new DocumentSearchJob(providerCancel::incrementAndGet);
        beforeStart.requestCancel();
        check(!beforeStart.start() && beforeStart.awaitStopped(1), "Cancel before run prevents start");

        CountDownLatch entered = new CountDownLatch(1), released = new CountDownLatch(1);
        AtomicBoolean closed = new AtomicBoolean();
        InputStream blocked = new InputStream() {
            @Override public int read() throws IOException {
                entered.countDown();
                try { released.await(); } catch (InterruptedException error) { throw new IOException(error); }
                throw new IOException("closed");
            }
            @Override public void close() { closed.set(true); released.countDown(); }
        };
        DocumentSearchJob job = new DocumentSearchJob(providerCancel::incrementAndGet);
        check(job.start(), "Search starts");
        AtomicReference<Throwable> outcome = new AtomicReference<>();
        Thread worker = new Thread(() -> {
            try {
                job.attach(blocked);
                DocumentTextSearch.scan(blocked, "x", true, 99, 1, 600, job::check);
            } catch (Throwable error) { outcome.set(error); }
            finally { try { blocked.close(); } catch (IOException ignored) {} job.detach(); job.finish(); }
        });
        worker.start();
        check(entered.await(2, TimeUnit.SECONDS), "Provider reached blocking read");
        check(!job.awaitStopped(1), "Active read is not falsely marked stopped");
        job.requestCancel();
        check(job.awaitStopped(2000), "Cancellation waits for scanning owner termination");
        worker.join(2000);
        check(!worker.isAlive() && closed.get() && outcome.get() instanceof IOException, "Stream closed and worker terminated");
        fails(CancellationException.class, job::check);
        check(providerCancel.get() == 2, "Both cancellations reach provider signal");
        System.out.println("DocumentTextSearch: UTF8/bounds/revocation/cancellation checks passed");
    }
}
