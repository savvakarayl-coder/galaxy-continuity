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
import com.galaxycontinuity.app.network.FileTransferClient
import com.galaxycontinuity.app.network.NsdDiscovery
import com.galaxycontinuity.app.network.WebSocketClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
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
        var lastStatus = "Disconnected"
    }

    private var nsdDiscovery: NsdDiscovery? = null
    private var webSocketClient: WebSocketClient? = null
    private var clipboardSync: ClipboardSync? = null
    private val fileTransferClient = FileTransferClient()
    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())

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
        clipboardSync?.start()

        nsdDiscovery = NsdDiscovery(this) { host, port, name ->
            lastStatus = "Connecting to $name..."
            updateNotification("Connecting to $name...")
            webSocketClient?.connect(host, port)
        }
        nsdDiscovery?.startDiscovery()
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
        serviceScope.cancel()
        nsdDiscovery?.stopDiscovery()
        clipboardSync?.stop()
        webSocketClient?.disconnect()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // WebSocket callbacks
    override fun onConnected(macName: String) {
        lastStatus = "Connected to $macName"
        updateNotification("Connected to $macName")
    }

    override fun onDisconnected() {
        lastStatus = "Disconnected. Searching..."
        updateNotification("Disconnected. Searching for Mac...")
        nsdDiscovery?.startDiscovery()
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
