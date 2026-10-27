package com.minnnng.dsh_android;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.Base64;
import java.util.concurrent.atomic.AtomicBoolean;

/** Host-only adapter; the production JNI interpreter and serial framing remain unchanged. */
public final class LinuxVmHost {
    static final class Console {
        private final LinuxVmConsole framed;
        private final ByteArrayOutputStream raw = new ByteArrayOutputStream();
        private final AtomicBoolean cancelled;
        private final boolean cancelOnReady;
        private boolean entered;
        Console(String command, boolean fresh, AtomicBoolean cancelled, boolean cancelOnReady) {
            this(command, fresh, cancelled, cancelOnReady, null);
        }
        Console(String command, boolean fresh, AtomicBoolean cancelled, boolean cancelOnReady, Long startupEpochSeconds) {
            framed = startupEpochSeconds == null ? new LinuxVmConsole(command, true, fresh)
                : new LinuxVmConsole(command, true, fresh, startupEpochSeconds);
            this.cancelled = cancelled; this.cancelOnReady = cancelOnReady;
        }
        synchronized int read(byte[] bytes, int capacity) { return framed.read(bytes, capacity); }
        synchronized void write(byte[] bytes) {
            raw.write(bytes, 0, Math.min(bytes.length, 256 * 1024 - raw.size()));
            framed.write(bytes);
            if (cancelOnReady && framed.output().contains("DSH_HOST_CANCEL_READY\n")) {
                entered = true; cancelled.set(true);
            }
        }
    }

    private static ByteBuffer load(String name, int emptyBytes, boolean readOnly) throws Exception {
        ByteBuffer result;
        if (name.equals("-")) result = ByteBuffer.allocateDirect(emptyBytes);
        else {
            Path path = Path.of(name);
            long size = Files.size(path);
            if (size < 1 || size > 256L * 1024 * 1024) throw new IllegalArgumentException("Host image size is invalid");
            result = ByteBuffer.allocateDirect(Math.toIntExact(size));
            try (FileChannel input = FileChannel.open(path, StandardOpenOption.READ)) {
                while (input.read(result) >= 0) { if (!result.hasRemaining()) break; }
            }
            result.position(0);
        }
        return readOnly ? result.asReadOnlyBuffer() : result;
    }

    private static void save(Path path, ByteBuffer buffer) throws Exception {
        ByteBuffer copy = buffer.duplicate(); copy.clear();
        try (FileChannel output = FileChannel.open(path, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)) {
            while (copy.hasRemaining()) output.write(copy);
            output.force(true);
        }
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 12 && args.length != 13) throw new IllegalArgumentException("Expected library, bios, kernel, root, workspace, input, output, command, directory, fresh, timeout, cancelOnReady, optional startupEpochSeconds");
        System.load(Path.of(args[0]).toAbsolutePath().toString());
        ByteBuffer bios = load(args[1], 0, true), kernel = load(args[2], 0, true);
        ByteBuffer root = load(args[3], 0, false), workspace = load(args[4], 128 * 1024 * 1024, false);
        boolean extra = !args[5].equals("-");
        ByteBuffer input = extra ? load(args[5], 0, true) : null;
        ByteBuffer output = extra ? load(args[6], 128 * 1024 * 1024, false) : null;
        ByteBuffer[] disks = extra ? new ByteBuffer[] {root, workspace, input, output} : new ByteBuffer[] {root, workspace};
        if (!args[9].equals("true") && !args[9].equals("false")) throw new IllegalArgumentException("Invalid workspace freshness");
        AtomicBoolean cancelled = new AtomicBoolean();
        long timeout = Long.parseLong(args[10]);
        if (timeout < 1000 || timeout > 120000 || (!args[11].equals("true") && !args[11].equals("false"))) {
            throw new IllegalArgumentException("Invalid host lifecycle options");
        }
        Long startupEpochSeconds = args.length == 13 ? Long.valueOf(args[12]) : null;
        Console console = new Console(Files.readString(Path.of(args[7]), StandardCharsets.UTF_8), Boolean.parseBoolean(args[9]), cancelled, Boolean.parseBoolean(args[11]), startupEpochSeconds);
        Path directory = Path.of(args[8]); Files.createDirectory(directory);
        long begin = System.nanoTime();
        int status = new LinuxVmEngine().run(bios, kernel, disks, console, cancelled, timeout);
        long elapsed = (System.nanoTime() - begin) / 1_000_000;
        Files.write(directory.resolve("serial.log"), console.raw.toByteArray(), StandardOpenOption.CREATE_NEW);
        Integer exit = console.framed.exitCode();
        boolean completed = status == 0 && exit != null && exit == 0;
        boolean workspaceUnchanged = true;
        if (args[4].equals("-")) {
            ByteBuffer check = workspace.duplicate(); check.clear();
            while (check.hasRemaining()) if (check.get() != 0) { workspaceUnchanged = false; break; }
        } else workspaceUnchanged = false;
        if (completed) {
            save(directory.resolve("root.bin"), root);
            save(directory.resolve("workspace.bin"), workspace);
            if (output != null) save(directory.resolve("extra.bin"), output);
        }
        String report = "{\"nativeStatus\":" + status + ",\"exitCode\":" + exit + ",\"elapsedMs\":" + elapsed +
            ",\"truncated\":" + console.framed.truncated() + ",\"imagesWritten\":" + completed + ",\"cancelAfterGuestEntry\":" + console.entered +
            ",\"freshWorkspaceUnchanged\":" + workspaceUnchanged +
            ",\"outputBase64\":\"" + Base64.getEncoder().encodeToString(console.framed.output().getBytes(StandardCharsets.UTF_8)) + "\"}";
        Files.writeString(directory.resolve("result.json"), report + "\n", StandardOpenOption.CREATE_NEW);
        System.out.println(report);
        if (!completed) System.exit(1);
    }
}

/** The class name and JNI signature bind directly to the unchanged Android C entry. */
final class LinuxVmEngine {
    native int run(ByteBuffer bios, ByteBuffer kernel, ByteBuffer[] disks,
        LinuxVmHost.Console console, AtomicBoolean cancelled, long timeoutMs);
}
