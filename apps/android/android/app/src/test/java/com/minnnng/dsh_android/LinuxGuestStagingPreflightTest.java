package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.UUID;

/** Host check that a previous run blocks publication without deleting its data. */
public final class LinuxGuestStagingPreflightTest {
    public static void main(String[] args) throws Exception {
        Path cache = Paths.get(System.getProperty("dsh.test.cache")).toRealPath();
        Path root = Files.createTempDirectory(cache, "linux-stage-preflight-");
        Path unrelated = root.resolve("ordinary-cache-file");
        Path stale = root.resolve("linux-guest-root-" + UUID.randomUUID());
        try {
            LinuxGuestStagingPreflight.requireEmptyWritableParent(root);
            try (var files = Files.list(root)) {
                if (files.findAny().isPresent()) throw new AssertionError("Probe was not removed");
            }
            Files.createFile(unrelated);
            LinuxGuestStagingPreflight.requireEmptyWritableParent(root);
            Files.createDirectory(stale);
            reject(root);
            if (!Files.isDirectory(stale)) throw new AssertionError("Stale run was erased");
            Files.delete(stale);
            LinuxGuestStagingPreflight.requireEmptyWritableParent(root);
            reject(root.resolve("missing"));
        } finally {
            Files.deleteIfExists(stale);
            Files.deleteIfExists(unrelated);
            Files.delete(root);
        }
        System.out.println("LinuxGuestStagingPreflightTest passed");
    }

    private static void reject(Path directory) throws Exception {
        try { LinuxGuestStagingPreflight.requireEmptyWritableParent(directory); }
        catch (IOException expected) { return; }
        throw new AssertionError("Unrecoverable guest cache was accepted");
    }
}
