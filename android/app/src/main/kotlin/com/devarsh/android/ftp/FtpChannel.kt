package com.devarsh.android.ftp

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Native core for the Android companion: FTP start/stop, storage access, and
 * live state/log events. Flutter owns all UI and talks to this over the same
 * channel names used on macOS (`app.filebridge/commands` + `/events`).
 */
class FtpChannel(
    private val activity: MainActivity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val methods = MethodChannel(messenger, COMMANDS)
    private val events = EventChannel(messenger, EVENTS)
    private var sink: EventChannel.EventSink? = null
    private val busListener: () -> Unit = { emitState() }

    fun attach() {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    fun detach() {
        ServerBus.removeListener(busListener)
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        ServerBus.addListener(busListener)
        emitState()
    }

    override fun onCancel(arguments: Any?) {
        ServerBus.removeListener(busListener)
        sink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ftpGetState" -> result.success(snapshot())
            "ftpStart" -> start(call, result)
            "ftpStop" -> {
                FtpServerService.stop(activity)
                result.success(null)
            }
            "ftpClearLog" -> {
                ServerBus.clearLog()
                result.success(null)
            }
            "ftpRequestStorage" -> {
                activity.requestAllFilesAccess()
                result.success(null)
            }
            "ftpRequestNotifications" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    ContextCompat.checkSelfPermission(
                        activity, Manifest.permission.POST_NOTIFICATIONS,
                    ) != PackageManager.PERMISSION_GRANTED
                ) {
                    activity.requestNotificationPermission()
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun emitState() {
        sink?.success(snapshot())
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        if (!hasStorageAccess()) {
            result.error(
                "NEED_STORAGE",
                "Grant all-files access so the server can read your storage.",
                null,
            )
            activity.requestAllFilesAccess()
            return
        }
        val port = when (val raw = call.argument<Any>("port")) {
            is Int -> raw
            is Long -> raw.toInt()
            is Number -> raw.toInt()
            else -> null
        }
        if (port == null || port !in 1..65535) {
            result.error("BAD_PORT", "Enter a valid port (1–65535).", null)
            return
        }
        val user = call.argument<String>("user")
            ?.trim()
            ?.ifEmpty { ServerConfig.DEFAULT_USER }
            ?: ServerConfig.DEFAULT_USER
        val pass = call.argument<String>("pass") ?: ""
        FtpServerService.start(
            activity,
            ServerConfig(
                port = port,
                username = user,
                password = pass,
                rootPath = rootPath(),
            ),
        )
        result.success(null)
    }

    private fun snapshot(): Map<String, Any?> {
        val state = ServerBus.state
        val host = state.host ?: NetworkUtils.localIpv4()
        return mapOf(
            "type" to "ftpState",
            "running" to state.running,
            "host" to host,
            "port" to state.port,
            "user" to state.user,
            "rootPath" to rootPath(),
            "hasStorageAccess" to hasStorageAccess(),
            "log" to ServerBus.logSnapshot(),
        )
    }

    private fun rootPath(): String =
        Environment.getExternalStorageDirectory()?.absolutePath
            ?: activity.filesDir.absolutePath

    private fun hasStorageAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            ContextCompat.checkSelfPermission(
                activity, Manifest.permission.WRITE_EXTERNAL_STORAGE,
            ) == PackageManager.PERMISSION_GRANTED
        }
    }

    companion object {
        const val COMMANDS = "app.filebridge/commands"
        const val EVENTS = "app.filebridge/events"
    }
}
