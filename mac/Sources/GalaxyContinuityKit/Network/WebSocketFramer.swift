import Foundation
import CryptoKit

public struct WebSocketFrame: Equatable {
    public let fin: Bool
    public let opcode: UInt8
    public let payload: Data

    public init(fin: Bool = true, opcode: UInt8, payload: Data) {
        self.fin = fin
        self.opcode = opcode
        self.payload = payload
    }
}

public enum WebSocketFramer {
    public static let websocketGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// Computes the RFC 6455 Sec-WebSocket-Accept header value from a client key
    public static func computeAcceptKey(for clientKey: String) -> String {
        let fullKey = clientKey.trimmingCharacters(in: .whitespacesAndNewlines) + websocketGuid
        let hash = Insecure.SHA1.hash(data: Data(fullKey.utf8))
        return Data(hash).base64EncodedString()
    }

    /// Encodes a WebSocket frame supporting 7-bit, 16-bit, and 64-bit payload lengths
    public static func encodeFrame(
        opcode: UInt8,
        payload: Data,
        fin: Bool = true,
        isMasked: Bool = false,
        maskKey: [UInt8]? = nil
    ) -> Data {
        var frame = Data()
        var b0: UInt8 = opcode & 0x0F
        if fin { b0 |= 0x80 }
        frame.append(b0)

        let len = payload.count
        let maskBit: UInt8 = isMasked ? 0x80 : 0x00

        if len <= 125 {
            frame.append(maskBit | UInt8(len))
        } else if len <= 65535 {
            frame.append(maskBit | 126)
            var beLen = UInt16(len).bigEndian
            frame.append(Data(bytes: &beLen, count: 2))
        } else {
            frame.append(maskBit | 127)
            var beLen = UInt64(len).bigEndian
            frame.append(Data(bytes: &beLen, count: 8))
        }

        if isMasked {
            let mask = maskKey ?? [UInt8.random(in: 0...255), UInt8.random(in: 0...255), UInt8.random(in: 0...255), UInt8.random(in: 0...255)]
            frame.append(contentsOf: mask)
            var masked = [UInt8](payload)
            for i in 0..<masked.count {
                masked[i] ^= mask[i % 4]
            }
            frame.append(contentsOf: masked)
        } else {
            frame.append(payload)
        }

        return frame
    }

    /// Decodes a WebSocket frame from an accumulated buffer.
    /// Returns nil if more data is required to complete the frame.
    public static func decodeFrame(from buffer: inout Data) -> WebSocketFrame? {
        guard buffer.count >= 2 else { return nil }

        let b0 = buffer[0]
        let b1 = buffer[1]
        let fin = (b0 & 0x80) != 0
        let opcode = b0 & 0x0F
        let isMasked = (b1 & 0x80) != 0
        var payloadLen = Int(b1 & 0x7F)
        var offset = 2

        if payloadLen == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            let high = Int(buffer[offset])
            let low = Int(buffer[offset + 1])
            payloadLen = (high << 8) | low
            offset += 2
        } else if payloadLen == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            var len: UInt64 = 0
            for i in 0..<8 {
                len = (len << 8) | UInt64(buffer[offset + i])
            }
            payloadLen = Int(len)
            offset += 8
        }

        var mask = [UInt8]()
        if isMasked {
            guard buffer.count >= offset + 4 else { return nil }
            mask = Array(buffer[offset..<(offset + 4)])
            offset += 4
        }

        guard buffer.count >= offset + payloadLen else { return nil }

        var payload = Array(buffer[offset..<(offset + payloadLen)])
        if isMasked {
            for i in 0..<payload.count {
                payload[i] ^= mask[i % 4]
            }
        }

        buffer.removeSubrange(0..<(offset + payloadLen))
        return WebSocketFrame(fin: fin, opcode: opcode, payload: Data(payload))
    }
}
