package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ReadOnlyBufferException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.Comparator;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.CancellationException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/** Host filesystem/JVM tests; Android crash durability additionally needs device evidence. */
public final class LinuxVmBlockStoreTest {
    private static final int BLOCK = LinuxVmBlockStore.BLOCK_BYTES;

    public static void main(String[] args) throws Exception {
        if (args.length == 3 && args[0].equals("child")) {
            child(Path.of(args[1]), args[2]);
            return;
        }
        Path cache = Path.of(".cache/android/linux-vm-block-store-tests").toAbsolutePath();
        Files.createDirectories(cache);
        Path root = Files.createTempDirectory(cache, "run-");
        try {
            baselineAndIncremental(root.resolve("incremental"));
            corruptAndBoundaries(root.resolve("validation"));
            failures(root.resolve("failures"));
            cancelledCapture(root.resolve("cancelled"));
            concurrentStores(root.resolve("threads"));
            concurrentProcesses(root.resolve("processes"));
            System.out.println("Linux VM block store: PASS (incremental, baseline restore, corruption, bounds, readonly, failures, cancellation, two stores, two processes)");
        } finally {
            try (var paths = Files.walk(root)) {
                for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(path);
            }
        }
    }

    private static void baselineAndIncremental(Path directory) throws Exception {
        LinuxVmBlockStore store = new LinuxVmBlockStore(directory.toFile());
        ByteBuffer disk = ByteBuffer.allocate(BLOCK * 3 + 17);
        disk.position(9);
        Map<Integer, String> base = store.hashes(disk.asReadOnlyBuffer());
        check(base.size() == 4 && disk.position() == 9, "hashing must preserve the caller position");
        check(store.capture(disk, base).isEmpty() && blockFiles(directory) == 0, "unchanged disk must not write blocks");
        disk.put(BLOCK + 7, (byte) 42);
        Map<Integer, String> first = store.capture(disk, base);
        check(first.keySet().equals(java.util.Set.of(1)) && blockFiles(directory) == 1, "one dirty block must write once");
        check(store.capture(disk, base).equals(first) && blockFiles(directory) == 1, "identical capture must reuse existing content");
        disk.put(BLOCK * 2 + 3, (byte) 24);
        Map<Integer, String> second = store.capture(disk, base);
        check(second.size() == 2 && blockFiles(directory) == 2, "one additional dirty block must add exactly one file");
        disk.put(BLOCK + 7, (byte) 0);
        Map<Integer, String> reverted = store.capture(disk, base);
        check(!reverted.containsKey(1) && reverted.size() == 1, "reverting to baseline must remove the manifest entry");
        ByteBuffer restored = ByteBuffer.allocate(disk.limit());
        restored.position(5);
        new LinuxVmBlockStore(directory.toFile()).overlay(restored, reverted);
        check(restored.position() == 5 && Arrays.equals(restored.array(), disk.array()), "overlay must restore bytes without moving position");
        disk.put(BLOCK * 3 + 16, (byte) 11);
        Map<Integer, String> tail = store.capture(disk, base);
        check(Files.size(file(directory, tail.get(3))) == 17, "last block must have exact remaining length");
        ByteBuffer output = ByteBuffer.allocate(disk.limit());
        store.overlay(output, tail);
        check(Arrays.equals(disk.array(), output.array()), "partial last block must round-trip");
        ByteBuffer sliced = ByteBuffer.allocate(BLOCK + 40);
        sliced.position(11).limit(BLOCK + 28);
        ByteBuffer slice = sliced.slice();
        Map<Integer, String> sliceBase = store.hashes(slice);
        slice.put(BLOCK + 16, (byte) 7);
        Map<Integer, String> sliceChanges = store.capture(slice, sliceBase);
        check(sliceChanges.keySet().equals(java.util.Set.of(1)), "slice must use its own limit and origin");
    }

    private static void corruptAndBoundaries(Path directory) throws Exception {
        LinuxVmBlockStore store = new LinuxVmBlockStore(directory.toFile());
        ByteBuffer disk = ByteBuffer.allocate(BLOCK + 3);
        Map<Integer, String> base = store.hashes(disk);
        disk.put(1, (byte) 2).put(BLOCK + 2, (byte) 4);
        Map<Integer, String> changes = store.capture(disk, base);
        ByteBuffer target = ByteBuffer.allocate(disk.limit());
        expect(IllegalArgumentException.class, () -> store.overlay(target, Map.of(2, changes.get(0))));
        expect(IllegalArgumentException.class, () -> store.overlay(target, Map.of(-1, changes.get(0))));
        expect(IllegalArgumentException.class, () -> store.overlay(target, Map.of(0, "../other")));
        expect(IllegalArgumentException.class, () -> store.capture(disk, Map.of(0, base.get(0))));
        expect(IOException.class, () -> store.overlay(target, Map.of(1, changes.get(0))));
        expect(ReadOnlyBufferException.class, () -> store.overlay(target.asReadOnlyBuffer(), changes));
        expect(ReadOnlyBufferException.class, () -> store.overlay(target.asReadOnlyBuffer(), Map.of()));
        expect(IllegalArgumentException.class, () -> store.hashes(ByteBuffer.allocate(LinuxVmBlockStore.MAX_BYTES + 1)));
        byte[] tail = Files.readAllBytes(file(directory, changes.get(1)));
        tail[0] ^= 1;
        Files.write(file(directory, changes.get(1)), tail);
        expect(IOException.class, () -> store.overlay(target, changes));
        check(target.get(1) == 0, "validation must discover a corrupt later block before applying the first");
        expect(IOException.class, () -> store.capture(disk, base));
        Files.write(file(directory, changes.get(1)), new byte[4]);
        expect(IOException.class, () -> store.overlay(target, changes));
        check(store.hashes(ByteBuffer.allocate(0)).isEmpty(), "empty buffer has an empty hash map");
        store.overlay(ByteBuffer.allocate(0), Map.of());
    }

    private static void failures(Path directory) throws Exception {
        LinuxVmBlockStore store = new LinuxVmBlockStore(directory.toFile());
        ByteBuffer disk = ByteBuffer.allocate(1);
        Map<Integer, String> base = store.hashes(disk);
        disk.put(0, (byte) 1);
        Files.delete(directory);
        Files.writeString(directory, "occupied");
        expect(IOException.class, () -> store.capture(disk, base));
        check(Files.readString(directory).equals("occupied"), "failed write must preserve the obstructing file");
        expect(IOException.class, () -> new LinuxVmBlockStore(directory.toFile()));
        Files.delete(directory);
        Files.createDirectory(directory);
        Map<Integer, String> expected = store.hashes(disk);
        Files.createDirectory(file(directory, expected.get(0)));
        expect(IOException.class, () -> store.capture(disk, base));
        check(blockFiles(directory) == 0, "invalid existing destination must not become a reported block");
    }

    private static void concurrentStores(Path directory) throws Exception {
        LinuxVmBlockStore first = new LinuxVmBlockStore(directory.toFile());
        LinuxVmBlockStore second = new LinuxVmBlockStore(directory.toFile());
        CountDownLatch start = new CountDownLatch(1);
        AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread one = new Thread(() -> concurrentCapture(first, start, failure));
        Thread two = new Thread(() -> concurrentCapture(second, start, failure));
        one.start(); two.start(); start.countDown();
        one.join(10000); two.join(10000);
        check(!one.isAlive() && !two.isAlive(), "independent stores must finish");
        if (failure.get() != null) throw new AssertionError("concurrent store failure", failure.get());
        check(blockFiles(directory) == 1, "equal concurrent content must deduplicate");
    }

    private static void cancelledCapture(Path directory) throws Exception {
        LinuxVmBlockStore store = new LinuxVmBlockStore(directory.toFile());
        ByteBuffer disk = ByteBuffer.allocate(BLOCK * 3);
        Map<Integer, String> base = store.hashes(disk);
        disk.put(0, (byte) 1).put(BLOCK, (byte) 2).put(BLOCK * 2, (byte) 3);
        AtomicInteger checks = new AtomicInteger();
        AtomicReference<Map<Integer, String>> returned = new AtomicReference<>();
        expect(CancellationException.class, () -> returned.set(store.capture(disk, base,
            () -> checks.incrementAndGet() == 2)));
        check(returned.get() == null && checks.get() == 2, "cancelled capture must not return a manifest");
        check(blockFiles(directory) == 1, "cancellation before the second block may leave only the first orphan");
        Map<Integer, String> complete = store.capture(disk, base);
        check(complete.size() == 3 && blockFiles(directory) == 3, "later capture must safely reuse a prior orphan");
        expect(CancellationException.class, () -> store.capture(ByteBuffer.allocate(0), Map.of(), () -> true));
    }

    private static void concurrentCapture(LinuxVmBlockStore store, CountDownLatch start, AtomicReference<Throwable> failure) {
        try {
            start.await();
            ByteBuffer disk = ByteBuffer.allocate(BLOCK);
            Map<Integer, String> base = store.hashes(disk);
            Arrays.fill(disk.array(), (byte) 93);
            Map<Integer, String> changed = store.capture(disk, base);
            ByteBuffer restored = ByteBuffer.allocate(BLOCK);
            store.overlay(restored, changed);
            check(Arrays.equals(restored.array(), disk.array()), "concurrent snapshot must read back");
        } catch (Throwable error) { failure.compareAndSet(null, error); }
    }

    private static void concurrentProcesses(Path directory) throws Exception {
        Files.createDirectories(directory);
        String java = Path.of(System.getProperty("java.home"), "bin", "java").toString();
        String classpath = System.getProperty("java.class.path");
        Process first = new ProcessBuilder(java, "-cp", classpath, LinuxVmBlockStoreTest.class.getName(), "child", directory.toString(), "one").redirectErrorStream(true).start();
        Process second = new ProcessBuilder(java, "-cp", classpath, LinuxVmBlockStoreTest.class.getName(), "child", directory.toString(), "two").redirectErrorStream(true).start();
        try {
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
            while (!Files.exists(directory.resolve("one.ready")) || !Files.exists(directory.resolve("two.ready"))) {
                if (System.nanoTime() > deadline) throw new AssertionError("child process did not reach barrier");
                Thread.sleep(5);
            }
            Files.writeString(directory.resolve("go"), "go");
            check(first.waitFor(10, TimeUnit.SECONDS) && second.waitFor(10, TimeUnit.SECONDS), "child writers must terminate");
            check(first.exitValue() == 0, "first child failed: " + new String(first.getInputStream().readAllBytes()));
            check(second.exitValue() == 0, "second child failed: " + new String(second.getInputStream().readAllBytes()));
            check(blockFiles(directory) == 1, "independent processes must share one valid content block");
        } finally {
            if (first.isAlive()) first.destroyForcibly().waitFor();
            if (second.isAlive()) second.destroyForcibly().waitFor();
        }
    }

    private static void child(Path directory, String name) throws Exception {
        LinuxVmBlockStore store = new LinuxVmBlockStore(directory.toFile());
        Files.writeString(directory.resolve(name + ".ready"), "ready");
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
        while (!Files.exists(directory.resolve("go"))) {
            if (System.nanoTime() > deadline) throw new AssertionError("parent did not release barrier");
            Thread.sleep(5);
        }
        AtomicReference<Throwable> failure = new AtomicReference<>();
        concurrentCapture(store, new CountDownLatch(0), failure);
        if (failure.get() != null) throw new AssertionError(failure.get());
    }

    private static Path file(Path directory, String checksum) { return directory.resolve("block-" + checksum + ".bin"); }
    private static long blockFiles(Path directory) throws IOException {
        try (var files = Files.list(directory)) {
            return files.filter(path -> path.getFileName().toString().startsWith("block-") && Files.isRegularFile(path)).count();
        }
    }
    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
    private interface Action { void run() throws Exception; }
    private static void expect(Class<? extends Throwable> type, Action action) throws Exception {
        try { action.run(); }
        catch (Throwable error) {
            if (type.isInstance(error)) return;
            throw new AssertionError("Expected " + type.getName(), error);
        }
        throw new AssertionError("Expected " + type.getName());
    }
}
