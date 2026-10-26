package com.minnnng.dsh_android

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import org.json.JSONArray
import org.json.JSONObject
import java.nio.file.Files
import java.util.UUID

/** Device-side path identity acceptance; does not start or approve a script. */
class ManualIsolatedScriptSelectionInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val result = Bundle()
        try {
            val app = targetContext.applicationContext
            val root = app.noBackupFilesDir.toPath().resolve("dsh/workspace")
            Files.createDirectories(root)
            val directory = Files.createTempDirectory(root, "manual-selection-")
            val file = directory.resolve("note.txt")
            Files.write(file, "test".toByteArray())
            val workspaceId = UUID.randomUUID().toString()
            val sessionId = UUID.randomUUID().toString()
            val catalog = JSONObject().put("sessions", JSONArray().put(JSONObject()
                .put("sessionId", sessionId).put("cwd", directory.toString())))
                .put("workspaces", JSONArray().put(JSONObject()
                    .put("workspaceId", workspaceId).put("path", directory.toString())
                    .put("sessionIds", JSONArray().put(sessionId))))
            fun request(name: String) = JSONObject()
                .put("sessionId", sessionId).put("workspaceId", workspaceId)
                .put("file", name).put("writable", false).put("host", "")
                .put("program", "async (input, host) => ({ ok: true })")
                .put("inputJson", "{}").put("deadlineMillis", 1_000)
            check(ManualIsolatedScriptRequest.select(request("note.txt"), catalog,
                java.io.File(app.applicationInfo.dataDir), root.toFile()).file == "note.txt")
            val grantDirectory = directory.resolve("notes")
            Files.createDirectory(grantDirectory)
            Files.write(grantDirectory.resolve("child.txt"), "child".toByteArray())
            val selectedDirectory = ManualIsolatedScriptRequest.select(request("notes/").put("writable", true),
                catalog, java.io.File(app.applicationInfo.dataDir), root.toFile())
            check(selectedDirectory.file == "notes/" && selectedDirectory.writable)
            check(selectedDirectory.scope("manual-directory", 2L,
                java.io.File(app.applicationInfo.dataDir).toPath()).readablePaths() == setOf("notes/"))
            val directoryReview = selectedDirectory.admission(UUID.randomUUID().toString(),
                "manual-directory", 2L).getJSONObject("scope")
            check(directoryReview.getJSONArray("writablePaths").getString(0) == "notes/")
            Files.move(grantDirectory, directory.resolve("old-notes"))
            Files.createDirectory(grantDirectory)
            val replacedDirectory = ManualIsolatedScriptRequest.select(request("notes/").put("writable", true), catalog,
                java.io.File(app.applicationInfo.dataDir), root.toFile())
            check(!selectedDirectory.sameIdentity(replacedDirectory)) {
                "A replaced directory retained the approved identity"
            }
            val beforeReplacement = ManualIsolatedScriptRequest.select(request("note.txt"), catalog,
                java.io.File(app.applicationInfo.dataDir), root.toFile())
            Files.move(file, directory.resolve("old-note.txt"))
            Files.write(file, "a replacement file with a different length".toByteArray())
            val afterReplacement = ManualIsolatedScriptRequest.select(request("note.txt"), catalog,
                java.io.File(app.applicationInfo.dataDir), root.toFile())
            check(!beforeReplacement.sameIdentity(afterReplacement)) {
                "A replaced file retained an old review identity"
            }
            val movedSession = JSONObject(catalog.toString())
            movedSession.getJSONArray("workspaces").getJSONObject(0)
                .put("sessionIds", JSONArray())
            try {
                ManualIsolatedScriptRequest.select(request("note.txt"), movedSession,
                    java.io.File(app.applicationInfo.dataDir), root.toFile())
                error("Removed workspace membership admitted")
            } catch (_: IllegalArgumentException) { }
            for (bad in listOf("../note.txt", "note.txt/", "/note.txt", "notes//", "notes/../")) {
                try {
                    ManualIsolatedScriptRequest.select(request(bad), catalog,
                        java.io.File(app.applicationInfo.dataDir), root.toFile())
                    error("Invalid file target admitted")
                } catch (_: IllegalArgumentException) { }
            }
            val link = directory.resolve("link.txt")
            Files.createSymbolicLink(link, file)
            try {
                ManualIsolatedScriptRequest.select(request("link.txt"), catalog,
                    java.io.File(app.applicationInfo.dataDir), root.toFile())
                error("Symlink admitted")
            } catch (_: IllegalArgumentException) { }
            Files.createSymbolicLink(directory.resolve("linked-notes"), grantDirectory)
            try {
                ManualIsolatedScriptRequest.select(request("linked-notes/"), catalog,
                    java.io.File(app.applicationInfo.dataDir), root.toFile())
                error("Symlinked directory admitted")
            } catch (_: IllegalArgumentException) { }
            val unrelated = request("note.txt").put("sessionId", UUID.randomUUID().toString())
            try {
                ManualIsolatedScriptRequest.select(unrelated, catalog,
                    java.io.File(app.applicationInfo.dataDir), root.toFile())
                error("Unregistered session admitted")
            } catch (_: IllegalArgumentException) { }
            val hostOnly = request("").put("workspaceId", "")
                .put("host", "https://example.org")
            check(ManualIsolatedScriptRequest.select(hostOnly, catalog,
                java.io.File(app.applicationInfo.dataDir), root.toFile()).host == "example.org")
            try {
                ManualIsolatedScriptRequest.select(hostOnly.put("host", "http://example.org"), catalog,
                    java.io.File(app.applicationInfo.dataDir), root.toFile())
                error("Non-HTTPS host admitted")
            } catch (_: IllegalArgumentException) { }
            // The same approved plan must still reserve a one-use receipt if the user
            // cancels before guest execution starts.
            val selected = ManualIsolatedScriptRequest.select(request("note.txt"), catalog,
                java.io.File(app.applicationInfo.dataDir), root.toFile())
            val runId = UUID.randomUUID().toString()
            val ownerId = "manual-$runId"
            val policyDirectory = java.io.File(app.filesDir, "manual-test-policy-$runId")
            check(policyDirectory.mkdirs())
            val handle = IsolatedScriptRunController.newPolicyOwner(app, policyDirectory,
                ownerId, sessionId)
            val bridge = IsolatedRunNativeBridge(app)
            val inbox = IsolatedExecutionApprovalInbox()
            try {
                val version = handle.owner.current().version() + 1
                val scope = selected.scope(ownerId, version,
                    java.io.File(app.applicationInfo.dataDir).toPath())
                val review = inbox.prepare(runId, scope, selected.program,
                    selected.inputJson, selected.deadlineMillis,
                    object : IsolatedExecutionApprovalInbox.Decision {
                        override fun approve(approved: IsolatedExecutionPolicyOwner.Scope,
                            namedRunId: String, approvalId: String) {
                            handle.approveTrustedUiChoiceForRun(approved, approvalId, namedRunId)
                            bridge.installApprovedPlan(namedRunId, sessionId, workspaceId,
                                approved, handle, selected.program, selected.inputJson,
                                selected.deadlineMillis)
                        }
                        override fun deny(namedRunId: String) {
                            bridge.discardApprovedPlan(namedRunId)
                            handle.close()
                        }
                    })
                inbox.approve(review.id(), review.challenge(), review.snapshotSha256())
                val admitted = bridge.admit(selected.admission(runId, ownerId, version))
                val token = JSONObject().put("runId", runId)
                    .put("token", admitted.getString("token"))
                check(bridge.cancel(token))
                check(bridge.settle(token).getString("state") == "CANCELLED")
                check(IsolatedScriptRunController.readReceipt(app, runId).state() ==
                    IsolatedScriptReceipt.State.CANCELLED)
                check(bridge.release(token))
            } finally { inbox.close(); bridge.close(); handle.close() }
            result.putString("passed", "registered-file-and-directory, replacement, membership, traversal, symlink, session, exact-https-host, approved-cancel-receipt")
            finish(Activity.RESULT_OK, result)
        } catch (failure: Throwable) {
            result.putString("failure", failure.stackTraceToString())
            finish(Activity.RESULT_CANCELED, result)
        }
    }
}
