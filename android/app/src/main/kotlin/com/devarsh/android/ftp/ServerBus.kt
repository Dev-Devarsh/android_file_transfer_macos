package com.devarsh.android.ftp

import android.os.Handler
import android.os.Looper
import java.util.concurrent.CopyOnWriteArraySet

/**
 * Tiny process-wide event bus so the foreground [FtpServerService] can publish
 * server state and a rolling activity log, and [FtpChannel] can forward it to
 * Flutter without binding to the service. All listener callbacks are delivered
 * on the main thread.
 */
object ServerBus {

    data class State(
        val running: Boolean = false,
        val host: String? = null,
        val port: Int = ServerConfig.DEFAULT_PORT,
        val user: String = ServerConfig.DEFAULT_USER,
    )

    @Volatile
    var state: State = State()
        private set

    private const val MAX_LOG = 400
    private val log = ArrayList<String>(MAX_LOG)
    private val listeners = CopyOnWriteArraySet<() -> Unit>()
    private val main = Handler(Looper.getMainLooper())

    fun addListener(l: () -> Unit) {
        listeners.add(l)
        notifyListeners()
    }

    fun removeListener(l: () -> Unit) {
        listeners.remove(l)
    }

    fun setState(state: State) {
        this.state = state
        notifyListeners()
    }

    fun log(line: String) {
        synchronized(log) {
            log.add(line)
            while (log.size > MAX_LOG) log.removeAt(0)
        }
        notifyListeners()
    }

    fun logSnapshot(): List<String> = synchronized(log) { ArrayList(log) }

    fun clearLog() {
        synchronized(log) { log.clear() }
        notifyListeners()
    }

    private fun notifyListeners() {
        for (l in listeners) main.post { l() }
    }
}
