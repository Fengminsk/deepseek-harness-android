package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;

/** Host-only hostile-path and pinned-content checks; never treats fixture bytes as distributable. */
public final class LinuxGuestInstalledElfVerifierTest {
    private static byte[] elf() {
        byte[] bytes = new byte[96];
        bytes[0] = 0x7f; bytes[1] = 'E'; bytes[2] = 'L'; bytes[3] = 'F';
        bytes[4] = 2; bytes[5] = 1; bytes[6] = 1;
        bytes[18] = (byte) 183;
        return bytes;
    }

    private static String sha(byte[] bytes) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
        StringBuilder result = new StringBuilder();
        for (byte value : digest) result.append(String.format("%02x", value & 0xff));
        return result.toString();
    }

    private static void denied(Checked action) throws Exception {
        try { action.run(); }
        catch (IOException | IllegalArgumentException expected) { return; }
        throw new AssertionError("Unsafe ELF provenance was admitted");
    }

    private interface Checked { void run() throws Exception; }

    public static void main(String[] args) throws Exception {
        Path root = Files.createTempDirectory("guest-elf-verifier-").toAbsolutePath();
        Path launcher = root.resolve(LinuxGuestInstalledElfVerifier.LAUNCHER_NAME);
        Path loader = root.resolve(LinuxGuestInstalledElfVerifier.LOADER_NAME);
        byte[] good = elf();
        String pin = sha(good);
        try {
            Files.write(launcher, good);
            Files.write(loader, good);
            var result = LinuxGuestInstalledElfVerifier.verifyPinned(root, pin, pin, false);
            if (!pin.equals(result.launcherSha256()) || !pin.equals(result.loaderSha256()))
                throw new AssertionError("Verified digests differ from installed bytes");
            denied(() -> LinuxGuestInstalledElfVerifier.verify(root));
            denied(() -> LinuxGuestInstalledElfVerifier.verifyPinned(root, "0".repeat(64), pin, false));
            denied(() -> LinuxGuestInstalledElfVerifier.verifyPinned(root, pin, "0".repeat(64), false));

            byte[] changed = good.clone(); changed[32] = 1;
            Files.write(loader, changed);
            denied(() -> LinuxGuestInstalledElfVerifier.verifyPinned(root, pin, pin, false));
            Files.write(loader, good);

            byte[] wrongArch = good.clone(); wrongArch[18] = 3;
            Files.write(launcher, wrongArch);
            denied(() -> LinuxGuestInstalledElfVerifier.verifyPinned(root, sha(wrongArch), pin, false));
            Files.write(launcher, good);
            Files.write(loader, new byte[63]);
            denied(() -> LinuxGuestInstalledElfVerifier.verifyPinned(root, pin, pin, false));
            Files.delete(loader);
            denied(() -> LinuxGuestInstalledElfVerifier.verifyPinned(root, pin, pin, false));

            // A junction/symlink must not let an App-writable file impersonate a package ELF.
            Path outside = Files.createTempFile("guest-elf-outside-", ".so");
            try {
                Files.write(outside, good);
                try {
                    Files.createSymbolicLink(loader, outside);
                    denied(() -> LinuxGuestInstalledElfVerifier.verifyPinned(root, pin, pin, false));
                } catch (UnsupportedOperationException | java.nio.file.FileSystemException unavailable) {
                    // Windows installations may deny unprivileged symlink creation.
                }
            } finally { Files.deleteIfExists(outside); }
            System.out.println("Linux guest installed ELF verifier host checks passed");
        } finally {
            Files.deleteIfExists(loader);
            Files.deleteIfExists(launcher);
            Files.deleteIfExists(root);
        }
    }
}
