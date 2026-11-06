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
        fun onClipboardReceived(text: String)
        fun onFileAvailable(fileId: String, filename: String, size: Long)
        fun onPingReceived(message: String)
    }

    private val tag = "GalaxyWS"
    private var client = OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()

    private var webSocket: WebSocket? = null
    private var isConnected = false
    private var currentHost = ""
    private var currentPort = 8765
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
                            val content = json.optString("content")
                            if (content.isNotEmpty()) {
                                mainHandler.post { listener.onClipboardReceived(content) }
                            }
                        }
                        "file_available" -> {
                            val fileId = json.optString("fileId")
                            val filename = json.optString("filename")
                            val size = json.optLong("fileSize")
                            mainHandler.post { listener.onFileAvailable(fileId, filename, size) }
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

    fun sendClipboard(text: String) {
        if (!isConnected) return
        val json = JSONObject().apply {
            put("type", "clipboard")
            put("content", text)
            put("contentType", "text/plain")
            put("source", "phone")
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
