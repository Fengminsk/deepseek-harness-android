package com.minnnng.dsh_android;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Comparator;
import java.util.HexFormat;

/** Host checks for atomic visibility, restart verification and fail-closed installation. */
public final class PinnedLinuxImageStoreTest {
    public static void main(String[] args) throws Exception {
        Path fixture = Files.createTempDirectory("pocket-linux-image-store-");
        try {
            require(ImageDigestHex.encode(new byte[] { 0, 15, 16, (byte) 255 })
                .equals("000f10ff"), "Android-compatible digest encoding changed");
            byte[] archive = "reviewed archive bytes".getBytes(java.nio.charset.StandardCharsets.UTF_8);
            String sha = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(archive));
            PinnedLinuxImageStore store = fixtureStore(fixture, sha, archive.length);
            require(store.inspect() == null, "Missing image must not look installed");

            byte[] wrong = archive.clone();
            wrong[0] ^= 1;
            rejected(() -> store.install(new ByteArrayInputStream(wrong)));
            rejected(() -> store.install(new ByteArrayInputStream(new byte[archive.length + 1])));
            rejected(() -> store.install(new InputStream() {
                @Override public int read() { return 0; }
                @Override public int read(byte[] bytes) { return 0; }
            }));
            require(store.inspect() == null, "Failed image became visible");
            Path versions = fixture.resolve("linux-userland/versions");
            try (var paths = Files.list(versions)) {
                require(paths.findAny().isEmpty(), "Failed installation left a stage");
            }

            PinnedLinuxImageStore.Installed installed =
                store.install(new ByteArrayInputStream(archive));
            require(!installed.executable() && installed.sha256().equals(sha),
                "Published image became executable or changed identity");
            require(Files.readAllBytes(installed.archive()).length == archive.length,
                "Published archive missing");
            PinnedLinuxImageStore restarted = fixtureStore(fixture, sha, archive.length);
            require(restarted.inspect().equals(installed), "Restart changed verified release");
            require(restarted.install(new ByteArrayInputStream(wrong)).equals(installed),
                "Already verified release should not be replaced by later source bytes");

            Path receipt = installed.directory().resolve("receipt.txt");
            String originalReceipt = new String(Files.readAllBytes(receipt), StandardCharsets.UTF_8);
            Files.write(receipt, originalReceipt.replace("executable=false", "executable=true ").getBytes(StandardCharsets.UTF_8));
            rejected(restarted::inspect);
            Files.write(receipt, originalReceipt.getBytes(StandardCharsets.UTF_8));
            byte[] tampered = archive.clone();
            tampered[1] ^= 1;
            Files.write(installed.archive(), tampered);
            rejected(restarted::inspect);
            require(Files.exists(installed.archive()), "Corrupt release must be retained for inspection");

            Path separate = Files.createDirectory(fixture.resolve("second"));
            PinnedLinuxImageStore second = fixtureStore(separate, sha, archive.length);
            InputStream interrupted = new InputStream() {
                private int reads;
                @Override public int read() throws IOException {
                    if (reads >= 3) throw new IOException("synthetic interrupted source");
                    return archive[reads++] & 0xff;
                }
            };
            rejected(() -> second.install(interrupted));
            require(second.inspect() == null, "Interrupted source published a release");
            Path abandoned = Files.createDirectory(separate.resolve("linux-userland/versions")
                .resolve(".staging-" + java.util.UUID.randomUUID()));
            Files.write(abandoned.resolve("receipt.txt"), "partial".getBytes(StandardCharsets.UTF_8));
            require(second.inspect() == null && !Files.exists(abandoned),
                "Restart did not retire an installer-owned partial stage");
            Path unknown = Files.createDirectory(separate.resolve("linux-userland/versions")
                .resolve(".staging-" + java.util.UUID.randomUUID()));
            Files.write(unknown.resolve("unrelated"), "preserve".getBytes(StandardCharsets.UTF_8));
            rejected(second::inspect);
            require(Files.exists(unknown.resolve("unrelated")),
                "Unknown staging content was deleted");

            if (args.length == 1) {
                Path reviewedArchive = Path.of(args[0]);
                Path officialRoot = Files.createDirectory(fixture.resolve("official"));
                PinnedLinuxImageStore official = new PinnedLinuxImageStore(officialRoot);
                try (InputStream source = Files.newInputStream(reviewedArchive)) {
                    PinnedLinuxImageStore.Installed published = official.install(source);
                    require(!published.executable() &&
                        published.bytes() == LinuxImageLeaseOwner.ARCHIVE_BYTES &&
                        published.sha256().equals(LinuxImageLeaseOwner.SHA256),
                        "Official locked archive published under wrong identity");
                }
                require(new PinnedLinuxImageStore(officialRoot).inspect() != null,
                    "Official locked archive failed offline restart verification");
            }
            System.out.println("PinnedLinuxImageStoreTest passed");
        } finally {
            java.util.List<Path> created;
            try (var paths = Files.walk(fixture)) {
                created = paths.sorted(Comparator.reverseOrder()).toList();
            }
            for (Path path : created) {
                Files.deleteIfExists(path);
            }
        }
    }

    private static PinnedLinuxImageStore fixtureStore(Path noBackup, String sha, long bytes) {
        return new PinnedLinuxImageStore(noBackup, "fixture", sha, bytes,
            "https://example.invalid/fixed-test-source");
    }

    private interface Action { Object run() throws Exception; }

    private static void rejected(Action operation) throws Exception {
        try { operation.run(); throw new AssertionError("Unsafe image release accepted"); }
        catch (IOException expected) { /* The source or installed identity failed closed. */ }
    }

    private static void require(boolean value, String error) {
        if (!value) throw new AssertionError(error);
    }
}
