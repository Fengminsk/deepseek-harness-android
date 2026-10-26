package com.minnnng.dsh_android;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.concurrent.TimeUnit;

/** Cold-read evidence for callback-free process death, without any task replay. */
public final class RuntimeProcessLeaseTest {
    private static int checks;
    private static void check(boolean value, String message) {
        checks++;
        if (!value) throw new AssertionError(message);
    }

    public static void main(String[] args) throws Exception {
        if (args.length == 2 && (args[0].equals("--hold") || args[0].equals("--hold-planned"))) {
            File childDirectory = new File(args[1]);
            System.out.println("child-entered");
            RuntimeProcessLease held = RuntimeProcessLease.start(childDirectory, System.currentTimeMillis());
            System.out.println("child-lease-acquired");
            if (args[0].equals("--hold-planned")) held.preparePlannedProcessExit();
            Files.write(new File(childDirectory, "ready").toPath(), new byte[] { 1 });
            Thread.sleep(30_000);
            held.closePlanned();
            return;
        }
        File directory = Files.createTempDirectory("runtime-process-lease-").toFile();
        long start = System.currentTimeMillis() - 10_000;
        try {
            check(RuntimeInterruptionRecord.read(directory) == null,
                    "absent process marker was treated as an interruption");
            RuntimeProcessLease active = RuntimeProcessLease.start(directory, start);
            check(RuntimeInterruptionRecord.read(directory) == null,
                    "live process was mistaken for an orphaned runtime");
            try {
                RuntimeProcessLease.start(directory, start + 1);
                throw new AssertionError("A second process claimed a live runtime lease");
            } catch (IOException | java.nio.channels.OverlappingFileLockException expected) {
                check(true, "unexpected concurrent owner rejection");
            }
            active.close(); // Simulates abrupt OS process death: the kernel releases the lock.
            String marker = new String(Files.readAllBytes(new File(directory, "agent-running-v1").toPath()),
                    StandardCharsets.UTF_8);
            check(marker.equals("1\n" + start + "\n"), "process marker stored more than a start time");
            RuntimeInterruptionRecord orphan = RuntimeInterruptionRecord.read(directory);
            check(orphan != null && orphan.kind.equals(RuntimeInterruptionRecord.RUNTIME_LOST)
                    && orphan.timeMillis > start, "cold read hid a callback-free process death");
            RuntimeProcessLease replacement = RuntimeProcessLease.start(directory, start + 1_000);
            RuntimeInterruptionRecord recovered = RuntimeInterruptionRecord.read(directory);
            check(recovered != null && recovered.kind.equals(RuntimeInterruptionRecord.RUNTIME_LOST),
                    "replacement did not persist the prior process interruption");
            replacement.closePlanned();
            check(RuntimeInterruptionRecord.read(directory).kind.equals(RuntimeInterruptionRecord.RUNTIME_LOST),
                    "planned replacement erased the prior interruption receipt");
            check(!new File(directory, "agent-running-v1").exists(),
                    "planned shutdown retained an active process marker");

            File tornWrite = new File(directory, "agent-running-v1-interrupted.tmp");
            Files.write(tornWrite.toPath(), "1\n".getBytes(StandardCharsets.UTF_8));
            RuntimeProcessLease afterTornWrite = RuntimeProcessLease.start(directory, start + 1_500);
            check(!tornWrite.exists(), "an unpublished marker was not cleaned on the next start");
            check(RuntimeInterruptionRecord.read(directory).kind.equals(RuntimeInterruptionRecord.RUNTIME_LOST),
                    "an unpublished marker changed the prior interruption receipt");
            afterTornWrite.closePlanned();

            RuntimeProcessLease timeout = RuntimeProcessLease.start(directory, start + 2_000);
            RuntimeInterruptionRecord.write(directory, RuntimeInterruptionRecord.SERVICE_TIMEOUT,
                    timeout.interruptionTime(start + 2_001));
            timeout.close();
            check(RuntimeInterruptionRecord.read(directory).kind.equals(RuntimeInterruptionRecord.SERVICE_TIMEOUT),
                    "orphan marker replaced a more specific saved timeout receipt");

            long futureReceipt = System.currentTimeMillis() + 100_000;
            RuntimeInterruptionRecord.write(directory, RuntimeInterruptionRecord.RUNTIME_LOST, futureReceipt);
            RuntimeProcessLease clockRollback = RuntimeProcessLease.start(directory, start + 3_000);
            check(clockRollback.interruptionTime(start + 3_001) > futureReceipt,
                    "wall-clock rollback could hide the next process interruption");
            clockRollback.closePlanned();

            RuntimeInterruptionRecord.write(directory, RuntimeInterruptionRecord.RUNTIME_LOST,
                    Long.MAX_VALUE);
            try {
                RuntimeProcessLease.start(directory, start + 3_000);
                throw new AssertionError("An overflowing receipt admitted a new runtime");
            } catch (IOException expected) { check(true, "unexpected overflowing receipt path"); }

            Files.write(new File(directory, "agent-running-v1").toPath(),
                    "not-a-marker".getBytes(StandardCharsets.UTF_8));
            try {
                RuntimeInterruptionRecord.read(directory);
                throw new AssertionError("Corrupt marker silently became a confirmed interruption");
            } catch (IOException expected) { check(true, "unexpected corrupt marker read path"); }
            try {
                RuntimeProcessLease.start(directory, start + 3_000);
                throw new AssertionError("Corrupt prior lease was overwritten by a new runtime");
            } catch (IOException expected) { check(true, "unexpected corrupt marker startup path"); }
        } finally {
            File[] files = directory.listFiles();
            if (files != null) for (File file : files) Files.delete(file.toPath());
            Files.delete(directory.toPath());
        }
        checkRealProcessDeath();
        checkPlannedProcessExit();
        checkFailedTransitionRetainsInterruption();
        System.out.println("RuntimeProcessLease: " + checks + " checks passed");
    }

    private static void checkFailedTransitionRetainsInterruption() throws Exception {
        File directory = Files.createTempDirectory("runtime-failed-transition-").toFile();
        try {
            RuntimeProcessLease failed = RuntimeProcessLease.start(directory, System.currentTimeMillis());
            RuntimeLifecycle lifecycle = new RuntimeLifecycle();
            check(lifecycle.fail(), "runtime failure did not latch before transition");
            if (lifecycle.closeForProcessExit()) failed.preparePlannedProcessExit();
            check(new File(directory, "agent-running-v1").isFile(),
                    "late transition cleared the failed runtime process marker");
            failed.close();
            RuntimeInterruptionRecord record = RuntimeInterruptionRecord.read(directory);
            check(record != null && record.kind.equals(RuntimeInterruptionRecord.RUNTIME_LOST),
                    "cold read lost a failure followed by a transition callback");
            RuntimeProcessLease replacement = RuntimeProcessLease.start(directory, System.currentTimeMillis());
            check(RuntimeInterruptionRecord.read(directory).kind.equals(RuntimeInterruptionRecord.RUNTIME_LOST),
                    "replacement did not retain the failed runtime interruption receipt");
            replacement.closePlanned();
        } finally {
            File[] files = directory.listFiles();
            if (files != null) for (File file : files) Files.delete(file.toPath());
            Files.delete(directory.toPath());
        }
    }

    private static void checkRealProcessDeath() throws Exception {
        File directory = Files.createTempDirectory("runtime-process-kill-").toFile();
        String java = new File(new File(System.getProperty("java.home"), "bin"),
                System.getProperty("os.name").startsWith("Windows") ? "java.exe" : "java").getPath();
        Process child = new ProcessBuilder(java, "-cp", System.getProperty("java.class.path"),
                RuntimeProcessLeaseTest.class.getName(), "--hold", directory.getPath())
                .redirectErrorStream(true).start();
        try {
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15);
            while (!new File(directory, "ready").isFile() && child.isAlive() && System.nanoTime() < deadline) {
                Thread.sleep(20);
            }
            if (!child.isAlive() || !new File(directory, "ready").isFile()) {
                child.destroyForcibly();
                child.waitFor(5, TimeUnit.SECONDS);
                throw new AssertionError("child did not acquire the real process lease: "
                        + new String(child.getInputStream().readAllBytes(), StandardCharsets.UTF_8));
            }
            check(true, "child lease readiness");
            child.destroyForcibly();
            check(child.waitFor(5, TimeUnit.SECONDS), "terminated child retained the process lease");
            check(new File(directory, "agent-running-v1").isFile(),
                    "a killed runtime lost its durable process marker");
            RuntimeInterruptionRecord inferred = null;
            long lockReleaseDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
            while (inferred == null && System.nanoTime() < lockReleaseDeadline) {
                inferred = RuntimeInterruptionRecord.read(directory);
                if (inferred == null) Thread.sleep(25);
            }
            check(inferred != null && inferred.kind.equals(RuntimeInterruptionRecord.RUNTIME_LOST),
                    "real OS process death was not recognized");
            RuntimeProcessLease restarted = RuntimeProcessLease.start(directory, System.currentTimeMillis());
            check(RuntimeInterruptionRecord.read(directory).kind.equals(RuntimeInterruptionRecord.RUNTIME_LOST),
                    "restart did not persist the process-death receipt");
            restarted.closePlanned();
        } finally {
            if (child.isAlive()) {
                child.destroyForcibly();
                child.waitFor(5, TimeUnit.SECONDS);
            }
            File[] files = directory.listFiles();
            if (files != null) for (File file : files) {
                // Windows can retain a killed JVM's lock-file handle briefly
                // after waitFor reports exit. This affects fixture cleanup only.
                long cleanupDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
                for (;;) {
                    try { Files.delete(file.toPath()); break; }
                    catch (java.nio.file.FileSystemException busy) {
                        if (System.nanoTime() >= cleanupDeadline) throw busy;
                        Thread.sleep(25);
                    }
                }
            }
            Files.delete(directory.toPath());
        }
    }

    private static void checkPlannedProcessExit() throws Exception {
        File directory = Files.createTempDirectory("runtime-planned-exit-").toFile();
        String java = new File(new File(System.getProperty("java.home"), "bin"),
                System.getProperty("os.name").startsWith("Windows") ? "java.exe" : "java").getPath();
        Process child = new ProcessBuilder(java, "-cp", System.getProperty("java.class.path"),
                RuntimeProcessLeaseTest.class.getName(), "--hold-planned", directory.getPath())
                .redirectErrorStream(true).start();
        try {
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15);
            while (!new File(directory, "ready").isFile() && child.isAlive() && System.nanoTime() < deadline) {
                Thread.sleep(20);
            }
            if (!child.isAlive() || !new File(directory, "ready").isFile()) {
                child.destroyForcibly();
                child.waitFor(5, TimeUnit.SECONDS);
                throw new AssertionError("planned child did not retain its lease: "
                        + new String(child.getInputStream().readAllBytes(), StandardCharsets.UTF_8));
            }
            check(!new File(directory, "agent-running-v1").exists(),
                    "planned process exit left a false orphan marker");
            try {
                RuntimeProcessLease.start(directory, System.currentTimeMillis());
                throw new AssertionError("A replacement started while the old process was still alive");
            } catch (IOException | java.nio.channels.OverlappingFileLockException expected) {
                check(true, "unexpected competing process rejection");
            }
            child.destroyForcibly();
            check(child.waitFor(5, TimeUnit.SECONDS), "planned child did not terminate");
            RuntimeProcessLease replacement = null;
            long lockReleaseDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
            while (replacement == null) {
                try { replacement = RuntimeProcessLease.start(directory, System.currentTimeMillis()); }
                catch (IOException busy) {
                    if (!"Another runtime process owns the lease".equals(busy.getMessage())
                            || System.nanoTime() >= lockReleaseDeadline) throw busy;
                    Thread.sleep(25);
                }
            }
            check(RuntimeInterruptionRecord.read(directory) == null,
                    "planned process exit was misreported as an unexpected interruption");
            replacement.closePlanned();
        } finally {
            if (child.isAlive()) {
                child.destroyForcibly();
                child.waitFor(5, TimeUnit.SECONDS);
            }
            File[] files = directory.listFiles();
            if (files != null) for (File file : files) {
                long cleanupDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
                for (;;) {
                    try { Files.delete(file.toPath()); break; }
                    catch (java.nio.file.FileSystemException busy) {
                        if (System.nanoTime() >= cleanupDeadline) throw busy;
                        Thread.sleep(25);
                    }
                }
            }
            Files.delete(directory.toPath());
        }
    }
}
