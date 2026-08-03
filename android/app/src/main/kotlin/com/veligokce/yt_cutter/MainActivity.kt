package com.veligokce.yt_cutter

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private val channelName = "com.veligokce.ytcutter/storage"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "openDownloads") {
                    try {
                        openDownloads()
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("OPEN_FAILED", error.message, null)
                    }
                    return@setMethodCallHandler
                }
                if (call.method != "saveToDownloads") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                val name = call.argument<String>("name")
                if (path == null || name == null) {
                    result.error("INVALID_ARGUMENT", "Eksik dosya bilgisi", null)
                    return@setMethodCallHandler
                }
                try {
                    result.success(saveToDownloads(File(path), name).toString())
                } catch (error: Exception) {
                    result.error("SAVE_FAILED", error.message, null)
                }
            }
    }

    private fun openDownloads() {
        val folder = Uri.parse(
            "content://com.android.externalstorage.documents/document/primary%3ADownload%2FYTCutter"
        )
        val viewIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(folder, DocumentsContract.Document.MIME_TYPE_DIR)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivity(viewIntent)
        } catch (_: Exception) {
            val picker = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    putExtra(DocumentsContract.EXTRA_INITIAL_URI, folder)
                }
            }
            startActivity(picker)
        }
    }

    private fun saveToDownloads(source: File, name: String): Uri {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4")
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    Environment.DIRECTORY_DOWNLOADS + "/YTCutter"
                )
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("Çıktı dosyası oluşturulamadı")
            try {
                resolver.openOutputStream(uri)?.use { output ->
                    FileInputStream(source).use { input -> input.copyTo(output) }
                } ?: throw IllegalStateException("Çıktı dosyası açılamadı")
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
                return uri
            } catch (error: Exception) {
                resolver.delete(uri, null, null)
                throw error
            }
        }

        val directory = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            "YTCutter"
        )
        directory.mkdirs()
        val destination = File(directory, name)
        source.copyTo(destination, overwrite = true)
        @Suppress("DEPRECATION")
        sendBroadcast(Intent(Intent.ACTION_MEDIA_SCANNER_SCAN_FILE, Uri.fromFile(destination)))
        return FileProvider.getUriForFile(this, "$packageName.fileprovider", destination)
    }
}
