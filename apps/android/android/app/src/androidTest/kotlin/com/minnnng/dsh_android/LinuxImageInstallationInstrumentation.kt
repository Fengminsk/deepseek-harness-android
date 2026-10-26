package com.minnnng.dsh_android

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import java.io.ByteArrayInputStream
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.security.MessageDigest
import java.util.Comparator
import java.util.UUID

/** Device storage contract; synthetic bytes only, no network, extraction, or guest execution. */
class LinuxImageInstallationInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val testRoot = targetContext.noBackupFilesDir.toPath()
            .resolve("image-install-test-${UUID.randomUUID()}")
        try {
            Files.createDirectory(testRoot)
            val archive = "synthetic inert archive fixture".toByteArray(StandardCharsets.UTF_8)
            val digest = ImageDigestHex.encode(MessageDigest.getInstance("SHA-256").digest(archive))
            val store = PinnedLinuxImageStore(testRoot, "fixture", digest,
                archive.size.toLong(), "https://example.invalid/fixed-fixture")
            check(store.inspect() == null) { "Uninstalled image appeared present" }
            val interrupted = ByteArrayInputStream(archive.copyOfRange(0, archive.size / 2))
            rejected { store.install(interrupted) }
            check(store.inspect() == null) { "Partial image became visible" }
            val installed = store.install(ByteArrayInputStream(archive))
            check(!installed.executable() && installed.sha256() == digest) {
                "Data-only image changed identity or execution state"
            }
            val restarted = PinnedLinuxImageStore(testRoot, "fixture", digest,
                archive.size.toLong(), "https://example.invalid/fixed-fixture")
            check(restarted.inspect() == installed) { "Restart verification rejected valid release" }
            val receipt = installed.directory().resolve("receipt.txt")
            val originalReceipt = String(Files.readAllBytes(receipt), StandardCharsets.UTF_8)
            Files.write(receipt, originalReceipt.replace("executable=false", "executable=true ")
                .toByteArray(StandardCharsets.UTF_8))
            rejected { restarted.inspect() }
            check(Files.exists(installed.archive(), LinkOption.NOFOLLOW_LINKS)) {
                "Tampered release was removed without inspection"
            }
            finish(Activity.RESULT_OK, Bundle().apply {
                putString("result", "linux-image-install-data-only-pass")
            })
        } catch (failure: Throwable) {
            finish(Activity.RESULT_CANCELED, Bundle().apply {
                putString("result", "linux-image-install-fail: ${failure.message}")
            })
        } finally {
            if (Files.exists(testRoot, LinkOption.NOFOLLOW_LINKS)) {
                Files.walk(testRoot).use { paths ->
                    paths.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) }
                }
            }
        }
    }

    private fun rejected(action: () -> Any?) {
        try {
            action()
            error("Unsafe image candidate was accepted")
        } catch (_: IOException) {
            // The store failed closed before an installed release became usable.
        }
    }
}
