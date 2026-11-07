package com.galaxycontinuity.app.service

import android.annotation.SuppressLint
import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.ImageFormat
import android.hardware.camera2.*
import android.media.ImageReader
import android.os.*
import android.util.Log
import android.util.Range
import androidx.core.app.NotificationCompat
import com.galaxycontinuity.app.network.StreamPacket

class ContinuityCameraService : Service() {

    companion object {
        private const val TAG = "ContinuityCamera"
        const val CHANNEL_ID = "galaxy_camera_channel"
        const val NOTIFICATION_ID = 4001

        const val ACTION_START = "com.galaxycontinuity.app.service.START_CAMERA"
        const val ACTION_STOP = "com.galaxycontinuity.app.service.STOP_CAMERA"

        const val EXTRA_LENS = "extra_lens"
        const val EXTRA_QUALITY = "extra_quality"
        const val EXTRA_FPS = "extra_fps"

        var instance: ContinuityCameraService? = null
            private set
        var isStreaming = false
            private set
    }

    private var cameraManager: CameraManager? = null
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    private var backgroundThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null

    // Persistent CaptureRequest state
    private var currentRequestBuilder: CaptureRequest.Builder? = null
    private var currentLens = "back"
    private var isTorchOn = false
    private var currentZoom = 1.0f
    private var currentFps = 30

    override fun onCreate() {
        super.onCreate()
        instance = this
        cameraManager = getSystemService(Context.CAMERA_SERVICE) as? CameraManager
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopCamera()
                stopSelf()
            }
            ACTION_START -> {
                val lens = intent.getStringExtra(EXTRA_LENS) ?: "back"
                val quality = intent.getStringExtra(EXTRA_QUALITY) ?: "1080p"
                val fps = intent.getIntExtra(EXTRA_FPS, 30).coerceAtLeast(1)
                startCamera(lens, quality, fps)
            }
        }
        return START_NOT_STICKY
    }

    private fun startCamera(lens: String, quality: String, fps: Int) {
        // Only close active camera hardware sensor — DO NOT call stopCamera() which terminates session
        closeCameraSensor()

        val notification = buildNotification("Continuity Camera active — streaming to Mac")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            } else {
                0
            }
            startForeground(NOTIFICATION_ID, notification, type)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        startBackgroundThread()
        currentLens = lens
        currentFps = fps

        // If switching to front lens, ensure torch is deactivated
        if (lens.equals("front", ignoreCase = true)) {
            isTorchOn = false
        }

        val (width, height) = when (quality.lowercase()) {
            "4k" -> Pair(3840, 2160)
            "720p" -> Pair(1280, 720)
            else -> Pair(1920, 1080)
        }

        openCamera(lens, width, height, fps)
    }

    @SuppressLint("MissingPermission")
    private fun openCamera(lens: String, width: Int, height: Int, fps: Int) {
        val manager = cameraManager ?: return
        val targetFacing = if (lens.equals("front", ignoreCase = true)) {
            CameraCharacteristics.LENS_FACING_FRONT
        } else {
            CameraCharacteristics.LENS_FACING_BACK
        }

        var selectedCameraId: String? = null
        try {
            for (id in manager.cameraIdList) {
                val chars = manager.getCameraCharacteristics(id)
                val facing = chars.get(CameraCharacteristics.LENS_FACING)
                if (facing == targetFacing) {
                    selectedCameraId = id
                    break
                }
            }
            if (selectedCameraId == null && manager.cameraIdList.isNotEmpty()) {
                selectedCameraId = manager.cameraIdList[0]
            }

            if (selectedCameraId == null) {
                Log.e(TAG, "No suitable camera found")
                stopSelf()
                return
            }

            // ImageReader for JPEG capture (verifies 0xFF 0xD8 payload)
            val reader = ImageReader.newInstance(width, height, ImageFormat.JPEG, 2)
            reader.setOnImageAvailableListener({ r ->
                val image = r.acquireLatestImage() ?: return@setOnImageAvailableListener
                try {
                    val plane = image.planes[0]
                    val buffer = plane.buffer
                    val bytes = ByteArray(buffer.remaining())
                    buffer.get(bytes)

                    // Pack into 5-byte header standard packet: streamType 0x02 (Camera)
                    val packet = StreamPacket.pack(StreamPacket.TYPE_CAMERA, bytes)
                    ContinuityService.activeClient?.sendBinary(packet)
                } catch (e: Exception) {
                    Log.e(TAG, "Error acquiring camera image: ${e.message}")
                } finally {
                    image.close()
                }
            }, backgroundHandler)
            imageReader = reader

            manager.openCamera(selectedCameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    cameraDevice = camera
                    startCaptureSession(camera, reader.surface, fps)
                    isStreaming = true
                }

                override fun onDisconnected(camera: CameraDevice) {
                    camera.close()
                    cameraDevice = null
                    isStreaming = false
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    camera.close()
                    cameraDevice = null
                    isStreaming = false
                    Log.e(TAG, "CameraDevice error: $error")
                }
            }, backgroundHandler)

        } catch (e: Exception) {
            Log.e(TAG, "Failed to open camera: ${e.message}", e)
            stopSelf()
        }
    }

    private fun startCaptureSession(camera: CameraDevice, surface: android.view.Surface, fps: Int) {
        try {
            val builder = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                addTarget(surface)
                set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, Range(fps, fps))
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    set(CaptureRequest.CONTROL_ZOOM_RATIO, currentZoom)
                }
                set(
                    CaptureRequest.FLASH_MODE,
                    if (isTorchOn) CaptureRequest.FLASH_MODE_TORCH else CaptureRequest.FLASH_MODE_OFF
                )
            }
            currentRequestBuilder = builder

            camera.createCaptureSession(
                listOf(surface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        captureSession = session
                        session.setRepeatingRequest(builder.build(), null, backgroundHandler)
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        Log.e(TAG, "Camera capture session configuration failed")
                    }
                },
                backgroundHandler
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start camera capture session", e)
        }
    }

    /**
     * Atomically mutates the persistent builder and updates the repeating capture request.
     * Preserves zoom, torch, AF mode, and AE frame rate constraints concurrently.
     */
    private fun updateCaptureRequest(mutator: (CaptureRequest.Builder.() -> Unit)? = null) {
        val session = captureSession ?: return
        val builder = currentRequestBuilder ?: return
        try {
            mutator?.invoke(builder)
            session.setRepeatingRequest(builder.build(), null, backgroundHandler)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to update capture request: ${e.message}", e)
        }
    }

    fun handleControl(action: String, lens: String?, zoom: Double?, torch: Boolean?) {
        when (action.lowercase().trim()) {
            "switch_lens" -> {
                val targetLens = lens ?: if (currentLens == "back") "front" else "back"
                // Switching lens restarts camera on new sensor without killing session or service
                startCamera(targetLens, "1080p", currentFps)
            }
            "set_zoom" -> {
                if (zoom != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    currentZoom = zoom.toFloat()
                    updateCaptureRequest {
                        set(CaptureRequest.CONTROL_ZOOM_RATIO, currentZoom)
                    }
                }
            }
            "toggle_torch" -> {
                if (torch != null) {
                    isTorchOn = torch
                    updateCaptureRequest {
                        set(
                            CaptureRequest.FLASH_MODE,
                            if (isTorchOn) CaptureRequest.FLASH_MODE_TORCH else CaptureRequest.FLASH_MODE_OFF
                        )
                    }
                }
            }
        }
    }

    /**
     * Closes the active Camera2 device, session, and ImageReader without terminating the service.
     */
    private fun closeCameraSensor() {
        try {
            captureSession?.stopRepeating()
            captureSession?.close()
            captureSession = null

            cameraDevice?.close()
            cameraDevice = null

            imageReader?.close()
            imageReader = null

            currentRequestBuilder = null
        } catch (e: Exception) {
            Log.e(TAG, "Error closing camera sensor: ${e.message}")
        }
    }

    /**
     * Full session teardown: closes sensor, stops background thread, sends camera_stop to Mac,
     * removes foreground notification, and calls stopSelf().
     */
    fun stopCamera() {
        if (!isStreaming && cameraDevice == null) return
        isStreaming = false

        closeCameraSensor()
        stopBackgroundThread()
        ContinuityService.activeClient?.sendCameraStop()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun startBackgroundThread() {
        if (backgroundThread == null) {
            backgroundThread = HandlerThread("CameraBackground").also { it.start() }
            backgroundHandler = Handler(backgroundThread!!.looper)
        }
    }

    private fun stopBackgroundThread() {
        backgroundThread?.quitSafely()
        try {
            backgroundThread?.join()
            backgroundThread = null
            backgroundHandler = null
        } catch (e: InterruptedException) {
            Log.e(TAG, "Background thread interrupted", e)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        stopCamera()
        instance = null
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Continuity Camera",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows status of Continuity Camera streaming feed"
            }
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val stopIntent = Intent(this, ContinuityCameraService::class.java).apply {
            action = ACTION_STOP
        }
        val pendingStop = PendingIntent.getService(
            this, 0, stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Galaxy Continuity Camera")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop Camera", pendingStop)
            .setOngoing(true)
            .build()
    }
}
