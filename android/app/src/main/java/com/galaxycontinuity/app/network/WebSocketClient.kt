package com.galaxycontinuity.app.network

import android.content.Context
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import okhttp3.*
import okio.ByteString
import okio.ByteString.Companion.toByteString
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

        // Milestone 3: Screen Mirroring & Continuity Camera
        fun onScreenStart(width: Int, height: Int, fps: Int, bitrate: Int)
        fun onScreenStop(reason: String?)
        fun onRemoteInput(action: String, x: Double, y: Double, button: Int)
        fun onRemoteKey(key: String, keyCode: Int)
        fun onCameraStart(lens: String, quality: String, fps: Int)
        fun onCameraStop()
        fun onCameraControl(action: String, lens: String?, zoom: Double?, torch: Boolean?)

        // Milestone 4: Notification Relay & Quick Reply
        fun onNotificationReply(id: String, packageName: String, replyText: String)
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
                    when (val type = json.optString("type")) {
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

                        // Milestone 3: Screen Mirroring
                        "screen_start" -> {
                            val width = json.optInt("width", 1080)
                            val height = json.optInt("height", 2400)
                            val fps = json.optInt("fps", 30)
                            val bitrate = json.optInt("bitrate", 4000000)
                            mainHandler.post { listener.onScreenStart(width, height, fps, bitrate) }
                        }
                        "screen_stop" -> {
                            val reason = json.optString("reason", "mac_requested").ifEmpty { null }
                            mainHandler.post { listener.onScreenStop(reason) }
                        }
                        "input_event" -> {
                            val action = json.optString("action", "down")
                            val x = json.optDouble("x", 0.5)
                            val y = json.optDouble("y", 0.5)
                            val button = json.optInt("button", 0)
                            mainHandler.post { listener.onRemoteInput(action, x, y, button) }
                        }
                        "input_key" -> {
                            val key = json.optString("key", "")
                            val keyCode = json.optInt("keyCode", 0)
                            mainHandler.post { listener.onRemoteKey(key, keyCode) }
                        }

                        // Milestone 3: Continuity Camera
                        "camera_start" -> {
                            val lens = if (json.has("lens")) json.getString("lens") else json.optString("facing", "back")
                            val quality = if (json.has("quality")) json.getString("quality") else json.optString("resolution", "1080p")
                            val fps = json.optInt("fps", 30)
                            mainHandler.post { listener.onCameraStart(lens, quality, fps) }
                        }
                        "camera_stop" -> {
                            mainHandler.post { listener.onCameraStop() }
                        }
                        "camera_control", "camera_switch_lens" -> {
                            val action = json.optString("action", if (type == "camera_switch_lens") "switch_lens" else "")
                            val lens = if (json.has("lens")) json.getString("lens") else if (json.has("facing")) json.getString("facing") else null
                            val zoom = if (json.has("zoom")) json.getDouble("zoom") else null
                            val torch = if (json.has("torch")) json.getBoolean("torch") else null
                            mainHandler.post { listener.onCameraControl(action, lens, zoom, torch) }
                        }

                        // Milestone 4: Notification Relay & Quick Reply
                        "notification_reply" -> {
                            val id = json.optString("id")
                            val pkg = json.optString("packageName")
                            val replyText = json.optString("replyText")
                            mainHandler.post { listener.onNotificationReply(id, pkg, replyText) }
                        }

                        else -> {
                            Log.d(tag, "Ignoring unhandled message type: $type")
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

    fun sendBinary(data: ByteArray) {
        if (!isConnected) return
        webSocket?.send(data.toByteString())
    }

    fun sendBinary(byteString: ByteString) {
        if (!isConnected) return
        webSocket?.send(byteString)
    }

    fun sendScreenStop(reason: String = "user_dismissed") {
        if (!isConnected) return
        val json = JSONObject().apply {
            put("type", "screen_stop")
            put("reason", reason)
        }
        webSocket?.send(json.toString())
    }

    fun sendCameraStop() {
        if (!isConnected) return
        val json = JSONObject().apply {
            put("type", "camera_stop")
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

    fun sendNotification(
        id: String = java.util.UUID.randomUUID().toString(),
        packageName: String = "",
        app: String,
        title: String,
        text: String,
        canReply: Boolean = false
    ) {
        if (!isConnected) return
        val json = JSONObject().apply {
            put("type", "phone_notification")
            put("id", id)
            put("packageName", packageName)
            put("app", app)
            put("title", title)
            put("text", text)
            put("canReply", canReply)
            put("timestamp", System.currentTimeMillis())
        }
        webSocket?.send(json.toString())
    }

    // Overload for backward compatibility
    fun sendNotification(app: String, title: String, text: String) {
        sendNotification(java.util.UUID.randomUUID().toString(), "", app, title, text, false)
    }

    fun disconnect() {
        webSocket?.close(1000, "App closing")
        webSocket = null
        isConnected = false
    }
}
