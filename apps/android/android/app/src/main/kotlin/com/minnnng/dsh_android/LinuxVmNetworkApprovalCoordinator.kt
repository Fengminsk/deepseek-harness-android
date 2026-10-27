package com.minnnng.dsh_android

import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardOpenOption
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.RejectedExecutionException

/** Native review requests confer no authority. Only Inbox's trusted UI decision can issue a token. */
internal class LinuxVmNetworkApprovalCoordinator(
    private val privateRoot: Path,
    private val directory: Path,
    private val inbox: IsolatedExecutionApprovalInbox,
    private val currentRoute: () -> JSONObject,
    private val observeRoute: (JSONObject, () -> Unit) -> AutoCloseable,
    private val execute: (JSONObject, IsolatedExecutionPolicyOwner.Lease, JSONObject) -> JSONObject,
    private val cancelExecution: (String) -> Unit,
    private val offer: (IsolatedExecutionApprovalInbox.Review) -> Boolean,
    private val dismiss: (String) -> Unit,
    private val sync: (Path) -> Unit,
    private val reviewMillis: Long = 120_000,
    private val unusedTokenMillis: Long = 30_000,
) : AutoCloseable {
    private enum class State { PREPARING, PENDING, APPROVED, RUNNING, STOPPING, CLOSED }
    private class Entry(val request: JSONObject) {
        val id = request.getString("id")
        val sessionId = request.getString("sessionId")
        val result = CompletableFuture<JSONObject>()
        val cleanup = CompletableFuture<Unit>()
        @Volatile var state = State.PREPARING
        var review: IsolatedExecutionApprovalInbox.Review? = null
        var store: IsolatedExecutionApprovalStore? = null
        var owner: IsolatedExecutionPolicyOwner? = null
        var route: JSONObject? = null
        var routeLabel = ""
        var token: String? = null
        var approvalId: String? = null
        var expiresNanos = 0L
        var expiresMillis = 0L
        var timer: ScheduledFuture<*>? = null
        var routeWatch: AutoCloseable? = null
        var cleanupStarted = false
        @Volatile var reviewDetached = false
    }
    private val entries = ConcurrentHashMap<String, Entry>()
    private val cancelled = ConcurrentHashMap<String, String>()
    private val ownership = Any()
    private val scheduler = Executors.newScheduledThreadPool(2) { task ->
        Thread(task, "linux-network-approval").apply { isDaemon = true }
    }
    @Volatile private var closed = false

    init { require(reviewMillis in 1..120_000 && unusedTokenMillis in 1..30_000) }

    fun review(params: JSONObject): JSONObject {
        val request = checkedRequest(params)
        val entry = Entry(request)
        synchronized(ownership) {
            if (closed) return response(entry, "unavailable")
            cancelled[entry.id]?.let { require(it == entry.sessionId); return response(entry, "cancelled") }
            require(entries.size < 32 && entries.putIfAbsent(entry.id, entry) == null) { "Linux review already exists or is full" }
        }
        try {
            synchronized(entry) {
                if (entry.state == State.CLOSED) return entry.result.get()
                val route = JSONObject(currentRoute().toString())
                entry.routeLabel = routeLabel(route)
                entry.route = route
                val root = privateRoot.toRealPath()
                require(directory.toAbsolutePath().normalize().startsWith(root) && directory.toAbsolutePath().normalize() != root)
                if (!Files.exists(directory, LinkOption.NOFOLLOW_LINKS)) {
                    Files.createDirectory(directory)
                    sync(directory.parent)
                }
                require(!Files.isSymbolicLink(directory) && directory.toRealPath().startsWith(root))
                val history = Files.createDirectory(directory.resolve(entry.id))
                sync(directory)
                val snapshot = JSONObject(request.toString()).put("route", route)
                writeOnce(history.resolve("request.json"), snapshot)
                val store = IsolatedExecutionApprovalStore(root, history, "linux-network-${entry.id}", entry.sessionId, sync)
                entry.store = store
                val owner = store.newOwner { runId, policy ->
                    check(runId == entry.id && policy.sessionId() == entry.sessionId)
                    writeOnce(history.resolve("admitted.json"), JSONObject().put("id", runId)
                        .put("sessionId", entry.sessionId).put("approvalId", entry.approvalId)
                        .put("approvalAuditId", request.getString("approvalAuditId")).put("policyVersion", policy.version()))
                }
                entry.owner = owner
                val hosts = request.getJSONArray("exactHosts")
                val scope = IsolatedExecutionPolicyOwner.Scope.granted(owner.current().ownerId(), entry.sessionId,
                    owner.current().version() + 1, null, null, emptySet(), emptySet(),
                    (0 until hosts.length()).map { hosts.getString(it) }.toSet(), 0,
                    request.getInt("networkCallLimit"), request.getLong("timeoutMs") + 5000)
                entry.expiresMillis = System.currentTimeMillis() + reviewMillis
                entry.expiresNanos = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(reviewMillis)
                // Inbox validates a bounded review payload, not Linux execution. The digest includes
                // the complete actual timeout/command/audit/route in snapshot, independently checked above.
                entry.review = inbox.prepare(entry.id, scope, request.getString("command"), snapshot.toString(),
                    minOf(request.getInt("timeoutMs"), PtcScriptEngine.MAX_DEADLINE_MILLIS),
                    object : IsolatedExecutionApprovalInbox.Decision {
                        override fun approve(approved: IsolatedExecutionPolicyOwner.Scope, runId: String, approvalId: String) {
                            try { synchronized(entry) {
                                check(!closed && entry.state == State.PENDING && runId == entry.id
                                    && System.nanoTime() < entry.expiresNanos) { "Linux review expired" }
                                check(currentRoute().toString() == entry.route.toString()) { "Linux proxy changed during review" }
                                store.prepareTrustedUiApproval(approved, approvalId)
                                owner.replace(approved)
                                entry.approvalId = approvalId
                                entry.token = UUID.randomUUID().toString()
                                entry.state = State.APPROVED
                                entry.timer?.cancel(false)
                                entry.expiresNanos = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(unusedTokenMillis)
                                entry.timer = scheduler.schedule({ retire(entry, "cancelled") }, unusedTokenMillis, TimeUnit.MILLISECONDS)
                                entry.result.complete(response(entry, "allowed-once"))
                            } } catch (failure: Exception) {
                                entry.result.complete(response(entry, "unavailable"))
                                throw failure
                            }
                        }
                        override fun deny(runId: String) {
                            check(runId == entry.id)
                            retire(entry, "rejected", removeReview = false)
                        }
                    })
                entry.state = State.PENDING
                entry.timer = scheduler.schedule({ retire(entry, "cancelled") }, reviewMillis, TimeUnit.MILLISECONDS)
            }
            val watch = observeRoute(checkNotNull(entry.route)) {
                try { scheduler.execute { retire(entry, "cancelled") } }
                catch (_: RejectedExecutionException) { /* Coordinator close already revokes every live owner. */ }
            }
            synchronized(entry) {
                if (entry.state == State.CLOSED) watch.close() else entry.routeWatch = watch
            }
            if (entry.state == State.PENDING && !offer(checkNotNull(entry.review))) retire(entry, "unavailable")
            return try { entry.result.get(reviewMillis, TimeUnit.MILLISECONDS) }
            catch (_: TimeoutException) { retire(entry, "cancelled"); entry.result.get() }
        } catch (failure: Exception) {
            retire(entry, "unavailable")
            throw failure
        }
    }

    fun cancelReview(params: JSONObject): JSONObject {
        exact(params, setOf("id", "sessionId"))
        val id = uuid(params, "id")
        val sessionId = text(params, "sessionId").also(IsolatedScriptWire::requireSessionId)
        val entry = synchronized(ownership) {
            val existing = entries[id]
            if (existing != null) require(existing.sessionId == sessionId)
            else {
                require(cancelled.size < 256 || cancelled.containsKey(id)) { "Linux cancellation capacity reached" }
                val prior = cancelled.putIfAbsent(id, sessionId)
                require(prior == null || prior == sessionId)
            }
            existing
        }
        if (entry != null && entry.state !in setOf(State.RUNNING, State.STOPPING)) retire(entry, "cancelled", onlyUnused = true)
        return JSONObject().put("id", id).put("sessionId", sessionId).put("revoked", true)
    }

    fun executeNetwork(params: JSONObject): JSONObject {
        exact(params, setOf("id", "sessionId", "command", "timeoutMs", "persistChanges", "approvalToken", "approvalAuditId"))
        val entry = entries[uuid(params, "id")] ?: error("Linux network approval is unavailable")
        val lease: IsolatedExecutionPolicyOwner.Lease
        val request: JSONObject
        var claimed = false
        var receipt: JSONObject? = null
        var executionFailure: Exception? = null
        try {
            synchronized(entry) {
                check(!closed && entry.state == State.APPROVED && System.nanoTime() < entry.expiresNanos)
                require(uuid(params, "approvalToken") == entry.token
                    && uuid(params, "approvalAuditId") == entry.request.getString("approvalAuditId"))
                for (name in listOf("sessionId", "command", "persistChanges")) {
                    require(params.get(name) == entry.request.get(name)) { "Linux approved request changed" }
                }
                require((params.opt("timeoutMs") is Int || params.opt("timeoutMs") is Long)
                    && params.getLong("timeoutMs") == entry.request.getLong("timeoutMs")) { "Linux approved timeout changed" }
                check(currentRoute().toString() == entry.route.toString()) { "Linux approved proxy changed" }
                entry.token = null
                entry.state = State.RUNNING
                claimed = true
                entry.timer?.cancel(false)
                lease = checkNotNull(entry.owner).admit(entry.id)
                request = JSONObject().put("id", entry.id).put("sessionId", entry.sessionId)
                    .put("command", entry.request.getString("command")).put("timeoutMs", entry.request.getLong("timeoutMs"))
                    .put("persistChanges", entry.request.getBoolean("persistChanges"))
                entry.timer = scheduler.schedule({ retire(entry, "cancelled") },
                    lease.policy().leaseMillis(), TimeUnit.MILLISECONDS)
            }
            receipt = execute(request, lease, JSONObject(checkNotNull(entry.route).toString()))
            return receipt
        } catch (failure: Exception) {
            executionFailure = failure
            throw failure
        } finally {
            if (claimed) {
                synchronized(entry) { entry.state = State.CLOSED; entry.timer?.cancel(false) }
                try {
                    finishCleanup(entry)
                    entry.cleanup.get(10, TimeUnit.SECONDS)
                    receipt?.put("approvalCleanupConfirmed", true)
                }
                catch (failure: Exception) {
                    // Preserve the Manager's actual terminal result even if approval-log cleanup failed.
                    stopAccepting()
                    if (receipt == null) {
                        if (executionFailure == null) throw failure else executionFailure.addSuppressed(failure)
                    } else receipt.put("approvalCleanupConfirmed", false).put("approvalCleanupError", "durable-revocation-unconfirmed")
                }
            } else retire(entry, "cancelled", onlyUnused = true)
        }
    }

    fun unavailable(requestId: String) {
        entries.values.firstOrNull { it.review?.id() == requestId }?.let { retire(it, "unavailable") }
    }

    fun pending(): List<IsolatedExecutionApprovalInbox.Review> = entries.values
        .filter { it.state == State.PENDING }.mapNotNull { it.review }

    /** UI additions come only from the native immutable request; no caller-supplied display JSON. */
    fun decorate(review: IsolatedExecutionApprovalInbox.Review, view: JSONObject): JSONObject {
        val entry = entries[review.runId()] ?: return view
        synchronized(entry) {
            if (entry.review?.id() != review.id()) return view
            return view.put("kind", "linux-network").put("expiresAtMillis", entry.expiresMillis)
                .put("timeoutMs", entry.request.getLong("timeoutMs")).put("persistChanges", entry.request.getBoolean("persistChanges"))
                .put("route", entry.routeLabel)
        }
    }

    private fun retire(entry: Entry, outcome: String, removeReview: Boolean = true, onlyUnused: Boolean = false) {
        val running: Boolean
        synchronized(entry) {
            if (!removeReview) entry.reviewDetached = true
            if (entry.state == State.CLOSED) return
            running = entry.state in setOf(State.RUNNING, State.STOPPING)
            if (running && onlyUnused) return
            if (entry.state == State.STOPPING) return
            entry.state = if (running) State.STOPPING else State.CLOSED
            entry.token = null
            entry.timer?.cancel(false)
            entry.result.complete(response(entry, outcome))
        }
        entry.owner?.revoke(entry.id)
        // Inbox invokes Decision.deny while holding its monitor. Native cancellation may wait
        // for the main Looper, so both that wait and disk cleanup belong to this worker.
        scheduler.execute {
            if (running) cancelExecution(entry.id)
            else finishCleanup(entry, removeReview)
        }
    }

    private fun finishCleanup(entry: Entry, removeReview: Boolean = true) {
        synchronized(entry) {
            if (entry.cleanupStarted) return
            entry.cleanupStarted = true
        }
        val owner = entry.owner
        val review = entry.review
        var failure: Exception? = null
        try {
            owner?.revoke(entry.id)
            if (owner != null) {
                val current = owner.current()
                owner.replace(IsolatedExecutionPolicyOwner.Scope.denied(current.ownerId(), current.sessionId(), current.version() + 1))
            }
        } catch (error: Exception) { failure = error }
        finally {
            try { owner?.close() } catch (error: Exception) { failure = combine(failure, error) }
            try { entry.routeWatch?.close() } catch (error: Exception) { failure = combine(failure, error) }
            try { entry.store?.close() } catch (error: Exception) { failure = combine(failure, error) }
            if (review != null) {
                dismiss(review.id())
                if (removeReview && !entry.reviewDetached) try { inbox.deny(review.id(), review.challenge()) }
                catch (_: IllegalArgumentException) { /* A concurrent UI decision already removed this request. */ }
                catch (error: IllegalStateException) { if (!entry.reviewDetached) failure = combine(failure, error) }
                catch (error: Exception) { failure = combine(failure, error) }
            }
            if (failure == null) entry.cleanup.complete(Unit) else {
                stopAccepting()
                entry.cleanup.completeExceptionally(failure)
            }
            entries.remove(entry.id, entry)
        }
        failure?.let { throw it }
    }

    private fun combine(first: Exception?, next: Exception): Exception = first?.apply { addSuppressed(next) } ?: next

    fun stopAccepting() { synchronized(ownership) { closed = true } }

    override fun close() {
        stopAccepting()
        val closing = entries.values.toList()
        closing.forEach { retire(it, "cancelled") }
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
        var failure: Exception? = null
        for (entry in closing) try {
            entry.cleanup.get(maxOf(1, deadline - System.nanoTime()), TimeUnit.NANOSECONDS)
        } catch (error: Exception) { failure = combine(failure, error) }
        if (closing.all { it.cleanup.isDone }) {
            scheduler.shutdown()
            if (!scheduler.awaitTermination(maxOf(1, deadline - System.nanoTime()), TimeUnit.NANOSECONDS)) {
                failure = combine(failure, TimeoutException("Linux approval cancellation workers have not retired"))
            }
        }
        failure?.let { throw it }
    }

    private fun writeOnce(path: Path, value: JSONObject) {
        FileChannel.open(path, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS).use { file ->
            val bytes = ByteBuffer.wrap(value.toString().toByteArray(Charsets.UTF_8))
            while (bytes.hasRemaining()) file.write(bytes)
            file.force(true)
        }
        sync(path.parent)
    }

    private fun response(entry: Entry, outcome: String) = JSONObject().put("id", entry.id).put("sessionId", entry.sessionId)
        .put("outcome", outcome).put("approvalId", if (outcome == "allowed-once") entry.approvalId else JSONObject.NULL)
        .put("token", if (outcome == "allowed-once") entry.token else JSONObject.NULL)
        .put("route", if (outcome == "allowed-once") entry.routeLabel else JSONObject.NULL)

    private fun checkedRequest(params: JSONObject): JSONObject {
        exact(params, setOf("id", "sessionId", "callId", "approvalAuditId", "command", "timeoutMs", "persistChanges", "exactHosts", "networkCallLimit"))
        uuid(params, "id"); uuid(params, "approvalAuditId")
        text(params, "sessionId").also(IsolatedScriptWire::requireSessionId)
        require(text(params, "callId").let { it.isNotBlank() && it.length <= 512 && !it.contains('\u0000') })
        require(text(params, "command").let { it.isNotBlank() && !it.contains('\u0000')
            && it.toByteArray(Charsets.UTF_8).size <= LinuxVmConsole.MAX_COMMAND_BYTES })
        require(params.opt("timeoutMs") is Int || params.opt("timeoutMs") is Long)
        require(params.getLong("timeoutMs") in 1000..120_000 && params.opt("persistChanges") is Boolean)
        require(params.opt("networkCallLimit") is Int && params.getInt("networkCallLimit") in 1..64)
        val hosts = params.getJSONArray("exactHosts")
        require(hosts.length() in 1..32)
        val names = (0 until hosts.length()).map { require(hosts.get(it) is String); hosts.getString(it) }
        require(names.toSet().size == names.size)
        IsolatedNetworkBroker.Policy(names.toSet())
        return JSONObject(params.toString())
    }

    private fun routeLabel(route: JSONObject): String {
        exact(route, setOf("mode", "url"))
        return when (route.getString("mode")) {
            "system" -> { require(route.isNull("url")); "手机网络（含当前 VPN）" }
            "local" -> {
                val uri = java.net.URI(route.getString("url"))
                require(uri.scheme == "http" && uri.host == "127.0.0.1" && uri.port in 1..65535
                    && uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null && uri.rawPath.isEmpty())
                "HTTP 127.0.0.1:${uri.port}"
            }
            else -> error("Linux proxy route is unavailable")
        }
    }
    private fun exact(value: JSONObject, keys: Set<String>) { require(value.keys().asSequence().toSet() == keys) }
    private fun text(value: JSONObject, key: String): String { require(value.opt(key) is String); return value.getString(key) }
    private fun uuid(value: JSONObject, key: String) = text(value, key).also { require(UUID.fromString(it).toString() == it) }
}
