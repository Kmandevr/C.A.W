// Linked sample folders on Android (#229) over "caw/linked_folders": the system folder picker with a persisted read grant, a bounded listing, and files opened as descriptors the engine reads through /proc/self/fd.
package com.kmandevr.caw

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * The Storage Access Framework, no storage permission (docs/decisions.md, "Linked sample folders on Android"):
 * ACTION_OPEN_DOCUMENT_TREE picks a folder and takePersistableUriPermission keeps read access across restarts
 * (developer.android.com, "Access documents and other files from shared storage", read 2026-11-17). Children are
 * listed through DocumentsContract under the tree, so nothing outside the picked folder is reachable. A file is
 * opened read-only with ContentResolver.openFileDescriptor and handed to Dart as a raw descriptor (detachFd); Dart
 * and the engine read it as /proc/self/fd/<n> and Dart closes it again through "close".
 */
class LinkedFolders(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private var pendingPick: MethodChannel.Result? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(activity.mainLooper)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pick" -> {
                if (pendingPick != null) return result.error("busy", "a folder picker is already open", null)
                pendingPick = result
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                }
                try {
                    @Suppress("DEPRECATION")
                    activity.startActivityForResult(intent, PICK_REQUEST)
                } catch (e: Exception) {
                    pendingPick = null
                    result.error("unavailable", e.message, null)
                }
            }
            "release" -> {
                val uri = call.argument<String>("uri")
                try {
                    if (uri != null) activity.contentResolver.releasePersistableUriPermission(Uri.parse(uri),
                        Intent.FLAG_GRANT_READ_URI_PERMISSION)
                } catch (_: Exception) {
                }
                result.success(null)
            }
            "reachable" -> {
                val uri = call.argument<String>("uri") ?: return result.success(false)
                result.success(activity.contentResolver.persistedUriPermissions.any { it.uri.toString() == uri && it.isReadPermission })
            }
            "list" -> {
                val uri = call.argument<String>("uri") ?: return result.error("args", "no uri", null)
                val maxDepth = (call.argument<Int>("maxDepth") ?: 16).coerceIn(1, 32)
                val maxFiles = (call.argument<Int>("maxFiles") ?: 50000).coerceIn(1, 200000)
                worker.execute {
                    val out = try {
                        list(Uri.parse(uri), maxDepth, maxFiles)
                    } catch (e: Exception) {
                        mapOf("files" to emptyList<Any>(), "error" to (e.message ?: "the folder could not be read"))
                    }
                    main.post { result.success(out) }
                }
            }
            "open" -> {
                val uri = call.argument<String>("uri")
                val doc = call.argument<String>("doc")
                if (uri == null || doc == null) return result.error("args", "no uri or document", null)
                worker.execute {
                    val fd = try {
                        val tree = Uri.parse(uri)
                        val file = DocumentsContract.buildDocumentUriUsingTree(tree, doc)
                        activity.contentResolver.openFileDescriptor(file, "r")?.detachFd() ?: -1
                    } catch (_: Exception) {
                        -1
                    }
                    main.post { result.success(fd) }
                }
            }
            "close" -> {
                val fd = call.argument<Int>("fd")
                try {
                    if (fd != null && fd > 2) ParcelFileDescriptor.adoptFd(fd).close()
                } catch (_: Exception) {
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun safeName(n: String): Boolean =
        n.isNotEmpty() && n.length <= 255 && !n.startsWith(".") && !n.contains('/') && !n.contains('\\') &&
            n.none { it.code < 0x20 || it.code == 0x7f }

    /** Breadth first under the tree, at most [maxDepth] folders deep and [maxFiles] audio files. */
    private fun list(tree: Uri, maxDepth: Int, maxFiles: Int): Map<String, Any> {
        val files = ArrayList<Map<String, Any>>()
        var truncated = false
        val queue = ArrayDeque<Triple<String, String, Int>>()
        queue.add(Triple(DocumentsContract.getTreeDocumentId(tree), "", 0))
        val columns = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        var folders = 0
        while (queue.isNotEmpty()) {
            val (parent, prefix, depth) = queue.removeFirst()
            if (++folders > 20000) {
                truncated = true
                break
            }
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parent)
            activity.contentResolver.query(children, columns, null, null, null)?.use { c ->
                while (c.moveToNext()) {
                    val id = c.getString(0) ?: continue
                    val name = c.getString(1) ?: continue
                    if (!safeName(name)) continue
                    val mime = c.getString(2) ?: ""
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        if (depth + 1 < maxDepth) queue.add(Triple(id, "$prefix$name/", depth + 1)) else truncated = true
                        continue
                    }
                    val ext = name.substringAfterLast('.', "").lowercase()
                    if (ext !in AUDIO) continue
                    if (files.size >= maxFiles) {
                        truncated = true
                        return mapOf("files" to files, "truncated" to true)
                    }
                    val size = if (c.isNull(3)) 0L else c.getLong(3)
                    val modified = if (c.isNull(4)) 0L else c.getLong(4)
                    files.add(mapOf("rel" to "$prefix$name", "doc" to id, "size" to size, "modified" to modified))
                }
            }
        }
        return mapOf("files" to files, "truncated" to truncated)
    }

    /** MainActivity forwards activity results here; true when it was this class's picker. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_REQUEST) return false
        val result = pendingPick ?: return true
        pendingPick = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        try {
            activity.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (e: SecurityException) {
            result.error("grant", "the folder's access could not be kept: ${e.message}", null)
            return true
        }
        var name = "Folder"
        try {
            val doc = DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
            activity.contentResolver.query(doc, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)
                ?.use { c -> if (c.moveToFirst()) name = c.getString(0) ?: name }
        } catch (_: Exception) {
        }
        result.success(mapOf("uri" to uri.toString(), "name" to name))
        return true
    }

    companion object {
        private const val PICK_REQUEST = 4733
        private val AUDIO = setOf("wav", "wave", "flac", "mp3")
    }
}
