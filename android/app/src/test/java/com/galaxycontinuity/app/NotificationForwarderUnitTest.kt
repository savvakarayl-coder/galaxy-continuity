package com.galaxycontinuity.app

import com.galaxycontinuity.app.service.NotificationForwarderService
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class NotificationForwarderUnitTest {

    @Before
    fun setUp() {
        NotificationForwarderService.clearCaches()
    }

    @Test
    fun testContentIntentCachingAndTriggering() {
        NotificationForwarderService.clearCaches()
        var intentFired = false
        val testId = "notif-test-101"

        NotificationForwarderService.registerTestContentIntent(testId) {
            intentFired = true
        }

        assertTrue(NotificationForwarderService.hasContentIntent(testId))
        val result = NotificationForwarderService.openNotification(testId, "com.example.app")
        assertTrue(result)
        assertTrue(intentFired)
    }

    @Test
    fun testContentIntentEvictionOnNotificationRemoved() {
        NotificationForwarderService.clearCaches()
        val testId = "notif-test-102"
        NotificationForwarderService.registerTestContentIntent(testId) {}
        assertTrue(NotificationForwarderService.hasContentIntent(testId))

        NotificationForwarderService.evictFromCache(testId)
        assertFalse(NotificationForwarderService.hasContentIntent(testId))
    }

    @Test
    fun testOpenNotificationReturnsFalseForUnknownIdWithoutPackage() {
        NotificationForwarderService.clearCaches()
        val result = NotificationForwarderService.openNotification("unknown-id-999", "")
        assertFalse(result)
    }
}
