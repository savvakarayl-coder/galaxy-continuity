package com.galaxycontinuity.app.service

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.*
import android.util.DisplayMetrics
import android.util.Log
import android.view.Surface
import androidx.core.app.NotificationCompat
import com.galaxycontinuity.app.network.StreamPacket
import kotlinx.coroutines.*
import java.nio.ByteBuffer

class ScreenMirroringService : Service() {

    companion object {
        private const val TAG = "ScreenMirroringService"
        const val CHANNEL_ID = "galaxy_screen_channel"
        const val NOTIFICATION_ID = 3001

        const val ACTION_START = "com.galaxycontinuity.app.service.START_SCREEN"
        const val ACTION_STOP = "com.galaxycontinuity.app.service.STOP_SCREEN"

        const val EXTRA_RESULT_CODE = "extra_result_code"
        const val EXTRA_RESULT_DATA = "extra_result_data"
        const val EXTRA_WIDTH = "extra_width"
        const val EXTRA_HEIGHT = "extra_height"
        const val EXTRA_FPS = "extra_fps"
        const val EXTRA_BITRATE = "extra_bitrate"

        var isStreaming = false
            private set
    }

    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var mediaCodec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var streamingJob: Job? = null
    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopScreenMirroring("user_requested")
                stopSelf()
            }
            ACTION_START -> {
                val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
                val resultData = intent.getParcelableExtra<Intent>(EXTRA_RESULT_DATA)
                val width = intent.getIntExtra(EXTRA_WIDTH, 1080)
                val height = intent.getIntExtra(EXTRA_HEIGHT, 2400)
                val fps = intent.getIntExtra(EXTRA_FPS, 30).coerceAtLeast(1)
                val bitrate = intent.getIntExtra(EXTRA_BITRATE, 4000000).coerceAtLeast(500000)

                if (resultCode == Activity.RESULT_OK && resultData != null) {
                    startMirroring(resultCode, resultData, width, height, fps, bitrate)
                } else {
                    Log.e(TAG, "Cannot start screen mirroring without valid result code & data")
                    stopSelf()
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun startMirroring(
        resultCode: Int,
        resultData: Intent,
        width: Int,
        height: Int,
        fps: Int,
        bitrate: Int
    ) {
        if (isStreaming) {
            Log.d(TAG, "Screen mirroring already running; ignoring restart")
            return
        }

        // On Android 14+ (UPSIDE_DOWN_CAKE), startForeground MUST precede getMediaProjection!
        val notification = buildNotification("Screen Mirroring active — streaming display to Mac")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            } else {
                0
            }
            startForeground(NOTIFICATION_ID, notification, type)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        val mpManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as? MediaProjectionManager
        if (mpManager == null) {
            stopSelf()
            return
        }

        mediaProjection = mpManager.getMediaProjection(resultCode, resultData)
        mediaProjection?.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                Log.d(TAG, "MediaProjection stopped by system")
                stopScreenMirroring("system_stopped")
            }
        }, Handler(Looper.getMainLooper()))

        try {
            setupMediaCodecAndVirtualDisplay(width, height, fps, bitrate)
            isStreaming = true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize encoder or virtual display", e)
            stopScreenMirroring("init_error")
        }
    }

    private fun setupMediaCodecAndVirtualDisplay(
        width: Int,
        height: Int,
        fps: Int,
        bitrate: Int
    ) {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1) // 1 second keyframe interval
        }

        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = codec.createInputSurface()
        codec.start()
        mediaCodec = codec

        val metrics: DisplayMetrics = resources.displayMetrics
        virtualDisplay = mediaProjection?.createVirtualDisplay(
            "GalaxyContinuityScreen",
            width,
            height,
            metrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            inputSurface,
            null,
            null
        )

        // Extraction loop
        streamingJob = serviceScope.launch {
            val bufferInfo = MediaCodec.BufferInfo()
            while (isActive && isStreaming) {
                try {
                    val outputIndex = codec.dequeueOutputBuffer(bufferInfo, 10000)
                    if (outputIndex >= 0) {
                        val outputBuffer = codec.getOutputBuffer(outputIndex)
                        if (outputBuffer != null && bufferInfo.size > 0) {
                            outputBuffer.position(bufferInfo.offset)
                            outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                            val outData = ByteArray(bufferInfo.size)
                            outputBuffer.get(outData)

                            // Frame into 5-byte packet: streamType 0x01 (Screen)
                            val packet = StreamPacket.pack(StreamPacket.TYPE_SCREEN, outData)
                            ContinuityService.activeClient?.sendBinary(packet)
                        }
                        codec.releaseOutputBuffer(outputIndex, false)
                    }
                } catch (e: Exception) {
                    if (isActive) {
                        Log.e(TAG, "Error in codec loop: ${e.message}")
                    }
                }
            }
        }
    }

    fun stopScreenMirroring(reason: String = "user_dismissed") {
        if (!isStreaming) return
        isStreaming = false

        streamingJob?.cancel()
        streamingJob = null

        try {
            virtualDisplay?.release()
            virtualDisplay = null

            mediaCodec?.stop()
            mediaCodec?.release()
            mediaCodec = null

            inputSurface?.release()
            inputSurface = null

            mediaProjection?.stop()
            mediaProjection = null
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing projection resources", e)
        }

        ContinuityService.activeClient?.sendScreenStop(reason)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        super.onDestroy()
        stopScreenMirroring("service_destroyed")
        serviceScope.cancel()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Screen Mirroring",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows status of live screen mirroring"
            }
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val stopIntent = Intent(this, ScreenMirroringService::class.java).apply {
            action = ACTION_STOP
        }
        val pendingStop = PendingIntent.getService(
            this, 0, stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Galaxy Continuity Screen")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_slideshow)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop Streaming", pendingStop)
            .setOngoing(true)
            .build()
    }
}
