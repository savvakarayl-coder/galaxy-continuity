package com.galaxycontinuity.app.network

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.*
import android.content.Context
import android.os.ParcelUuid
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

class BleDiscoveryManager(
    private val context: Context,
    private val onPeerDiscovered: (shortId: String, role: Byte, port: Int) -> Unit
) {
    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("19B10000-E8F2-537E-4F6C-D104768A1214")
        val PARCEL_UUID = ParcelUuid(SERVICE_UUID)
        val PROTOCOL_TAG = byteArrayOf(0x47.toByte(), 0x43.toByte()) // "GC"
        const val ROLE_MAC_HOST: Byte = 0x01
        const val ROLE_GALAXY_CLIENT: Byte = 0x02
        const val DEFAULT_MANUFACTURER_ID = 0x0075 // Samsung manufacturer ID

        fun buildAdvertisementPayload(role: Byte = ROLE_GALAXY_CLIENT, port: Int = 8765, shortId: ByteArray): ByteArray {
            val buffer = ByteBuffer.allocate(9).order(ByteOrder.BIG_ENDIAN)
            buffer.put(PROTOCOL_TAG)
            buffer.put(role)
            buffer.putShort(port.toShort())
            val truncated = if (shortId.size >= 4) shortId.copyOfRange(0, 4) else shortId.copyOf(4)
            buffer.put(truncated)
            return buffer.array()
        }

        fun parseAdvertisementPayload(data: ByteArray): ParsedBleBeacon? {
            if (data.size < 9) return null
            if (data[0] != PROTOCOL_TAG[0] || data[1] != PROTOCOL_TAG[1]) return null

            val role = data[2]
            val buffer = ByteBuffer.wrap(data, 3, 2).order(ByteOrder.BIG_ENDIAN)
            val port = buffer.short.toInt() and 0xFFFF
            val sb = java.lang.StringBuilder()
            for (i in 5 until 9) {
                sb.append(String.format("%02x", data[i]))
            }
            return ParsedBleBeacon(role = role, port = port, shortId = sb.toString())
        }
    }

    data class ParsedBleBeacon(
        val role: Byte,
        val port: Int,
        val shortId: String
    )

    private val tag = "BleDiscovery"
    private val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? = bluetoothManager?.adapter
    private var advertiser: BluetoothLeAdvertiser? = null
    private var scanner: BluetoothLeScanner? = null

    private var advertiseCallback: AdvertiseCallback? = null
    private var scanCallback: ScanCallback? = null

    fun startAdvertising(port: Int = 8765, shortId: ByteArray = byteArrayOf(0xCA.toByte(), 0xFE.toByte(), 0xBA.toByte(), 0xBE.toByte())) {
        stopAdvertising()
        val adapter = bluetoothAdapter ?: return
        if (!adapter.isEnabled) return

        advertiser = adapter.bluetoothLeAdvertiser ?: return

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .setTimeout(0)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .build()

        val mfgPayload = buildAdvertisementPayload(role = ROLE_GALAXY_CLIENT, port = port, shortId = shortId)
        val data = AdvertiseData.Builder()
            .addServiceUuid(PARCEL_UUID)
            .addManufacturerData(DEFAULT_MANUFACTURER_ID, mfgPayload)
            .setIncludeDeviceName(false)
            .build()

        advertiseCallback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                Log.d(tag, "BLE advertising started successfully")
            }

            override fun onStartFailure(errorCode: Int) {
                Log.e(tag, "BLE advertising failed with code $errorCode")
            }
        }

        try {
            advertiser?.startAdvertising(settings, data, advertiseCallback)
        } catch (e: SecurityException) {
            Log.e(tag, "Missing BLE permission for advertising", e)
        } catch (e: Exception) {
            Log.e(tag, "Error starting BLE advertising", e)
        }
    }

    fun stopAdvertising() {
        advertiseCallback?.let {
            try {
                advertiser?.stopAdvertising(it)
            } catch (e: Exception) {
                Log.e(tag, "Error stopping advertising", e)
            }
        }
        advertiseCallback = null
        advertiser = null
    }

    fun startScanning() {
        stopScanning()
        val adapter = bluetoothAdapter ?: return
        if (!adapter.isEnabled) return

        scanner = adapter.bluetoothLeScanner ?: return

        val filter = ScanFilter.Builder()
            .setServiceUuid(PARCEL_UUID)
            .build()

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        scanCallback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult?) {
                val record = result?.scanRecord ?: return
                // Check manufacturer data or service data
                val mfgData = record.getManufacturerSpecificData(DEFAULT_MANUFACTURER_ID)
                if (mfgData != null) {
                    val parsed = parseAdvertisementPayload(mfgData)
                    if (parsed != null) {
                        Log.d(tag, "Discovered Mac host via BLE: shortId=${parsed.shortId} port=${parsed.port}")
                        onPeerDiscovered(parsed.shortId, parsed.role, parsed.port)
                    }
                }
            }

            override fun onScanFailed(errorCode: Int) {
                Log.e(tag, "BLE scan failed with code $errorCode")
            }
        }

        try {
            scanner?.startScan(listOf(filter), settings, scanCallback)
        } catch (e: SecurityException) {
            Log.e(tag, "Missing BLE permission for scan", e)
        } catch (e: Exception) {
            Log.e(tag, "Error starting BLE scan", e)
        }
    }

    fun stopScanning() {
        scanCallback?.let {
            try {
                scanner?.stopScan(it)
            } catch (e: Exception) {
                Log.e(tag, "Error stopping scan", e)
            }
        }
        scanCallback = null
        scanner = null
    }
}
