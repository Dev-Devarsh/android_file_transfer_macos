package com.devarsh.android.ftp

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Flutter host. Native UI is gone — this activity only wires platform channels
 * to the FTP server core ([FtpServerService], [ServerBus]) and handles the
 * system permission screens those channels request.
 *
 * Uses [requestPermissions] rather than Activity Result APIs because
 * [FlutterActivity] extends [android.app.Activity], not ComponentActivity.
 */
class MainActivity : FlutterActivity() {

    private var channel: FtpChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ftp = FtpChannel(
            activity = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        )
        ftp.attach()
        channel = ftp
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        channel?.emitState()
    }

    override fun onResume() {
        super.onResume()
        // Storage access is granted in a system settings screen; refresh when
        // the user returns so Flutter can update the Grant button / status.
        channel?.emitState()
    }

    override fun onDestroy() {
        channel?.detach()
        channel = null
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        channel?.emitState()
    }

    fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIF)
        }
    }

    fun requestAllFilesAccess() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                startActivity(
                    Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                        .setData(Uri.parse("package:$packageName")),
                )
            } catch (_: Exception) {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
        } else {
            requestPermissions(
                arrayOf(
                    Manifest.permission.READ_EXTERNAL_STORAGE,
                    Manifest.permission.WRITE_EXTERNAL_STORAGE,
                ),
                REQ_STORAGE,
            )
        }
    }

    companion object {
        private const val REQ_NOTIF = 1001
        private const val REQ_STORAGE = 1002
    }
}
