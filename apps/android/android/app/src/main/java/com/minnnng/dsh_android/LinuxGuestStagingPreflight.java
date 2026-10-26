package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.util.UUID;

/**
 * Rejects an isolated rootfs stage when the cache is inaccessible or a previous run was left
 * behind. It deliberately does not delete another run's files: a restarted isolated process may
 * have a different UID, and filesystem permissions are never broadened to make cleanup work.
 */
final class LinuxGuestStagingPreflight {
    private static final String RUN_PREFIX = "linux-guest-root-";

    static void requireEmptyWritableParent(Path parent) throws IOException {
        if (parent == null || Files.isSymbolicLink(parent)
                || !Files.isDirectory(parent, LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException("Isolated guest cache is unavailable");
        }
        try (DirectoryStream<Path> stale = Files.newDirectoryStream(parent,
                RUN_PREFIX + "*")) {
            if (stale.iterator().hasNext()) {
                throw new IOException("Previous isolated guest rootfs could not be retired");
            }
        }
        // An empty per-run sibling proves only present ability to create and unlink a directory.
        // It does not prove the Android UID may open files within it or execute the userland.
        Path probe = parent.resolve(RUN_PREFIX + "probe-" + UUID.randomUUID());
        Files.createDirectory(probe);
        Files.delete(probe);
    }

    private LinuxGuestStagingPreflight() {}
}
