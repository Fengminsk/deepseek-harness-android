package com.minnnng.dsh_android

import android.os.Message
import android.os.Messenger

/** One App-owned reply endpoint for a single admitted isolated script. */
internal interface IsolatedScriptCallbacks {
    val grantsJson: String
    fun call(message: Message, guest: Messenger, reject: (String) -> Unit)
    fun proposedResult(sender: Int, reported: Int)
    /** Existing file and PTC bridges keep their original result validation. */
    fun proposedResult(sender: Int, reported: Int, status: PtcScriptEngine.Status) =
        proposedResult(sender, reported)
    fun cancel()
    fun retire(scriptCompleted: Boolean): IsolatedScriptHostBridge.Retirement
}
