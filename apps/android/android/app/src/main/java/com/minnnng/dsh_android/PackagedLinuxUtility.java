package com.minnnng.dsh_android;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.util.List;

/** Resolves the fixed candidate executable only from Android's installed native library directory. */
final class PackagedLinuxUtility {
    static final String EXECUTABLE_NAME = "libpocket_linux_utility.so";

    static List<String> argv(IsolatedLinuxCommandPolicy.Request request, String nativeLibraryDir)
            throws IOException {
        String mode;
        switch (request.command) {
            case SHA256: mode = "sha256"; break;
            case COUNT_BYTES:
            case TEST_PACKAGED_COUNT_BYTES: mode = "count_bytes"; break;
            case COUNT_LINES: mode = "count_lines"; break;
            default: mode = null;
        }
        if (mode == null) {
            return request.argv();
        }
        if (nativeLibraryDir == null || nativeLibraryDir.isEmpty()) {
            throw new IOException("Installed native library directory unavailable");
        }
        File directory = new File(nativeLibraryDir);
        if (!directory.isAbsolute() || !directory.isDirectory()) {
            throw new IOException("Installed native library directory rejected");
        }
        File executable = new File(directory, EXECUTABLE_NAME);
        if (Files.isSymbolicLink(executable.toPath()) ||
                !executable.getCanonicalFile().getParentFile().equals(directory.getCanonicalFile()) ||
                !executable.isFile() || !executable.canExecute()) {
            throw new IOException("APK-packaged candidate executable unavailable");
        }
        return AndroidJava28.listOf(executable.getCanonicalPath(), mode);
    }

    private PackagedLinuxUtility() { }
}
