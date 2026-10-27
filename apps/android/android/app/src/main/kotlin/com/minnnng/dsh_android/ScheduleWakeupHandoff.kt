package com.minnnng.dsh_android

/** Runs under the wake owner's monitor; retains no duplicate generation or token state. */
internal object ScheduleWakeupHandoff {
    fun fail(
        expectedGeneration: String, currentGeneration: String?, token: String?,
        markFailed: (String) -> Unit, release: () -> Unit,
    ) {
        if (expectedGeneration != currentGeneration || token == null) return
        try { markFailed(token) }
        finally { release() }
    }
}
