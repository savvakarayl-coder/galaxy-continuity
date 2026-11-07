package com.galaxycontinuity.app.network

import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Standardized 5-byte binary packet framer according to shared/PROTOCOL.md § 4.2.
 *
 * Header layout:
 * - Byte 0: UInt8 Stream Type (0x01: Screen Mirroring Frame, 0x02: Continuity Camera Frame)
 * - Bytes 1-4: UInt32 Big-Endian Payload Length
 * - Bytes 5..N: Media Payload
 */
object StreamPacket {
    const val TYPE_SCREEN: Byte = 0x01
    const val TYPE_CAMERA: Byte = 0x02
    const val HEADER_SIZE: Int = 5

    data class UnpackedPacket(
        val streamType: Byte,
        val length: Int,
        val payload: ByteArray
    ) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is UnpackedPacket) return false
            return streamType == other.streamType && length == other.length && payload.contentEquals(other.payload)
        }

        override fun hashCode(): Int {
            var result = streamType.toInt()
            result = 31 * result + length
            result = 31 * result + payload.contentHashCode()
            return result
        }
    }

    /**
     * Packs a stream type and binary payload into a 5-byte header standard frame.
     */
    fun pack(streamType: Byte, payload: ByteArray): ByteArray {
        val buffer = ByteBuffer.allocate(HEADER_SIZE + payload.size)
        buffer.order(ByteOrder.BIG_ENDIAN)
        buffer.put(streamType)
        buffer.putInt(payload.size)
        buffer.put(payload)
        return buffer.array()
    }

    fun packToByteString(streamType: Byte, payload: ByteArray): ByteString {
        return pack(streamType, payload).toByteString()
    }

    /**
     * Unpacks a 5-byte stream packet. Returns null if data is shorter than 5 bytes or payload is truncated.
     */
    fun unpack(bytes: ByteArray): UnpackedPacket? {
        if (bytes.size < HEADER_SIZE) return null
        val buffer = ByteBuffer.wrap(bytes)
        buffer.order(ByteOrder.BIG_ENDIAN)
        val streamType = buffer.get()
        val length = buffer.getInt()
        if (length < 0 || bytes.size < HEADER_SIZE + length) return null

        val payload = ByteArray(length)
        buffer.get(payload)
        return UnpackedPacket(streamType, length, payload)
    }
}
