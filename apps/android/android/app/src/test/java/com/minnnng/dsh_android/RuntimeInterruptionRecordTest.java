package com.minnnng.dsh_android;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

/** Host-side private receipt read/write and redaction checks. */
public final class RuntimeInterruptionRecordTest {
    private static int checks;
    private static void check(boolean condition, String message) {
        checks++;
        if (!condition) throw new AssertionError(message);
    }

    public static void main(String[] args) throws Exception {
        File directory = Files.createTempDirectory("agent-interruption-").toFile();
        try {
            check(RuntimeInterruptionRecord.read(directory) == null, "absent record appeared as an interruption");
            RuntimeInterruptionRecord.write(directory, RuntimeInterruptionRecord.RUNTIME_LOST, 1_782_000_000_000L);
            RuntimeInterruptionRecord first = RuntimeInterruptionRecord.read(directory);
            check(first != null && first.kind.equals(RuntimeInterruptionRecord.RUNTIME_LOST)
                    && first.timeMillis == 1_782_000_000_000L, "runtime loss did not survive a cold read");
            String raw = Files.readString(new File(directory, "agent-interruption-v1").toPath());
            check(raw.equals("1\nruntime-lost\n1782000000000\n"), "record carried unexpected task data");
            RuntimeInterruptionRecord.write(directory, RuntimeInterruptionRecord.SERVICE_TIMEOUT, 1_782_000_100_000L);
            RuntimeInterruptionRecord second = RuntimeInterruptionRecord.read(directory);
            check(second != null && second.kind.equals(RuntimeInterruptionRecord.SERVICE_TIMEOUT)
                    && second.timeMillis == 1_782_000_100_000L, "latest interruption did not replace prior receipt");
            try {
                RuntimeInterruptionRecord.write(directory, "arbitrary-error-secret", 1);
                throw new AssertionError("arbitrary exception text was accepted");
            } catch (IllegalArgumentException expected) {
                check(true, "unexpected validation path");
            }
            check(RuntimeInterruptionRecord.read(directory).kind.equals(RuntimeInterruptionRecord.SERVICE_TIMEOUT),
                    "invalid write changed the prior receipt");
            Files.writeString(new File(directory, "agent-interruption-v1").toPath(),
                    "1\nruntime-lost\nunknown\n", StandardCharsets.UTF_8);
            try {
                RuntimeInterruptionRecord.read(directory);
                throw new AssertionError("Torn receipt was presented as confirmed");
            } catch (java.io.IOException expected) {
                check(true, "unexpected corrupt receipt path");
            }
        } finally {
            File[] files = directory.listFiles();
            if (files != null) for (File file : files) check(file.delete(), "temporary test file remained");
            check(directory.delete(), "temporary test directory remained");
        }
        System.out.println("RuntimeInterruptionRecord: " + checks + " checks passed");
    }
}
