package com.minnnng.dsh_android

import android.content.Intent
import android.content.BroadcastReceiver
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.ResultReceiver
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import java.io.File
import java.io.FileNotFoundException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/** Test-APK-only provider. Each grant exposes two generated text files and no host-selected path. */
class PtcSafAcceptanceProvider : DocumentsProvider() {
    private class Fixture(val directory: File) {
        val hold = AtomicBoolean()
        val entered = AtomicBoolean()
    }
    private val fixtures = ConcurrentHashMap<String, Fixture>()

    override fun onCreate() = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
        super.call(method, arg, extras)?.let { return it }
        require(method in setOf("ptc.create", "ptc.arm", "ptc.state", "ptc.revoke", "ptc.remove"))
        val app = requireNotNull(context)
        check(Binder.getCallingUid() == Process.myUid()) { "Fixture control requires the test APK UID" }
        val id = requireNotNull(arg)
        require(UUID.fromString(id).toString() == id && id[14] == '4')
        val identity = Binder.clearCallingIdentity()
        try {
            if (method == "ptc.create") {
                val folder = File(app.cacheDir, "ptc-saf-$id")
                check(folder.mkdir())
                File(folder, "alpha.txt").writeText("PTC SAF needle $id\n", Charsets.UTF_8)
                File(folder, "beta.txt").writeText("unmatched fixture\n", Charsets.UTF_8)
                check(fixtures.putIfAbsent(id, Fixture(folder)) == null)
                val uri = DocumentsContract.buildTreeDocumentUri(AUTHORITY, id)
                app.grantUriPermission(TARGET, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                return Bundle().apply { putString("uri", uri.toString()) }
            }
            val fixture = fixtures[id] ?: throw FileNotFoundException("Unknown test root")
            return Bundle().apply {
                when (method) {
                    "ptc.arm" -> { fixture.entered.set(false); fixture.hold.set(true) }
                    "ptc.state" -> putBoolean("entered", fixture.entered.get())
                    "ptc.revoke", "ptc.remove" -> {
                        app.revokeUriPermission(TARGET, DocumentsContract.buildTreeDocumentUri(AUTHORITY, id),
                            Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        if (method == "ptc.remove") {
                            check(fixtures.remove(id, fixture))
                            for (name in FILES) check(File(fixture.directory, name).delete())
                            check(fixture.directory.delete())
                        }
                    }
                }
            }
        } finally { Binder.restoreCallingIdentity(identity) }
    }

    override fun queryRoots(projection: Array<out String>?): Cursor = MatrixCursor(
        projection ?: arrayOf(DocumentsContract.Root.COLUMN_ROOT_ID,
            DocumentsContract.Root.COLUMN_DOCUMENT_ID, DocumentsContract.Root.COLUMN_TITLE,
            DocumentsContract.Root.COLUMN_FLAGS))

    private fun selection(documentId: String): Pair<Fixture, String?> {
        val parts = documentId.split(':')
        if (parts.size !in 1..2 || (parts.size == 2 && parts[1] !in FILES)) throw FileNotFoundException("Unknown test document")
        return (fixtures[parts[0]] ?: throw FileNotFoundException("Unknown test root")) to parts.getOrNull(1)
    }

    private fun row(cursor: MatrixCursor, documentId: String) {
        val (fixture, fileName) = selection(documentId)
        val file = fileName?.let { File(fixture.directory, it) }
        val values: Map<String, Any?> = mapOf("document_id" to documentId, "_display_name" to (fileName ?: "PTC acceptance"),
            "mime_type" to if (fileName == null) DocumentsContract.Document.MIME_TYPE_DIR else "text/plain",
            "flags" to 0, "_size" to (file?.length() ?: 0L), "last_modified" to (file?.lastModified() ?: 0L))
        cursor.addRow(cursor.columnNames.map { values[it] }.toTypedArray())
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor =
        MatrixCursor(projection ?: COLUMNS).apply { row(this, documentId) }

    override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor {
        val (_, file) = selection(parentDocumentId)
        check(file == null)
        return MatrixCursor(projection ?: COLUMNS).apply { FILES.forEach { row(this, "$parentDocumentId:$it") } }
    }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean =
        fixtures.containsKey(parentDocumentId) && FILES.any { documentId == "$parentDocumentId:$it" }

    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException("Read-only test documents")
        val (fixture, name) = selection(documentId)
        if (name == null) throw FileNotFoundException("Directory")
        if (fixture.hold.get()) {
            val cancelled = CountDownLatch(1)
            signal?.setOnCancelListener { cancelled.countDown() }
            fixture.entered.set(true)
            try {
                check(cancelled.await(20, TimeUnit.SECONDS)) { "Test search was not cancelled" }
                requireNotNull(signal).throwIfCanceled()
                error("Cancellation latch completed without cancellation")
            } finally { signal?.setOnCancelListener(null) }
        }
        signal?.throwIfCanceled()
        return ParcelFileDescriptor.open(File(fixture.directory, name), ParcelFileDescriptor.MODE_READ_ONLY)
    }

    companion object {
        const val AUTHORITY = "com.minnnng.dsh_android.test.ptc.documents"
        const val TARGET = "com.minnnng.dsh_android"
        val CONTROL: Uri = Uri.parse("content://$AUTHORITY")
        private val FILES = listOf("alpha.txt", "beta.txt")
        private val COLUMNS = arrayOf("document_id", "_display_name", "mime_type", "flags", "_size", "last_modified")
    }
}

/** Signature-protected explicit control, running under the provider's test APK UID. */
class PtcSafAcceptanceControlReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val reply = intent.getParcelableExtra("reply", ResultReceiver::class.java) ?: return
        val pending = goAsync()
        Thread({
            try {
                val method = requireNotNull(intent.getStringExtra("method"))
                require(method in setOf("ptc.create", "ptc.arm", "ptc.state", "ptc.revoke", "ptc.remove"))
                val caseId = requireNotNull(intent.getStringExtra("caseId"))
                require(UUID.fromString(caseId).toString() == caseId && caseId[14] == '4')
                val result = requireNotNull(context.contentResolver.call(PtcSafAcceptanceProvider.CONTROL,
                    method, caseId, null))
                reply.send(1, result)
            } catch (failure: Throwable) {
                reply.send(0, Bundle().apply { putString("failure", (failure.javaClass.simpleName + ": " + failure.message).take(512)) })
            } finally { pending.finish() }
        }, "ptc-saf-control").start()
    }
}
