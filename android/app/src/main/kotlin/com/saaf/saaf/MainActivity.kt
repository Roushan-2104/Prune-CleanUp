package com.saaf.saaf

import android.app.Activity
import android.content.ContentUris
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Size
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * Hosts the "saaf/trash" channel: lists photos in Android's system Trash,
 * gives their thumbnails, restores them or deletes them permanently.
 * Needs Android 11 (API 30)+.
 */
class MainActivity : FlutterActivity() {
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pendingRequest: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "saaf/trash")
            .setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.error("unsupported", "System Trash needs Android 11 or newer", null)
            return
        }
        when (call.method) {
            "list" -> background(result) { listTrashed() }
            "thumbnail" -> background(result) {
                thumbnail(call.argument<String>("id")!!.toLong(), call.argument<Int>("size") ?: 300)
            }
            "restore" -> {
                val uris = call.argument<List<String>>("ids")!!.map { uriOf(it.toLong()) }
                askUser(uris, result) { MediaStore.createTrashRequest(contentResolver, it, false) }
            }
            "deleteForever" -> {
                val uris = call.argument<List<String>>("ids")!!.map { uriOf(it.toLong()) }
                askUser(uris, result) { MediaStore.createDeleteRequest(contentResolver, it) }
            }
            else -> result.notImplemented()
        }
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        io.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("failed", e.message, null) }
            }
        }
    }

    private fun uriOf(id: Long): Uri =
        ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)

    private fun listTrashed(): List<Map<String, Any?>> {
        val projection = arrayOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.SIZE,
            MediaStore.Images.Media.DATE_EXPIRES,
        )
        val args = Bundle().apply {
            putInt(MediaStore.QUERY_ARG_MATCH_TRASHED, MediaStore.MATCH_ONLY)
            putStringArray(
                android.content.ContentResolver.QUERY_ARG_SORT_COLUMNS,
                arrayOf(MediaStore.Images.Media.DATE_EXPIRES),
            )
        }
        val out = mutableListOf<Map<String, Any?>>()
        contentResolver.query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, projection, args, null)?.use { c ->
            val id = c.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
            val name = c.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)
            val size = c.getColumnIndexOrThrow(MediaStore.Images.Media.SIZE)
            val expires = c.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_EXPIRES)
            while (c.moveToNext()) {
                out += mapOf(
                    "id" to c.getLong(id).toString(),
                    "name" to c.getString(name),
                    "bytes" to c.getLong(size),
                    "expiresSec" to c.getLong(expires),
                )
            }
        }
        return out
    }

    private fun thumbnail(id: Long, size: Int): ByteArray {
        val bitmap = try {
            contentResolver.loadThumbnail(uriOf(id), Size(size, size), null)
        } catch (e: Exception) {
            // Fallback: decode the file itself at reduced resolution.
            val opts = BitmapFactory.Options().apply { inSampleSize = 8 }
            contentResolver.openInputStream(uriOf(id)).use { BitmapFactory.decodeStream(it, null, opts) }
                ?: throw e
        }
        return ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
            out.toByteArray()
        }
    }

    /**
     * Restore and permanent delete both go through an Android system dialog
     * ("Restore N items?" / "Permanently delete N items?"). We report whether
     * the user agreed.
     */
    private fun askUser(
        uris: List<Uri>,
        result: MethodChannel.Result,
        makeRequest: (List<Uri>) -> android.app.PendingIntent,
    ) {
        if (uris.isEmpty()) {
            result.success(true)
            return
        }
        pendingRequest?.error("cancelled", "Another request started", null)
        pendingRequest = result
        startIntentSenderForResult(makeRequest(uris).intentSender, USER_REQUEST, null, 0, 0, 0)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == USER_REQUEST) {
            pendingRequest?.success(resultCode == Activity.RESULT_OK)
            pendingRequest = null
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    companion object {
        private const val USER_REQUEST = 4207
    }
}
