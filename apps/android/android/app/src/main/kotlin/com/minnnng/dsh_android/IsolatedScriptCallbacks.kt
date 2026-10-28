package com.minnnng.dsh_android

import android.os.Message
import android.os.Messenger

/** One App-owned reply endpoint for a single admitted isolated script. */
internal interface IsolatedScriptCallbacks {
    val grantsJson: String
    fun call(message: Message, guest: Messenger, reject: (String) -> Unit)
    fun proposedResult(sender: Int, reported: Int)
    /** A privately confirmed parent cancellation may precede the native cancel RPC. */
    val parentCancellationRequested: Boolean get() = false
    /** Each bridge restricts which non-success results may retire pending callbacks. */
    fun proposedResult(sender: Int, reported: Int, status: PtcScriptEngine.Status) =
        proposedResult(sender, reported)
    fun cancel()
    fun retire(scriptCompleted: Boolean): IsolatedScriptHostBridge.Retirement
}
