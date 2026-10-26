package com.minnnng.dsh_android

import android.app.Activity
import android.app.Application
import android.app.Instrumentation
import android.util.Base64
import android.os.Build
import android.os.Bundle
import android.os.Looper
import android.os.Process
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.function.BooleanSupplier
import org.json.JSONObject
import java.util.UUID

/** Device-only acceptance for the internal Linux-style command boundary. */
class LinuxCommandAcceptanceInstrumentation : Instrumentation() {
    private lateinit var arguments: Bundle

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        this.arguments = arguments ?: Bundle.EMPTY
        start()
    }

    override fun onStart() {
        val passed = mutableListOf<String>()
        val failed = mutableListOf<String>()
        try {
            check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) { "Android 10+ required" }
            val app = targetContext.applicationContext
            check(Application.getProcessName() == app.packageName + ":agent") {
                "Instrumentation must run in the Agent process"
            }
            check(Looper.myLooper() != Looper.getMainLooper()) { "Acceptance must not block the main thread" }
            when (arguments.getString("phase", "baseline")) {
                "baseline" -> {
                    test("kernel-command-isolated", passed, failed) {
                        val result = IsolatedLinuxCommandRunner.run(app,
                            IsolatedLinuxCommandPolicy.Command.KERNEL, BooleanSupplier { false })
                        check(result.completed && result.exitCode == 0) { result.detail ?: result.kind.name }
                        check(result.output.startsWith("Linux ")) { "Kernel output did not come from uname" }
                        checkIsolatedChild(result.guestUid)
                    }
                    test("identity-command-matches-child-uid", passed, failed) {
                        val result = IsolatedLinuxCommandRunner.run(app,
                            IsolatedLinuxCommandPolicy.Command.IDENTITY, BooleanSupplier { false })
                        check(result.completed && result.exitCode == 0) { result.detail ?: result.kind.name }
                        checkIsolatedChild(result.guestUid)
                        check(result.output.trim().toIntOrNull() == result.guestUid) {
                            "Child id output did not match the Binder guest UID"
                        }
                    }
                    test("pre-admission-cancel", passed, failed) {
                        val result = IsolatedLinuxCommandRunner.run(app,
                            IsolatedLinuxCommandPolicy.Command.KERNEL, BooleanSupplier { true })
                        check(result.kind == GuestTerminal.Kind.CANCELLED) { result.detail ?: result.kind.name }
                    }
                    test("sha256-stdin", passed, failed) {
                        val bytes = "hello\n".toByteArray(StandardCharsets.UTF_8)
                        val result = IsolatedLinuxCommandRunner.run(app,
                            IsolatedLinuxCommandPolicy.Request.of(
                                IsolatedLinuxCommandPolicy.Command.SHA256, null, bytes), BooleanSupplier { false })
                        check(result.completed && result.exitCode == 0) { result.detail ?: result.kind.name }
                        val expected = MessageDigest.getInstance("SHA-256").digest(bytes)
                            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
                        check(result.output.substringBefore(' ').trim() == expected) { "SHA-256 output differs from input digest" }
                    }
                    test("apk-packaged-core-boundaries", passed, failed) {
                        val bytes = ByteArray(IsolatedLinuxCommandPolicy.MAX_STDIN_BYTES) { index ->
                            if (index % 79 == 78) '\n'.code.toByte() else 'x'.code.toByte()
                        }
                        val nativeDir = app.applicationInfo.nativeLibraryDir
                        for (command in listOf(IsolatedLinuxCommandPolicy.Command.SHA256,
                            IsolatedLinuxCommandPolicy.Command.COUNT_BYTES,
                            IsolatedLinuxCommandPolicy.Command.COUNT_LINES)) {
                            val request = IsolatedLinuxCommandPolicy.Request.of(command, null, bytes)
                            val argv = PackagedLinuxUtility.argv(request, nativeDir)
                            check(argv.size == 2 && argv[0].startsWith(nativeDir + "/") &&
                                argv[0].endsWith("/" + PackagedLinuxUtility.EXECUTABLE_NAME) &&
                                argv[1] == command.wireName) {
                                "Core command did not resolve to the APK packaged executable"
                            }
                            val result = IsolatedLinuxCommandRunner.run(app, request,
                                BooleanSupplier { false })
                            check(result.completed && result.exitCode == 0 &&
                                result.retirementConfirmed) { result.detail ?: result.kind.name }
                            checkIsolatedChild(result.guestUid)
                            val expected = when (command) {
                                IsolatedLinuxCommandPolicy.Command.SHA256 ->
                                    MessageDigest.getInstance("SHA-256").digest(bytes)
                                        .joinToString("") { "%02x".format(it.toInt() and 0xff) } + "  -\n"
                                IsolatedLinuxCommandPolicy.Command.COUNT_BYTES ->
                                    "${bytes.size}\n"
                                else -> "${bytes.count { it == '\n'.code.toByte() }}\n"
                            }
                            check(result.output == expected) {
                                "APK packaged ${command.wireName} output differs"
                            }
                        }
                    }
                    test("count-and-sort-stdin", passed, failed) {
                        val bytes = "b\na\nb\n".toByteArray(StandardCharsets.UTF_8)
                        val byteCount = IsolatedLinuxCommandRunner.run(app,
                            IsolatedLinuxCommandPolicy.Request.of(
                                IsolatedLinuxCommandPolicy.Command.COUNT_BYTES, null, bytes), BooleanSupplier { false })
                        check(byteCount.completed && byteCount.output.trim().toLongOrNull() == bytes.size.toLong()) {
                            byteCount.detail ?: "Byte count differs"
                        }
                        val lineCount = IsolatedLinuxCommandRunner.run(app,
                            IsolatedLinuxCommandPolicy.Request.of(
                                IsolatedLinuxCommandPolicy.Command.COUNT_LINES, null, bytes), BooleanSupplier { false })
                        check(lineCount.completed && lineCount.output.trim().toLongOrNull() == 3L) {
                            lineCount.detail ?: "Line count differs"
                        }
                        val sorted = IsolatedLinuxCommandRunner.run(app,
                            IsolatedLinuxCommandPolicy.Request.of(
                                IsolatedLinuxCommandPolicy.Command.SORT_LINES, null, bytes), BooleanSupplier { false })
                        check(sorted.completed && sorted.output == "a\nb\nb\n") {
                            sorted.detail ?: "Sort output differs"
                        }
                    }
                    test("literal-filter-stdin", passed, failed) {
                        val bytes = "b\na\nb\n".toByteArray(StandardCharsets.UTF_8)
                        val result = IsolatedLinuxCommandRunner.run(app,
                            IsolatedLinuxCommandPolicy.Request.of(
                                IsolatedLinuxCommandPolicy.Command.FILTER_LITERAL, "b", bytes), BooleanSupplier { false })
                        check(result.completed && result.output == "b\nb\n") {
                            result.detail ?: "Literal filter output differs"
                        }
                    }
                    test("literal-filter-no-match", passed, failed) {
                        val result = IsolatedLinuxCommandRunner.run(app,
                            IsolatedLinuxCommandPolicy.Request.of(
                                IsolatedLinuxCommandPolicy.Command.FILTER_LITERAL, "missing",
                                "b\na\n".toByteArray(StandardCharsets.UTF_8)), BooleanSupplier { false })
                        check(result.completed && result.exitCode == 1 && result.output.isEmpty()) {
                            result.detail ?: "No-match grep result differs"
                        }
                    }
                    test("app-rpc-fixed-sha256", passed, failed) {
                        LinuxCommandManager(app).use { manager ->
                            val bytes = "hello\n".toByteArray(StandardCharsets.UTF_8)
                            val id = UUID.randomUUID().toString()
                            val result = manager.execute(JSONObject()
                                .put("id", id).put("command", "sha256")
                                .put("stdinBase64", Base64.encodeToString(bytes, Base64.NO_WRAP)))
                            check(result.getString("id") == id &&
                                result.getString("kind") == GuestTerminal.Kind.COMPLETED.name &&
                                result.getInt("exitCode") == 0) { "App RPC command did not complete" }
                            checkIsolatedChild(result.getInt("guestUid"))
                            val expected = MessageDigest.getInstance("SHA-256").digest(bytes)
                                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
                            check(result.getString("output").substringBefore(' ').trim() == expected) {
                                "App RPC SHA-256 output differs"
                            }
                        }
                    }
                    test("app-rpc-rejects-test-command-and-cwd", passed, failed) {
                        LinuxCommandManager(app).use { manager ->
                            fun rejected(request: JSONObject) {
                                val failure = runCatching { manager.execute(request) }.exceptionOrNull()
                                check(failure is IllegalArgumentException) {
                                    "Unapproved App RPC request was not rejected at admission"
                                }
                            }
                            rejected(JSONObject().put("id", UUID.randomUUID().toString())
                                .put("command", "_test_delay"))
                            rejected(JSONObject().put("id", UUID.randomUUID().toString())
                                .put("command", "sha256").put("cwd", "/"))
                        }
                    }
                }
                "lifecycle" -> {
                    check((app.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
                        "Debug-only lifecycle commands require a debuggable package"
                    }
                    test("apk-packaged-fixed-utility", passed, failed) {
                        val bytes = "native utility\n".toByteArray(StandardCharsets.UTF_8)
                        val result = IsolatedLinuxCommandRunner.run(app,
                            IsolatedLinuxCommandPolicy.Request.of(
                                IsolatedLinuxCommandPolicy.Command.TEST_PACKAGED_COUNT_BYTES,
                                null, bytes), BooleanSupplier { false })
                        check(result.completed && result.exitCode == 0 && result.retirementConfirmed) {
                            result.detail ?: result.kind.name
                        }
                        check(result.output.trim() == bytes.size.toString()) {
                            "APK-packaged utility returned the wrong byte count"
                        }
                        checkIsolatedChild(result.guestUid)
                    }
                    test("in-flight-cancel", passed, failed) {
                        val cancelled = AtomicBoolean(false)
                        val startedUid = AtomicInteger(-1)
                        val started = System.nanoTime()
                        val result = IsolatedLinuxCommandRunner.run(app,
                            IsolatedLinuxCommandPolicy.Request.of(
                                IsolatedLinuxCommandPolicy.Command.TEST_DELAY, null, null),
                            BooleanSupplier { cancelled.get() }) { uid ->
                            startedUid.set(uid)
                            cancelled.set(true)
                        }
                        checkIsolatedChild(startedUid.get().takeIf { it >= 0 })
                        check(result.kind == GuestTerminal.Kind.CANCELLED) { result.detail ?: result.kind.name }
                        check(result.guestUid == startedUid.get()) {
                            "Cancellation returned before the isolated guest's terminal receipt"
                        }
                        check((System.nanoTime() - started) / 1_000_000 <
                            IsolatedLinuxCommandPolicy.HOST_DEADLINE_MS) { "Cancellation exceeded host deadline" }
                    }
                    test("guest-deadline", passed, failed) {
                        val result = IsolatedLinuxCommandRunner.run(app,
                            IsolatedLinuxCommandPolicy.Command.TEST_DELAY, BooleanSupplier { false })
                        check(result.kind == GuestTerminal.Kind.TIMED_OUT) { result.detail ?: result.kind.name }
                        checkIsolatedChild(result.guestUid)
                    }
                    test("output-limit", passed, failed) {
                        val result = IsolatedLinuxCommandRunner.run(app,
                            IsolatedLinuxCommandPolicy.Command.TEST_OUTPUT_FLOOD, BooleanSupplier { false })
                        check(result.kind == GuestTerminal.Kind.ERROR &&
                            result.detail?.contains("output exceeded limit") == true) {
                            result.detail ?: result.kind.name
                        }
                    }
                    test("isolated-worker-death", passed, failed) {
                        val result = IsolatedLinuxCommandRunner.run(app,
                            IsolatedLinuxCommandPolicy.Command.TEST_SERVICE_DEATH, BooleanSupplier { false })
                        check(result.kind == GuestTerminal.Kind.WORKER_DIED) { result.detail ?: result.kind.name }
                    }
                }
                else -> error("Unknown Linux command acceptance phase")
            }
        } catch (failure: Throwable) {
            failed += "setup: ${failure.javaClass.simpleName}: ${failure.message}"
        }
        finish(if (failed.isEmpty()) Activity.RESULT_OK else Activity.RESULT_CANCELED, Bundle().apply {
            putString("passed", passed.joinToString(","))
            putString("failed", failed.joinToString(" | "))
            putInt("passedCount", passed.size)
            putInt("failedCount", failed.size)
        })
    }

    private fun checkIsolatedChild(uid: Int?) {
        check(uid != null && uid != Process.myUid()) { "Guest UID equals App UID or is missing" }
        if (Build.VERSION.SDK_INT >= 34) {
            check(Process.isIsolatedUid(uid)) { "Guest UID is not an Android isolated UID" }
        }
    }

    private fun test(name: String, passed: MutableList<String>, failed: MutableList<String>, body: () -> Unit) {
        try {
            body()
            passed += name
        } catch (failure: Throwable) {
            failed += "$name: ${failure.javaClass.simpleName}: ${failure.message}"
        }
    }
}
