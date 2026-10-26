package com.minnnng.dsh_android

import android.app.Activity
import android.app.Instrumentation
import android.database.MatrixCursor
import android.os.Bundle
import android.provider.DocumentsContract

/** Exercises the same Android Cursor adapter used by SAF search with reordered provider fields. */
class DocumentSearchColumnsInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val result = Bundle()
        try {
            MatrixCursor(arrayOf("flags", "mime_type", "document_id", "_display_name")).use { cursor ->
                cursor.addRow(arrayOf<Any?>(DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT,
                    "text/plain", "root:notes.txt", "notes.txt"))
                check(cursor.moveToFirst())
                val row = DocumentSearchColumns(cursor.columnNames, true,
                    DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT)
                    .read(DocumentSearchManager.CursorValues(cursor))
                check(row.documentId == "root:notes.txt" && row.name == "notes.txt" &&
                    row.mime == "text/plain" && row.size == null && row.virtual)
            }
            MatrixCursor(arrayOf("_display_name", "mime_type")).use { cursor ->
                cursor.addRow(arrayOf("root", DocumentsContract.Document.MIME_TYPE_DIR))
                check(cursor.moveToFirst())
                val row = DocumentSearchColumns(cursor.columnNames, false,
                    DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT)
                    .read(DocumentSearchManager.CursorValues(cursor))
                check(row.documentId == null && row.name == "root" &&
                    row.mime == DocumentsContract.Document.MIME_TYPE_DIR && row.size == null)
            }
            result.putString("passed", "reordered-provider-columns, optional-fields-omitted")
            finish(Activity.RESULT_OK, result)
        } catch (failure: Throwable) {
            result.putString("failure", failure.stackTraceToString())
            finish(Activity.RESULT_CANCELED, result)
        }
    }
}
