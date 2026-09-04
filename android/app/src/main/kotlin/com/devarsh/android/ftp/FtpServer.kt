package com.devarsh.android.ftp

import android.content.Context
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap

/**
 * Accepts FTP control connections and hands each one to an [FtpSession] on its
 * own thread. The macOS client opens a fresh short-lived connection per
 * operation, so the server is deliberately connection-per-thread and stateless
 * between connections.
 */
class FtpServer(private val config: ServerConfig, private val context: Context) {

    @Volatile
    private var running = false
    private var serverSocket: ServerSocket? = null
    private val sessions =
        Collections.newSetFromMap(ConcurrentHashMap<FtpSession, Boolean>())

    val isRunning: Boolean get() = running

    /** Binds the listening socket and starts accepting. Throws on bind failure. */
    fun start() {
        val ss = ServerSocket()
        ss.reuseAddress = true
        ss.bind(InetSocketAddress(config.port))
        serverSocket = ss
        running = true
        Thread({ acceptLoop(ss) }, "ftp-accept").apply { isDaemon = true }.start()
        ServerBus.log("Listening on port ${config.port}, serving ${config.rootPath}")
    }

    private fun acceptLoop(ss: ServerSocket) {
        while (running) {
            val socket = try {
                ss.accept()
            } catch (e: Exception) {
                if (running) ServerBus.log("Accept error: ${e.message}")
                break
            }
            val session = FtpSession(socket, config, context) { sessions.remove(it) }
            sessions.add(session)
            session.isDaemon = true
            session.start()
        }
    }

    fun stop() {
        running = false
        try {
            serverSocket?.close()
        } catch (_: Exception) {
        }
        for (s in sessions) s.closeQuietly()
        sessions.clear()
        ServerBus.log("Server stopped")
    }
}
