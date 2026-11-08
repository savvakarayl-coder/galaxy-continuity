package com.galaxycontinuity.app.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.galaxycontinuity.app.MainActivity
import com.galaxycontinuity.app.network.BleDiscoveryManager
import com.galaxycontinuity.app.network.FileTransferClient
import com.galaxycontinuity.app.network.NsdDiscovery
import com.galaxycontinuity.app.network.WebSocketClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.io.File

class ContinuityService : Service(), WebSocketClient.ContinuityListener {

    companion object {
        const val CHANNEL_ID = "galaxy_continuity_channel"
        const val CHANNEL_QUICK_DROP = "galaxy_quick_drop_channel"
        const val NOTIFICATION_ID = 1001
        const val QUICK_DROP_NOTIFICATION_ID = 2001

        var isRunning = false
        var activeClient: WebSocketClient? = null
        var activeClipboardSync: ClipboardSync? = null
        var lastStatus = "Disconnected"
        val isSocketConnected = MutableStateFlow(false)
        val connectionStatus = MutableStateFlow("Disconnected. Searching...")

        fun connectManually(host: String, port: Int = 8765) {
            activeClient?.connect(host, port)
        }
    }

    private var nsdDiscovery: NsdDiscovery? = null
    private var bleDiscovery: BleDiscoveryManager? = null
    private var webSocketClient: WebSocketClient? = null
    private var clipboardSync: ClipboardSync? = null
    private val fileTransferClient = FileTransferClient()
    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var reconnectionJob: Job? = null
    private var reconnectAttempt = 0

    private fun saveLastKnownHost(host: String, port: Int) {
        if (host.isEmpty() || host == "127.0.0.1") return
        try {
            getSharedPreferences("galaxy_continuity_prefs", Context.MODE_PRIVATE)
                .edit()
                .putString("last_known_host", host)
                .putInt("last_known_port", port)
                .apply()
            android.util.Log.d("ContinuityService", "Persisted last-known Wi-Fi host: $host:$port")
        } catch (e: Exception) {
            android.util.Log.w("ContinuityService", "Failed to persist last-known host: ${e.message}")
        }
    }

    private fun getLastKnownHost(): String? {
        return try {
            getSharedPreferences("galaxy_continuity_prefs", Context.MODE_PRIVATE)
                .getString("last_known_host", null)
        } catch (e: Exception) {
            null
        }
    }

    private fun getLastKnownPort(): Int {
        return try {
            getSharedPreferences("galaxy_continuity_prefs", Context.MODE_PRIVATE)
                .getInt("last_known_port", 8765)
        } catch (e: Exception) {
            8765
        }
    }

    private fun startReconnectionLoop() {
        if (reconnectionJob?.isActive == true) return
        reconnectionJob = serviceScope.launch {
            while (isRunning && !isSocketConnected.value) {
                reconnectAttempt++

                // Probe 1: USB Loopback (via adb reverse)
                android.util.Log.d("ContinuityService", "Reconnection attempt #$reconnectAttempt: probing USB loopback 127.0.0.1:8765...")
                updateNotification("Connecting to Mac (USB/Wi-Fi)...")
                try {
                    webSocketClient?.connect("127.0.0.1", 8765)
                } catch (e: Exception) {
                    android.util.Log.d("ContinuityService", "USB loopback connect error: ${e.message}")
                }

                kotlinx.coroutines.delay(1200L)
                if (!isRunning || isSocketConnected.value) break

                // Probe 2: Cached last-known Wi-Fi host
                val cachedHost = getLastKnownHost()
                val cachedPort = getLastKnownPort()
                if (!cachedHost.isNullOrEmpty() && cachedHost != "127.0.0.1") {
                    android.util.Log.d("ContinuityService", "Reconnection attempt #$reconnectAttempt: probing cached Wi-Fi host $cachedHost:$cachedPort...")
                    try {
                        webSocketClient?.connect(cachedHost, cachedPort)
                    } catch (e: Exception) {
                        android.util.Log.d("ContinuityService", "Cached host connect error: ${e.message}")
                    }
                    kotlinx.coroutines.delay(1200L)
                    if (!isRunning || isSocketConnected.value) break
                }

                // Probe 3: Trigger mDNS scan
                nsdDiscovery?.startDiscovery()
                kotlinx.coroutines.delay(1500L)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        createNotificationChannel()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            } else {
                0
            }
            startForeground(NOTIFICATION_ID, buildNotification("Searching for Mac on Wi-Fi..."), type)
        } else {
            startForeground(NOTIFICATION_ID, buildNotification("Searching for Mac on Wi-Fi..."))
        }

        webSocketClient = WebSocketClient(this, this)
        activeClient = webSocketClient

        clipboardSync = ClipboardSync(this) { content, contentType, hash ->
            webSocketClient?.sendClipboard(content, contentType, hash)
        }
        activeClipboardSync = clipboardSync
        clipboardSync?.start()

        nsdDiscovery = NsdDiscovery(this) { host, port, name ->
            lastStatus = "Connecting to $name..."
            connectionStatus.value = "Connecting to $name..."
            updateNotification("Connecting to $name...")
            saveLastKnownHost(host, port)
            webSocketClient?.connect(host, port)
        }
        nsdDiscovery?.startDiscovery()

        // Proximity detection via Bluetooth Low Energy (Apple-like near discovery)
        try {
            bleDiscovery = BleDiscoveryManager(this) { shortId, role, port ->
                android.util.Log.d("ContinuityService", "BLE proximity beacon detected from Mac: shortId=$shortId, port=$port")
                if (!isSocketConnected.value) {
                    val host = getLastKnownHost() ?: "127.0.0.1"
                    webSocketClient?.connect(host, port)
                }
            }
            bleDiscovery?.startScanning()
        } catch (e: Exception) {
            android.util.Log.w("ContinuityService", "BLE discovery initialization skipped: ${e.message}")
        }

        // Kick off background reconnection loop immediately (attempt 0 runs with 0ms delay)
        startReconnectionLoop()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manualHost = intent?.getStringExtra("host")
        val manualPort = intent?.getIntExtra("port", 8765) ?: 8765
        if (!manualHost.isNullOrEmpty()) {
            webSocketClient?.connect(manualHost, manualPort)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        isRunning = false
        activeClient = null
        activeClipboardSync = null
        isSocketConnected.value = false
        connectionStatus.value = "Disconnected"
        reconnectionJob?.cancel()
        reconnectionJob = null
        serviceScope.cancel()
        nsdDiscovery?.stopDiscovery()
        bleDiscovery?.stopScanning()
        clipboardSync?.stop()
        webSocketClient?.disconnect()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // WebSocket callbacks
    override fun onConnected(macName: String) {
        reconnectionJob?.cancel()
        reconnectionJob = null
        reconnectAttempt = 0
        val host = webSocketClient?.currentHost ?: ""
        val port = webSocketClient?.currentPort ?: 8765
        if (host.isNotEmpty() && host != "127.0.0.1") {
            saveLastKnownHost(host, port)
        }
        lastStatus = "Connected to $macName"
        connectionStatus.value = "Connected to $macName"
        isSocketConnected.value = true
        updateNotification("Connected to $macName")
    }

    override fun onDisconnected() {
        lastStatus = "Disconnected. Searching..."
        connectionStatus.value = "Disconnected. Searching..."
        isSocketConnected.value = false
        updateNotification("Disconnected. Searching for Mac...")
        nsdDiscovery?.startDiscovery()
        startReconnectionLoop()
    }

    override fun onClipboardReceived(content: String, contentType: String, hash: String?) {
        clipboardSync?.updateClipboardFromMac(content, contentType, hash)
    }

    override fun onFileAvailable(fileId: String, filename: String, size: Long) {
        val host = webSocketClient?.currentHost?.takeIf { it.isNotEmpty() } ?: return
        val port = webSocketClient?.currentPort ?: 8765
        val serverUrl = "http://$host:$port"

        val downloadDir = File(
            android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOWNLOADS),
            "GalaxyContinuity"
        ).takeIf { it.exists() || it.mkdirs() }
            ?: File(getExternalFilesDir(android.os.Environment.DIRECTORY_DOWNLOADS) ?: filesDir, "GalaxyContinuity").apply { mkdirs() }

        showTransferNotification(fileId, filename, 0.0, false)

        serviceScope.launch {
            var lastUpdate = 0L
            val result = fileTransferClient.downloadFile(serverUrl, fileId, downloadDir, filename) { bytes, total, pct ->
                val now = System.currentTimeMillis()
                if (now - lastUpdate > 300 || pct >= 100.0) {
                    lastUpdate = now
                    showTransferNotification(fileId, filename, pct, false)
                    webSocketClient?.sendFileProgress(fileId, bytes, total, pct, "transferring")
                }
            }

            result.onSuccess { savedFile ->
                showTransferNotification(fileId, filename, 100.0, true, savedFile)
                webSocketClient?.sendFileComplete(fileId, "success", "Saved to ${savedFile.absolutePath}")
            }.onFailure { err ->
                showTransferFailedNotification(filename, err.message ?: "Download failed")
                webSocketClient?.sendFileComplete(fileId, "error", err.message ?: "Download failed")
            }
        }
    }

    override fun onFileProgress(fileId: String, bytesTransferred: Long, totalBytes: Long, percentage: Double, status: String) {
        // Handle remote progress update if needed
    }

    override fun onFileComplete(fileId: String, status: String, message: String) {
        // Handle remote complete update if needed
    }

    override fun onPingReceived(message: String) {
        // Vibrate and sound
    }

    // MARK: - Milestone 3 Screen Mirroring & Input Callbacks
    override fun onScreenStart(width: Int, height: Int, fps: Int, bitrate: Int) {
        android.util.Log.d("ContinuityService", "Received screen_start ($width x $height @ $fps fps)")
        val startIntent = Intent(this, ScreenMirroringService::class.java).apply {
            action = ScreenMirroringService.ACTION_START
            putExtra(ScreenMirroringService.EXTRA_WIDTH, width)
            putExtra(ScreenMirroringService.EXTRA_HEIGHT, height)
            putExtra(ScreenMirroringService.EXTRA_FPS, fps)
            putExtra(ScreenMirroringService.EXTRA_BITRATE, bitrate)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(startIntent)
        } else {
            startService(startIntent)
        }
    }

    override fun onScreenStop(reason: String?) {
        android.util.Log.d("ContinuityService", "Received screen_stop (reason: $reason)")
        val stopIntent = Intent(this, ScreenMirroringService::class.java).apply {
            action = ScreenMirroringService.ACTION_STOP
        }
        startService(stopIntent)
    }

    override fun onRemoteInput(action: String, x: Double, y: Double, button: Int) {
        ContinuityAccessibilityService.instance?.handleInputEvent(action, x, y, button)
    }

    override fun onRemoteKey(key: String, keyCode: Int) {
        ContinuityAccessibilityService.instance?.handleKeyInput(key, keyCode)
    }

    // MARK: - Milestone 3 Continuity Camera Callbacks
    override fun onCameraStart(lens: String, quality: String, fps: Int) {
        android.util.Log.d("ContinuityService", "Received camera_start (lens: $lens, quality: $quality, fps: $fps)")
        val intent = Intent(this, ContinuityCameraService::class.java).apply {
            action = ContinuityCameraService.ACTION_START
            putExtra(ContinuityCameraService.EXTRA_LENS, lens)
            putExtra(ContinuityCameraService.EXTRA_QUALITY, quality)
            putExtra(ContinuityCameraService.EXTRA_FPS, fps)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    override fun onCameraStop() {
        android.util.Log.d("ContinuityService", "Received camera_stop")
        val intent = Intent(this, ContinuityCameraService::class.java).apply {
            action = ContinuityCameraService.ACTION_STOP
        }
        startService(intent)
    }

    override fun onCameraControl(action: String, lens: String?, zoom: Double?, torch: Boolean?) {
        ContinuityCameraService.instance?.handleControl(action, lens, zoom, torch)
    }

    override fun onNotificationReply(id: String, packageName: String, replyText: String) {
        android.util.Log.d("ContinuityService", "Received notification_reply for $id ($packageName): $replyText")
        NotificationForwarderService.replyToNotification(id, packageName, replyText)
    }

    override fun onRemoteText(text: String) {
        ContinuityAccessibilityService.instance?.handleTextInput(text)
    }

    override fun onRemoteScroll(x: Double, y: Double, dx: Double, dy: Double) {
        ContinuityAccessibilityService.instance?.handleScroll(x, y, dx, dy)
    }

    override fun onNotificationOpen(id: String, packageName: String) {
        android.util.Log.d("ContinuityService", "Received notification_open for id=$id pkg=$packageName")
        NotificationForwarderService.openNotification(this, id, packageName)
    }

    private fun showTransferNotification(fileId: String, filename: String, percentage: Double, completed: Boolean, file: File? = null) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        val builder = NotificationCompat.Builder(this, CHANNEL_QUICK_DROP)
            .setSmallIcon(if (completed) android.R.drawable.stat_sys_download_done else android.R.drawable.stat_sys_download)
            .setContentTitle(if (completed) "⚡ Quick Drop Complete" else "⚡ Receiving $filename")
            .setContentText(if (completed) "$filename saved to Downloads/GalaxyContinuity" else "${percentage.toInt()}%")
            .setOngoing(!completed)

        if (!completed) {
            builder.setProgress(100, percentage.toInt(), false)
        } else {
            builder.setProgress(0, 0, false)
            if (file != null) {
                val uri = try {
                    androidx.core.content.FileProvider.getUriForFile(
                        this,
                        "${packageName}.fileprovider",
                        file
                    )
                } catch (e: Exception) {
                    android.net.Uri.fromFile(file)
                }
                val ext = file.extension.lowercase()
                val mimeType = try {
                    android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "*/*"
                } catch (_: Throwable) {
                    "*/*"
                }
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, mimeType)
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION
                }
                val pending = PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE)
                builder.setContentIntent(pending)
            }
        }
        manager.notify(QUICK_DROP_NOTIFICATION_ID, builder.build())
    }

    private fun showTransferFailedNotification(filename: String, reason: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        val notification = NotificationCompat.Builder(this, CHANNEL_QUICK_DROP)
            .setSmallIcon(android.R.drawable.stat_notify_error)
            .setContentTitle("Quick Drop Failed")
            .setContentText("Could not download $filename: $reason")
            .build()
        manager.notify(QUICK_DROP_NOTIFICATION_ID, notification)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return

            val channel = NotificationChannel(
                CHANNEL_ID,
                "Galaxy Continuity Status",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows status of Mac connection"
            }
            manager.createNotificationChannel(channel)

            val quickDropChannel = NotificationChannel(
                CHANNEL_QUICK_DROP,
                "Quick Drop Transfers",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows progress and completion of Quick Drop file transfers"
            }
            manager.createNotificationChannel(quickDropChannel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Galaxy Continuity")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_share)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }
}
