package com.minnnng.dsh_android

import android.app.Activity
import android.app.Instrumentation
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process
import android.os.SharedMemory
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/** Device-only negative protocol checks. No image is installed or Linux process started. */
class LinuxGuestImageHandoffInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        try {
            probe(rejectOffer = true)
            val storage = probe(rejectOffer = false)
            finish(Activity.RESULT_OK, Bundle().apply {
                putString("result", "linux-guest-image-handoff-negative-pass")
                putString("isolatedStorage", storage)
            })
        } catch (failure: Throwable) {
            finish(Activity.RESULT_CANCELED, Bundle().apply {
                putString("result", "linux-guest-image-handoff-negative-fail")
                putString("detail", failure.message?.take(180))
            })
        }
    }

    private data class Observed(val what: Int, val uid: Int, val data: Bundle)

    private fun probe(rejectOffer: Boolean): String {
        val app = targetContext.applicationContext
        val runId = UUID.randomUUID().toString()
        val nonce = UUID.randomUUID().toString()
        val token = UUID.randomUUID().toString()
        val received = ArrayBlockingQueue<Observed>(4)
        val reply = Messenger(Handler(Looper.getMainLooper()) { message ->
            val copy = Bundle(message.data)
            received.offer(Observed(message.what, message.sendingUid, copy))
            true
        })
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                val guest = Messenger(binder)
                remote = guest
                guest.send(Message.obtain(null, IsolatedLinuxGuestBinderService.OPEN).apply {
                    replyTo = reply
                    data = Bundle().apply {
                        putString(IsolatedLinuxGuestBinderService.RUN_ID, runId)
                        putString(IsolatedLinuxGuestBinderService.NONCE, nonce)
                    }
                })
            }
            override fun onServiceDisconnected(name: ComponentName) { remote = null }
            @Volatile var remote: Messenger? = null
        }
        var bound = false
        try {
            val intent = Intent(app, IsolatedLinuxGuestBinderService::class.java)
            bound = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                app.bindIsolatedService(intent, Context.BIND_AUTO_CREATE,
                    "guest_image_probe_" + nonce.replace("-", ""), app.mainExecutor, connection)
            } else app.bindService(intent, connection, Context.BIND_AUTO_CREATE)
            check(bound)
            val hello = checkNotNull(received.poll(5, TimeUnit.SECONDS))
            check(hello.what == IsolatedLinuxGuestBinderService.HELLO &&
                hello.uid > 0 && hello.uid != Process.myUid() &&
                hello.data.getInt(IsolatedLinuxGuestBinderService.UID) == hello.uid &&
                hello.data.getString(IsolatedLinuxGuestBinderService.RUN_ID) == runId &&
                hello.data.getString(IsolatedLinuxGuestBinderService.NONCE) == nonce)
            val expires = TimeUnit.NANOSECONDS.toMillis(System.nanoTime()) + 5_000
            checkNotNull(connection.remote).send(Message.obtain(null,
                IsolatedLinuxGuestBinderService.IMAGE_OFFER).apply {
                data = Bundle().apply {
                    putString(IsolatedLinuxGuestBinderService.RUN_ID, runId)
                    putString(IsolatedLinuxGuestBinderService.NONCE, nonce)
                    putString(IsolatedLinuxGuestBinderService.TOKEN, token)
                    putString(IsolatedLinuxGuestBinderService.DIGEST,
                        if (rejectOffer) "0".repeat(64) else LinuxImageLeaseOwner.SHA256)
                    putString(IsolatedLinuxGuestBinderService.VERSION, LinuxImageLeaseOwner.VERSION)
                    putString(IsolatedLinuxGuestBinderService.ABI, LinuxImageLeaseOwner.ABI)
                    putLong(IsolatedLinuxGuestBinderService.LENGTH,
                        LinuxImageLeaseOwner.ARCHIVE_BYTES)
                    putLong(IsolatedLinuxGuestBinderService.EXPIRES, expires)
                }
            })
            if (rejectOffer) {
                check(received.poll(750, TimeUnit.MILLISECONDS) == null) {
                    "Unpinned image offer obtained a capability"
                }
                return "not-applicable"
            } else {
                val claim = checkNotNull(received.poll(5, TimeUnit.SECONDS))
                if (claim.what == IsolatedLinuxGuestBinderService.END) {
                    check(claim.uid == hello.uid &&
                        claim.data.getString(IsolatedLinuxGuestBinderService.RUN_ID) == runId &&
                        claim.data.getString(IsolatedLinuxGuestBinderService.NONCE) == nonce &&
                        claim.data.getInt(IsolatedLinuxGuestBinderService.UID) == hello.uid) {
                        "Isolated storage denial had an invalid identity"
                    }
                    return "preflight-denied"
                }
                check(claim.what == IsolatedLinuxGuestBinderService.IMAGE_CLAIM &&
                    claim.uid == hello.uid &&
                    claim.data.getString(IsolatedLinuxGuestBinderService.RUN_ID) == runId &&
                    claim.data.getString(IsolatedLinuxGuestBinderService.NONCE) == nonce &&
                    claim.data.getString(IsolatedLinuxGuestBinderService.TOKEN) == token)
                val image = SharedMemory.create("guest-bad-call-test", 8)
                try {
                    checkNotNull(connection.remote).send(Message.obtain(null,
                        IsolatedLinuxGuestBinderService.IMAGE_SNAPSHOT).apply {
                        data = Bundle().apply {
                            putString(IsolatedLinuxGuestBinderService.RUN_ID, runId)
                            putString(IsolatedLinuxGuestBinderService.NONCE, nonce)
                            putString(IsolatedLinuxGuestBinderService.CALL_ID,
                                UUID.randomUUID().toString())
                            putParcelable(IsolatedLinuxGuestBinderService.IMAGE, image)
                        }
                    })
                } finally { image.close() }
                check(received.poll(750, TimeUnit.MILLISECONDS) == null) {
                    "Mismatched snapshot call was reported staged"
                }
                return "preflight-allowed"
            }
        } finally {
            runCatching {
                connection.remote?.send(Message.obtain(null,
                    IsolatedLinuxGuestBinderService.CANCEL).apply {
                    data = Bundle().apply {
                        putString(IsolatedLinuxGuestBinderService.RUN_ID, runId)
                        putString(IsolatedLinuxGuestBinderService.NONCE, nonce)
                    }
                })
            }
            if (bound) app.unbindService(connection)
        }
    }
}
