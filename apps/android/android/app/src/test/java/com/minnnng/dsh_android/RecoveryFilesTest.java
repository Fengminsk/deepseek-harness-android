package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

/** Host checks use real temporary files and inject directory-sync failures at commit boundaries. */
public final class RecoveryFilesTest {
    private static final String PATCH = "profile-patch";
    private static int checks;
    private static Path root;
    private static final class Sync implements RecoveryFiles.SyncDirectory {
        Path fail;
        CountDownLatch reached, release;
        int calls;
        @Override public void sync(Path path) throws IOException {
            calls++;
            if (path.equals(fail)) {
                if (reached != null) {
                    reached.countDown();
                    try { if (!release.await(5, TimeUnit.SECONDS)) throw new IOException("test wait"); }
                    catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new IOException(error); }
                }
                throw new IOException("injected directory sync failure");
            }
            // Android uses Os.fsync on the directory fd. Windows does not expose this
            // through FileChannel; these checks exercise ordering, not power-loss hardware.
        }
    }
    private static RecoveryFiles store(Path base, String generation, Sync sync) throws IOException {
        return new RecoveryFiles(base, generation, sync, (id, text) -> {});
    }
    private static String id() { return UUID.randomUUID().toString(); }
    private static void check(boolean condition, String message) {
        checks++;
        if (!condition) throw new AssertionError(message);
    }
    private interface Checked { void run() throws Exception; }
    private static void rejects(String code, Checked call) throws Exception {
        try { call.run(); throw new AssertionError("Expected " + code); }
        catch (RecoveryFiles.Failure failure) { check(code.equals(failure.code), failure.code); }
    }
    private static Path fresh(String name) throws IOException { return Files.createDirectory(root.resolve(name)); }
    private static Path patch(Path base) { return base.resolve("dsh/profiles/android/cordis.patch.yml"); }
    private static String sha(String text) { return RecoveryFiles.hash(text.getBytes(StandardCharsets.UTF_8)); }

    public static void main(String[] args) throws Exception {
        root = Paths.get(args[0]).toAbsolutePath().normalize();
        missingWriteAndRestore();
        compareAndPreserve();
        uncertainCommitAndRestart();
        journalBeforeTouch();
        repairOnlyAssets();
        fixedPathsAndBounds();
        modesAndLogs();
        serialOwnership();
        rejectionEvidence();
        processOwnedModeQueue();
        System.out.println("RecoveryFiles: " + checks + " checks passed (fixed files, CAS, backup, crash receipts, modes, repair, serialization)");
    }

    private static void missingWriteAndRestore() throws Exception {
        Path base = fresh("missing");
        Sync sync = new Sync();
        RecoveryFiles files = store(base, "g1", sync);
        check(files.read(PATCH).get("sha256").equals("missing"), "missing hash");
        String request = id();
        Map<String, Object> saved = files.write(PATCH, "missing", "locale: 中文\n", request);
        check(saved.get("state").equals("saved"), "save receipt");
        check(Files.readString(patch(base)).equals("locale: 中文\n"), "saved exact text");
        String backup = (String) saved.get("backupId");
        check(files.readBackup(backup).get("exists").equals(false), "absent backup represented");
        check(files.backups().size() == 1, "one backup");
        files.restore(backup, sha("locale: 中文\n"), id());
        check(!Files.exists(patch(base)), "restore absence");
        check(sync.calls > 5, "directory sync points");
    }

    private static void compareAndPreserve() throws Exception {
        Path base = fresh("cas");
        Files.createDirectories(patch(base).getParent());
        String old = "# 原样\ncredential: private-test-marker\n";
        Files.writeString(patch(base), old);
        RecoveryFiles files = store(base, "g1", new Sync());
        rejects("recovery/conflict", () -> files.write(PATCH, "missing", "wrong", id()));
        check(Files.readString(patch(base)).equals(old), "conflict changed source");
        String request = id();
        Map<String, Object> receipt = files.write(PATCH, sha(old), "updated: true\n", request);
        String backup = (String) receipt.get("backupId");
        check(files.readBackup(backup).get("text").equals(old), "backup exact bytes");
        Map<String, Object> repeated = files.write(PATCH, sha(old), "updated: true\n", request);
        check(repeated.get("backupId").equals(backup), "same request replayed");
        check(files.backups().size() == 1, "duplicate backup");
        rejects("recovery/request-conflict", () -> files.write(PATCH, sha(old), "other", request));
        check(!files.operations().toString().contains("private-test-marker"), "journal exposed source text");
        files.restore(backup, sha("updated: true\n"), id());
        check(Files.readString(patch(base)).equals(old), "restore exact bytes");
        check(files.backups().size() == 2, "restore did not preserve replaced content");
    }

    private static void uncertainCommitAndRestart() throws Exception {
        Path base = fresh("unknown");
        Files.createDirectories(patch(base).getParent());
        Files.writeString(patch(base), "old");
        Sync sync = new Sync();
        sync.fail = patch(base).getParent();
        RecoveryFiles files = store(base, "g1", sync);
        String request = id();
        rejects("recovery/write-unconfirmed", () -> files.write(PATCH, sha("old"), "new", request));
        check(Files.readString(patch(base)).equals("new"), "fault did not follow rename");
        check(files.receipt(request).get("state").equals("unknown"), "late failure claimed saved");
        RecoveryFiles replacement = store(base, "g2", new Sync());
        check(replacement.receipt(request).get("state").equals("unknown"), "unknown lost on restart");
        check(replacement.write(PATCH, sha("old"), "new", request).get("state").equals("unknown"), "unknown replayed");
        check(replacement.backups().size() == 1, "unknown created another backup");
    }

    private static void journalBeforeTouch() throws Exception {
        Path base = fresh("pending");
        Files.createDirectories(patch(base).getParent());
        Files.writeString(patch(base), "unchanged");
        Sync sync = new Sync();
        RecoveryFiles files = store(base, "first", sync);
        files.setMode("maintenance", id());
        Files.createDirectories(base.resolve("pocket-recovery/operations"));
        sync.fail = base.resolve("pocket-recovery/operations");
        String request = id();
        try { files.write(PATCH, sha("unchanged"), "would-change", request); throw new AssertionError("missing fault"); }
        catch (IOException expected) { check(Files.readString(patch(base)).equals("unchanged"), "write before durable journal"); }
        check(files.receipt(request).get("state").equals("unknown"), "failed begin still claimed pending in same generation");
        RecoveryFiles replacement = store(base, "replacement", new Sync());
        check(replacement.receipt(request).get("state").equals("unknown"), "old pending reported running");
        check(replacement.write(PATCH, sha("unchanged"), "would-change", request).get("state").equals("unknown"), "pending replayed");
        check(Files.readString(patch(base)).equals("unchanged"), "pending mutated file on read");
    }

    private static void repairOnlyAssets() throws Exception {
        Path base = fresh("repair");
        RecoveryFiles files = store(base, "g", new Sync());
        String hash = sha("runtime");
        Path runtime = base.resolve("runtimes").resolve(hash);
        Files.createDirectories(runtime);
        Files.writeString(runtime.resolve(".complete"), hash);
        Files.createDirectories(base.resolve("dsh/sessions"));
        Files.writeString(base.resolve("dsh/sessions/kept"), "private-history");
        String request = id();
        Map<String, Object> receipt = files.runtimeRepair(hash, request);
        check(receipt.get("state").equals("saved"), "repair receipt");
        check(!Files.exists(runtime), "runtime not quarantined");
        check(Files.readString(base.resolve("dsh/sessions/kept")).equals("private-history"), "repair touched sessions");
        Path quarantine = base.resolve("pocket-recovery/runtime-cache").resolve((String) receipt.get("backupId"));
        check(Files.readString(quarantine.resolve(".complete")).equals(hash), "quarantine removed contents");
        check(files.runtimeRepair(hash, request).get("backupId").equals(receipt.get("backupId")), "repair replayed");
    }

    private static void fixedPathsAndBounds() throws Exception {
        Path base = fresh("limits");
        RecoveryFiles files = store(base, "g", new Sync());
        rejects("recovery/file-invalid", () -> files.read("../sessions"));
        rejects("recovery/request-invalid", () -> files.write(PATCH, "missing", "x", "../escape"));
        rejects("recovery/hash-invalid", () -> files.write(PATCH, "", "x", id()));
        rejects("recovery/too-large", () -> files.write(PATCH, "missing", "x".repeat(RecoveryFiles.MAX_BYTES + 1), id()));
        rejects("recovery/encoding-invalid", () -> files.write(PATCH, "missing", "\ud800", id()));
        Files.createDirectories(patch(base).getParent());
        Files.write(patch(base), new byte[] {(byte) 0xff});
        rejects("recovery/encoding-invalid", () -> files.read(PATCH));
        check(Files.readAllBytes(patch(base))[0] == (byte) 0xff, "bad UTF8 modified");
    }

    private static void modesAndLogs() throws Exception {
        Path base = fresh("mode");
        RecoveryFiles files = store(base, "one", new Sync());
        check(files.mode()[0].equals("active"), "first mode");
        String token = id();
        files.setMode("maintenance", token);
        RecoveryFiles replacement = store(base, "two", new Sync());
        check(Arrays.equals(replacement.mode(), new String[] {"maintenance", token}), "mode cached");
        rejects("recovery/mode-invalid", () -> files.setMode("unknown", id()));
        Files.createDirectories(base.resolve("dsh"));
        String log = "x".repeat(RecoveryFiles.LOG_BYTES + 20) + "END";
        Files.writeString(base.resolve("dsh/runtime-stderr.log"), log);
        Map<String, Object> tail = replacement.log();
        check(tail.get("truncated").equals(true), "tail truncation missing");
        check(((String) tail.get("text")).length() == RecoveryFiles.LOG_BYTES, "log unbounded");
        check(((String) tail.get("text")).endsWith("END"), "wrong log end");
        check(tail.get("private").equals(true), "private log marker");
        Files.writeString(base.resolve("pocket-recovery-mode"), "damaged");
        rejects("recovery/control-damaged", files::mode);
    }

    private static void serialOwnership() throws Exception {
        Path base = fresh("serial");
        Files.createDirectories(patch(base).getParent());
        Files.writeString(patch(base), "old");
        Sync sync = new Sync();
        sync.fail = patch(base).getParent();
        sync.reached = new CountDownLatch(1);
        sync.release = new CountDownLatch(1);
        RecoveryFiles files = store(base, "g", sync);
        ExecutorService pool = Executors.newFixedThreadPool(2);
        AtomicInteger completed = new AtomicInteger();
        try {
            Future<?> writing = pool.submit(() -> {
                try { files.write(PATCH, sha("old"), "new", id()); }
                catch (IOException expected) { completed.incrementAndGet(); }
            });
            check(sync.reached.await(5, TimeUnit.SECONDS), "did not reach commit");
            Future<?> reading = pool.submit(() -> {
                try { files.operations(); completed.incrementAndGet(); }
                catch (IOException error) { throw new RuntimeException(error); }
            });
            check(!reading.isDone(), "read overlapped commit");
            sync.release.countDown();
            writing.get(5, TimeUnit.SECONDS);
            reading.get(5, TimeUnit.SECONDS);
            check(completed.get() == 2, "operation lost on client wait");
        } finally { sync.release.countDown(); pool.shutdownNow(); }
    }

    private static void rejectionEvidence() throws Exception {
        Path base = fresh("rejected");
        RecoveryFiles files = new RecoveryFiles(base, "g", ignored -> {}, (fileId, text) -> {
            if (text.equals("invalid")) throw new RecoveryFiles.Failure("recovery/json-invalid", "Invalid JSON");
        });
        String invalid = id();
        try { files.write("profile-manifest", "missing", "invalid", invalid); throw new AssertionError(); }
        catch (RecoveryFiles.Failure failure) { check(invalid.equals(failure.notStartedRequestId), "invalid JSON has no rejection proof"); }
        String conflict = id();
        try { files.write(PATCH, sha("other"), "draft", conflict); throw new AssertionError(); }
        catch (RecoveryFiles.Failure failure) { check(conflict.equals(failure.notStartedRequestId), "CAS rejection has no proof"); }
        check(files.operations().isEmpty(), "rejections wrote journals");
        String prior = id();
        files.write(PATCH, "missing", "saved", prior);
        try { files.write(PATCH, sha("saved"), "invalid", prior); throw new AssertionError(); }
        catch (RecoveryFiles.Failure failure) { check(failure.notStartedRequestId == null, "existing ID rejected as never started"); }
        check(files.rejection("recovery/generation-conflict", "changed", prior).notStartedRequestId == null, "old request evidence erased");
        String fresh = id();
        check(fresh.equals(files.rejection("recovery/generation-conflict", "changed", fresh).notStartedRequestId), "fresh generation refusal not proved");
        Sync sync = new Sync();
        sync.fail = patch(base).getParent();
        RecoveryFiles failed = store(base, "g", sync);
        try { failed.write(PATCH, sha("saved"), "late failure", id()); throw new AssertionError(); }
        catch (RecoveryFiles.Failure failure) { check(failure.notStartedRequestId == null, "after-rename failure marked not-started"); }
    }

    private static void processOwnedModeQueue() throws Exception {
        Path base = fresh("mode-queue");
        Sync delayed = new Sync();
        delayed.fail = base;
        delayed.reached = new CountDownLatch(1);
        delayed.release = new CountDownLatch(1);
        RecoveryFiles oldActivity = store(base, "old-activity", delayed);
        RecoveryFiles newActivity = store(base, "new-activity", new Sync());
        String oldToken = id(), newToken = id();
        CountDownLatch finished = new CountDownLatch(1);
        RecoveryModeQueue.execute(() -> {
            try { oldActivity.setMode("maintenance", oldToken); } catch (IOException expected) { /* late fsync failure */ }
        });
        check(delayed.reached.await(5, TimeUnit.SECONDS), "mode did not reach fsync");
        RecoveryModeQueue.execute(() -> {
            try { newActivity.setMode("active", newToken); }
            catch (IOException error) { throw new RuntimeException(error); }
            finally { finished.countDown(); }
        });
        // A separate store sees the rename although its writer has not confirmed durability.
        check(Arrays.equals(newActivity.mode(), new String[] {"maintenance", oldToken}), "fresh preference concealed incomplete mode change");
        check(finished.getCount() == 1, "replacement Activity raced old writer");
        delayed.release.countDown();
        check(finished.await(5, TimeUnit.SECONDS), "next mode write lost");
        check(Arrays.equals(newActivity.mode(), new String[] {"active", newToken}), "old Activity overwrote newer mode intent");
    }
}
