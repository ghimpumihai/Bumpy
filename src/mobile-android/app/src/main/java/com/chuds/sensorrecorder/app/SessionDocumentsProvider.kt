package com.chuds.sensorrecorder.app

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import com.chuds.sensorrecorder.R
import java.io.File
import java.io.FileNotFoundException

/**
 * Session folders in the phone's Files app, like the iOS app's (Android hides `Android/data` there).
 * Read-only: nothing is deleted on a phone until its trip is verified in the cloud.
 */
class SessionDocumentsProvider : DocumentsProvider() {
    private val root: File by lazy {
        val ctx = checkNotNull(context)
        File(ctx.getExternalFilesDir(null) ?: ctx.filesDir, "sessions").canonicalFile
    }

    override fun onCreate() = true

    private fun file(id: String): File {
        val f = File(root, id).canonicalFile
        if (f != root && !f.path.startsWith(root.path + File.separator)) throw FileNotFoundException(id)
        if (!f.exists() && f != root) throw FileNotFoundException(id)
        return f
    }

    override fun queryRoots(projection: Array<out String>?): Cursor = MatrixCursor(projection ?: ROOT_COLUMNS).apply {
        newRow().add(Root.COLUMN_ROOT_ID, "sessions")
            .add(Root.COLUMN_DOCUMENT_ID, "")
            .add(Root.COLUMN_TITLE, "Bumpy")
            .add(Root.COLUMN_SUMMARY, "Recorded trips")
            .add(Root.COLUMN_FLAGS, Root.FLAG_LOCAL_ONLY or Root.FLAG_SUPPORTS_IS_CHILD)
            .add(Root.COLUMN_ICON, R.mipmap.ic_launcher)
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor =
        MatrixCursor(projection ?: DOCUMENT_COLUMNS).also { add(it, file(documentId)) }

    override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor =
        MatrixCursor(projection ?: DOCUMENT_COLUMNS).also { c ->
            file(parentDocumentId).listFiles().orEmpty().sortedByDescending { it.name }.forEach { add(c, it) }
        }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean =
        (file(documentId).path + File.separator).startsWith(file(parentDocumentId).path + File.separator)

    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException("read-only")
        return ParcelFileDescriptor.open(file(documentId), ParcelFileDescriptor.MODE_READ_ONLY)
    }

    private fun add(c: MatrixCursor, f: File) {
        c.newRow().add(Document.COLUMN_DOCUMENT_ID, f.path.removePrefix(root.path).trimStart(File.separatorChar))
            .add(Document.COLUMN_DISPLAY_NAME, if (f == root) "Bumpy" else f.name)
            .add(Document.COLUMN_MIME_TYPE, if (f.isDirectory) Document.MIME_TYPE_DIR else mime(f))
            .add(Document.COLUMN_LAST_MODIFIED, f.lastModified())
            .add(Document.COLUMN_SIZE, f.length())
            .add(Document.COLUMN_FLAGS, 0)
    }

    private fun mime(f: File) = when (f.extension) {
        "csv" -> "text/csv"
        "json" -> "application/json"
        "txt" -> "text/plain"
        else -> "application/octet-stream"
    }

    private companion object {
        val ROOT_COLUMNS = arrayOf(
            Root.COLUMN_ROOT_ID, Root.COLUMN_DOCUMENT_ID, Root.COLUMN_TITLE, Root.COLUMN_SUMMARY, Root.COLUMN_FLAGS, Root.COLUMN_ICON,
        )
        val DOCUMENT_COLUMNS = arrayOf(
            Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE,
            Document.COLUMN_LAST_MODIFIED, Document.COLUMN_SIZE, Document.COLUMN_FLAGS,
        )
    }
}
