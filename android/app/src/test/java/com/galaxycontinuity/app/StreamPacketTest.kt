package com.galaxycontinuity.app

import com.galaxycontinuity.app.network.StreamPacket
import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class StreamPacketTest {

    @Test
    fun testScreenStreamPacketPackingAndUnpacking() {
        val fakeNal = byteArrayOf(0x00, 0x00, 0x00, 0x01, 0x65, 0x08, 0x09)
        val packet = StreamPacket.pack(StreamPacket.TYPE_SCREEN, fakeNal)

        assertEquals(StreamPacket.HEADER_SIZE + fakeNal.size, packet.size)
        assertEquals(0x01.toByte(), packet[0])

        val unpacked = StreamPacket.unpack(packet)
        assertNotNull(unpacked)
        assertEquals(StreamPacket.TYPE_SCREEN, unpacked!!.streamType)
        assertEquals(fakeNal.size, unpacked.length)
        assertArrayEquals(fakeNal, unpacked.payload)
    }

    @Test
    fun testCameraStreamPacketWithJpegPayload() {
        // Mock JPEG starting with 0xFF 0xD8 SOI marker
        val fakeJpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte(), 0x10, 0x20)
        val packet = StreamPacket.pack(StreamPacket.TYPE_CAMERA, fakeJpeg)

        assertEquals(StreamPacket.HEADER_SIZE + fakeJpeg.size, packet.size)
        assertEquals(0x02.toByte(), packet[0])

        val unpacked = StreamPacket.unpack(packet)
        assertNotNull(unpacked)
        assertEquals(StreamPacket.TYPE_CAMERA, unpacked!!.streamType)
        assertEquals(fakeJpeg.size, unpacked.length)
        assertTrue(unpacked.payload[0] == 0xFF.toByte() && unpacked.payload[1] == 0xD8.toByte())
    }

    @Test
    fun testShortHeaderUnpackRejection() {
        val shortBytes = byteArrayOf(0x01, 0x00, 0x00)
        val unpacked = StreamPacket.unpack(shortBytes)
        assertNull("Packets with fewer than 5 bytes must return null", unpacked)
    }

    @Test
    fun testTruncatedPayloadUnpackRejection() {
        val buffer = ByteBuffer.allocate(StreamPacket.HEADER_SIZE + 2)
        buffer.order(ByteOrder.BIG_ENDIAN)
        buffer.put(0x01.toByte())
        buffer.putInt(100) // Claims 100 bytes but only 2 provided
        buffer.put(byteArrayOf(0x01, 0x02))

        val unpacked = StreamPacket.unpack(buffer.array())
        assertNull("Truncated payload packets must return null", unpacked)
    }

    @Test
    fun testZeroLengthPayloadPacket() {
        val emptyPayload = ByteArray(0)
        val packet = StreamPacket.pack(StreamPacket.TYPE_CAMERA, emptyPayload)
        assertEquals(StreamPacket.HEADER_SIZE, packet.size)

        val unpacked = StreamPacket.unpack(packet)
        assertNotNull(unpacked)
        assertEquals(0, unpacked!!.length)
        assertEquals(0, unpacked.payload.size)
    }

    @Test
    fun testScreenStreamPacketWithJpegPayload() {
        val fakeScreenJpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte(), 0x01, 0x02)
        val packet = StreamPacket.pack(StreamPacket.TYPE_SCREEN, fakeScreenJpeg)

        assertEquals(StreamPacket.HEADER_SIZE + fakeScreenJpeg.size, packet.size)
        assertEquals(StreamPacket.TYPE_SCREEN, packet[0])

        val unpacked = StreamPacket.unpack(packet)
        assertNotNull(unpacked)
        assertEquals(StreamPacket.TYPE_SCREEN, unpacked!!.streamType)
        assertEquals(fakeScreenJpeg.size, unpacked.length)
        assertTrue(unpacked.payload[0] == 0xFF.toByte() && unpacked.payload[1] == 0xD8.toByte())
    }
}
