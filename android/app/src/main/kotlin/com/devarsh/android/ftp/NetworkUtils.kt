package com.devarsh.android.ftp

import java.net.Inet4Address
import java.net.NetworkInterface

/** Helpers for finding the address a phone shows to other devices on the LAN. */
object NetworkUtils {

    /**
     * Best-effort local IPv4 address on the active Wi-Fi/Ethernet interface.
     * Prefers a private LAN address (192.168/10/172.16-31) and skips loopback
     * and virtual/down interfaces. Returns null if none can be determined.
     */
    fun localIpv4(): String? {
        val candidates = ArrayList<String>()
        try {
            for (nif in NetworkInterface.getNetworkInterfaces()) {
                if (!nif.isUp || nif.isLoopback || nif.isVirtual) continue
                val name = nif.name.lowercase()
                // Skip tunnels and cellular so we advertise the Wi-Fi address.
                if (name.startsWith("rmnet") || name.startsWith("tun") || name.startsWith("ppp")) continue
                for (addr in nif.inetAddresses) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress) {
                        val ip = addr.hostAddress ?: continue
                        if (isPrivate(ip)) candidates.add(0, ip) else candidates.add(ip)
                    }
                }
            }
        } catch (_: Exception) {
            return null
        }
        return candidates.firstOrNull()
    }

    private fun isPrivate(ip: String): Boolean {
        if (ip.startsWith("192.168.") || ip.startsWith("10.")) return true
        if (ip.startsWith("172.")) {
            val second = ip.split(".").getOrNull(1)?.toIntOrNull() ?: return false
            return second in 16..31
        }
        return false
    }
}
