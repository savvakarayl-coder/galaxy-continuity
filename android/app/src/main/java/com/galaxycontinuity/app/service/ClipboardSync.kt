package com.galaxycontinuity.app.service

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.util.Base64
import android.util.Log
import androidx.core.content.FileProvider
import java.io.File
import java.security.MessageDigest

class ClipboardSync(
    private val context: Context,
    private val onSendClipboard: (content: String, contentType: String, hash: String) -> Unit
) {
    // Secondary constructor for backward compatibility
    constructor(
        context: Context,
        onSendText: (text: String) -> Unit
    ) : this(context, { content, _, _ -> onSendText(content) })

    private val tag = "ClipboardSync"
    private val clipboardManager = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    private var lastSeenText: String? = null
    private var lastSeenHash: String? = null
    private var lastSentHash: String? = null
    private var isUpdatingFromMac = false

    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener {
        if (isUpdatingFromMac) return@OnPrimaryClipChangedListener

        val clip = clipboardManager.primaryClip ?: return@OnPrimaryClipChangedListener
        if (clip.itemCount == 0) return@OnPrimaryClipChangedListener

        val item = clip.getItemAt(0)

        // 1. Check for image URI in primary clip
        val uri = item.uri
        val clipDesc = clip.description
        val isImage = uri != null && (
            clipDesc.hasMimeType("image/*") ||
            clipDesc.hasMimeType("image/png") ||
            clipDesc.hasMimeType("image/jpeg") ||
            (context.contentResolver?.getType(uri)?.startsWith("image/") == true)
        )

        if (isImage && uri != null) {
            try {
                val bytes = context.contentResolver?.openInputStream(uri)?.use { it.readBytes() }
                if (bytes != null && bytes.isNotEmpty()) {
                    val hash = sha256Hex(bytes)
                    if (hash != lastSeenHash && hash != lastSentHash) {
                        lastSeenHash = hash
                        lastSentHash = hash
                        val b64 = encodeBase64(bytes)
                        lastSeenText = b64
                        val mime = context.contentResolver?.getType(uri) ?: "image/png"
                        safeLogD(tag, "Phone image clipboard changed: $mime (${bytes.size} bytes)... sending to Mac")
                        onSendClipboard(b64, mime, hash)
                        return@OnPrimaryClipChangedListener
                    }
                }
            } catch (e: Exception) {
                safeLogE(tag, "Failed to read image from clipboard URI: $uri", e)
            }
        }

        // 2. Check for plain text (supports empty string for clipboard clearing)
        val text = item.text?.toString()
        if (text != null) {
            val bytes = text.toByteArray(Charsets.UTF_8)
            val hash = sha256Hex(bytes)
            if (hash != lastSeenHash && hash != lastSentHash && text != lastSeenText) {
                lastSeenText = text
                lastSeenHash = hash
                lastSentHash = hash
                safeLogD(tag, "Phone clipboard changed: ${text.take(30)}... sending to Mac")
                onSendClipboard(text, "text/plain", hash)
            }
        }
    }

    /**
     * Actively checks primary clip and synchronizes if a new clip is present.
     * Called by AccessibilityService on user UI interactions (copy, selection, window focus change).
     */
    fun checkAndSyncClipboard() {
        try {
            clipListener.onPrimaryClipChanged()
        } catch (e: Exception) {
            safeLogE(tag, "Error in manual checkAndSyncClipboard: ${e.message}")
        }
    }

    fun start() {
        clipboardManager.addPrimaryClipChangedListener(clipListener)
    }

    fun stop() {
        clipboardManager.removePrimaryClipChangedListener(clipListener)
    }

    fun updateClipboardFromMac(content: String, contentType: String = "text/plain", hash: String? = null) {
        if (content.isEmpty() && contentType.startsWith("image/")) return

        val computedHash = hash ?: sha256Hex(
            if (contentType.startsWith("image/")) {
                try {
                    decodeBase64(content)
                } catch (e: Exception) {
                    content.toByteArray(Charsets.UTF_8)
                }
            } else {
                content.toByteArray(Charsets.UTF_8)
            }
        )

        // Echo loop suppression: check hash and content
        if (shouldSuppress(computedHash, content, lastSeenHash, lastSentHash, lastSeenText)) {
            safeLogD(tag, "Dropping echo clipboard update from Mac (hash=$computedHash)")
            return
        }

        isUpdatingFromMac = true
        lastSeenHash = computedHash
        lastSeenText = content

        try {
            if (contentType.startsWith("image/")) {
                val imageBytes = decodeBase64(content)
                if (imageBytes.isNotEmpty()) {
                    val imageDir = File(context.cacheDir, "clipboard").apply { mkdirs() }
                    val ext = if (contentType.contains("jpeg") || contentType.contains("jpg")) "jpg" else "png"
                    val imageFile = File(imageDir, "synced_clip_${computedHash.take(8)}.$ext")
                    imageFile.writeBytes(imageBytes)

                    val uri: Uri = try {
                        FileProvider.getUriForFile(
                            context,
                            "${context.packageName}.fileprovider",
                            imageFile
                        )
                    } catch (e: Exception) {
                        safeLogW(tag, "FileProvider failed: ${e.message}, falling back to file URI")
                        Uri.fromFile(imageFile)
                    }

                    val clip = ClipData.newUri(context.contentResolver, "Galaxy Continuity Image", uri)
                    clipboardManager.setPrimaryClip(clip)
                    safeLogD(tag, "Updated Galaxy clipboard with image from Mac (${imageBytes.size} bytes)")
                }
            } else {
                val clip = ClipData.newPlainText("Galaxy Continuity", content)
                clipboardManager.setPrimaryClip(clip)
                safeLogD(tag, "Updated Galaxy clipboard from Mac: ${content.take(30)}...")
            }
        } catch (e: Exception) {
            safeLogE(tag, "Failed to update clipboard from Mac", e)
        } finally {
            isUpdatingFromMac = false
        }
    }

    fun updateClipboardFromMac(text: String) {
        updateClipboardFromMac(text, "text/plain", null)
    }

    private fun safeLogD(tag: String, msg: String) {
        try { Log.d(tag, msg) } catch (t: Throwable) { println("[$tag] $msg") }
    }

    private fun safeLogW(tag: String, msg: String) {
        try { Log.w(tag, msg) } catch (t: Throwable) { println("[$tag] WARN: $msg") }
    }

    private fun safeLogE(tag: String, msg: String, tr: Throwable? = null) {
        try { Log.e(tag, msg, tr) } catch (t: Throwable) { println("[$tag] ERROR: $msg ${tr?.message ?: ""}") }
    }

    companion object {
        fun sha256Hex(bytes: ByteArray): String {
            val md = MessageDigest.getInstance("SHA-256")
            val digest = md.digest(bytes)
            return digest.joinToString("") { "%02x".format(it) }
        }

        fun encodeBase64(bytes: ByteArray): String {
            return try {
                Base64.encodeToString(bytes, Base64.NO_WRAP)
            } catch (t: Throwable) {
                java.util.Base64.getEncoder().encodeToString(bytes)
            }
        }

        fun decodeBase64(b64: String): ByteArray {
            return try {
                Base64.decode(b64, Base64.DEFAULT)
            } catch (t: Throwable) {
                java.util.Base64.getDecoder().decode(b64)
            }
        }

        fun shouldSuppress(
            incomingHash: String,
            incomingContent: String,
            lastSeenHash: String? = null,
            lastSentHash: String? = null,
            lastSeenText: String? = null
        ): Boolean {
            return (incomingHash.isNotEmpty() && (incomingHash == lastSeenHash || incomingHash == lastSentHash)) ||
                   (incomingContent.isNotEmpty() && incomingContent == lastSeenText)
        }
    }
}
