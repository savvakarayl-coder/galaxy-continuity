package com.galaxycontinuity.app.service

import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Intent
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class NotificationForwarderService : NotificationListenerService() {
    private val tag = "NotifForwarder"

    data class ReplyActionHolder(
        val pendingIntent: PendingIntent,
        val remoteInput: RemoteInput
    )

    companion object {
        var instance: NotificationForwarderService? = null
            private set

        private val replyCache = ConcurrentHashMap<String, ReplyActionHolder>()

        fun replyToNotification(id: String, packageName: String, replyText: String): Boolean {
            val service = instance
            if (service != null) {
                return service.reply(id, packageName, replyText)
            }
            // Fallback for headless / simulated execution
            val holder = replyCache[id] ?: return false
            return try {
                val intent = Intent()
                val bundle = Bundle()
                bundle.putCharSequence(holder.remoteInput.resultKey, replyText)
                RemoteInput.addResultsToIntent(arrayOf(holder.remoteInput), intent, bundle)
                holder.pendingIntent.send(null, 0, intent)
                true
            } catch (e: Exception) {
                Log.e("NotifForwarder", "Fallback reply failed: ${e.message}")
                false
            }
        }

        fun registerTestReplyAction(id: String, holder: ReplyActionHolder) {
            replyCache[id] = holder
        }

        fun hasReplyAction(id: String): Boolean {
            return replyCache.containsKey(id)
        }

        fun clearReplyCache() {
            replyCache.clear()
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        Log.d(tag, "Notification listener connected")
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        if (instance == this) {
            instance = null
        }
        Log.d(tag, "Notification listener disconnected")
    }

    override fun onDestroy() {
        super.onDestroy()
        if (instance == this) {
            instance = null
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        super.onNotificationPosted(sbn)
        if (sbn == null || sbn.isOngoing) return

        val pkg = sbn.packageName ?: ""
        // Filter out system noise or self
        if (pkg.contains("galaxycontinuity") || pkg.contains("android.systemui")) return

        val extras = sbn.notification?.extras ?: return
        val title = extras.getCharSequence("android.title")?.toString() ?: ""
        val text = extras.getCharSequence("android.text")?.toString() ?: ""

        if (title.isEmpty() && text.isEmpty()) return

        val appName = try {
            val pm = applicationContext.packageManager
            val ai = pm.getApplicationInfo(pkg, 0)
            pm.getApplicationLabel(ai).toString()
        } catch (e: Exception) {
            pkg
        }

        val notifId = sbn.key ?: UUID.randomUUID().toString()

        // Inspect notification actions for RemoteInput (quick reply)
        var canReply = false
        val actions = sbn.notification?.actions
        if (actions != null) {
            for (action in actions) {
                val remoteInputs = action.remoteInputs
                if (remoteInputs != null && remoteInputs.isNotEmpty() && action.actionIntent != null) {
                    val targetRemoteInput = remoteInputs.first()
                    replyCache[notifId] = ReplyActionHolder(action.actionIntent, targetRemoteInput)
                    canReply = true
                    break
                }
            }
        }

        Log.d(tag, "Forwarding notification from $appName: $title - $text (canReply: $canReply, id: $notifId)")
        ContinuityService.activeClient?.sendNotification(
            id = notifId,
            packageName = pkg,
            app = appName,
            title = title,
            text = text,
            canReply = canReply
        )
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        super.onNotificationRemoved(sbn)
        sbn?.key?.let { replyCache.remove(it) }
    }

    fun reply(id: String, packageName: String, replyText: String): Boolean {
        val holder = replyCache[id]
        if (holder == null) {
            Log.w(tag, "No active reply intent cached for notification ID $id")
            return false
        }

        return try {
            val intent = Intent()
            val bundle = Bundle()
            bundle.putCharSequence(holder.remoteInput.resultKey, replyText)
            RemoteInput.addResultsToIntent(arrayOf(holder.remoteInput), intent, bundle)
            holder.pendingIntent.send(this, 0, intent)
            Log.d(tag, "Sent reply for notification ID $id: $replyText")
            true
        } catch (e: Exception) {
            Log.e(tag, "Failed to send notification reply: ${e.message}", e)
            false
        }
    }
}
