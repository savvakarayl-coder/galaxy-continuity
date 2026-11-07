package com.galaxycontinuity.app.network

import android.content.Context
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import okhttp3.*
import org.json.JSONObject
import java.util.concurrent.TimeUnit

class WebSocketClient(
    private val context: Context,
    private val listener: ContinuityListener
) {
    interface ContinuityListener {
        fun onConnected(macName: String)
        fun onDisconnected()
        fun onClipboardReceived(content: String, contentType: String = "text/plain", hash: String? = null)
        fun onFileAvailable(fileId: String, filename: String, size: Long)
        fun onFileProgress(fileId: String, bytesTransferred: Long, totalBytes: Long, percentage: Double, status: String)
        fun onFileComplete(fileId: String, status: String, message: String)
        fun onPingReceived(message: String)
    }

    private val tag = "GalaxyWS"
    private var client = OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()

    private var webSocket: WebSocket? = null
    var isConnected = false
        private set
    var currentHost = ""
    var currentPort = 8765
    private val mainHandler = Handler(Looper.getMainLooper())

    fun connect(host: String, port: Int = 8765) {
        currentHost = host
        currentPort = port
        disconnect()

        val url = "ws://$host:$port/ws"
        Log.d(tag, "Connecting to $url")

        val request = Request.Builder().url(url).build()
        webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                isConnected = true
                Log.d(tag, "WebSocket opened!")
                sendHandshake()
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                try {
                    val json = JSONObject(text)
                    when (json.optString("type")) {
                        "handshake_ack" -> {
                            val macName = json.optString("device", "MacBook Pro")
                            mainHandler.post { listener.onConnected(macName) }
                        }
                        "clipboard" -> {
                            val content = if (json.has("content")) json.getString("content") else json.optString("payload", "")
                            val contentType = json.optString("contentType", "text/plain").ifEmpty { "text/plain" }
                            val hash = json.optString("hash").ifEmpty { null }
                            mainHandler.post { listener.onClipboardReceived(content, contentType, hash) }
                        }
                        "file_available" -> {
                            val fileId = json.optString("fileId")
                            val filename = json.optString("filename")
                            val size = json.optLong("fileSize")
                            mainHandler.post { listener.onFileAvailable(fileId, filename, size) }
                        }
                        "file_progress" -> {
                            val fileId = json.optString("fileId")
                            val transferred = json.optLong("bytesTransferred")
                            val total = json.optLong("totalBytes")
                            val pct = json.optDouble("percentage")
                            val status = json.optString("status")
                            mainHandler.post { listener.onFileProgress(fileId, transferred, total, pct, status) }
                        }
                        "file_complete" -> {
                            val fileId = json.optString("fileId")
                            val status = json.optString("status")
                            val message = json.optString("message")
                            mainHandler.post { listener.onFileComplete(fileId, status, message) }
                        }
                        "ping_device" -> {
                            val msg = json.optString("message", "Ping from Mac")
                            mainHandler.post { listener.onPingReceived(msg) }
                        }
                    }
                } catch (e: Exception) {
                    Log.e(tag, "Error parsing message: $text", e)
                }
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                isConnected = false
                mainHandler.post { listener.onDisconnected() }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                isConnected = false
                Log.e(tag, "WebSocket error: ${t.message}")
                mainHandler.post { listener.onDisconnected() }
            }
        })
    }

    private fun sendHandshake() {
        val bm = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        val level = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: 100

        val deviceName = "Samsung ${Build.MODEL}"
        val json = JSONObject().apply {
            put("type", "handshake")
            put("device", deviceName)
            put("platform", "android")
            put("version", "1.0.0")
            put("battery", JSONObject().apply {
                put("level", level)
                put("isCharging", false)
            })
        }
        webSocket?.send(json.toString())
    }

    fun sendClipboard(content: String, contentType: String = "text/plain", hash: String? = null) {
        if (!isConnected) return
        val json = JSONObject().apply {
            put("type", "clipboard")
            put("content", content)
            put("payload", content)
            put("contentType", contentType)
            put("source", "phone")
            if (hash != null) {
                put("hash", hash)
            }
        }
        webSocket?.send(json.toString())
    }

    fun sendFileProgress(fileId: String, bytesTransferred: Long, totalBytes: Long, percentage: Double, status: String) {
        if (!isConnected) return
        val json = JSONObject().apply {
            put("type", "file_progress")
            put("fileId", fileId)
            put("bytesTransferred", bytesTransferred)
            put("totalBytes", totalBytes)
            put("percentage", percentage)
            put("status", status)
        }
        webSocket?.send(json.toString())
    }

    fun sendFileComplete(fileId: String, status: String, message: String) {
        if (!isConnected) return
        val json = JSONObject().apply {
            put("type", "file_complete")
            put("fileId", fileId)
            put("status", status)
            put("message", message)
        }
        webSocket?.send(json.toString())
    }

    fun sendNotification(app: String, title: String, text: String) {
        if (!isConnected) return
        val json = JSONObject().apply {
            put("type", "phone_notification")
            put("app", app)
            put("title", title)
            put("text", text)
            put("timestamp", System.currentTimeMillis())
        }
        webSocket?.send(json.toString())
    }

    fun disconnect() {
        webSocket?.close(1000, "App closing")
        webSocket = null
        isConnected = false
    }
}
