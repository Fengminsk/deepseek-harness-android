package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Arrays;

/**
 * App-side preflight for the two package-installed arm64 ELF candidates. This does not launch
 * either executable: the native supervisor must independently verify its own opened descriptors.
 */
final class LinuxGuestInstalledElfVerifier {
    static final String LAUNCHER_NAME = "libdsh_proot_candidate.so";
    static final String LOADER_NAME = "libdsh_proot_loader_candidate.so";
    static final String LAUNCHER_SHA256 =
            "c22cdb13c5de4b6e0022f7ede7a5ca0bf88675d4b674aa339a885b96d8b26f7f";
    static final String LOADER_SHA256 =
            "c5e85afb7599bd82f2419fb054d597514d5c9578954288bef0c5320cd8b63fbf";
    private static final long MAX_ELF_BYTES = 64L * 1024 * 1024;

    static final class Verified {
        private final String launcherSha256;
        private final String loaderSha256;

        private Verified(String launcherSha256, String loaderSha256) {
            this.launcherSha256 = launcherSha256;
            this.loaderSha256 = loaderSha256;
        }

        String launcherSha256() { return launcherSha256; }
        String loaderSha256() { return loaderSha256; }
    }

    private LinuxGuestInstalledElfVerifier() { }

    /** Requires a package-owned native library directory, never an App-writable staging path. */
    static Verified verify(Path nativeLibraryDir) throws IOException {
        return verifyPinned(nativeLibraryDir, LAUNCHER_SHA256, LOADER_SHA256, true);
    }

    /** Synthetic digest fixture; package-private so host tests can exercise the same file checks. */
    static Verified verifyPinned(Path nativeLibraryDir, String launcherPin,
                                 String loaderPin, boolean requireReadOnly) throws IOException {
        if (nativeLibraryDir == null || !nativeLibraryDir.isAbsolute()
                || !validDigest(launcherPin) || !validDigest(loaderPin))
            throw new IllegalArgumentException("Pinned native library directory and digests required");
        Path root = nativeLibraryDir.normalize();
        BasicFileAttributes directory = Files.readAttributes(root, BasicFileAttributes.class,
                LinkOption.NOFOLLOW_LINKS);
        if (!directory.isDirectory() || directory.isSymbolicLink()
                || (requireReadOnly && Files.isWritable(root)))
            throw new IOException("Native library directory is not a read-only real directory");
        String launcher = inspect(root, LAUNCHER_NAME, launcherPin, requireReadOnly);
        String loader = inspect(root, LOADER_NAME, loaderPin, requireReadOnly);
        return new Verified(launcher, loader);
    }

    private static String inspect(Path root, String name, String expected,
                                  boolean requireReadOnly) throws IOException {
        Path file = root.resolve(name);
        if (!file.getParent().equals(root)) throw new IOException("Executable escaped package directory");
        BasicFileAttributes before = Files.readAttributes(file, BasicFileAttributes.class,
                LinkOption.NOFOLLOW_LINKS);
        if (!before.isRegularFile() || before.isSymbolicLink()
                || before.size() < 64 || before.size() > MAX_ELF_BYTES
                || (requireReadOnly && (Files.isWritable(file) || !Files.isExecutable(file))))
            throw new IOException("Installed guest candidate is not a read-only executable ELF");
        MessageDigest hash;
        try { hash = MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException impossible) { throw new IllegalStateException(impossible); }
        long total = 0;
        byte[] header = new byte[20];
        try (FileChannel channel = FileChannel.open(file, StandardOpenOption.READ,
                LinkOption.NOFOLLOW_LINKS)) {
            ByteBuffer buffer = ByteBuffer.allocate(16 * 1024);
            int headerLength = 0;
            while (channel.read(buffer) != -1) {
                buffer.flip();
                int count = buffer.remaining();
                total += count;
                if (total > MAX_ELF_BYTES) throw new IOException("Installed guest ELF grew beyond limit");
                int copy = Math.min(count, header.length - headerLength);
                buffer.get(header, headerLength, copy);
                headerLength += copy;
                buffer.position(0);
                hash.update(buffer);
                buffer.clear();
            }
            if (total != before.size() || headerLength < header.length || !arm64Elf(header))
                throw new IOException("Installed guest candidate is not the pinned arm64 ELF");
            BasicFileAttributes after = Files.readAttributes(file, BasicFileAttributes.class,
                    LinkOption.NOFOLLOW_LINKS);
            if (!after.isRegularFile() || after.size() != before.size()
                    || !after.lastModifiedTime().equals(before.lastModifiedTime())
                    || (before.fileKey() != null && !before.fileKey().equals(after.fileKey())))
                throw new IOException("Installed guest candidate changed during verification");
        }
        String actual = hex(hash.digest());
        if (!expected.equals(actual)) throw new IOException("Installed guest ELF digest mismatch");
        return actual;
    }

    private static boolean arm64Elf(byte[] h) {
        return Arrays.equals(Arrays.copyOf(h, 4), new byte[]{0x7f, 'E', 'L', 'F'})
                && h[4] == 2 && h[5] == 1 && h[6] == 1
                && (h[18] & 0xff) == 183 && h[19] == 0;
    }

    private static boolean validDigest(String value) {
        return value != null && value.matches("[0-9a-f]{64}");
    }

    private static String hex(byte[] bytes) {
        char[] chars = "0123456789abcdef".toCharArray();
        StringBuilder out = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) {
            out.append(chars[(value >>> 4) & 15]);
            out.append(chars[value & 15]);
        }
        return out.toString();
    }
}
