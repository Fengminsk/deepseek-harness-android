package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.UUID;

public final class IsolatedScriptReceiptTest {
    public static void main(String[] args) throws Exception {
        Path root = Files.createTempDirectory("isolated-script-receipt-");
        try {
            IsolatedScriptReceipt receipts = new IsolatedScriptReceipt(root, ignored -> {});
            String completed = UUID.randomUUID().toString();
            receipts.admit(completed);
            refuses(() -> receipts.admit(completed));
            receipts.finish(new IsolatedScriptReceipt.Entry(
                    completed, IsolatedScriptReceipt.State.COMPLETED, "{\"ok\":true}", null));
            if (receipts.read(completed).state() != IsolatedScriptReceipt.State.COMPLETED)
                throw new AssertionError("Completed result was not durable");
            if (!"[]".equals(receipts.read(completed).logsJson()))
                throw new AssertionError("A legacy completion lost its empty logs");
            String logged = UUID.randomUUID().toString();
            receipts.admit(logged);
            receipts.finish(new IsolatedScriptReceipt.Entry(logged,
                    IsolatedScriptReceipt.State.COMPLETED, "{\"ok\":true}",
                    "[\"first 6\",\"second\"]", null));
            if (!"[\"first 6\",\"second\"]".equals(receipts.read(logged).logsJson()))
                throw new AssertionError("Console logs were not durable");
            String versionOne = UUID.randomUUID().toString();
            receipts.admit(versionOne);
            Files.write(root.resolve("isolated-script-runs").resolve(versionOne + ".receipt"),
                    versionOneReceipt(versionOne, "{\"legacy\":true}"));
            IsolatedScriptReceipt.Entry oldCompletion = receipts.read(versionOne);
            if (oldCompletion.state() != IsolatedScriptReceipt.State.COMPLETED
                    || !"{\"legacy\":true}".equals(oldCompletion.outputJson())
                    || !"[]".equals(oldCompletion.logsJson()))
                throw new AssertionError("Version-one receipt did not project empty logs");
            refuses(() -> receipts.finish(new IsolatedScriptReceipt.Entry(
                    completed, IsolatedScriptReceipt.State.CANCELLED, null, null)));

            String interrupted = UUID.randomUUID().toString();
            receipts.admit(interrupted);
            IsolatedScriptReceipt restarted = new IsolatedScriptReceipt(root, ignored -> {});
            if (restarted.recoverInterrupted().size() != 1
                    || restarted.read(interrupted).state() != IsolatedScriptReceipt.State.INTERRUPTED_UNCONFIRMED)
                throw new AssertionError("Startup did not settle an admitted run without replay");
            if (!restarted.recoverInterrupted().isEmpty())
                throw new AssertionError("A recovered run was recovered twice");
            refuses(() -> restarted.admit(interrupted));

            String failedSync = sameBucket(completed);
            IsolatedScriptReceipt unsynced = new IsolatedScriptReceipt(root, ignored -> {
                throw new IOException("injected directory sync failure");
            });
            refuses(() -> unsynced.admit(failedSync));
            refuses(() -> receipts.admit(failedSync));
            if (receipts.recoverInterrupted().size() != 1)
                throw new AssertionError("An uncertain admission was lost");

            Path failedWriteRoot = Files.createDirectory(root.resolve("failed-receipt-write"));
            String failedWriteId = UUID.randomUUID().toString();
            Path failedWriteDirectory = failedWriteRoot.resolve("isolated-script-runs")
                    .resolve(failedWriteId + ".receipt");
            IsolatedScriptReceipt failedWrite = new IsolatedScriptReceipt(failedWriteRoot, directory -> {
                Path ledgerPath = directory.resolve("ledger-" + failedWriteId.substring(0, 2) + ".log");
                if (directory.getFileName().toString().equals("isolated-script-runs")
                        && Files.exists(ledgerPath) && Files.size(ledgerPath) == 12) {
                    Files.createDirectory(failedWriteDirectory);
                }
            });
            refuses(() -> failedWrite.admit(failedWriteId));
            Files.delete(failedWriteDirectory);
            refuses(() -> failedWrite.admit(failedWriteId));
            refuses(() -> new IsolatedScriptReceipt(failedWriteRoot, ignored -> {})
                    .admit(failedWriteId));

            String damaged = UUID.randomUUID().toString();
            receipts.admit(damaged);
            Path file = root.resolve("isolated-script-runs").resolve(damaged + ".receipt");
            Files.write(file, new byte[] { 1, 2, 3 });
            refuses(() -> receipts.read(damaged));
            String following = UUID.randomUUID().toString();
            receipts.admit(following);
            if (receipts.recoverInterrupted().size() != 1
                    || receipts.read(following).state() != IsolatedScriptReceipt.State.INTERRUPTED_UNCONFIRMED)
                throw new AssertionError("Damaged receipt blocked another interrupted run");
            refuses(() -> receipts.admit(damaged));
            String newRun = UUID.randomUUID().toString();
            receipts.admit(newRun);
            receipts.finish(new IsolatedScriptReceipt.Entry(
                    newRun, IsolatedScriptReceipt.State.COMPLETED, "{}", null));

            Path countRoot = Files.createDirectory(root.resolve("count-quota"));
            IsolatedScriptReceipt countQuota = new IsolatedScriptReceipt(
                    countRoot, ignored -> {}, 3, 128L * 1024 * 1024);
            String firstCount = UUID.randomUUID().toString();
            String secondCount = UUID.randomUUID().toString();
            countQuota.admit(firstCount);
            countQuota.admit(secondCount);
            expectsCapacity(() -> countQuota.admit(UUID.randomUUID().toString()));
            if (countQuota.read(firstCount).state() != IsolatedScriptReceipt.State.ADMITTED)
                throw new AssertionError("Over-capacity recovery mutated an admitted run");
            countQuota.finish(new IsolatedScriptReceipt.Entry(
                    firstCount, IsolatedScriptReceipt.State.CANCELLED, null, null));
            String replacement = UUID.randomUUID().toString();
            countQuota.admit(replacement);
            refuses(() -> countQuota.read(firstCount));
            refuses(() -> countQuota.admit(firstCount));
            IsolatedScriptReceipt restartedQuota = new IsolatedScriptReceipt(
                    countRoot, ignored -> {}, 3, 128L * 1024 * 1024);
            refuses(() -> restartedQuota.admit(firstCount));
            if (restartedQuota.recoverInterrupted().size() != 2)
                throw new AssertionError("At-capacity recovery did not settle both active runs");

            Path orphanRoot = Files.createDirectory(root.resolve("orphan-terminal-temp"));
            IsolatedScriptReceipt orphanStore = new IsolatedScriptReceipt(
                    orphanRoot, ignored -> {}, 1, 128L * 1024 * 1024);
            String orphanRun = UUID.randomUUID().toString();
            orphanStore.admit(orphanRun);
            Path orphanDirectory = orphanRoot.resolve("isolated-script-runs");
            Files.write(orphanDirectory.resolve("receipt-crash-a.tmp"), new byte[] { 1 });
            Files.write(orphanDirectory.resolve("receipt-crash-b.tmp"), new byte[] { 2 });
            IsolatedScriptReceipt resumedOrphan = new IsolatedScriptReceipt(
                    orphanRoot, ignored -> {}, 1, 128L * 1024 * 1024);
            if (Files.exists(orphanDirectory.resolve("receipt-crash-a.tmp"))
                    || Files.exists(orphanDirectory.resolve("receipt-crash-b.tmp")))
                throw new AssertionError("Unpublished terminal temp survived restart");
            if (resumedOrphan.recoverInterrupted().size() != 1)
                throw new AssertionError("A crash temp prevented interrupted-run recovery");
            refuses(() -> resumedOrphan.admit(orphanRun));

            Path byteRoot = Files.createDirectory(root.resolve("byte-quota"));
            IsolatedScriptReceipt byteQuota = new IsolatedScriptReceipt(
                    byteRoot, ignored -> {}, 10, 2L * 100 * 1024);
            String largeJson = "\"" + "x".repeat(60_000) + "\"";
            String[] oldIds = new String[2];
            for (int index = 0; index < 2; index++) {
                String runId = UUID.randomUUID().toString();
                oldIds[index] = runId;
                byteQuota.admit(runId);
                byteQuota.finish(new IsolatedScriptReceipt.Entry(
                        runId, IsolatedScriptReceipt.State.COMPLETED, largeJson, null));
            }
            byteQuota.admit(UUID.randomUUID().toString());
            for (String oldId : oldIds) refuses(() -> byteQuota.admit(oldId));

            Path migrationRoot = Files.createDirectory(root.resolve("legacy-migration"));
            IsolatedScriptReceipt oldFormat = new IsolatedScriptReceipt(migrationRoot, ignored -> {});
            String legacyId = UUID.randomUUID().toString();
            oldFormat.admit(legacyId);
            Path oldLedger = migrationRoot.resolve("isolated-script-runs")
                    .resolve("ledger-" + legacyId.substring(0, 2) + ".log");
            Files.delete(oldLedger);
            // Recreate a pre-ledger store: it has a receipt but no migration marker.
            Files.delete(migrationRoot.resolve("isolated-script-runs")
                    .resolve("migration-v1.complete"));
            IsolatedScriptReceipt migrated = new IsolatedScriptReceipt(migrationRoot, ignored -> {}, 1,
                    128L * 1024 * 1024);
            refuses(() -> migrated.admit(legacyId));
            migrated.finish(new IsolatedScriptReceipt.Entry(
                    legacyId, IsolatedScriptReceipt.State.CANCELLED, null, null));
            migrated.admit(UUID.randomUUID().toString());
            refuses(() -> migrated.admit(legacyId));
            refuses(() -> new IsolatedScriptReceipt(migrationRoot, ignored -> {}).admit(legacyId));

            Path damagedMarkerRoot = Files.createDirectory(root.resolve("damaged-migration-marker"));
            new IsolatedScriptReceipt(damagedMarkerRoot, ignored -> {});
            Files.write(damagedMarkerRoot.resolve("isolated-script-runs")
                    .resolve("migration-v1.complete"), new byte[] { 1, 2, 3 });
            refusesCorruption(() -> new IsolatedScriptReceipt(damagedMarkerRoot, ignored -> {}));

            Path ledgerQuotaRoot = Files.createDirectory(root.resolve("ledger-quota"));
            IsolatedScriptReceipt ledgerQuota = new IsolatedScriptReceipt(
                    ledgerQuotaRoot, ignored -> {}, 4, 128L * 1024 * 1024, 12 + 20 * 2);
            String ledgerFirst = UUID.randomUUID().toString();
            String ledgerSecond = sameBucket(ledgerFirst);
            ledgerQuota.admit(ledgerFirst);
            ledgerQuota.finish(new IsolatedScriptReceipt.Entry(
                    ledgerFirst, IsolatedScriptReceipt.State.CANCELLED, null, null));
            ledgerQuota.admit(ledgerSecond);
            expectsCapacity(() -> ledgerQuota.admit(sameBucket(ledgerFirst)));
            refuses(() -> ledgerQuota.admit(ledgerFirst));

            Path stressRoot = Files.createDirectory(root.resolve("compact-ledger-stress"));
            IsolatedScriptReceipt stress = new IsolatedScriptReceipt(
                    stressRoot, ignored -> {}, 4, 128L * 1024 * 1024, 12 + 20 * 256);
            String stressSeed = UUID.randomUUID().toString();
            String[] stressedIds = new String[256];
            long stressStarted = System.nanoTime();
            for (int index = 0; index < stressedIds.length; index++) {
                String runId = sameBucket(stressSeed);
                stressedIds[index] = runId;
                stress.admit(runId);
                stress.finish(new IsolatedScriptReceipt.Entry(
                        runId, IsolatedScriptReceipt.State.CANCELLED, null, null));
            }
            expectsCapacity(() -> stress.admit(sameBucket(stressSeed)));
            refuses(() -> stress.admit(stressedIds[0]));
            IsolatedScriptReceipt stressRestart = new IsolatedScriptReceipt(
                    stressRoot, ignored -> {}, 4, 128L * 1024 * 1024, 12 + 20 * 256);
            refuses(() -> stressRestart.admit(stressedIds[0]));
            refuses(() -> stressRestart.admit(stressedIds[255]));
            System.out.println("256 same-bucket durable admissions with receipt compaction: "
                    + (System.nanoTime() - stressStarted) / 1_000_000 + " ms");

            Path corruptLedgerRoot = Files.createDirectory(root.resolve("damaged-ledger"));
            IsolatedScriptReceipt damagedLedger = new IsolatedScriptReceipt(corruptLedgerRoot, ignored -> {});
            String inDamagedBucket = UUID.randomUUID().toString();
            damagedLedger.admit(inDamagedBucket);
            Path damagedLedgerFile = corruptLedgerRoot.resolve("isolated-script-runs")
                    .resolve("ledger-" + inDamagedBucket.substring(0, 2) + ".log");
            byte[] intactLedger = Files.readAllBytes(damagedLedgerFile);
            Files.write(damagedLedgerFile, new byte[] { 9 }, StandardOpenOption.APPEND);
            refusesCorruption(() -> damagedLedger.admit(sameBucket(inDamagedBucket)));
            IsolatedScriptReceipt tornRestart = new IsolatedScriptReceipt(corruptLedgerRoot, ignored -> {});
            tornRestart.admit(differentBucket(inDamagedBucket));
            intactLedger[intactLedger.length - 1] ^= 1;
            Files.write(damagedLedgerFile, intactLedger, StandardOpenOption.TRUNCATE_EXISTING);
            refusesCorruption(() -> tornRestart.admit(sameBucket(inDamagedBucket)));
            IsolatedScriptReceipt checksumRestart = new IsolatedScriptReceipt(corruptLedgerRoot, ignored -> {});
            checksumRestart.admit(differentBucket(inDamagedBucket));

            Path corruptRoot = Files.createDirectory(root.resolve("corrupt-store"));
            IsolatedScriptReceipt corrupt = new IsolatedScriptReceipt(
                    corruptRoot, ignored -> {}, 2, 128L * 1024 * 1024);
            Files.createDirectory(corruptRoot.resolve("isolated-script-runs").resolve("unexpected"));
            refusesCorruption(() -> corrupt.admit(UUID.randomUUID().toString()));
        } finally {
            // The caller owns this isolated test directory; never remove a project path here.
            try (var files = Files.walk(root)) {
                files.sorted(java.util.Comparator.reverseOrder()).forEach(path -> {
                    try { Files.delete(path); } catch (IOException failure) { throw new RuntimeException(failure); }
                });
            }
        }
    }

    private interface Operation { void run() throws Exception; }

    private static byte[] versionOneReceipt(String runId, String outputJson) throws Exception {
        java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
        try (java.io.DataOutputStream out = new java.io.DataOutputStream(bytes)) {
            out.writeInt(0x44534853);
            out.writeInt(1);
            out.writeUTF(runId);
            out.writeUTF("COMPLETED");
            byte[] output = outputJson.getBytes(java.nio.charset.StandardCharsets.UTF_8);
            out.writeInt(output.length);
            out.write(output);
            out.writeInt(-1);
        }
        byte[] content = bytes.toByteArray();
        byte[] checksum = java.security.MessageDigest.getInstance("SHA-256").digest(content);
        byte[] frame = java.util.Arrays.copyOf(content, content.length + checksum.length);
        System.arraycopy(checksum, 0, frame, content.length, checksum.length);
        return frame;
    }

    private static String sameBucket(String id) {
        return id.substring(0, 2) + UUID.randomUUID().toString().substring(2);
    }

    private static String differentBucket(String id) {
        char first = id.charAt(0) == 'a' ? 'b' : 'a';
        return first + UUID.randomUUID().toString().substring(1);
    }
    private static void refuses(Operation call) throws Exception {
        try { call.run(); }
        catch (IOException expected) { return; }
        throw new AssertionError("Uncertain or duplicate script run was accepted");
    }

    private static void expectsCapacity(Operation call) throws Exception {
        try { call.run(); }
        catch (IsolatedScriptReceipt.CapacityExceededException expected) { return; }
        throw new AssertionError("Receipt capacity was not enforced");
    }

    private static void refusesCorruption(Operation call) throws Exception {
        try { call.run(); }
        catch (IsolatedScriptReceipt.CapacityExceededException wrong) {
            throw new AssertionError("Corruption was reported as capacity", wrong);
        } catch (IOException expected) { return; }
        throw new AssertionError("Corrupt receipt store was accepted");
    }
}
