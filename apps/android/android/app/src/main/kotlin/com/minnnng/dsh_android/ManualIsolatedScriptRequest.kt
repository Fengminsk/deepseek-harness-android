package com.minnnng.dsh_android

import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.attribute.BasicFileAttributes
import java.util.UUID

/** Validates a user-selected, registered App-private workspace before any approval is prepared. */
internal object ManualIsolatedScriptRequest {
    data class Selection(
        val sessionId: String, val workspaceId: String?, val workspace: Path?,
        val file: String?, val fileIdentity: String?, val writable: Boolean, val host: String?,
        val program: String, val inputJson: String, val deadlineMillis: Int,
    ) {
        val needsApproval get() = file != null || host != null
        fun request() = JSONObject().put("sessionId", sessionId)
            .put("workspaceId", workspaceId ?: "").put("file", file ?: "")
            .put("writable", writable).put("host", if (host == null) "" else "https://$host")
            .put("program", program).put("inputJson", inputJson)
            .put("deadlineMillis", deadlineMillis)

        fun sameIdentity(other: Selection) = sessionId == other.sessionId &&
            workspaceId == other.workspaceId && workspace == other.workspace &&
            file == other.file && fileIdentity == other.fileIdentity &&
            writable == other.writable && host == other.host &&
            program == other.program && inputJson == other.inputJson &&
            deadlineMillis == other.deadlineMillis
        fun scope(ownerId: String, version: Long, appRoot: Path): IsolatedExecutionPolicyOwner.Scope {
            val readable = if (file == null) emptySet() else setOf(file)
            val writablePaths = if (writable && file != null) setOf(file) else emptySet()
            return if (!needsApproval) IsolatedExecutionPolicyOwner.Scope.denied(ownerId, sessionId, version)
            else IsolatedExecutionPolicyOwner.Scope.granted(
                ownerId, sessionId, version, if (file == null) null else appRoot,
                if (file == null) null else workspace, readable, writablePaths,
                if (host == null) emptySet() else setOf(host),
                if (file == null) 0 else 16, if (host == null) 0 else 8,
                maxOf(30_000L, deadlineMillis.toLong() + 5_000L),
            )
        }
        fun admission(runId: String, ownerId: String, version: Long) = JSONObject()
            .put("kind", "script").put("runId", runId).put("sessionId", sessionId)
            .put("program", program).put("inputJson", inputJson)
            .put("deadlineMillis", deadlineMillis)
            .put("scope", JSONObject().put("ownerId", ownerId).put("sessionId", sessionId)
                .put("version", version).put("workspaceId", workspaceId ?: JSONObject.NULL)
                .put("readablePaths", org.json.JSONArray(if (file == null) emptyList() else listOf(file)))
                .put("writablePaths", org.json.JSONArray(if (writable && file != null) listOf(file) else emptyList()))
                .put("exactHosts", org.json.JSONArray(if (host == null) emptyList() else listOf(host)))
                .put("fileCallLimit", if (file == null) 0 else 16)
                .put("networkCallLimit", if (host == null) 0 else 8)
                .put("leaseMillis", maxOf(30_000L, deadlineMillis.toLong() + 5_000L)))
    }

    fun select(params: JSONObject, catalog: JSONObject, appRoot: File, runtimeWorkspace: File): Selection {
        require(params.keys().asSequence().toSet() == setOf(
            "sessionId", "workspaceId", "file", "writable", "host", "program", "inputJson", "deadlineMillis"))
        val sessionId = params.getString("sessionId")
        require(UUID.fromString(sessionId).toString() == sessionId)
        val workspaceId = params.optString("workspaceId").takeIf { it.isNotBlank() }
        if (workspaceId != null) require(UUID.fromString(workspaceId).toString() == workspaceId)
        val file = params.optString("file").takeIf { it.isNotBlank() }
        val writable = params.getBoolean("writable")
        require(!writable || file != null)
        val host = params.optString("host").takeIf { it.isNotBlank() }
        if (host != null) {
            require(host.startsWith("https://")) { "Only an exact HTTPS host may be selected" }
            val value = host.removePrefix("https://")
            require(!value.contains('/') && !value.contains('?') && !value.contains('#') &&
                !value.contains(':') && !value.contains('@')) { "Choose one HTTPS host, without a path or port" }
            IsolatedNetworkBroker.Policy(setOf(value))
        }
        val program = params.getString("program")
        val inputJson = params.getString("inputJson")
        val deadlineMillis = params.getInt("deadlineMillis")
        PtcScriptEngine.validate(program, inputJson, deadlineMillis)
        val sessions = catalog.getJSONArray("sessions")
        val registeredSession = (0 until sessions.length()).map { sessions.getJSONObject(it) }
            .firstOrNull { it.optString("sessionId") == sessionId }
            ?: throw IllegalArgumentException("Session is not registered")
        var workspace: Path? = null
        var fileIdentity: String? = null
        if (file != null) {
            require(workspaceId != null) { "A file or directory needs a registered workspace" }
            val workspaces = catalog.getJSONArray("workspaces")
            val registered = (0 until workspaces.length()).map { workspaces.getJSONObject(it) }
                .firstOrNull { it.optString("workspaceId") == workspaceId }
                ?: throw IllegalArgumentException("Workspace is not registered")
            val memberIds = registered.getJSONArray("sessionIds")
            require((0 until memberIds.length()).any { memberIds.getString(it) == sessionId }) {
                "Session workspace changed"
            }
            val expected = java.nio.file.Paths.get(registered.getString("path")).toAbsolutePath().normalize()
            val runtimeRoot = runtimeWorkspace.toPath().toRealPath()
            require(expected.startsWith(runtimeRoot)) { "Only the App-private runtime workspace is supported" }
            require(registeredSession.optString("cwd") == expected.toString()) {
                "Session workspace identity changed"
            }
            val privateRoot = appRoot.toPath().toRealPath()
            require(expected.startsWith(privateRoot) && expected != privateRoot)
            var cursor = privateRoot
            for (segment in privateRoot.relativize(expected)) {
                cursor = cursor.resolve(segment)
                require(!Files.isSymbolicLink(cursor)) { "Workspace link is unavailable" }
            }
            require(Files.isDirectory(expected, LinkOption.NOFOLLOW_LINKS))
            workspace = expected.toRealPath()
            // A trailing slash is an explicit directory grant. The broker still
            // requires a bounded relative child name for every guest operation.
            IsolatedCapabilityBroker.GrantSpec(file, setOf(IsolatedCapabilityBroker.Action.READ))
            cursor = workspace
            for (segment in java.nio.file.Paths.get(file.removeSuffix("/"))) {
                cursor = cursor.resolve(segment)
                require(!Files.isSymbolicLink(cursor)) { "Selected path link is unavailable" }
            }
            require(if (file.endsWith('/')) Files.isDirectory(cursor, LinkOption.NOFOLLOW_LINKS)
                else Files.isRegularFile(cursor, LinkOption.NOFOLLOW_LINKS)) {
                "Select an existing regular file or directory"
            }
            require(cursor.toRealPath().startsWith(workspace))
            val attributes = Files.readAttributes(cursor, BasicFileAttributes::class.java,
                LinkOption.NOFOLLOW_LINKS)
            fileIdentity = attributes.fileKey()?.toString()
                ?: "${attributes.creationTime().toMillis()}:${attributes.lastModifiedTime().toMillis()}:${attributes.size()}"
        }
        return Selection(sessionId, if (file == null) null else workspaceId,
            workspace, file, fileIdentity, writable, host?.removePrefix("https://"),
            program, inputJson, deadlineMillis)
    }
}
