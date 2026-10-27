package com.minnnng.dsh_android

import android.app.Instrumentation
import android.os.Bundle

/** Verifies the composed display for thirty seconds; no model or user data is opened. */
class BlackScreenAcceptanceInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }
    override fun onStart() {
        val report = Bundle()
        try {
            AcceptanceForegroundLease.open(this).use { foreground ->
                var samples = 0
                repeat(6) {
                    Thread.sleep(5000)
                    val (width, height) = foreground.verifyBlackPixels()
                    report.putInt("width", width)
                    report.putInt("height", height)
                    samples++
                }
                report.putInt("samples", samples)
            }
            report.putString("passed", "composed-screen-all-rgb-zero")
            finish(-1, report)
        } catch (failure: Throwable) {
            report.putString("failure", "${failure.javaClass.simpleName}: ${failure.message}")
            finish(0, report)
        }
    }
}
