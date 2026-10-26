package com.minnnng.dsh_android

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import android.os.Process
import android.os.SharedMemory
import android.system.OsConstants
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.function.BooleanSupplier

/** Device contract for one immutable image transfer and rejection of a writable descriptor. */
class LinuxImageGuestBridgeInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        try {
            val good = FixtureSource(sealed = true)
            val verified = LinuxImageGuestBridge.verify(targetContext, good,
                BooleanSupplier { false })
            check(verified.verified && verified.sha256 == good.digest &&
                verified.guestUid != null && verified.guestUid != Process.myUid()) {
                "Sealed image did not receive a separate-UID verified receipt: $verified"
            }
            check(good.claims.get() == 1 && good.revocations.get() == 1 &&
                good.closures.get() == 1) {
                "Sealed image lease or descriptor was not retired once"
            }

            val writable = FixtureSource(sealed = false)
            val rejected = LinuxImageGuestBridge.verify(targetContext, writable,
                BooleanSupplier { false })
            check(!rejected.verified && writable.claims.get() == 1 &&
                writable.revocations.get() == 1 && writable.closures.get() == 1) {
                "Writable descriptor was accepted or lease/descriptor was not retired: $rejected"
            }

            val corrupt = FixtureSource(sealed = true, corrupt = true)
            val digestRejected = LinuxImageGuestBridge.verify(targetContext, corrupt,
                BooleanSupplier { false })
            check(!digestRejected.verified && corrupt.claims.get() == 1 &&
                corrupt.revocations.get() == 1 && corrupt.closures.get() == 1) {
                "Corrupt snapshot was accepted or resources were not retired: $digestRejected"
            }
            finish(Activity.RESULT_OK, Bundle().apply {
                putString("result", "linux-image-guest-bridge-pass")
            })
        } catch (failure: Throwable) {
            finish(Activity.RESULT_CANCELED, Bundle().apply {
                putString("result", "linux-image-guest-bridge-fail: ${failure.message}")
            })
        }
    }

    private class FixtureSource(private val sealed: Boolean, private val corrupt: Boolean = false) :
        LinuxImageGuestBridge.Source {
        private val bytes = ByteArray(4096) { (it % 211).toByte() }
        val digest: String = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        val claims = AtomicInteger()
        val revocations = AtomicInteger()
        val closures = AtomicInteger()
        private var offer: LinuxImageLeaseOwner.Offer? = null

        override fun issue(runId: String, leaseMillis: Long): LinuxImageLeaseOwner.Offer {
            check(offer == null)
            val expires = TimeUnit.NANOSECONDS.toMillis(System.nanoTime()) + leaseMillis
            return LinuxImageLeaseOwner.Offer(runId, UUID.randomUUID().toString(),
                "fixture", LinuxImageLeaseOwner.ABI, digest, bytes.size.toLong(), expires)
                .also { offer = it }
        }

        override fun claim(runId: String, token: String): LinuxImageDescriptorBroker.Descriptor {
            val issued = checkNotNull(offer)
            check(issued.runId() == runId && issued.token() == token)
            check(claims.incrementAndGet() == 1)
            val memory = SharedMemory.create("image-guest-fixture", bytes.size)
            val mapped = memory.mapReadWrite()
            try {
                val payload = bytes.copyOf()
                if (corrupt) payload[0] = (payload[0].toInt() xor 0x5a).toByte()
                mapped.put(payload)
            }
            finally { SharedMemory.unmap(mapped) }
            if (sealed) check(memory.setProtect(OsConstants.PROT_READ))
            return LinuxImageDescriptorBroker.Descriptor(memory, digest, issued.version(),
                issued.abi(), issued.bytes(), issued.expiresAtMillis()) {
                closures.incrementAndGet()
            }
        }

        override fun revoke(runId: String) {
            check(offer?.runId() == runId)
            revocations.incrementAndGet()
        }
    }
}
