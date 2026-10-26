package com.minnnng.dsh_android;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicLong;

/** Standalone host test; production remains pinned to the reviewed Alpine hash. */
public final class LinuxImageLeaseOwnerTest {
    private static void check(boolean value) { if (!value) throw new AssertionError(); }

    private static void rejected(Checked action) {
        try { action.run(); }
        catch (IOException | IllegalArgumentException | IllegalStateException expected) { return; }
        catch (Exception unexpected) { throw new AssertionError(unexpected); }
        throw new AssertionError("Expected an image lease rejection");
    }

    @FunctionalInterface private interface Checked { void run() throws Exception; }

    private static String digest(byte[] input) throws Exception {
        return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(input));
    }

    public static void main(String[] ignored) throws Exception {
        Path installation = Files.createTempDirectory("pocket-linux-image-lease-");
        byte[] original = "verified fixture only".getBytes(StandardCharsets.UTF_8);
        String sha = digest(original);
        Path release = Files.createDirectories(installation.resolve("versions").resolve(sha));
        Path archive = release.resolve("image.tar.gz");
        Files.write(archive, original);
        AtomicLong clock = new AtomicLong(1000);
        try (LinuxImageLeaseOwner owner = new LinuxImageLeaseOwner(
                installation, clock::get, "fixture-1", sha, original.length)) {
            String run = UUID.randomUUID().toString();
            LinuxImageLeaseOwner.Offer offer = owner.issue(run, 1000);
            check(offer.runId().equals(run) && offer.version().equals("fixture-1") &&
                    offer.sha256().equals(sha) && offer.bytes() == original.length);
            rejected(() -> owner.issue(run, 1000));
            rejected(() -> owner.issue("../guest/path", 1000));
            rejected(() -> owner.issue(UUID.randomUUID().toString(), 0));
            rejected(() -> owner.claim(UUID.randomUUID().toString(), offer.token()));
            rejected(() -> owner.claim(run, UUID.randomUUID().toString()));

            // The candidate changed without changing its byte length. Claim
            // cannot reuse the hash checked at issue time.
            byte[] altered = original.clone();
            altered[0] ^= 1;
            Files.write(archive, altered);
            rejected(() -> owner.claim(run, offer.token()));
            rejected(() -> owner.claim(run, offer.token())); // consumed on uncertainty
            Files.write(archive, original);
            rejected(() -> owner.issue(run, 1000)); // same run stays retired

            String valid = UUID.randomUUID().toString();
            LinuxImageLeaseOwner.Offer second = owner.issue(valid, 1000);
            check(owner.claim(valid, second.token()).archive().equals(archive));
            rejected(() -> owner.claim(valid, second.token()));

            String revoked = UUID.randomUUID().toString();
            LinuxImageLeaseOwner.Offer third = owner.issue(revoked, 1000);
            owner.revoke(revoked);
            rejected(() -> owner.claim(revoked, third.token()));
            rejected(() -> owner.issue(revoked, 1000));

            String expired = UUID.randomUUID().toString();
            LinuxImageLeaseOwner.Offer fourth = owner.issue(expired, 25);
            clock.addAndGet(25);
            rejected(() -> owner.claim(expired, fourth.token()));

            Files.delete(archive);
            try { Files.createSymbolicLink(archive, installation.resolve("outside")); }
            catch (UnsupportedOperationException | IOException | SecurityException unsupported) {
                // Windows developer hosts often disallow symbolic links.
            }
            rejected(() -> owner.issue(UUID.randomUUID().toString(), 1000));
        } finally {
            try (var files = Files.walk(installation)) {
                files.sorted(java.util.Comparator.reverseOrder()).forEach(path -> {
                    try { Files.deleteIfExists(path); }
                    catch (IOException failure) { throw new AssertionError(failure); }
                });
            }
        }
        System.out.println("LinuxImageLeaseOwnerTest passed");
    }
}
