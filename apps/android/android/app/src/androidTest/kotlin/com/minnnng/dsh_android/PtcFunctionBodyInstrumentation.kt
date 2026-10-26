package com.minnnng.dsh_android

import android.app.Activity
import android.app.Application
import android.app.Instrumentation
import android.os.Bundle
import android.os.Looper
import org.json.JSONObject
import org.json.JSONArray

/**
 * Explicit JNI parser/return-value acceptance. This executes in the :agent test process,
 * so it does not itself prove Binder UID confinement. Run the existing isolated guest
 * instrumentation separately for that boundary.
 */
class PtcFunctionBodyInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val result = Bundle()
        try {
            val app = targetContext.applicationContext
            check(Application.getProcessName() == app.packageName + ":agent")
            check(Looper.myLooper() != Looper.getMainLooper())
            val success = run("""
                const value = await Promise.resolve(input.n);
                return {
                  answer: value * 7,
                  process: typeof process,
                  require: typeof require,
                  fetch: typeof fetch,
                  host: typeof host
                };
            """.trimIndent(), "{\"n\":6}")
            check(success.status == PtcScriptEngine.Status.COMPLETED)
            val data = JSONObject(success.outputJson!!)
            check(data.getInt("answer") == 42)
            for (name in listOf("process", "require", "fetch", "host")) {
                check(data.getString(name) == "undefined") { "$name leaked into the guest" }
            }

            val closed = run("""
                const AsyncFunction = (async () => {}).constructor;
                let evalDenied = false, functionDenied = false;
                try { eval('1 + 1'); } catch (_) { evalDenied = true; }
                try { new AsyncFunction('return 1'); }
                catch (_) { functionDenied = true; }
                return { evalDenied, functionDenied };
            """.trimIndent())
            check(closed.status == PtcScriptEngine.Status.COMPLETED)
            val denial = JSONObject(closed.outputJson!!)
            check(denial.getBoolean("evalDenied") && denial.getBoolean("functionDenied")) {
                "String code generation stayed enabled after trusted construction"
            }

            for (escape in listOf(
                "}; return {forged:1}; const x=async()=>{",
                "}, (()=>{globalThis.marker=1})(), async()=>{",
            )) {
                check(run(escape).status == PtcScriptEngine.Status.INVALID_PROGRAM) {
                    "Function-body source escaped the AsyncFunction grammar"
                }
            }
            check(run("return { missing: undefined };").status ==
                    PtcScriptEngine.Status.OUTPUT_INVALID) {
                "Function-body output bypassed the native lossless JSON snapshot"
            }
            val logged = run("console.log('first', input.n); console.warn('second'); return { ok: true };", "{\"n\":6}")
            check(logged.status == PtcScriptEngine.Status.COMPLETED)
            val lines = JSONArray(logged.logsJson!!)
            check(lines.length() == 2 && lines.getString(0) == "first 6" &&
                lines.getString(1) == "second") { "Guest console logs were not captured" }
            check(run("for (let i = 0; i < 130; i++) console.log(i); return 1;").status ==
                PtcScriptEngine.Status.OUTPUT_TOO_LARGE) { "Console output budget was bypassed" }
            result.putString("passed", "async-body, ambient-denial, codegen-denial, escape, snapshot, console-budget")
            finish(Activity.RESULT_OK, result)
        } catch (failure: Throwable) {
            result.putString("failure", failure.stackTraceToString())
            finish(Activity.RESULT_CANCELED, result)
        }
    }

    private fun run(body: String, input: String = "{}"): PtcScriptEngine.Result =
        PtcScriptEngine().use { it.runFunctionBody(body, input, 2_000) }
}
