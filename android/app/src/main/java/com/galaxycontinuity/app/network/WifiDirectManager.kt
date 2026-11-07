package com.galaxycontinuity.app.network

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.NetworkInfo
import android.net.wifi.p2p.*
import android.os.Looper
import android.util.Log

class WifiDirectManager(
    private val context: Context,
    private val onConnectionAvailable: (host: String, port: Int) -> Unit
) {
    companion object {
        const val DEFAULT_GROUP_OWNER_IP = "192.168.49.1"
        const val DEFAULT_PORT = 8765
    }

    private val tag = "WifiDirect"
    private var p2pManager: WifiP2pManager? = null
    private var channel: WifiP2pManager.Channel? = null
    private var receiver: BroadcastReceiver? = null
    var isConnected = false
        private set

    fun initialize() {
        p2pManager = context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
        channel = p2pManager?.initialize(context, Looper.getMainLooper(), null)

        val intentFilter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
        }

        receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                        val networkInfo = intent.getParcelableExtra<NetworkInfo>(WifiP2pManager.EXTRA_NETWORK_INFO)
                        if (networkInfo?.isConnected == true) {
                            requestConnectionInfo()
                        } else {
                            isConnected = false
                        }
                    }
                }
            }
        }

        try {
            context.registerReceiver(receiver, intentFilter)
        } catch (e: Exception) {
            Log.e(tag, "Error registering Wi-Fi Direct receiver", e)
        }
    }

    fun createGroup() {
        val mgr = p2pManager ?: return
        val ch = channel ?: return

        try {
            mgr.createGroup(ch, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    Log.d(tag, "Wi-Fi Direct Group created successfully (GO IP: $DEFAULT_GROUP_OWNER_IP)")
                    isConnected = true
                    onConnectionAvailable(DEFAULT_GROUP_OWNER_IP, DEFAULT_PORT)
                }

                override fun onFailure(reason: Int) {
                    Log.e(tag, "Failed to create Wi-Fi Direct group: reason $reason")
                }
            })
        } catch (e: SecurityException) {
            Log.e(tag, "Missing permission for createGroup", e)
        }
    }

    fun requestConnectionInfo() {
        val mgr = p2pManager ?: return
        val ch = channel ?: return

        try {
            mgr.requestConnectionInfo(ch) { info ->
                if (info != null && info.groupFormed) {
                    val hostAddress = if (info.isGroupOwner) {
                        DEFAULT_GROUP_OWNER_IP
                    } else {
                        info.groupOwnerAddress?.hostAddress ?: DEFAULT_GROUP_OWNER_IP
                    }
                    Log.d(tag, "Wi-Fi Direct connected to group owner: $hostAddress:$DEFAULT_PORT")
                    isConnected = true
                    onConnectionAvailable(hostAddress, DEFAULT_PORT)
                }
            }
        } catch (e: SecurityException) {
            Log.e(tag, "Missing permission for requestConnectionInfo", e)
        }
    }

    fun tearDown() {
        try {
            receiver?.let { context.unregisterReceiver(it) }
        } catch (e: Exception) {
            Log.e(tag, "Error unregistering receiver", e)
        }
        receiver = null

        val mgr = p2pManager
        val ch = channel
        if (mgr != null && ch != null) {
            try {
                mgr.removeGroup(ch, null)
            } catch (e: Exception) {
                Log.e(tag, "Error removing group", e)
            }
        }
        p2pManager = null
        channel = null
        isConnected = false
    }
}
