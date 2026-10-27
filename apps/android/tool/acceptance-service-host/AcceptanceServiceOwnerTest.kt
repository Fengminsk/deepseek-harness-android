package com.minnnng.dsh_android

import java.util.UUID
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

object AcceptanceServiceOwnerTest {
    private class Resources : AcceptanceServiceOwner.Port {
        val events = Collections.synchronizedList(mutableListOf<String>())
        var held = false
        var foreground = false
        var acquireFailure = false
        var releaseFailure = false
        var enterStart: CountDownLatch? = null
        var allowStart: CountDownLatch? = null
        var enterRelease: CountDownLatch? = null
        var allowRelease: CountDownLatch? = null
        var bound = 0L
        override fun startForeground() {
            enterStart?.countDown()
            check(allowStart?.await(5, TimeUnit.SECONDS) != false)
            foreground = true; events.add("foreground")
        }
        override fun acquireCpu(timeoutMillis: Long) {
            held = true; bound = timeoutMillis; events.add("acquire")
            if (acquireFailure) error("partial acquisition")
        }
        override fun cpuHeld() = held
        override fun releaseCpu() {
            enterRelease?.countDown()
            check(allowRelease?.await(5, TimeUnit.SECONDS) != false)
            if (releaseFailure) error("release refused")
            held = false; events.add("release")
        }
        override fun stopForeground() { foreground = false; events.add("remove") }
        override fun requestStop() { events.add("stop-request") }
        override fun status(token: String, state: String, failure: String?) {
            if (state == "ready") check(held && foreground)
            if (state == "closed") check(!held && !foreground)
            if (state == "failed" || state == "close-failed" || state == "rejected") check(!failure.isNullOrBlank())
            events.add(state)
        }
    }

    @JvmStatic fun main(args: Array<String>) {
        var count = 0
        fun run(name: String, body: () -> Unit) { body(); count++; println("PASS $name") }
        run("ready waits for actual foreground and CPU acquisition") {
            val resources = Resources().apply { enterStart = CountDownLatch(1); allowStart = CountDownLatch(1) }
            val owner = AcceptanceServiceOwner(resources)
            val token = UUID.randomUUID().toString()
            val failure = AtomicReference<Throwable?>()
            val thread = Thread { try { owner.start(token, 1000, 0) } catch (error: Throwable) { failure.set(error) } }
            thread.start()
            try {
                check(resources.enterStart!!.await(5, TimeUnit.SECONDS))
                check(!resources.events.contains("ready"))
            } finally { resources.allowStart!!.countDown(); thread.join(5000) }
            check(!thread.isAlive && failure.get() == null)
            check(resources.events.take(3) == listOf("foreground", "acquire", "ready"))
            owner.release(token)
            check(!resources.events.contains("closed"))
            owner.destroyed()
            check(resources.events.last() == "closed")
        }
        run("closed waits for actual release and onDestroy, not stop request") {
            val resources = Resources()
            val owner = AcceptanceServiceOwner(resources)
            val token = UUID.randomUUID().toString()
            owner.start(token, 1000, 0)
            owner.release(token)
            resources.enterRelease = CountDownLatch(1); resources.allowRelease = CountDownLatch(1)
            val failure = AtomicReference<Throwable?>()
            val thread = Thread { try { owner.destroyed() } catch (error: Throwable) { failure.set(error) } }
            thread.start()
            try {
                check(resources.enterRelease!!.await(5, TimeUnit.SECONDS))
                check(resources.events.contains("stop-request") && !resources.events.contains("closed"))
            } finally { resources.allowRelease!!.countDown(); thread.join(5000) }
            check(!thread.isAlive && failure.get() == null && resources.events.last() == "closed")
        }
        run("foreign owner cannot stop or replace an active lease") {
            val resources = Resources(); val owner = AcceptanceServiceOwner(resources)
            val token = UUID.randomUUID().toString(); val foreign = UUID.randomUUID().toString()
            owner.start(token, 1000, 0); owner.start(foreign, 2000, 0); owner.release(foreign)
            check(resources.events.count { it == "ready" } == 1 && resources.events.last() == "rejected")
            check(resources.held && resources.foreground && !resources.events.contains("stop-request"))
            owner.release(token); owner.destroyed()
        }
        run("deadline cancels fixture before bounded cleanup releases carrier") {
            val resources = Resources(); val owner = AcceptanceServiceOwner(resources)
            val token = UUID.randomUUID().toString(); owner.start(token, 1000, 10)
            owner.checkDeadline(1009); check(!resources.events.contains("failed"))
            owner.checkDeadline(1010); check(resources.events.last() == "failed")
            check(resources.held && resources.foreground && !resources.events.contains("stop-request"))
            check(resources.bound == 1000 + AcceptanceServiceOwner.CLEANUP_GRACE_MILLIS)
            owner.release(token); owner.destroyed(); check(resources.events.last() == "closed")
        }
        run("lost owner cannot hold CPU past the cleanup deadline") {
            val resources = Resources(); val owner = AcceptanceServiceOwner(resources)
            owner.start(UUID.randomUUID().toString(), 1000, 0)
            owner.checkDeadline(1000 + AcceptanceServiceOwner.CLEANUP_GRACE_MILLIS)
            check(!resources.held && !resources.foreground && resources.events.last() == "stop-request")
            owner.destroyed(); check(resources.events.last() == "closed" && resources.events.contains("failed"))
        }
        run("partial startup failure releases acquired CPU and never acknowledges ready") {
            val resources = Resources().apply { acquireFailure = true }; val owner = AcceptanceServiceOwner(resources)
            owner.start(UUID.randomUUID().toString(), 1000, 0)
            check(!resources.held && !resources.foreground && !resources.events.contains("ready"))
            owner.destroyed(); check(resources.events.last() == "closed" && resources.events.contains("failed"))
        }
        run("resource release failure cannot produce a closed acknowledgement") {
            val resources = Resources(); val owner = AcceptanceServiceOwner(resources)
            val token = UUID.randomUUID().toString(); owner.start(token, 1000, 0); resources.releaseFailure = true
            owner.release(token); owner.destroyed()
            check(resources.events.last() == "close-failed" && !resources.events.contains("closed"))
            resources.releaseFailure = false; resources.releaseCpu()
        }
        run("unexpected destruction and Android timeout fail active fixture") {
            for (timeout in listOf(false, true)) {
                val resources = Resources(); val owner = AcceptanceServiceOwner(resources)
                owner.start(UUID.randomUUID().toString(), 1000, 0)
                if (timeout) owner.forceStop("Android timeout")
                owner.destroyed(); owner.destroyed()
                check(resources.events.count { it == "closed" } == 1 && resources.events.contains("failed"))
                check(!resources.held && !resources.foreground)
            }
        }
        run("malformed, excessive or overflowing leases acquire no resources") {
            for ((token, duration, now) in listOf(Triple("bad", 1000L, 0L),
                Triple(UUID.randomUUID().toString(), 7_200_000L, 0L),
                Triple(UUID.randomUUID().toString(), 1000L, Long.MAX_VALUE))) {
                val resources = Resources(); var rejected = false
                try { AcceptanceServiceOwner(resources).start(token, duration, now) }
                catch (_: IllegalArgumentException) { rejected = true }
                check(rejected && resources.events.isEmpty())
            }
        }
        println("Acceptance service owner: $count passed; Android scheduling and physical displays unverified")
    }
}
