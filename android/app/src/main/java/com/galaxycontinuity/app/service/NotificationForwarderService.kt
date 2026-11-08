package com.galaxycontinuity.app.service

import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
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
        private val contentIntentCache = ConcurrentHashMap<String, PendingIntent>()
        private val packageCache = ConcurrentHashMap<String, String>()
        private val testContentIntentCallbacks = ConcurrentHashMap<String, () -> Unit>()

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

        fun openNotification(id: String, packageName: String): Boolean {
            val testCb = testContentIntentCallbacks[id]
            if (testCb != null) {
                testCb.invoke()
                return true
            }
            val service = instance
            if (service != null) {
                return service.open(id, packageName)
            }
            val pendingIntent = contentIntentCache[id]
            if (pendingIntent != null) {
                return try {
                    pendingIntent.send()
                    Log.d("NotifForwarder", "Executed cached contentIntent for $id ($packageName)")
                    true
                } catch (e: Exception) {
                    Log.e("NotifForwarder", "Fallback contentIntent send failed: ${e.message}")
                    false
                }
            }
            return false
        }

        fun openNotification(context: Context, id: String, packageName: String): Boolean {
            val testCb = testContentIntentCallbacks[id]
            if (testCb != null) {
                testCb.invoke()
                return true
            }
            val service = instance
            if (service != null) {
                return service.open(id, packageName)
            }
            val pendingIntent = contentIntentCache[id]
            if (pendingIntent != null) {
                return try {
                    pendingIntent.send()
                    Log.d("NotifForwarder", "Executed cached contentIntent for $id ($packageName)")
                    true
                } catch (e: Exception) {
                    Log.w("NotifForwarder", "Fallback contentIntent send failed, launching package: ${e.message}")
                    launchPackage(context, packageName)
                }
            }
            return launchPackage(context, packageName)
        }

        private fun launchPackage(context: Context, packageName: String): Boolean {
            if (packageName.isEmpty()) return false
            return try {
                val pm = context.packageManager
                val intent = pm.getLaunchIntentForPackage(packageName)
                if (intent != null) {
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
                    context.startActivity(intent)
                    Log.d("NotifForwarder", "Successfully launched package activity for $packageName")
                    true
                } else {
                    Log.w("NotifForwarder", "No launch intent found for package $packageName")
                    false
                }
            } catch (e: Exception) {
                Log.e("NotifForwarder", "Failed to launch package $packageName: ${e.message}", e)
                false
            }
        }

        fun registerTestReplyAction(id: String, holder: ReplyActionHolder) {
            replyCache[id] = holder
        }

        fun hasReplyAction(id: String): Boolean {
            return replyCache.containsKey(id)
        }

        fun registerTestContentIntent(id: String, pendingIntent: PendingIntent) {
            contentIntentCache[id] = pendingIntent
        }

        fun registerTestContentIntent(id: String, callback: () -> Unit) {
            testContentIntentCallbacks[id] = callback
        }

        fun hasContentIntent(id: String): Boolean {
            return contentIntentCache.containsKey(id) || testContentIntentCallbacks.containsKey(id)
        }

        fun evictFromCache(id: String) {
            replyCache.remove(id)
            contentIntentCache.remove(id)
            packageCache.remove(id)
            testContentIntentCallbacks.remove(id)
        }

        fun clearReplyCache() {
            clearCaches()
        }

        fun clearCaches() {
            replyCache.clear()
            contentIntentCache.clear()
            packageCache.clear()
            testContentIntentCallbacks.clear()
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

        // Cache contentIntent for notification open action
        sbn.notification?.contentIntent?.let {
            contentIntentCache[notifId] = it
        }
        if (pkg.isNotEmpty()) {
            packageCache[notifId] = pkg
        }

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
        sbn?.key?.let {
            evictFromCache(it)
        }
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

    fun open(id: String, packageName: String): Boolean {
        val testCb = testContentIntentCallbacks[id]
        if (testCb != null) {
            testCb.invoke()
            return true
        }
        val pendingIntent = contentIntentCache[id]
        if (pendingIntent != null) {
            return try {
                pendingIntent.send()
                Log.d(tag, "Fired contentIntent for notification $id ($packageName)")
                true
            } catch (e: Exception) {
                Log.w(tag, "contentIntent.send() failed for $id, falling back to package launch", e)
                launchPackage(this, packageName)
            }
        }
        val fallbackPkg = if (packageName.isNotEmpty()) packageName else packageCache[id] ?: ""
        return launchPackage(this, fallbackPkg)
    }
}
