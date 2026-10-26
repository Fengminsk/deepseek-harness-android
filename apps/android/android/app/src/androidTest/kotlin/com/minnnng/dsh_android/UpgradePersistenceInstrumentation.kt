package com.minnnng.dsh_android

import android.app.Application
import android.app.Instrumentation
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Bundle
import android.os.Looper
import android.os.Process
import android.provider.DocumentsContract
import android.util.Base64
import java.io.File
import java.io.FileOutputStream
import java.io.FileNotFoundException
import java.io.IOException
import java.nio.file.Files
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.CountDownLatch

/** Device-only, synthetic proof that an APK upgrade preserves private data and Android Keystore access. */
class UpgradePersistenceInstrumentation : Instrumentation() {
    private lateinit var options: Bundle

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        options = arguments ?: Bundle.EMPTY
        start()
    }

    override fun onStart() {
        val result = Bundle()
        try {
            val app = targetContext.applicationContext
            check(Application.getProcessName() == app.packageName + ":agent") {
                "Upgrade acceptance must run in the Agent process"
            }
            check(Looper.myLooper() != Looper.getMainLooper()) {
                "Upgrade acceptance must not block the main thread"
            }
            val token = options.getString("token") ?: error("Missing acceptance token")
            require(token.matches(Regex("[0-9a-f]{32}"))) { "Invalid acceptance token" }
            val phase = options.getString("phase") ?: error("Missing acceptance phase")
            val canary = File(app.noBackupFilesDir, "upgrade-acceptance-$token.canary")
            val reference = "acceptance/upgrade/$token"
            val vault = CredentialVault(app)
            val versionCode = app.packageManager.getPackageInfo(app.packageName, 0).longVersionCode
            val grants = app.contentResolver.persistedUriPermissions
                .filter { it.isReadPermission }
                .map { "${it.uri}|read|write=${it.isWritePermission}" }
                .sorted()
            val grantDigest = sha256(grants.joinToString("\n").toByteArray(Charsets.UTF_8))
            val requireSafGrant = options.getString("requireSafGrant") == "true"
            if (requireSafGrant) check(grants.isNotEmpty()) { "No persisted SAF read grant exists" }
            val safPath = options.getString("safReadablePathBase64")?.let { encoded ->
                String(Base64.decode(encoded, Base64.URL_SAFE or Base64.NO_WRAP), Charsets.UTF_8)
            }
            val safDocument = safPath?.let { path ->
                val expectedRoot = if (phase == "seed") null else expectedDigest("safRootSha256")
                try {
                    readGrantedDocument(app, path, expectedRoot)
                } catch (failure: Exception) {
                    // Provider errors can contain private URI/path details. Keep them out of adb output.
                    throw IOException("SAF readability proof failed (${failure.javaClass.simpleName})")
                }
            }
            val connectivity = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val internetNetworkCount = connectivity.allNetworks.count { network ->
                connectivity.getNetworkCapabilities(network)
                    ?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
            }
            if (options.getString("requireOffline") == "true") {
                check(internetNetworkCount == 0) { "Android still exposes an Internet-capable network" }
            }
            result.putString("phase", phase)
            result.putString("token", token)
            result.putLong("versionCode", versionCode)
            result.putInt("processPid", Process.myPid())
            result.putInt("safGrantCount", grants.size)
            result.putString("safGrantSha256", grantDigest)
            safDocument?.let {
                result.putString("safRootSha256", it.rootSha256)
                result.putString("safDocumentIdSha256", it.documentIdSha256)
                result.putString("safDocumentSha256", it.contentSha256)
                result.putLong("safDocumentBytes", it.bytes)
            }
            result.putInt("internetNetworkCount", internetNetworkCount)
            when (phase) {
                "seed" -> {
                    check(!canary.exists() && !Files.isSymbolicLink(canary.toPath())) {
                        "Acceptance canary already exists"
                    }
                    check(vault.get(reference) == null) { "Acceptance credential already exists" }
                    val bytes = ByteArray(64).also { SecureRandom().nextBytes(it) }
                    val secret = ByteArray(32).also { SecureRandom().nextBytes(it) }
                    val value = Base64.encodeToString(secret, Base64.NO_WRAP)
                    check(canary.createNewFile()) { "Could not create acceptance canary" }
                    FileOutputStream(canary).use { output ->
                        output.write(bytes)
                        output.fd.sync()
                    }
                    vault.set(reference, value)
                    result.putString("canarySha256", sha256(bytes))
                    result.putString("credentialSha256", sha256(value.toByteArray(Charsets.UTF_8)))
                }
                "verify", "cleanup", "hold" -> {
                    val expectedCanary = expectedDigest("canarySha256")
                    val expectedCredential = expectedDigest("credentialSha256")
                    val expectedGrant = expectedDigest("safGrantSha256")
                    val expectedGrantCount = options.getString("safGrantCount")?.toIntOrNull()
                        ?: error("Missing or invalid safGrantCount")
                    check(expectedGrantCount == grants.size && expectedGrant == grantDigest) {
                        "Persisted SAF read grants changed"
                    }
                    if (safDocument != null) {
                        check(safDocument.documentIdSha256 == expectedDigest("safDocumentIdSha256")) {
                            "Persisted SAF document identity changed"
                        }
                        check(safDocument.contentSha256 == expectedDigest("safDocumentSha256")) {
                            "Persisted SAF document content changed or could not be read"
                        }
                        val expectedBytes = options.getString("safDocumentBytes")?.toLongOrNull()
                        check(expectedBytes != null && expectedBytes == safDocument.bytes) {
                            "Persisted SAF document byte count changed"
                        }
                    }
                    check(canary.isFile && !Files.isSymbolicLink(canary.toPath()) && canary.length() == 64L) {
                        "Acceptance canary is absent or changed"
                    }
                    val canarySha = sha256(canary.readBytes())
                    check(canarySha == expectedCanary) { "Acceptance canary digest changed" }
                    val decrypted = vault.get(reference) ?: error("Acceptance credential is absent")
                    val credentialSha = sha256(decrypted.toByteArray(Charsets.UTF_8))
                    check(credentialSha == expectedCredential) { "Android Keystore could not recover acceptance credential" }
                    result.putString("canarySha256", canarySha)
                    result.putString("credentialSha256", credentialSha)
                    if (phase == "hold") {
                        val ready = Bundle().apply {
                            putString("holdReady", "true")
                            putString("token", token)
                            putInt("processPid", Process.myPid())
                        }
                        sendStatus(1, ready)
                        CountDownLatch(1).await()
                        error("Process hold returned without force-stop")
                    }
                    if (phase == "cleanup") {
                        // A failed verification never removes diagnostic evidence. These
                        // names are generated from this test's strict token, not user input paths.
                        vault.set(reference, null)
                        check(canary.delete()) { "Could not remove verified acceptance canary" }
                        check(vault.get(reference) == null && !canary.exists()) {
                            "Acceptance cleanup did not settle"
                        }
                        result.putString("cleaned", "true")
                    }
                }
                else -> error("Unknown acceptance phase")
            }
            result.putString("passed", "true")
            finish(-1, result)
        } catch (failure: Throwable) {
            result.putString("passed", "false")
            result.putString("failure", (failure.javaClass.simpleName + ": " +
                (failure.message ?: "acceptance failed")).take(512))
            finish(0, result)
        }
    }

    private fun expectedDigest(name: String): String =
        (options.getString(name) ?: error("Missing $name")).also {
            require(it.matches(Regex("[0-9a-f]{64}"))) { "Invalid $name" }
        }

    private data class SafDocumentProof(val rootSha256: String, val documentIdSha256: String,
        val contentSha256: String, val bytes: Long)

    /** Read an existing user-granted document; never create, mutate, or log its URI or contents. */
    private fun readGrantedDocument(app: Context, path: String, expectedRoot: String?): SafDocumentProof {
        require(path.length in 1..1024 && !path.startsWith('/') && !path.endsWith('/')) {
            "Invalid SAF relative path"
        }
        val segments = path.split('/')
        require(segments.size <= 16 && segments.all { it.isNotEmpty() && it != "." && it != ".." &&
            it.length <= 255 && !it.contains('\\') && it.none { char -> char.isISOControl() } }) {
            "Invalid SAF relative path segments"
        }
        val resolver = app.contentResolver
        val candidates = app.contentResolver.persistedUriPermissions
            .filter { it.isReadPermission && DocumentsContract.isTreeUri(it.uri) }
            .filter { expectedRoot == null || sha256(it.uri.toString().toByteArray(Charsets.UTF_8)) == expectedRoot }
        val proofs = mutableListOf<SafDocumentProof>()
        for (permission in candidates) {
            val tree = permission.uri
            val rootSha = sha256(tree.toString().toByteArray(Charsets.UTF_8))
            try {
                var document = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                for (segment in segments) {
                    val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree,
                        DocumentsContract.getDocumentId(document))
                    var childId: String? = null
                    resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
                        val idColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                        val nameColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                        var scanned = 0
                        while (cursor.moveToNext()) {
                            check(++scanned <= 4096) { "SAF directory exceeds acceptance scan limit" }
                            if (!cursor.isNull(nameColumn) && cursor.getString(nameColumn) == segment) {
                                check(childId == null) { "SAF path is ambiguous" }
                                childId = cursor.getString(idColumn)
                            }
                        }
                    } ?: throw IOException("SAF provider did not return directory listing")
                    document = DocumentsContract.buildDocumentUriUsingTree(tree,
                        childId ?: throw FileNotFoundException("SAF acceptance document is absent"))
                }
                resolver.query(document, arrayOf(DocumentsContract.Document.COLUMN_MIME_TYPE,
                    DocumentsContract.Document.COLUMN_FLAGS), null, null, null)?.use { cursor ->
                    check(cursor.moveToFirst()) { "SAF acceptance document is absent" }
                    val mime = cursor.getString(cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE))
                    val flags = cursor.getInt(cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_FLAGS))
                    check(mime != DocumentsContract.Document.MIME_TYPE_DIR &&
                        flags and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT == 0) {
                        "SAF acceptance path must name a regular file"
                    }
                } ?: throw IOException("SAF provider did not return document metadata")
                val digest = MessageDigest.getInstance("SHA-256")
                var bytes = 0L
                resolver.openInputStream(document)?.use { input ->
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        bytes += count
                        check(bytes <= 16L * 1024 * 1024) { "SAF acceptance file exceeds 16 MiB limit" }
                        digest.update(buffer, 0, count)
                    }
                } ?: throw IOException("SAF provider could not open document")
                proofs += SafDocumentProof(rootSha,
                    sha256(document.toString().toByteArray(Charsets.UTF_8)), digest.digest().joinToString("") {
                    "%02x".format(it.toInt() and 0xff) }, bytes)
            } catch (missing: FileNotFoundException) {
                if (expectedRoot != null) throw missing
            }
        }
        check(proofs.size == 1) { "Expected exactly one readable SAF document at the relative path" }
        return proofs.single()
    }

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }
}
