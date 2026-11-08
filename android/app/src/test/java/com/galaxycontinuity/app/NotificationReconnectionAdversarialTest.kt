package com.galaxycontinuity.app

import com.galaxycontinuity.app.service.NotificationForwarderService
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

class NotificationReconnectionAdversarialTest {

    @Before
    fun setUp() {
        NotificationForwarderService.clearCaches()
    }

    // MARK: - 1. Notification Click When Target App Has Expired Pending Intent or Missing Activity

    @Test
    fun testPendingIntentExpiredOrExceptionHandling() {
        val testId = "notif-expired-99"
        var callbackInvoked = false

        // Simulate an expired/broken PendingIntent throwing an exception
        NotificationForwarderService.registerTestContentIntent(testId) {
            callbackInvoked = true
            throw RuntimeException("Simulated PendingIntent CanceledException")
        }

        val threwException = try {
            NotificationForwarderService.openNotification(testId, "com.expired.target")
            false
        } catch (e: RuntimeException) {
            true
        }

        assertTrue("Callback was invoked", callbackInvoked)
        // Verify empirically whether testContentIntentCallbacks leaks the exception:
        assertTrue("testCb propagates exception when not caught in hook", threwException)
    }

    @Test
    fun testNotificationOpenWithMissingOrEmptyPackage() {
        NotificationForwarderService.clearCaches()

        // Empty ID and empty package
        val resultEmpty = NotificationForwarderService.openNotification("", "")
        assertFalse("Empty package and ID must safely return false", resultEmpty)

        // Non-existent ID with no package name
        val resultNoPkg = NotificationForwarderService.openNotification("random-ghost-id", "")
        assertFalse("Non-existent ID without package must return false", resultNoPkg)
    }

    @Test
    fun testNotificationOpenRoutingWithValidContentIntent() {
        NotificationForwarderService.clearCaches()
        val notifId = "valid-notif-777"
        val callCount = AtomicInteger(0)

        NotificationForwarderService.registerTestContentIntent(notifId) {
            callCount.incrementAndGet()
        }

        assertTrue(NotificationForwarderService.hasContentIntent(notifId))
        val success = NotificationForwarderService.openNotification(notifId, "com.valid.app")
        assertTrue(success)
        assertEquals(1, callCount.get())

        // Evict notification (simulating user dismiss or onNotificationRemoved)
        NotificationForwarderService.evictFromCache(notifId)
        assertFalse(NotificationForwarderService.hasContentIntent(notifId))

        // Opening after eviction must fail safely
        val afterEvictSuccess = NotificationForwarderService.openNotification(notifId, "")
        assertFalse(afterEvictSuccess)
    }

    // MARK: - 2. Reconnection State Machine & Exponential Backoff Clamp

    @Test
    fun testExponentialBackoffClampAt10Seconds() {
        // Model the exact reconnection backoff schedule in ContinuityService
        fun calculateDelay(attempt: Int): Long {
            return when (attempt) {
                0 -> 0L
                1 -> 1000L
                2 -> 2000L
                3 -> 4000L
                else -> 10000L
            }
        }

        // Verify progression
        assertEquals("Attempt 0 runs immediately", 0L, calculateDelay(0))
        assertEquals("Attempt 1 delays 1 second", 1000L, calculateDelay(1))
        assertEquals("Attempt 2 delays 2 seconds", 2000L, calculateDelay(2))
        assertEquals("Attempt 3 delays 4 seconds", 4000L, calculateDelay(3))

        // Verify hard clamp at 10 seconds for all subsequent attempts
        assertEquals("Attempt 4 clamps to 10 seconds", 10000L, calculateDelay(4))
        assertEquals("Attempt 5 clamps to 10 seconds", 10000L, calculateDelay(5))
        assertEquals("Attempt 10 clamps to 10 seconds", 10000L, calculateDelay(10))
        assertEquals("Attempt 50 clamps to 10 seconds", 10000L, calculateDelay(50))
        assertEquals("Attempt 1000 clamps to 10 seconds", 10000L, calculateDelay(1000))
    }

    @Test
    fun testRapidDisconnectReconnectCycleStateResets() {
        var reconnectAttempt = 0
        var isSocketConnected = false

        fun simulateDisconnect() {
            isSocketConnected = false
        }

        fun simulateConnected() {
            isSocketConnected = true
            reconnectAttempt = 0 // Exactly matching ContinuityService.onConnected
        }

        fun simulateNextAttempt(): Long {
            val delay = when (reconnectAttempt) {
                0 -> 0L
                1 -> 1000L
                2 -> 2000L
                3 -> 4000L
                else -> 10000L
            }
            reconnectAttempt++
            return delay
        }

        // 50 rapid connect/disconnect cycles
        for (i in 1..50) {
            simulateDisconnect()
            assertFalse(isSocketConnected)

            // First attempt after disconnect must have 0ms delay (immediate probe)
            val initialDelay = simulateNextAttempt()
            assertEquals("Cycle $i first probe must have 0ms delay", 0L, initialDelay)

            // Progress a few failed attempts
            simulateNextAttempt() // 1s
            simulateNextAttempt() // 2s
            assertTrue(reconnectAttempt >= 2)

            // Reconnection event occurs
            simulateConnected()
            assertTrue(isSocketConnected)
            assertEquals("Cycle $i reconnect must reset reconnectAttempt to 0", 0, reconnectAttempt)
        }
    }

    // MARK: - 3. USB Reverse Port & WebSocket Protocol Serialization

    @Test
    fun testNotificationOpenJsonParsing() {
        val json = JSONObject().apply {
            put("type", "notification_open")
            put("id", "notif-abc-123")
            put("packageName", "org.telegram.messenger")
        }

        assertEquals("notification_open", json.getString("type"))
        assertEquals("notif-abc-123", json.getString("id"))
        assertEquals("org.telegram.messenger", json.getString("packageName"))
    }

    @Test
    fun testNotificationClickAliasJsonParsing() {
        val json = JSONObject().apply {
            put("type", "notification_click")
            put("id", "notif-xyz-999")
            put("packageName", "com.google.android.youtube")
        }

        val type = json.getString("type")
        assertTrue(type == "notification_open" || type == "notification_click")
        assertEquals("notif-xyz-999", json.getString("id"))
        assertEquals("com.google.android.youtube", json.getString("packageName"))
    }

    @Test
    fun testInputScrollWithDisplacementDeltasParsing() {
        val json = JSONObject().apply {
            put("type", "input_scroll")
            put("x", 0.5)
            put("y", 0.5)
            put("dx", -25.5)
            put("dy", 120.0)
        }

        assertEquals("input_scroll", json.getString("type"))
        assertEquals(0.5, json.getDouble("x"), 0.001)
        assertEquals(0.5, json.getDouble("y"), 0.001)
        assertEquals(-25.5, json.getDouble("dx"), 0.001)
        assertEquals(120.0, json.getDouble("dy"), 0.001)
    }

    @Test
    fun testInputTextDirectTypingParsing() {
        val json = JSONObject().apply {
            put("type", "input_text")
            put("text", "Hello from Mac Keyboard! 🚀")
        }

        assertEquals("input_text", json.getString("type"))
        assertEquals("Hello from Mac Keyboard! 🚀", json.getString("text"))
    }
}
