package com.galaxycontinuity.app.service

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

class NotificationForwarderService : NotificationListenerService() {
    private val tag = "NotifForwarder"

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

        Log.d(tag, "Forwarding notification from $appName: $title - $text")
        ContinuityService.activeClient?.sendNotification(
            app = appName,
            title = title,
            text = text
        )
    }
}
