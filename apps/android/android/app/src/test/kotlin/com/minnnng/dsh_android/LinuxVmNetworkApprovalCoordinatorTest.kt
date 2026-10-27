package com.minnnng.dsh_android

import org.json.JSONArray
import org.json.JSONObject
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Host approval tests: real Inbox/PolicyOwner/ApprovalStore, no Android gesture or guest evidence. */
object LinuxVmNetworkApprovalCoordinatorTest {
    private class Fixture(val available: Boolean = true, reviewMillis: Long = 120_000, tokenMillis: Long = 30_000) : AutoCloseable {
        val root = Files.createTempDirectory("linux-network-approval-")
        val inbox = IsolatedExecutionApprovalInbox()
        val executor = Executors.newCachedThreadPool()
        val offered = CompletableFuture<IsolatedExecutionApprovalInbox.Review>()
        val calls = AtomicInteger()
        val cancels = AtomicInteger()
        val routeChanges = CopyOnWriteArrayList<() -> Unit>()
        var route = JSONObject().put("mode", "local").put("url", "http://127.0.0.1:7890")
        var onExecute: (IsolatedExecutionPolicyOwner.Lease) -> Unit = {}
        var onCancel: () -> Unit = {}
        var onSync: (java.nio.file.Path) -> Unit = {}
        val coordinator = LinuxVmNetworkApprovalCoordinator(root, root.resolve("policies"), inbox,
            currentRoute = { JSONObject(route.toString()) },
            observeRoute = { _, changed -> routeChanges.add(changed); AutoCloseable { routeChanges.remove(changed) } },
            execute = { params, lease, approvedRoute ->
                check(lease.runId() == params.getString("id") && lease.active(lease.policy().version()))
                check(lease.policy().appPrivateRoot() == null && lease.policy().workspaceRoot() == null)
                check(lease.policy().readablePaths().isEmpty() && lease.policy().writablePaths().isEmpty())
                check(lease.policy().fileCallLimit() == 0 && lease.policy().exactHosts() == setOf("example.com"))
                check(approvedRoute.toString() == route.toString())
                calls.incrementAndGet(); onExecute(lease)
                JSONObject().put("id", params.getString("id")).put("hostFixtureOnly", true)
            }, cancelExecution = { cancels.incrementAndGet(); onCancel() },
            offer = { offered.complete(it); available }, dismiss = {}, sync = { onSync(it) },
            reviewMillis = reviewMillis, unusedTokenMillis = tokenMillis)

        fun request() = JSONObject().put("id", UUID.randomUUID().toString()).put("sessionId", "approval-host-session")
            .put("callId", "original-tool-call").put("approvalAuditId", UUID.randomUUID().toString())
            .put("command", "dsh-fetch https://example.com/info").put("timeoutMs", 120_000).put("persistChanges", false)
            .put("exactHosts", JSONArray(listOf("example.com"))).put("networkCallLimit", 3)
        fun review(request: JSONObject) = CompletableFuture.supplyAsync({ coordinator.review(request) }, executor)
        fun approve(request: JSONObject): JSONObject {
            val pending = review(request)
            val ui = offered.get(3, TimeUnit.SECONDS)
            check(!pending.isDone && calls.get() == 0)
            // This invokes the exact trusted decision method. It does not certify an Android click.
            inbox.approve(ui.id(), ui.challenge(), ui.snapshotSha256())
            return pending.get(3, TimeUnit.SECONDS)
        }
        fun execution(request: JSONObject, grant: JSONObject) = JSONObject().apply {
            for (key in listOf("id", "sessionId", "command", "timeoutMs", "persistChanges", "approvalAuditId")) put(key, request.get(key))
            put("approvalToken", grant.getString("token"))
        }
        fun cancel(request: JSONObject) = coordinator.cancelReview(JSONObject().put("id", request.getString("id"))
            .put("sessionId", request.getString("sessionId")))
        override fun close() {
            try { coordinator.close() } finally { inbox.close(); executor.shutdownNow() }
        }
    }
    private fun rejects(action: () -> Unit) {
        try { action() } catch (_: Exception) { return }
        error("Expected rejection")
    }
    private fun checkCase(name: String, body: () -> Unit) { body(); println("PASS: $name") }

    @JvmStatic fun main(args: Array<String>) {
        checkCase("no usable foreground UI returns unavailable without a grant or execution") {
            Fixture(false).use { f ->
                val reply = f.review(f.request()).get(3, TimeUnit.SECONDS)
                check(reply.getString("outcome") == "unavailable" && reply.isNull("token") && f.calls.get() == 0)
            }
        }
        checkCase("trusted approval binds the full 120-second command and consumes a token once") {
            Fixture().use { f ->
                val request = f.request(); val grant = f.approve(request)
                check(grant.getString("outcome") == "allowed-once")
                check(UUID.fromString(grant.getString("approvalId")).toString() == grant.getString("approvalId"))
                val history = f.root.resolve("policies").resolve(request.getString("id"))
                val saved = JSONObject(Files.readString(history.resolve("request.json")))
                check(saved.getLong("timeoutMs") == 120_000L && saved.getString("command") == request.getString("command"))
                check(saved.getJSONObject("route").getString("url").endsWith(":7890"))
                check(f.coordinator.executeNetwork(f.execution(request, grant)).getBoolean("approvalCleanupConfirmed"))
                rejects { f.coordinator.executeNetwork(f.execution(request, grant)) }
                check(f.calls.get() == 1 && Files.exists(history.resolve("admitted.json")))
                IsolatedExecutionApprovalStore(f.root, history, "linux-network-${request.getString("id")}",
                    request.getString("sessionId"), {}).use { check(it.recoveredDenied().exactHosts().isEmpty()) }
            }
        }
        for (field in listOf("command", "sessionId", "timeoutMs", "persistChanges", "approvalAuditId", "approvalToken")) {
            checkCase("changed $field cannot consume an approved command") {
                Fixture().use { f ->
                    val request = f.request(); val grant = f.approve(request); val execute = f.execution(request, grant)
                    execute.put(field, when (field) {
                        "timeoutMs" -> 1000; "persistChanges" -> true
                        "approvalAuditId", "approvalToken" -> UUID.randomUUID().toString()
                        else -> "different"
                    })
                    rejects { f.coordinator.executeNetwork(execute) }; check(f.calls.get() == 0)
                }
            }
        }
        checkCase("pending and early cancellation settle the review without authority") {
            Fixture().use { f ->
                val request = f.request(); val waiting = f.review(request); f.offered.get(3, TimeUnit.SECONDS)
                check(f.cancel(request).getBoolean("revoked")); check(f.cancel(request).getBoolean("revoked"))
                check(waiting.get(3, TimeUnit.SECONDS).getString("outcome") == "cancelled")
                check(f.calls.get() == 0)
                val early = f.request(); f.cancel(early)
                check(f.review(early).get(3, TimeUnit.SECONDS).getString("outcome") == "cancelled")
            }
        }
        checkCase("route change invalidates pending review and unused approved token") {
            for (approved in listOf(false, true)) Fixture().use { f ->
                val request = f.request(); val waiting = f.review(request); val ui = f.offered.get(3, TimeUnit.SECONDS)
                if (approved) f.inbox.approve(ui.id(), ui.challenge(), ui.snapshotSha256())
                val grant = if (approved) waiting.get(3, TimeUnit.SECONDS) else null
                f.route = JSONObject().put("mode", "local").put("url", "http://127.0.0.1:7891")
                if (approved) rejects { f.coordinator.executeNetwork(f.execution(request, checkNotNull(grant))) }
                else { f.routeChanges.forEach { it() }; check(waiting.get(3, TimeUnit.SECONDS).getString("outcome") == "cancelled") }
                check(f.calls.get() == 0)
            }
        }
        checkCase("review expiry cannot be approved later") {
            Fixture(reviewMillis = 75).use { f ->
                val request = f.request(); val waiting = f.review(request); val ui = f.offered.get(3, TimeUnit.SECONDS)
                check(waiting.get(3, TimeUnit.SECONDS).getString("outcome") == "cancelled")
                rejects { f.inbox.approve(ui.id(), ui.challenge(), ui.snapshotSha256()) }; check(f.calls.get() == 0)
            }
        }
        checkCase("an approved but unused token expires without executing") {
            Fixture(tokenMillis = 75).use { f ->
                val request = f.request(); val grant = f.approve(request)
                val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
                while (f.inbox.list().isNotEmpty() && System.nanoTime() < deadline) Thread.sleep(10)
                rejects { f.coordinator.executeNetwork(f.execution(request, grant)) }; check(f.calls.get() == 0)
            }
        }
        checkCase("duplicate execute and late cancelReview do not revoke a consumed live lease") {
            Fixture().use { f ->
                val request = f.request(); val grant = f.approve(request)
                val entered = CompletableFuture<IsolatedExecutionPolicyOwner.Lease>(); val finish = CompletableFuture<Unit>()
                f.onExecute = { lease -> entered.complete(lease); finish.get(3, TimeUnit.SECONDS) }
                val running = CompletableFuture.supplyAsync({ f.coordinator.executeNetwork(f.execution(request, grant)) }, f.executor)
                try {
                    val lease = entered.get(3, TimeUnit.SECONDS)
                    rejects { f.coordinator.executeNetwork(f.execution(request, grant)) }
                    f.cancel(request)
                    check(lease.active(lease.policy().version()) && f.cancels.get() == 0 && f.calls.get() == 1)
                } finally { finish.complete(Unit); running.get(3, TimeUnit.SECONDS) }
            }
        }
        checkCase("durable admission failure never calls the executor") {
            Fixture().use { f ->
                val request = f.request(); val grant = f.approve(request)
                val history = f.root.resolve("policies").resolve(request.getString("id"))
                Files.writeString(history.resolve("admitted.json"), "existing reservation")
                rejects { f.coordinator.executeNetwork(f.execution(request, grant)) }; check(f.calls.get() == 0)
            }
        }
        checkCase("Inbox deny does not wait for native retirement and coordinator close joins cleanup") {
            Fixture().use { f ->
                val request = f.request(); val grant = f.approve(request)
                val entered = CompletableFuture<Unit>(); val finish = CompletableFuture<Unit>()
                f.onExecute = { entered.complete(Unit); finish.get(3, TimeUnit.SECONDS) }
                f.onCancel = { finish.get(3, TimeUnit.SECONDS) }
                val running = CompletableFuture.supplyAsync({ f.coordinator.executeNetwork(f.execution(request, grant)) }, f.executor)
                var closing: CompletableFuture<Void>? = null
                try {
                    entered.get(3, TimeUnit.SECONDS)
                    val denied = CompletableFuture.runAsync({ f.inbox.close() }, f.executor)
                    denied.get(1, TimeUnit.SECONDS)
                    closing = CompletableFuture.runAsync({ f.coordinator.close() }, f.executor)
                    check(!closing.isDone && !running.isDone)
                } finally { finish.complete(Unit); running.get(3, TimeUnit.SECONDS); closing?.get(3, TimeUnit.SECONDS) }
            }
        }
        checkCase("failed durable UI approval cannot produce a token") {
            Fixture().use { f ->
                val request = f.request(); val waiting = f.review(request); val ui = f.offered.get(3, TimeUnit.SECONDS)
                f.onSync = { throw java.io.IOException("fixture sync failure") }
                rejects { f.inbox.approve(ui.id(), ui.challenge(), ui.snapshotSha256()) }
                check(waiting.get(3, TimeUnit.SECONDS).getString("outcome") == "unavailable" && f.calls.get() == 0)
                // Await the failed cleanup explicitly; the failure is not a successful durable revocation.
                try { f.coordinator.close() } catch (_: Exception) { }
            }
        }
        checkCase("close waits for a cancellation worker even after execution and durable cleanup finish") {
            Fixture().use { f ->
                val request = f.request(); val grant = f.approve(request)
                val entered = CompletableFuture<Unit>(); val finish = CompletableFuture<Unit>()
                val cancelling = CompletableFuture<Unit>(); val cancelFinished = CompletableFuture<Unit>()
                f.onExecute = { entered.complete(Unit); finish.get(3, TimeUnit.SECONDS) }
                f.onCancel = { cancelling.complete(Unit); cancelFinished.get(3, TimeUnit.SECONDS) }
                val running = CompletableFuture.supplyAsync({ f.coordinator.executeNetwork(f.execution(request, grant)) }, f.executor)
                var closing: CompletableFuture<Void>? = null
                try {
                    entered.get(3, TimeUnit.SECONDS); f.inbox.close(); cancelling.get(3, TimeUnit.SECONDS)
                    finish.complete(Unit); running.get(3, TimeUnit.SECONDS)
                    closing = CompletableFuture.runAsync({ f.coordinator.close() }, f.executor)
                    try { closing.get(75, TimeUnit.MILLISECONDS); error("Close returned before its cancellation worker") }
                    catch (_: java.util.concurrent.TimeoutException) { }
                } finally { finish.complete(Unit); cancelFinished.complete(Unit); running.get(3, TimeUnit.SECONDS); closing?.get(3, TimeUnit.SECONDS) }
            }
        }
        checkCase("cleanup failure preserves the actual result and prevents new approvals") {
            Fixture().use { f ->
                val request = f.request(); val grant = f.approve(request)
                f.onExecute = { f.onSync = { throw java.io.IOException("fixture cleanup failure") } }
                val receipt = f.coordinator.executeNetwork(f.execution(request, grant))
                check(receipt.getBoolean("hostFixtureOnly") && receipt.getString("id") == request.getString("id"))
                check(!receipt.getBoolean("approvalCleanupConfirmed"))
                check(receipt.getString("approvalCleanupError") == "durable-revocation-unconfirmed")
                check(f.review(f.request()).get(3, TimeUnit.SECONDS).getString("outcome") == "unavailable")
            }
        }
        println("Host coordinator authorization checks passed; Android UI, fsync and guest networking are not certified.")
    }
}
