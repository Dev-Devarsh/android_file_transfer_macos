package com.devarsh.android.ftp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * Runs the [FtpServer] as a foreground service so transfers keep going while the
 * app is backgrounded or the screen is off. Holds a partial wake lock and a
 * high-performance Wi-Fi lock for the duration.
 */
class FtpServerService : Service() {

    private var server: FtpServer? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

        val port = intent?.getIntExtra(EXTRA_PORT, ServerConfig.DEFAULT_PORT) ?: ServerConfig.DEFAULT_PORT
        val user = intent?.getStringExtra(EXTRA_USER) ?: ServerConfig.DEFAULT_USER
        val pass = intent?.getStringExtra(EXTRA_PASS) ?: ""
        val root = intent?.getStringExtra(EXTRA_ROOT) ?: filesDir.absolutePath
        val config = ServerConfig(port = port, username = user, password = pass, rootPath = root)

        val host = NetworkUtils.localIpv4()
        startForeground(NOTIF_ID, buildNotification(host, port))
        acquireLocks()

        try {
            val srv = FtpServer(config, applicationContext)
            srv.start()
            server = srv
            ServerBus.setState(ServerBus.State(running = true, host = host, port = port, user = user))
        } catch (e: Exception) {
            ServerBus.log("Failed to start: ${e.message}")
            ServerBus.setState(ServerBus.State(running = false, port = port, user = user))
            stopSelf()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        server?.stop()
        server = null
        releaseLocks()
        val current = ServerBus.state
        ServerBus.setState(current.copy(running = false, host = null))
        super.onDestroy()
    }

    private fun acquireLocks() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "aftftp:wake").also {
            it.setReferenceCounted(false)
            it.acquire()
        }
        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
            WifiManager.WIFI_MODE_FULL_HIGH_PERF else WifiManager.WIFI_MODE_FULL_HIGH_PERF
        wifiLock = wm.createWifiLock(mode, "aftftp:wifi").also {
            it.setReferenceCounted(false)
            it.acquire()
        }
    }

    private fun releaseLocks() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        }
        try {
            if (wifiLock?.isHeld == true) wifiLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
        wifiLock = null
    }

    private fun buildNotification(host: String?, port: Int): Notification {
        createChannel()
        val openIntent = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopIntent = PendingIntent.getService(
            this, 1, Intent(this, FtpServerService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val address = if (host != null) "ftp://$host:$port" else "starting…"
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Wi-Fi FTP running")
            .setContentText(address)
            .setSmallIcon(R.drawable.ic_stat_ftp)
            .setOngoing(true)
            .setContentIntent(openIntent)
            .addAction(0, "Stop", stopIntent)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            val channel = NotificationChannel(
                CHANNEL_ID, "FTP server", NotificationManager.IMPORTANCE_LOW,
            ).apply { description = "Shown while the Wi-Fi FTP server is running" }
            nm.createNotificationChannel(channel)
        }
    }

    companion object {
        const val ACTION_STOP = "com.devarsh.android.ftp.STOP"
        const val EXTRA_PORT = "port"
        const val EXTRA_USER = "user"
        const val EXTRA_PASS = "pass"
        const val EXTRA_ROOT = "root"

        private const val CHANNEL_ID = "ftp_server"
        private const val NOTIF_ID = 42

        fun start(context: Context, config: ServerConfig) {
            val intent = Intent(context, FtpServerService::class.java)
                .putExtra(EXTRA_PORT, config.port)
                .putExtra(EXTRA_USER, config.username)
                .putExtra(EXTRA_PASS, config.password)
                .putExtra(EXTRA_ROOT, config.rootPath)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.startService(
                Intent(context, FtpServerService::class.java).setAction(ACTION_STOP),
            )
        }
    }
}
