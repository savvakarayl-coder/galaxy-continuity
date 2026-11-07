package com.galaxycontinuity.app.network

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log

class DiscoveryCoordinator(
    private val context: Context,
    private val onDeviceResolved: (host: String, port: Int, source: String) -> Unit
) {
    private val tag = "DiscoveryCoordinator"
    private val handler = Handler(Looper.getMainLooper())

    private var nsdDiscovery: NsdDiscovery? = null
    private var bleDiscovery: BleDiscoveryManager? = null
    private var wifiDirectManager: WifiDirectManager? = null

    private var isDiscovered = false
    private val bleFallbackRunnable = Runnable {
        if (!isDiscovered) {
            Log.d(tag, "Tier 1 (mDNS) timed out after 3.0s; escalating to Tier 2 (BLE)...")
            startTier2Ble()
        }
    }

    private val wifiDirectFallbackRunnable = Runnable {
        if (!isDiscovered) {
            Log.d(tag, "Tier 2 (BLE) timed out after 5.0s; escalating to Tier 3 (Wi-Fi Direct P2P)...")
            startTier3WifiDirect()
        }
    }

    fun startDiscovery() {
        stopDiscovery()
        isDiscovered = false

        // Start Tier 1: mDNS / Bonjour
        Log.d(tag, "Starting Tier 1: Apple Bonjour / mDNS discovery...")
        nsdDiscovery = NsdDiscovery(context) { host, port, name ->
            if (!isDiscovered) {
                isDiscovered = true
                cancelEscalationTimers()
                Log.d(tag, "Discovered Mac via Tier 1 (mDNS): $host:$port ($name)")
                onDeviceResolved(host, port, "mDNS")
            }
        }
        nsdDiscovery?.startDiscovery()

        // Schedule fallback to Tier 2 after 3 seconds if unresolved
        handler.postDelayed(bleFallbackRunnable, 3000)
    }

    private fun startTier2Ble() {
        bleDiscovery = BleDiscoveryManager(context) { shortId, role, port ->
            if (!isDiscovered && role == BleDiscoveryManager.ROLE_MAC_HOST) {
                isDiscovered = true
                cancelEscalationTimers()
                Log.d(tag, "Discovered Mac host via Tier 2 (BLE): shortId=$shortId port=$port")
                // With BLE beacon, connect to local or direct subnet
                onDeviceResolved("192.168.49.1", port, "BLE")
            }
        }
        bleDiscovery?.startScanning()
        bleDiscovery?.startAdvertising()

        // Schedule fallback to Tier 3 after 5 more seconds
        handler.postDelayed(wifiDirectFallbackRunnable, 5000)
    }

    private fun startTier3WifiDirect() {
        wifiDirectManager = WifiDirectManager(context) { host, port ->
            if (!isDiscovered) {
                isDiscovered = true
                cancelEscalationTimers()
                Log.d(tag, "Established Tier 3 (Wi-Fi Direct): $host:$port")
                onDeviceResolved(host, port, "WifiDirect")
            }
        }
        wifiDirectManager?.initialize()
        wifiDirectManager?.createGroup()
    }

    private fun cancelEscalationTimers() {
        handler.removeCallbacks(bleFallbackRunnable)
        handler.removeCallbacks(wifiDirectFallbackRunnable)
    }

    fun stopDiscovery() {
        cancelEscalationTimers()
        nsdDiscovery?.stopDiscovery()
        nsdDiscovery = null

        bleDiscovery?.stopScanning()
        bleDiscovery?.stopAdvertising()
        bleDiscovery = null

        wifiDirectManager?.tearDown()
        wifiDirectManager = null
        isDiscovered = false
    }
}
