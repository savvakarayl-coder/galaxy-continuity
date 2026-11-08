package com.galaxycontinuity.app.service

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
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
import java.io.ByteArrayOutputStream
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
        const val EXTRA_FORMAT = "extra_format" // "h264" or "jpeg"

        var isStreaming = false
            private set

        // Cache granted MediaProjection tokens during active application lifecycle
        var cachedResultCode: Int? = null
        var cachedResultData: Intent? = null
    }

    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var mediaCodec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var imageReader: ImageReader? = null
    private var streamingJob: Job? = null
    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    // H.264 SPS/PPS parameter set cache
    private var spsPpsBuffer: ByteArray? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        val notification = buildNotification("Initializing Screen Mirroring...")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                val reason = intent.getStringExtra("reason") ?: "user_requested"
                stopScreenMirroring(reason)
                stopSelf()
            }
            ACTION_START -> {
                var resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
                var resultData = intent.getParcelableExtra<Intent>(EXTRA_RESULT_DATA)

                if (resultData != null && resultCode == Activity.RESULT_OK) {
                    cachedResultCode = resultCode
                    cachedResultData = resultData
                } else if (cachedResultData != null && cachedResultCode == Activity.RESULT_OK) {
                    resultCode = cachedResultCode!!
                    resultData = cachedResultData
                }

                val width = intent.getIntExtra(EXTRA_WIDTH, 720)
                val height = intent.getIntExtra(EXTRA_HEIGHT, 1600)
                val fps = intent.getIntExtra(EXTRA_FPS, 30).coerceAtLeast(1)
                val bitrate = intent.getIntExtra(EXTRA_BITRATE, 3000000).coerceAtLeast(500000)
                val format = intent.getStringExtra(EXTRA_FORMAT) ?: "h264"

                if (resultCode == Activity.RESULT_OK && resultData != null) {
                    startMirroring(resultCode, resultData, width, height, fps, bitrate, format)
                } else {
                    Log.w(TAG, "Cannot start screen mirroring: missing MediaProjection user consent. Requesting via MainActivity...")
                    try {
                        val consentIntent = Intent(this@ScreenMirroringService, com.galaxycontinuity.app.MainActivity::class.java).apply {
                            action = "com.galaxycontinuity.app.REQUEST_SCREEN_CAPTURE"
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        }
                        startActivity(consentIntent)
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to launch consent activity: ${e.message}")
                    }
                    ContinuityService.activeClient?.sendScreenStop("media_projection_permission_required")
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
        bitrate: Int,
        format: String
    ) {
        if (isStreaming) {
            Log.d(TAG, "Screen mirroring already running; restarting with new session")
            stopScreenMirroring("restarting")
        }

        // Foreground service type MEDIA_PROJECTION is required for MediaProjection on Android 10+ (Q)
        val notification = buildNotification("Screen Mirroring active — streaming display to Mac")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        val mpManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as? MediaProjectionManager
        if (mpManager == null) {
            ContinuityService.activeClient?.sendScreenStop("projection_service_unavailable")
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

        isStreaming = true

        try {
            if (format.equals("jpeg", ignoreCase = true)) {
                setupImageReaderAndVirtualDisplay(width, height)
            } else {
                try {
                    setupMediaCodecAndVirtualDisplay(width, height, fps, bitrate)
                } catch (e: Exception) {
                    Log.w(TAG, "MediaCodec setup failed, falling back to ImageReader JPEG stream", e)
                    setupImageReaderAndVirtualDisplay(width, height)
                }
            }
        } catch (e: Exception) {
            isStreaming = false
            Log.e(TAG, "Failed to initialize video encoder or virtual display", e)
            stopScreenMirroring("init_error")
        }
    }

    private fun setupMediaCodecAndVirtualDisplay(
        width: Int,
        height: Int,
        fps: Int,
        bitrate: Int
    ) {
        val mediaFormat = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1) // 1 second keyframe interval
            // Ensure hardware encoder periodically produces frames even when phone display is static
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000L)
        }

        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(mediaFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
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
            var frameCount = 0
            Log.d(TAG, "Entering MediaCodec extraction loop (isStreaming=$isStreaming)")
            while (isActive && isStreaming) {
                try {
                    val outputIndex = codec.dequeueOutputBuffer(bufferInfo, 10000)
                    if (outputIndex >= 0) {
                        frameCount++
                        if (frameCount <= 5 || frameCount % 30 == 0) {
                            Log.d(TAG, "MediaCodec frame #$frameCount produced, size=${bufferInfo.size}, flags=${bufferInfo.flags}")
                        }
                        val outputBuffer = codec.getOutputBuffer(outputIndex)
                        if (outputBuffer != null && bufferInfo.size > 0) {
                            outputBuffer.position(bufferInfo.offset)
                            outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                            val outData = ByteArray(bufferInfo.size)
                            outputBuffer.get(outData)

                            // Cache SPS/PPS parameter sets
                            if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                                spsPpsBuffer = outData.clone()
                            }

                            // Prepend SPS/PPS to IDR keyframe if available to ensure decoder lock
                            val finalPayload = if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0 &&
                                spsPpsBuffer != null && !outData.contentEquals(spsPpsBuffer!!)
                            ) {
                                val combined = ByteArray(spsPpsBuffer!!.size + outData.size)
                                System.arraycopy(spsPpsBuffer!!, 0, combined, 0, spsPpsBuffer!!.size)
                                System.arraycopy(outData, 0, combined, spsPpsBuffer!!.size, outData.size)
                                combined
                            } else {
                                outData
                            }

                            // Frame into 5-byte packet: streamType 0x01 (Screen)
                            val packet = StreamPacket.pack(StreamPacket.TYPE_SCREEN, finalPayload)
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
            Log.d(TAG, "Exiting MediaCodec extraction loop (isStreaming=$isStreaming, isActive=$isActive)")
        }
    }

    /**
     * Fallback/JPEG pipeline: Uses ImageReader with RGBA_8888 and compresses frames to JPEG.
     * Guarantees 100% interoperability with macOS NSImage(data:).
     */
    private fun setupImageReaderAndVirtualDisplay(width: Int, height: Int) {
        val reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        val metrics: DisplayMetrics = resources.displayMetrics

        val handlerThread = HandlerThread("ScreenCaptureThread").also { it.start() }
        val handler = Handler(handlerThread.looper)

        reader.setOnImageAvailableListener({ r ->
            val image = r.acquireLatestImage() ?: return@setOnImageAvailableListener
            try {
                val planes = image.planes
                val buffer = planes[0].buffer
                val pixelStride = planes[0].pixelStride
                val rowStride = planes[0].rowStride
                val rowPadding = rowStride - pixelStride * width

                val bitmap = Bitmap.createBitmap(
                    width + rowPadding / pixelStride,
                    height,
                    Bitmap.Config.ARGB_8888
                )
                bitmap.copyPixelsFromBuffer(buffer)

                val finalBitmap = if (rowPadding == 0) bitmap else Bitmap.createBitmap(bitmap, 0, 0, width, height)
                val out = ByteArrayOutputStream()
                finalBitmap.compress(Bitmap.CompressFormat.JPEG, 75, out)
                val jpegBytes = out.toByteArray()

                val packet = StreamPacket.pack(StreamPacket.TYPE_SCREEN, jpegBytes)
                ContinuityService.activeClient?.sendBinary(packet)

                if (finalBitmap !== bitmap) {
                    bitmap.recycle()
                }
                finalBitmap.recycle()
            } catch (e: Exception) {
                Log.e(TAG, "Error encoding screen JPEG frame: ${e.message}")
            } finally {
                image.close()
            }
        }, handler)

        virtualDisplay = mediaProjection?.createVirtualDisplay(
            "GalaxyContinuityScreen",
            width,
            height,
            metrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            reader.surface,
            null,
            handler
        )
        imageReader = reader
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

            imageReader?.close()
            imageReader = null

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
