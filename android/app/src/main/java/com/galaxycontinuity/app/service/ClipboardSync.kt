package com.galaxycontinuity.app.service

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.util.Log

class ClipboardSync(
    private val context: Context,
    private val onSendClipboardToMac: (text: String) -> Unit
) {
    private val tag = "ClipboardSync"
    private val clipboardManager = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    private var lastSeenText = ""
    private var isUpdatingFromMac = false

    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener {
        if (isUpdatingFromMac) return@OnPrimaryClipChangedListener

        val clip = clipboardManager.primaryClip
        if (clip != null && clip.itemCount > 0) {
            val text = clip.getItemAt(0).text?.toString() ?: ""
            if (text.isNotEmpty() && text != lastSeenText) {
                lastSeenText = text
                Log.d(tag, "Phone clipboard changed: ${text.take(30)}... sending to Mac")
                onSendClipboardToMac(text)
            }
        }
    }

    fun start() {
        clipboardManager.addPrimaryClipChangedListener(clipListener)
    }

    fun stop() {
        clipboardManager.removePrimaryClipChangedListener(clipListener)
    }

    fun updateClipboardFromMac(text: String) {
        if (text.isEmpty() || text == lastSeenText) return
        isUpdatingFromMac = true
        lastSeenText = text

        val clip = ClipData.newPlainText("Galaxy Continuity", text)
        clipboardManager.setPrimaryClip(clip)
        Log.d(tag, "Updated Galaxy clipboard from Mac: ${text.take(30)}...")

        isUpdatingFromMac = false
    }
}
