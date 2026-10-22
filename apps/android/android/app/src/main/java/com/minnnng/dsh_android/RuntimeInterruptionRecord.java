package com.minnnng.dsh_android;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.util.List;

/** The last service interruption, without task input, output, paths, or exception text. */
public final class RuntimeInterruptionRecord {
    public static final String RUNTIME_LOST = "runtime-lost";
    public static final String SERVICE_TIMEOUT = "service-timeout";
    private static final String NAME = "agent-interruption-v1";

    public final String kind;
    public final long timeMillis;

    private RuntimeInterruptionRecord(String kind, long timeMillis) {
        this.kind = kind;
        this.timeMillis = timeMillis;
    }

    /** Synchronously replaces the prior App-private receipt before the service process exits. */
    public static void write(File directory, String kind, long timeMillis) throws IOException {
        if (!valid(kind) || timeMillis <= 0) throw new IllegalArgumentException("Invalid interruption");
        File temporary = File.createTempFile(NAME + "-", ".tmp", directory);
        boolean committed = false;
        try {
            byte[] bytes = ("1\n" + kind + "\n" + timeMillis + "\n").getBytes(StandardCharsets.UTF_8);
            try (FileOutputStream stream = new FileOutputStream(temporary)) {
                stream.write(bytes);
                stream.getFD().sync();
            }
            Files.move(temporary.toPath(), new File(directory, NAME).toPath(),
                    StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            committed = true;
        } finally {
            if (!committed) Files.deleteIfExists(temporary.toPath());
        }
    }

    /** Missing means no known interruption; corrupt records require an explicit read error. */
    public static RuntimeInterruptionRecord read(File directory) throws IOException {
        File file = new File(directory, NAME);
        if (!file.exists()) return null;
        if (file.length() > 64) throw new IOException("Invalid interruption receipt");
        List<String> lines = Files.readAllLines(file.toPath(), StandardCharsets.UTF_8);
        if (lines.size() != 3 || !"1".equals(lines.get(0)) || !valid(lines.get(1))) {
            throw new IOException("Invalid interruption receipt");
        }
        try {
            long timeMillis = Long.parseLong(lines.get(2));
            if (timeMillis <= 0) throw new IOException("Invalid interruption receipt");
            return new RuntimeInterruptionRecord(lines.get(1), timeMillis);
        } catch (NumberFormatException invalid) {
            throw new IOException("Invalid interruption receipt", invalid);
        }
    }

    private static boolean valid(String kind) {
        return RUNTIME_LOST.equals(kind) || SERVICE_TIMEOUT.equals(kind);
    }
}
