package com.example.nas_player

import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.webkit.CookieManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Extends AudioServiceActivity so the UI and the media service share one
 * Flutter engine (required by audio_service 0.18.x).
 *
 * Channels:
 *  - nasplayer/cookies: exposes android.webkit.CookieManager so HttpOnly NAS
 *    session cookies (invisible to document.cookie) can be read.
 *  - nasplayer/saf: Storage Access Framework folder picking + recursive tree
 *    listing, so cloud providers like Google Drive (which have no filesystem
 *    path) can be scanned and streamed via content:// URIs.
 */
class MainActivity : AudioServiceActivity() {
    private var pendingTreeResult: MethodChannel.Result? = null

    companion object {
        private const val OPEN_TREE_REQUEST = 4242
        private const val MAX_FOLDERS = 5000
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "nasplayer/cookies"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getCookies" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrEmpty()) {
                        result.error("BAD_ARGS", "url is required", null)
                    } else {
                        result.success(CookieManager.getInstance().getCookie(url))
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "nasplayer/saf"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickTree" -> {
                    if (pendingTreeResult != null) {
                        result.error("BUSY", "A picker is already open", null)
                        return@setMethodCallHandler
                    }
                    pendingTreeResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                        addFlags(
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                        )
                    }
                    startActivityForResult(intent, OPEN_TREE_REQUEST)
                }
                "listTree" -> {
                    val uri = call.argument<String>("uri")
                    if (uri.isNullOrEmpty()) {
                        result.error("BAD_ARGS", "uri is required", null)
                    } else {
                        listTree(uri, result)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != OPEN_TREE_REQUEST) return
        val pending = pendingTreeResult ?: return
        pendingTreeResult = null

        val uri = data?.data
        if (resultCode == RESULT_OK && uri != null) {
            try {
                contentResolver.takePersistableUriPermission(
                    uri, Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (_: SecurityException) {
                // Provider granted a non-persistable permission; the session
                // grant still lets us scan and play right now.
            }
            pending.success(uri.toString())
        } else {
            pending.success(null)
        }
    }

    /**
     * Recursively list a document tree via ContentResolver (works for any
     * DocumentsProvider — Google Drive, USB, local). Runs off the main
     * thread: cloud providers hit the network per folder.
     */
    private fun listTree(treeUriStr: String, result: MethodChannel.Result) {
        Thread {
            val mainHandler = Handler(Looper.getMainLooper())
            try {
                val treeUri = Uri.parse(treeUriStr)
                val out = ArrayList<HashMap<String, Any?>>()
                val rootId = DocumentsContract.getTreeDocumentId(treeUri)
                val stack = ArrayDeque<Pair<String, String>>()
                stack.addLast(Pair(rootId, ""))
                var folders = 0

                val projection = arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                    DocumentsContract.Document.COLUMN_SIZE,
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED
                )

                while (stack.isNotEmpty() && folders < MAX_FOLDERS) {
                    val (docId, relPath) = stack.removeFirst()
                    folders++
                    val childrenUri = DocumentsContract
                        .buildChildDocumentsUriUsingTree(treeUri, docId)
                    contentResolver.query(childrenUri, projection, null, null, null)
                        ?.use { c ->
                            while (c.moveToNext()) {
                                val childId = c.getString(0) ?: continue
                                val name = c.getString(1) ?: continue
                                val mime = c.getString(2) ?: ""
                                val childRel =
                                    if (relPath.isEmpty()) name else "$relPath/$name"
                                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                                    stack.addLast(Pair(childId, childRel))
                                } else {
                                    val entry = HashMap<String, Any?>()
                                    entry["uri"] = DocumentsContract
                                        .buildDocumentUriUsingTree(treeUri, childId)
                                        .toString()
                                    entry["name"] = name
                                    entry["relativePath"] = childRel
                                    entry["size"] =
                                        if (c.isNull(3)) null else c.getLong(3)
                                    entry["modified"] =
                                        if (c.isNull(4)) null else c.getLong(4)
                                    out.add(entry)
                                }
                            }
                        }
                }
                mainHandler.post { result.success(out) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("SAF_ERROR", e.message ?: "listTree failed", null)
                }
            }
        }.start()
    }
}
