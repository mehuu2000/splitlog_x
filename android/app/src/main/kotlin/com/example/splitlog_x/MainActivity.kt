package com.example.splitlog_x

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val appChannelName = "splitlog_x/app"
    private val chooseLegacyFileRequestCode = 4101
    private var pendingFilePickerResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            appChannelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "chooseLegacyFile" -> showLegacyFilePicker(result)
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun showLegacyFilePicker(result: MethodChannel.Result) {
        if (pendingFilePickerResult != null) {
            result.error(
                "file_picker_busy",
                "A document picker is already open.",
                null,
            )
            return
        }

        pendingFilePickerResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/json"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf("application/json", "text/json", "text/plain"),
            )
        }
        try {
            startActivityForResult(intent, chooseLegacyFileRequestCode)
        } catch (error: Exception) {
            pendingFilePickerResult = null
            result.error(
                "file_picker_unavailable",
                "Unable to open the document picker.",
                error.localizedMessage,
            )
        }
    }

    @Deprecated("Deprecated in Android SDK, retained for FlutterActivity compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != chooseLegacyFileRequestCode) {
            return
        }

        val result = pendingFilePickerResult ?: return
        pendingFilePickerResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }

        try {
            val content = contentResolver.openInputStream(uri)?.bufferedReader().use {
                it?.readText()
            }
            if (content == null) {
                result.error(
                    "file_read_failed",
                    "Unable to read the selected sessions.json file.",
                    null,
                )
            } else {
                result.success(content)
            }
        } catch (error: Exception) {
            result.error(
                "file_read_failed",
                "Unable to read the selected sessions.json file.",
                error.localizedMessage,
            )
        }
    }
}
