package com.minnnng.dsh_android

import android.app.Instrumentation
import android.os.Bundle
import java.io.Closeable

/** Selects a test carrier without changing the fixture's task or retirement owner. */
internal class AcceptanceCarrierLease private constructor(
    private val lease: Closeable,
    private val verify: () -> Unit,
    private val instrumentation: Instrumentation,
    private val report: Bundle,
) : Closeable {
    fun checkActive() = verify()

    override fun close() {
        try {
            lease.close()
            report.putString("foregroundClosed", "true")
        } finally {
            report.putString("deviceStateAfter", AcceptanceServiceLease.deviceState(instrumentation.targetContext))
        }
    }

    companion object {
        fun selection(arguments: Bundle): String = (arguments.getString("foregroundCarrier") ?: "activity").also {
            require(it in setOf("activity", "service")) { "Unknown acceptance foreground carrier" }
        }

        fun open(instrumentation: Instrumentation, arguments: Bundle, report: Bundle,
            durationMillis: Long, onFailure: (Throwable) -> Unit): AcceptanceCarrierLease {
            val selected = selection(arguments)
            report.putString("foregroundCarrier", selected)
            report.putString("deviceStateBefore", AcceptanceServiceLease.deviceState(instrumentation.targetContext))
            val result = if (selected == "service") {
                val owner = AcceptanceServiceLease.open(instrumentation, durationMillis, onFailure)
                AcceptanceCarrierLease(owner, owner::checkActive, instrumentation, report)
            } else {
                val owner = AcceptanceForegroundLease.open(instrumentation, onFailure)
                AcceptanceCarrierLease(owner, owner::checkActive, instrumentation, report)
            }
            try {
                result.checkActive()
                report.putString("foregroundConfirmed", "true")
                report.putString("deviceStateReady", AcceptanceServiceLease.deviceState(instrumentation.targetContext))
                return result
            } catch (failure: Throwable) {
                try { result.close() } catch (cleanup: Throwable) { failure.addSuppressed(cleanup) }
                throw failure
            }
        }
    }
}
