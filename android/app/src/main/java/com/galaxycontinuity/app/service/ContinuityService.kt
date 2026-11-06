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
import com.galaxycontinuity.app.network.NsdDiscovery
import com.galaxycontinuity.app.network.WebSocketClient

class ContinuityService : Service(), WebSocketClient.ContinuityListener {

    companion object {
        const val CHANNEL_ID = "galaxy_continuity_channel"
        const val NOTIFICATION_ID = 1001

        var isRunning = false
        var activeClient: WebSocketClient? = null
        var lastStatus = "Disconnected"
    }

    private var nsdDiscovery: NsdDiscovery? = null
    private var webSocketClient: WebSocketClient? = null
    private var clipboardSync: ClipboardSync? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification("Searching for Mac on Wi-Fi..."))

        webSocketClient = WebSocketClient(this, this)
        activeClient = webSocketClient

        clipboardSync = ClipboardSync(this) { text ->
            webSocketClient?.sendClipboard(text)
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

    override fun onClipboardReceived(text: String) {
        clipboardSync?.updateClipboardFromMac(text)
    }

    override fun onFileAvailable(fileId: String, filename: String, size: Long) {
        // Trigger download via DownloadManager or HTTP client
    }

    override fun onPingReceived(message: String) {
        // Vibrate and sound
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Galaxy Continuity Status",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows status of Mac connection"
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
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
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }
}
