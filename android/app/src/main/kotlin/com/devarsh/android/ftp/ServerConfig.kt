package com.devarsh.android.ftp

import java.io.File

/**
 * Runtime configuration for the FTP server. Defaults line up with what the
 * macOS "Android File Transfer" app pre-fills in its Wi-Fi dialog: port 2121,
 * user "anonymous", empty password.
 */
data class ServerConfig(
    val port: Int = DEFAULT_PORT,
    val username: String = DEFAULT_USER,
    val password: String = "",
    /** Absolute path the FTP root ("/") maps to — normally shared storage. */
    val rootPath: String,
    /** When true, any password is accepted for the "anonymous" user. */
    val allowAnonymous: Boolean = true,
) {
    val root: File get() = File(rootPath)

    companion object {
        const val DEFAULT_PORT = 2121
        const val DEFAULT_USER = "anonymous"
    }
}
