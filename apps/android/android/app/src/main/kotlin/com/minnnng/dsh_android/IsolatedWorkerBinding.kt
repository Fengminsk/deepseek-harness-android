package com.minnnng.dsh_android

import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import java.util.UUID

/** One binding per operation; API 29+ assigns a distinct isolated service instance. */
internal object IsolatedWorkerBinding {
    fun bind(app: Context, connection: ServiceConnection): Boolean {
        val intent = Intent(app, IsolatedWorkerService::class.java)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val instance = "worker_" + UUID.randomUUID().toString().replace("-", "")
            app.bindIsolatedService(intent, Context.BIND_AUTO_CREATE, instance, app.mainExecutor, connection)
        } else {
            // Android 9 supports isolatedProcess, but not multiple named instances.
            app.bindService(intent, connection, Context.BIND_AUTO_CREATE)
        }
    }
}
