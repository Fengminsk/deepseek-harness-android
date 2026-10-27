package com.minnnng.dsh_android

import java.util.UUID

/** One non-restartable test lease. Closed is acknowledged only after Service.onDestroy and resource release. */
internal class AcceptanceServiceOwner(private val port: Port) {
    interface Port {
        fun startForeground()
        fun acquireCpu(timeoutMillis: Long)
        fun cpuHeld(): Boolean
        fun releaseCpu()
        fun stopForeground()
        fun requestStop()
        fun status(token: String, state: String, failure: String?)
    }

    private var token: String? = null
    private var deadline = 0L
    private var stopping = false
    private var destroyed = false
    private var failure: String? = null

    @Synchronized
    fun start(supplied: String, durationMillis: Long, now: Long) {
        require(UUID.fromString(supplied).toString() == supplied && UUID.fromString(supplied).version() == 4)
        require(durationMillis in 1_000..MAX_DURATION_MILLIS && now >= 0 &&
            now <= Long.MAX_VALUE - durationMillis - CLEANUP_GRACE_MILLIS)
        if (token != null || destroyed) {
            port.status(supplied, "rejected", "An acceptance service lease already owns this instance")
            return
        }
        token = supplied
        deadline = now + durationMillis
        try {
            port.startForeground()
            port.acquireCpu(durationMillis + CLEANUP_GRACE_MILLIS)
            check(port.cpuHeld()) { "Acceptance CPU lease was not acquired" }
            port.status(supplied, "ready", null)
        } catch (error: Throwable) {
            forceStop("Acceptance service startup failed: $error")
        }
    }

    @Synchronized
    fun release(supplied: String) {
        if (supplied != token || stopping || destroyed) return
        stopping = true
        releaseResources()
        port.requestStop()
    }

    @Synchronized
    fun checkDeadline(now: Long) {
        if (token != null && !stopping && !destroyed) {
            if (now >= deadline + CLEANUP_GRACE_MILLIS || !port.cpuHeld())
                forceStop("Acceptance service cleanup deadline expired")
            else if (now >= deadline) fail("Acceptance service lease expired")
        }
    }

    @Synchronized
    fun fail(reason: String) {
        if (destroyed) return
        if (failure == null) {
            failure = reason
            token?.let { port.status(it, "failed", failure) }
        }
    }

    @Synchronized
    fun forceStop(reason: String) {
        if (destroyed) return
        fail(reason)
        if (!stopping) {
            stopping = true
            releaseResources()
            port.requestStop()
        }
    }

    @Synchronized
    fun destroyed() {
        if (destroyed) return
        if (!stopping && token != null) {
            failure = failure ?: "Acceptance service was destroyed before owner release"
            port.status(requireNotNull(token), "failed", failure)
        }
        stopping = true
        val released = releaseResources()
        destroyed = true
        token?.let { port.status(it, if (released) "closed" else "close-failed", failure) }
    }

    private fun releaseResources(): Boolean {
        var released = true
        try { port.releaseCpu(); check(!port.cpuHeld()) { "CPU lease is still held" } }
        catch (error: Throwable) { released = false; failure = failure ?: "CPU lease release failed: $error" }
        try { port.stopForeground() }
        catch (error: Throwable) { released = false; failure = failure ?: "Foreground removal failed: $error" }
        if (!released) token?.let { port.status(it, "failed", failure) }
        return released
    }

    companion object {
        const val CLEANUP_GRACE_MILLIS = 120_000L
        const val MAX_DURATION_MILLIS = 7_200_000L - CLEANUP_GRACE_MILLIS
    }
}
