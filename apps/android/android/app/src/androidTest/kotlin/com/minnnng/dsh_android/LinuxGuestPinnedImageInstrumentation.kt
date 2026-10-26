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
import android.system.Os
import android.system.OsConstants
import java.nio.file.Files
import java.nio.file.LinkOption
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/** Opt-in, pinned-archive device probe. It never starts PRoot or publishes a task result. */
class LinuxGuestPinnedImageInstrumentation : Instrumentation() {
    private var fixture: String? = null

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        fixture = arguments?.getString("fixture")
        start()
    }

    override fun onStart() {
        val name = fixture
        if (name == null || !Regex("linux-guest-pinned-probe-[0-9a-f-]{36}\\.tar\\.gz")
                .matches(name)) {
            finish(Activity.RESULT_CANCELED, Bundle().apply {
                putString("result", "pinned-image-probe-invalid-fixture")
            })
            return
        }
        val path = targetContext.cacheDir.toPath().resolve(name)
        try {
            check(!Files.isSymbolicLink(path) && Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS))
            check(Files.size(path) == LinuxImageLeaseOwner.ARCHIVE_BYTES)
            probe(path)
            finish(Activity.RESULT_OK, Bundle().apply {
                putString("result", "pinned-image-stage-and-retire-pass")
                putString("sha256", LinuxImageLeaseOwner.SHA256)
            })
        } catch (failure: Throwable) {
            finish(Activity.RESULT_CANCELED, Bundle().apply {
                putString("result", "pinned-image-stage-and-retire-fail")
                putString("detail", failure.message?.take(180))
            })
        } finally {
            // Only this unique test fixture is removed. Production image and guest state are
            // never touched; the host runner also retries deletion after instrument failure.
            runCatching { Files.deleteIfExists(path) }
        }
    }

    private data class Observed(val what: Int, val uid: Int, val data: Bundle)

    private fun probe(path: java.nio.file.Path) {
        val app = targetContext.applicationContext
        val runId = UUID.randomUUID().toString()
        val nonce = UUID.randomUUID().toString()
        val token = UUID.randomUUID().toString()
        val received = ArrayBlockingQueue<Observed>(6)
        val reply = Messenger(Handler(Looper.getMainLooper()) { message ->
            received.offer(Observed(message.what, message.sendingUid, Bundle(message.data)))
            true
        })
        val connection = object : ServiceConnection {
            @Volatile var remote: Messenger? = null
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                remote = Messenger(binder)
                remote?.send(Message.obtain(null, IsolatedLinuxGuestBinderService.OPEN).apply {
                    replyTo = reply
                    data = Bundle().apply {
                        putString(IsolatedLinuxGuestBinderService.RUN_ID, runId)
                        putString(IsolatedLinuxGuestBinderService.NONCE, nonce)
                    }
                })
            }
            override fun onServiceDisconnected(name: ComponentName) { remote = null }
        }
        var bound = false
        try {
            val intent = Intent(app, IsolatedLinuxGuestBinderService::class.java)
            bound = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                app.bindIsolatedService(intent, Context.BIND_AUTO_CREATE,
                    "guest_pinned_probe_" + nonce.replace("-", ""), app.mainExecutor, connection)
            } else app.bindService(intent, connection, Context.BIND_AUTO_CREATE)
            check(bound) { "Isolated Binder service did not bind" }
            val hello = checkNotNull(received.poll(5, TimeUnit.SECONDS)) { "No isolated HELLO" }
            check(hello.what == IsolatedLinuxGuestBinderService.HELLO &&
                hello.uid > 0 && hello.uid != Process.myUid() &&
                hello.data.getInt(IsolatedLinuxGuestBinderService.UID) == hello.uid &&
                hello.data.getBoolean(IsolatedLinuxGuestBinderService.ISOLATED) &&
                hello.data.getString(IsolatedLinuxGuestBinderService.RUN_ID) == runId &&
                hello.data.getString(IsolatedLinuxGuestBinderService.NONCE) == nonce)
            val expires = TimeUnit.NANOSECONDS.toMillis(System.nanoTime()) + 15_000
            checkNotNull(connection.remote).send(Message.obtain(null,
                IsolatedLinuxGuestBinderService.IMAGE_OFFER).apply {
                data = Bundle().apply {
                    putString(IsolatedLinuxGuestBinderService.RUN_ID, runId)
                    putString(IsolatedLinuxGuestBinderService.NONCE, nonce)
                    putString(IsolatedLinuxGuestBinderService.TOKEN, token)
                    putString(IsolatedLinuxGuestBinderService.DIGEST, LinuxImageLeaseOwner.SHA256)
                    putString(IsolatedLinuxGuestBinderService.VERSION, LinuxImageLeaseOwner.VERSION)
                    putString(IsolatedLinuxGuestBinderService.ABI, LinuxImageLeaseOwner.ABI)
                    putLong(IsolatedLinuxGuestBinderService.LENGTH, LinuxImageLeaseOwner.ARCHIVE_BYTES)
                    putLong(IsolatedLinuxGuestBinderService.EXPIRES, expires)
                }
            })
            val offerReply = checkNotNull(received.poll(5, TimeUnit.SECONDS)) { "No image claim or denial" }
            check(offerReply.uid == hello.uid &&
                offerReply.data.getString(IsolatedLinuxGuestBinderService.RUN_ID) == runId &&
                offerReply.data.getString(IsolatedLinuxGuestBinderService.NONCE) == nonce)
            if (offerReply.what == IsolatedLinuxGuestBinderService.END) {
                error("Isolated storage preflight denied image staging")
            }
            check(offerReply.what == IsolatedLinuxGuestBinderService.IMAGE_CLAIM &&
                offerReply.data.getInt(IsolatedLinuxGuestBinderService.UID) == hello.uid &&
                offerReply.data.getString(IsolatedLinuxGuestBinderService.TOKEN) == token)
            val callId = checkNotNull(offerReply.data.getString(IsolatedLinuxGuestBinderService.CALL_ID))
            val raw = Os.open(path.toString(),
                OsConstants.O_RDONLY or OsConstants.O_CLOEXEC or OsConstants.O_NOFOLLOW, 0)
            val image = try {
                LinuxImageImmutableSnapshot.copyAndSeal(raw, LinuxImageLeaseOwner.ARCHIVE_BYTES,
                    LinuxImageLeaseOwner.SHA256, expires)
            } finally { Os.close(raw) }
            try {
                checkNotNull(connection.remote).send(Message.obtain(null,
                    IsolatedLinuxGuestBinderService.IMAGE_SNAPSHOT).apply {
                    data = Bundle().apply {
                        putString(IsolatedLinuxGuestBinderService.RUN_ID, runId)
                        putString(IsolatedLinuxGuestBinderService.NONCE, nonce)
                        putString(IsolatedLinuxGuestBinderService.CALL_ID, callId)
                        putParcelable(IsolatedLinuxGuestBinderService.IMAGE, image)
                    }
                })
                val staged = checkNotNull(received.poll(15, TimeUnit.SECONDS)) { "No staging receipt" }
                check(staged.what == IsolatedLinuxGuestBinderService.IMAGE_STAGED &&
                    staged.uid == hello.uid &&
                    staged.data.getInt(IsolatedLinuxGuestBinderService.UID) == hello.uid &&
                    staged.data.getString(IsolatedLinuxGuestBinderService.RUN_ID) == runId &&
                    staged.data.getString(IsolatedLinuxGuestBinderService.NONCE) == nonce &&
                    staged.data.getString(IsolatedLinuxGuestBinderService.CALL_ID) == callId)
                check(staged.data.getString(IsolatedLinuxGuestBinderService.STATUS) == "staged" &&
                    staged.data.getString(IsolatedLinuxGuestBinderService.DIGEST) ==
                    LinuxImageLeaseOwner.SHA256) { "Pinned image rejected by isolated stager" }
            } finally { image.close() }
            // Binder message order makes CANCEL finish rootfs removal before the next OPEN.
            // Reusing this Messenger verifies normal cleanup by the same isolated UID.
            val nextRunId = UUID.randomUUID().toString()
            val nextNonce = UUID.randomUUID().toString()
            val nextToken = UUID.randomUUID().toString()
            checkNotNull(connection.remote).send(Message.obtain(null,
                IsolatedLinuxGuestBinderService.CANCEL).apply {
                data = Bundle().apply {
                    putString(IsolatedLinuxGuestBinderService.RUN_ID, runId)
                    putString(IsolatedLinuxGuestBinderService.NONCE, nonce)
                }
            })
            try {
                checkNotNull(connection.remote).send(Message.obtain(null,
                    IsolatedLinuxGuestBinderService.OPEN).apply {
                    replyTo = reply
                    data = Bundle().apply {
                        putString(IsolatedLinuxGuestBinderService.RUN_ID, nextRunId)
                        putString(IsolatedLinuxGuestBinderService.NONCE, nextNonce)
                    }
                })
                val nextHello = checkNotNull(received.poll(5, TimeUnit.SECONDS)) {
                    "No HELLO after staged rootfs cancellation"
                }
                check(nextHello.what == IsolatedLinuxGuestBinderService.HELLO &&
                    nextHello.uid == hello.uid &&
                    nextHello.data.getInt(IsolatedLinuxGuestBinderService.UID) == hello.uid &&
                    nextHello.data.getString(IsolatedLinuxGuestBinderService.RUN_ID) == nextRunId &&
                    nextHello.data.getString(IsolatedLinuxGuestBinderService.NONCE) == nextNonce)
                checkNotNull(connection.remote).send(Message.obtain(null,
                    IsolatedLinuxGuestBinderService.IMAGE_OFFER).apply {
                    data = Bundle().apply {
                        putString(IsolatedLinuxGuestBinderService.RUN_ID, nextRunId)
                        putString(IsolatedLinuxGuestBinderService.NONCE, nextNonce)
                        putString(IsolatedLinuxGuestBinderService.TOKEN, nextToken)
                        putString(IsolatedLinuxGuestBinderService.DIGEST, LinuxImageLeaseOwner.SHA256)
                        putString(IsolatedLinuxGuestBinderService.VERSION, LinuxImageLeaseOwner.VERSION)
                        putString(IsolatedLinuxGuestBinderService.ABI, LinuxImageLeaseOwner.ABI)
                        putLong(IsolatedLinuxGuestBinderService.LENGTH, LinuxImageLeaseOwner.ARCHIVE_BYTES)
                        putLong(IsolatedLinuxGuestBinderService.EXPIRES,
                            TimeUnit.NANOSECONDS.toMillis(System.nanoTime()) + 15_000)
                    }
                })
                val nextClaim = checkNotNull(received.poll(5, TimeUnit.SECONDS)) {
                    "No claim after staged rootfs cancellation"
                }
                check(nextClaim.what == IsolatedLinuxGuestBinderService.IMAGE_CLAIM &&
                    nextClaim.uid == hello.uid &&
                    nextClaim.data.getInt(IsolatedLinuxGuestBinderService.UID) == hello.uid &&
                    nextClaim.data.getString(IsolatedLinuxGuestBinderService.RUN_ID) == nextRunId &&
                    nextClaim.data.getString(IsolatedLinuxGuestBinderService.NONCE) == nextNonce &&
                    nextClaim.data.getString(IsolatedLinuxGuestBinderService.TOKEN) == nextToken) {
                    "Staged rootfs remained after normal cancellation"
                }
            } finally {
                runCatching {
                    connection.remote?.send(Message.obtain(null,
                        IsolatedLinuxGuestBinderService.CANCEL).apply {
                        data = Bundle().apply {
                            putString(IsolatedLinuxGuestBinderService.RUN_ID, nextRunId)
                            putString(IsolatedLinuxGuestBinderService.NONCE, nextNonce)
                        }
                    })
                }
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
