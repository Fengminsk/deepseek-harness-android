package com.minnnng.dsh_android

import android.app.Activity
import android.app.Application
import android.app.Instrumentation
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.Looper
import java.io.File
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.SecureDirectoryStream
import java.util.Comparator
import java.util.function.BooleanSupplier

/** Device acceptance for App-private file-provider operations used by the isolated broker. */
class FileBrokerProviderInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val report = Bundle()
        val passed = mutableListOf<String>()
        val failed = mutableListOf<String>()
        try {
            val app = targetContext.applicationContext
            check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
            check(Application.getProcessName() == app.packageName + ":agent")
            check(Looper.myLooper() != Looper.getMainLooper())
            test("secure-provider-and-revision", passed, failed) {
                withFixture(app) { fixture ->
                    Files.newDirectoryStream(File(app.applicationInfo.dataDir).toPath()).use { stream ->
                        check(stream is SecureDirectoryStream<*>)
                        report.putString("provider", stream.javaClass.name)
                    }
                    val note = fixture.workspace.resolve("note.txt")
                    val links = Files.getAttribute(note, "unix:nlink", LinkOption.NOFOLLOW_LINKS)
                    check(links is Number && links.toLong() == 1L)
                    report.putLong("links", links.toLong())
                    val snapshot = fixture.writer.snapshot("note.txt", BooleanSupplier { false })
                    check(String(snapshot.content(), StandardCharsets.UTF_8) == "first")
                    check(fixture.writer.version("note.txt") == snapshot.sha256())
                    check(fixture.writer.version("new.txt") == IsolatedWorkerWriteback.MISSING)
                }
            }
            test("edit-create-and-stale", passed, failed) {
                withFixture(app) { fixture ->
                    val workspace = IsolatedCapabilityWorkspace(app, fixture.workspace.toFile())
                    val before = workspace.read("note.txt", BooleanSupplier { false })
                    check(before.text() == "first")
                    val edited = workspace.edit("note.txt", before.revision(), "first", "second", 1,
                        BooleanSupplier { false })
                    check(edited.previousRevision() == before.revision())
                    check(workspace.read("note.txt", BooleanSupplier { false }).text() == "second")
                    val created = workspace.write("new.txt", IsolatedWorkerWriteback.MISSING, "created",
                        BooleanSupplier { false })
                    check(created.previousRevision() == IsolatedWorkerWriteback.MISSING)
                    check(workspace.read("new.txt", BooleanSupplier { false }).text() == "created")
                    check(runCatching {
                        workspace.write("note.txt", before.revision(), "stale", BooleanSupplier { false })
                    }.exceptionOrNull() is IsolatedCapabilityBroker.StaleRevision)
                    check(runCatching {
                        workspace.edit("note.txt", before.revision(), "second", "stale", 1,
                            BooleanSupplier { false })
                    }.exceptionOrNull() is IsolatedCapabilityBroker.StaleRevision)
                    check(workspace.read("note.txt", BooleanSupplier { false }).text() == "second")
                }
            }
            test("cancel-and-link-isolation", passed, failed) {
                withFixture(app) { fixture ->
                    val secret = Files.write(fixture.root.resolve("private.txt"), "private".toByteArray())
                    val symlink = fixture.workspace.resolve("symlink.txt")
                    Files.createSymbolicLink(symlink, secret)
                    val normal = IsolatedCapabilityWorkspace(app, fixture.workspace.toFile())
                    check(runCatching {
                        normal.read("symlink.txt", BooleanSupplier { false })
                    }.isFailure)
                    check(runCatching {
                        normal.write("symlink.txt", IsolatedWorkerWriteback.MISSING, "overwrite",
                            BooleanSupplier { false })
                    }.isFailure)
                    val hardlink = fixture.workspace.resolve("hardlink.txt")
                    Files.createLink(hardlink, secret)
                    check((Files.getAttribute(secret, "unix:nlink", LinkOption.NOFOLLOW_LINKS)
                        as Number).toLong() == 2L)
                    check(runCatching {
                        normal.read("hardlink.txt", BooleanSupplier { false })
                    }.isFailure)
                    check(runCatching {
                        normal.write("hardlink.txt", IsolatedWorkerWriteback.MISSING, "overwrite",
                            BooleanSupplier { false })
                    }.isFailure)
                    check(String(Files.readAllBytes(secret), StandardCharsets.UTF_8) == "private")
                    val gate = IsolatedWorkerWriteback.PublishGate()
                    val cancelled = IsolatedCapabilityWorkspace(app, fixture.workspace.toFile(), gate)
                    val revision = cancelled.read("note.txt", BooleanSupplier { false }).revision()
                    gate.cancel()
                    check(runCatching {
                        cancelled.write("note.txt", revision, "later", BooleanSupplier { false })
                    }.isFailure)
                    check(normal.read("note.txt", BooleanSupplier { false }).text() == "first")
                }
            }
        } catch (failure: Throwable) {
            failed += "setup: ${failure.javaClass.simpleName}: ${failure.message}"
        }
        report.putString("passed", passed.joinToString(","))
        report.putString("failed", failed.joinToString(" | "))
        report.putInt("passedCount", passed.size)
        report.putInt("failedCount", failed.size)
        finish(if (failed.isEmpty()) Activity.RESULT_OK else Activity.RESULT_CANCELED, report)
    }

    private fun test(name: String, passed: MutableList<String>, failed: MutableList<String>,
                     body: () -> Unit) {
        try { body(); passed += name }
        catch (failure: Throwable) {
            failed += "$name: ${failure.javaClass.simpleName}: ${failure.message}"
        }
    }

    private data class Fixture(val root: Path, val workspace: Path,
                               val writer: IsolatedWorkerWriteback)

    private fun withFixture(app: Context, body: (Fixture) -> Unit) {
        val root = Files.createTempDirectory(app.filesDir.toPath(), "broker-provider-")
        try {
            val workspace = Files.createDirectory(root.resolve("workspace"))
            Files.write(workspace.resolve("note.txt"), "first".toByteArray())
            val writer = IsolatedWorkerWriteback(File(app.applicationInfo.dataDir).toPath(),
                workspace, IsolatedWorkerWriteback.DirectorySync {
                    IsolatedScriptRunController.syncDirectory(it)
                })
            body(Fixture(root, workspace, writer))
        } finally {
            Files.walk(root).use { paths ->
                paths.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) }
            }
        }
    }
}
