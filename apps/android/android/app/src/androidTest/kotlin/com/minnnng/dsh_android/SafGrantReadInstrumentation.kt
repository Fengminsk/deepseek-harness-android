package com.minnnng.dsh_android

import android.app.Application
import android.app.Instrumentation
import android.os.Bundle
import android.os.Process
import java.security.MessageDigest

/** Reads only a named acceptance fixture through the App's persisted SAF grant path. */
class SafGrantReadInstrumentation : Instrumentation() {
    private lateinit var options: Bundle

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        options = arguments ?: Bundle.EMPTY
        start()
    }

    override fun onStart() {
        val result = Bundle()
        try {
            val app = targetContext.applicationContext
            check(Application.getProcessName() == app.packageName + ":agent") {
                "SAF acceptance must run in the Agent process"
            }
            val access = DocumentAccess(app)
            val fixture = "dsh-saf-acceptance.txt"
            val expected = "Pocket Harness SAF acceptance v1\n"
            val candidates = mutableListOf<String>()
            val roots = access.roots()
            for (index in 0 until roots.length()) {
                val root = roots.getJSONObject(index)
                if (!root.optBoolean("directory") || !root.optBoolean("available")) continue
                val id = root.getString("id")
                val entries = access.list(id, "")
                if ((0 until entries.length()).any { entry ->
                        val item = entries.getJSONObject(entry)
                        item.getString("name") == fixture && !item.getBoolean("directory")
                    }) candidates.add(id)
            }
            check(candidates.size == 1) {
                "Expected one granted directory containing the dedicated SAF acceptance fixture; found ${candidates.size}"
            }
            val rootId = candidates.single()
            val expectedRoot = options.getString("rootId")
            if (expectedRoot != null) {
                require(expectedRoot.matches(Regex("[0-9a-f]{64}"))) { "Invalid rootId" }
                check(rootId == expectedRoot) { "Persisted SAF grant identity changed" }
            }
            val page = access.read(rootId, fixture, 0)
            check(!page.getBoolean("truncated") && page.getString("text") == expected) {
                "SAF fixture bytes differ from the expected content"
            }
            result.putString("result", "saf-persisted-read-pass")
            result.putString("rootId", rootId)
            result.putString("contentSha256", sha256(expected.toByteArray(Charsets.UTF_8)))
            result.putInt("processPid", Process.myPid())
            finish(-1, result)
        } catch (failure: Throwable) {
            result.putString("failure", (failure.javaClass.simpleName + ": " +
                (failure.message ?: "SAF acceptance failed")).take(512))
            finish(0, result)
        }
    }

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }
}
