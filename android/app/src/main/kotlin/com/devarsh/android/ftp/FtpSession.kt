package com.devarsh.android.ftp

import android.content.Context
import android.media.MediaScannerConnection
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Handles one FTP control connection: reads CRLF-terminated commands and
 * replies with numeric responses. Implements the subset of RFC 959 / RFC 3659
 * that the ftpconnect-based macOS client uses, in passive mode by default.
 *
 * A virtual path space is exposed rooted at "/", which maps onto [config.root]
 * on disk. All resolved paths are confined to that root.
 */
class FtpSession(
    private val control: Socket,
    private val config: ServerConfig,
    private val context: Context,
    private val onClose: (FtpSession) -> Unit,
) : Thread("ftp-session") {

    private val root: File = File(config.rootPath).canonicalFile

    private var reader: BufferedReader? = null
    private var writer: BufferedWriter? = null

    private var authenticated = false
    private var pendingUser: String? = null
    private var cwd = "/" // virtual working directory
    private var binary = true

    private var passiveServer: ServerSocket? = null
    private var activeTarget: InetSocketAddress? = null
    private var restart = 0L
    private var renameFrom: File? = null

    override fun run() {
        try {
            control.tcpNoDelay = true
            reader = BufferedReader(InputStreamReader(control.getInputStream(), Charsets.UTF_8))
            writer = BufferedWriter(OutputStreamWriter(control.getOutputStream(), Charsets.UTF_8))
            send("220 AFT Wi-Fi FTP ready")
            while (true) {
                val line = reader?.readLine() ?: break
                if (line.isEmpty()) continue
                val space = line.indexOf(' ')
                val cmd = (if (space < 0) line else line.substring(0, space)).uppercase(Locale.US)
                val arg = if (space < 0) "" else line.substring(space + 1)
                ServerBus.log(if (cmd == "PASS") "> PASS ****" else "> $line")
                if (!dispatch(cmd, arg)) break
            }
        } catch (_: Exception) {
            // Client vanished or socket error — just tear down.
        } finally {
            closeQuietly()
            onClose(this)
        }
    }

    // --- command dispatch ---------------------------------------------------

    /** Returns false when the connection should close (QUIT). */
    private fun dispatch(cmd: String, arg: String): Boolean {
        when (cmd) {
            "USER" -> { pendingUser = arg.trim(); authenticated = false; send("331 Password required") }
            "PASS" -> doPass(arg)
            "QUIT" -> { send("221 Goodbye"); return false }
            "SYST" -> send("215 UNIX Type: L8")
            "FEAT" -> sendFeat()
            "OPTS" -> if (arg.uppercase(Locale.US).startsWith("UTF8")) send("200 OK")
                      else send("501 Option not understood")
            "NOOP" -> send("200 OK")
            "TYPE" -> {
                binary = !arg.trim().uppercase(Locale.US).startsWith("A")
                send("200 Type set to ${if (binary) "I" else "A"}")
            }
            else -> {
                if (!authenticated) { send("530 Please login with USER and PASS"); return true }
                dispatchAuthed(cmd, arg)
            }
        }
        return true
    }

    private fun dispatchAuthed(cmd: String, arg: String) {
        when (cmd) {
            "PWD", "XPWD" -> send("257 \"$cwd\" is current directory")
            "CWD", "XCWD" -> doCwd(arg)
            "CDUP", "XCUP" -> doCwd("..")
            "PASV" -> doPasv()
            "EPSV" -> doEpsv()
            "PORT" -> doPort(arg)
            "EPRT" -> doEprt(arg)
            "LIST" -> doList(arg, machine = false)
            "MLSD" -> doList(arg, machine = true)
            "NLST" -> doNlst(arg)
            "RETR" -> doRetr(arg)
            "STOR" -> doStor(arg, append = false)
            "APPE" -> doStor(arg, append = true)
            "SIZE" -> doSize(arg)
            "MDTM" -> doMdtm(arg)
            "DELE" -> doDele(arg)
            "RMD", "XRMD" -> doRmd(arg)
            "MKD", "XMKD" -> doMkd(arg)
            "RNFR" -> doRnfr(arg)
            "RNTO" -> doRnto(arg)
            "REST" -> { restart = arg.trim().toLongOrNull() ?: 0L; send("350 Restart at $restart") }
            "ABOR" -> send("226 Abort complete")
            else -> send("502 Command not implemented")
        }
    }

    private fun doPass(pass: String) {
        val user = pendingUser ?: ""
        val ok = if (config.allowAnonymous && user.equals("anonymous", ignoreCase = true)) {
            true
        } else {
            user == config.username && pass == config.password
        }
        if (ok) {
            authenticated = true
            send("230 User logged in")
        } else {
            send("530 Login incorrect")
        }
    }

    private fun sendFeat() {
        val body = buildString {
            append("211-Features:\r\n")
            append(" UTF8\r\n")
            append(" MLSD\r\n")
            append(" SIZE\r\n")
            append(" MDTM\r\n")
            append(" REST STREAM\r\n")
            append("211 End")
        }
        send(body)
    }

    // --- navigation ---------------------------------------------------------

    private fun doCwd(arg: String) {
        val virtual = resolveVirtual(arg)
        val file = toReal(virtual)
        if (within(file) && file.isDirectory) {
            cwd = virtual
            send("250 Directory changed to $cwd")
        } else {
            send("550 Not a directory")
        }
    }

    // --- data channel setup -------------------------------------------------

    private fun doPasv() {
        closePassive()
        val ps = ServerSocket()
        ps.reuseAddress = true
        ps.bind(InetSocketAddress(control.localAddress, 0))
        passiveServer = ps
        val local = control.localAddress
        val bytes = (local as? Inet4Address)?.address
        if (bytes == null) {
            closePassive()
            send("425 Passive mode requires IPv4; use EPSV")
            return
        }
        val port = ps.localPort
        val ipStr = bytes.joinToString(",") { (it.toInt() and 0xFF).toString() }
        send("227 Entering Passive Mode ($ipStr,${port shr 8},${port and 0xFF})")
    }

    private fun doEpsv() {
        closePassive()
        val ps = ServerSocket()
        ps.reuseAddress = true
        ps.bind(InetSocketAddress(control.localAddress, 0))
        passiveServer = ps
        send("229 Entering Extended Passive Mode (|||${ps.localPort}|)")
    }

    private fun doPort(arg: String) {
        val parts = arg.split(",").mapNotNull { it.trim().toIntOrNull() }
        if (parts.size != 6) { send("501 Bad PORT"); return }
        val host = "${parts[0]}.${parts[1]}.${parts[2]}.${parts[3]}"
        val port = (parts[4] shl 8) or parts[5]
        closePassive()
        activeTarget = InetSocketAddress(host, port)
        send("200 PORT command successful")
    }

    private fun doEprt(arg: String) {
        // Format: |proto|addr|port|
        val fields = arg.split("|")
        if (fields.size < 4) { send("501 Bad EPRT"); return }
        val host = fields[2]
        val port = fields[3].toIntOrNull() ?: run { send("501 Bad EPRT port"); return }
        closePassive()
        activeTarget = InetSocketAddress(host, port)
        send("200 EPRT command successful")
    }

    private fun openData(): Socket {
        val ps = passiveServer
        if (ps != null) {
            ps.soTimeout = 30_000
            return ps.accept()
        }
        val target = activeTarget ?: throw IOException("No data connection established")
        val s = Socket()
        s.connect(target, 30_000)
        return s
    }

    // --- listings -----------------------------------------------------------

    private fun doList(arg: String, machine: Boolean) {
        val dir = listTarget(arg)
        if (!within(dir) || !dir.isDirectory) { send("550 Not a directory"); return }
        send("150 Here comes the directory listing")
        try {
            openData().use { data ->
                val out = BufferedWriter(OutputStreamWriter(data.getOutputStream(), Charsets.UTF_8))
                val children = dir.listFiles() ?: emptyArray()
                for (f in children) {
                    out.write(if (machine) mlsdLine(f) else listLine(f))
                    out.write("\r\n")
                }
                out.flush()
            }
            send("226 Directory send OK")
        } catch (e: Exception) {
            send("425 Can't open data connection")
        } finally {
            closePassive()
        }
    }

    private fun doNlst(arg: String) {
        val dir = listTarget(arg)
        if (!within(dir) || !dir.isDirectory) { send("550 Not a directory"); return }
        send("150 Here comes the directory listing")
        try {
            openData().use { data ->
                val out = BufferedWriter(OutputStreamWriter(data.getOutputStream(), Charsets.UTF_8))
                for (f in dir.listFiles() ?: emptyArray()) {
                    out.write(f.name); out.write("\r\n")
                }
                out.flush()
            }
            send("226 Directory send OK")
        } catch (e: Exception) {
            send("425 Can't open data connection")
        } finally {
            closePassive()
        }
    }

    /** Strips `ls`-style option tokens ("-a", "-l") and resolves the target dir. */
    private fun listTarget(arg: String): File {
        val cleaned = arg.split(" ")
            .filter { it.isNotEmpty() && !it.startsWith("-") }
            .joinToString(" ")
        val virtual = if (cleaned.isBlank()) cwd else resolveVirtual(cleaned)
        return toReal(virtual)
    }

    private fun mlsdLine(f: File): String {
        val type = if (f.isDirectory) "dir" else "file"
        val size = if (f.isDirectory) 0L else f.length()
        return "type=$type;size=$size;modify=${utcStamp(f.lastModified())}; ${f.name}"
    }

    private fun listLine(f: File): String {
        val perms = if (f.isDirectory) "drwxr-xr-x" else "-rw-r--r--"
        val size = if (f.isDirectory) 4096L else f.length()
        return String.format(Locale.US, "%s 1 ftp ftp %12d %s %s", perms, size, lsDate(f.lastModified()), f.name)
    }

    // --- transfers ----------------------------------------------------------

    private fun doRetr(arg: String) {
        val file = toReal(resolveVirtual(arg))
        if (!within(file) || !file.isFile) { restart = 0; send("550 File not found"); return }
        val offset = restart
        restart = 0
        send("150 Opening data connection for ${file.name}")
        try {
            openData().use { data ->
                FileInputStream(file).use { input ->
                    if (offset > 0) input.skip(offset)
                    val out = data.getOutputStream()
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                    }
                    out.flush()
                }
            }
            send("226 Transfer complete")
        } catch (e: Exception) {
            send("426 Transfer failed")
        } finally {
            closePassive()
        }
    }

    private fun doStor(arg: String, append: Boolean) {
        val file = toReal(resolveVirtual(arg))
        if (!within(file)) { restart = 0; send("550 Invalid path"); return }
        file.parentFile?.mkdirs()
        val appendMode = append || restart > 0
        restart = 0
        send("150 Ready to receive ${file.name}")
        try {
            openData().use { data ->
                FileOutputStream(file, appendMode).use { fout ->
                    val input = data.getInputStream()
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        fout.write(buf, 0, n)
                    }
                    fout.flush()
                    // Force the bytes to disk before we announce completion and
                    // re-index, so a viewer opening the file can't read a
                    // half-flushed copy.
                    try { fout.fd.sync() } catch (_: Exception) {}
                }
            }
            send("226 Transfer complete")
            // Direct File I/O to shared storage does NOT update Android's media
            // index, so apps that open files via MediaStore can otherwise see a
            // stale/empty entry (right size, blank content). Re-scan the file.
            rescan(file)
        } catch (e: Exception) {
            send("426 Transfer failed")
        } finally {
            closePassive()
        }
    }

    /** Re-index a written/changed/removed path so MediaStore reflects it. */
    private fun rescan(file: File) {
        try {
            MediaScannerConnection.scanFile(context, arrayOf(file.absolutePath), null, null)
        } catch (_: Exception) {
        }
    }

    // --- single-file ops ----------------------------------------------------

    private fun doSize(arg: String) {
        val file = toReal(resolveVirtual(arg))
        if (within(file) && file.isFile) send("213 ${file.length()}")
        else send("550 Not a regular file")
    }

    private fun doMdtm(arg: String) {
        val file = toReal(resolveVirtual(arg))
        if (within(file) && file.exists()) send("213 ${utcStamp(file.lastModified())}")
        else send("550 File not found")
    }

    private fun doDele(arg: String) {
        val file = toReal(resolveVirtual(arg))
        if (within(file) && file.isFile && file.delete()) { rescan(file); send("250 File deleted") }
        else send("550 Delete failed")
    }

    private fun doRmd(arg: String) {
        val file = toReal(resolveVirtual(arg))
        if (within(file) && file.isDirectory && file.delete()) send("250 Directory removed")
        else send("550 Remove failed")
    }

    private fun doMkd(arg: String) {
        val virtual = resolveVirtual(arg)
        val file = toReal(virtual)
        if (within(file) && (file.isDirectory || file.mkdirs())) send("257 \"$virtual\" created")
        else send("550 Create failed")
    }

    private fun doRnfr(arg: String) {
        val file = toReal(resolveVirtual(arg))
        if (within(file) && file.exists()) { renameFrom = file; send("350 Ready for RNTO") }
        else send("550 File not found")
    }

    private fun doRnto(arg: String) {
        val from = renameFrom
        renameFrom = null
        val to = toReal(resolveVirtual(arg))
        if (from != null && within(to) && from.renameTo(to)) {
            rescan(from); rescan(to); send("250 Rename successful")
        } else send("550 Rename failed")
    }

    // --- path handling ------------------------------------------------------

    /** Resolves [arg] (absolute or relative to [cwd]) into a normalized virtual path. */
    private fun resolveVirtual(arg: String): String {
        val combined = if (arg.startsWith("/")) arg else "$cwd/$arg"
        val stack = ArrayList<String>()
        for (seg in combined.split("/")) {
            when (seg) {
                "", "." -> {}
                ".." -> if (stack.isNotEmpty()) stack.removeAt(stack.size - 1)
                else -> stack.add(seg)
            }
        }
        return "/" + stack.joinToString("/")
    }

    private fun toReal(virtual: String): File =
        File(root, virtual.removePrefix("/")).canonicalFile

    /** True when [f] is the root or lives inside it — blocks path traversal. */
    private fun within(f: File): Boolean =
        f == root || f.path.startsWith(root.path + File.separator)

    // --- io helpers ---------------------------------------------------------

    private fun send(response: String) {
        val w = writer ?: return
        w.write(response)
        w.write("\r\n")
        w.flush()
        ServerBus.log("< ${response.substringBefore("\r\n")}")
    }

    private fun closePassive() {
        try {
            passiveServer?.close()
        } catch (_: Exception) {
        }
        passiveServer = null
        activeTarget = null
    }

    fun closeQuietly() {
        closePassive()
        try {
            control.close()
        } catch (_: Exception) {
        }
    }

    private fun utcStamp(epochMillis: Long): String = utcFormat.get()!!.format(Date(epochMillis))

    private fun lsDate(epochMillis: Long): String {
        val sixMonths = 182L * 24 * 60 * 60 * 1000
        val fmt = if (System.currentTimeMillis() - epochMillis > sixMonths) lsDateOld else lsDateRecent
        return fmt.get()!!.format(Date(epochMillis))
    }

    companion object {
        private val utcFormat = ThreadLocal.withInitial {
            SimpleDateFormat("yyyyMMddHHmmss", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
        }
        private val lsDateRecent = ThreadLocal.withInitial { SimpleDateFormat("MMM d HH:mm", Locale.US) }
        private val lsDateOld = ThreadLocal.withInitial { SimpleDateFormat("MMM d  yyyy", Locale.US) }
    }
}
