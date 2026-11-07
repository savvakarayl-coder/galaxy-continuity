import AppKit
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public final class H264Decoder: @unchecked Sendable {
    private var formatDesc: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    public var onFrameDecoded: (@Sendable (NSImage) -> Void)?

    public init() {}

    public func decode(annexB: Data) {
        let nals = extractNALUnits(from: annexB)
        var sps: Data?
        var pps: Data?
        var sliceNals: [Data] = []

        for nal in nals {
            guard !nal.isEmpty else { continue }
            let nalType = nal[0] & 0x1F
            if nalType == 7 {
                sps = nal
            } else if nalType == 8 {
                pps = nal
            } else if nalType == 1 || nalType == 5 {
                sliceNals.append(nal)
            }
        }

        if let sps = sps, let pps = pps {
            configureFormatDescription(sps: sps, pps: pps)
        }

        guard let formatDesc = self.formatDesc, let session = self.decompressionSession else { return }

        for slice in sliceNals {
            decodeSlice(slice, formatDesc: formatDesc, session: session)
        }
    }

    public func reset() {
        decompressionSession = nil
        formatDesc = nil
    }

    private func extractNALUnits(from data: Data) -> [Data] {
        var nalUnits: [Data] = []
        let bytes = [UInt8](data)
        let count = bytes.count
        guard count >= 4 else { return [] }

        var startIndices: [(index: Int, prefixLen: Int)] = []
        var i = 0
        while i < count - 2 {
            if bytes[i] == 0 && bytes[i+1] == 0 {
                if bytes[i+2] == 1 {
                    startIndices.append((index: i + 3, prefixLen: 3))
                    i += 3
                    continue
                } else if i < count - 3 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                    startIndices.append((index: i + 4, prefixLen: 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }

        for (idx, item) in startIndices.enumerated() {
            let start = item.index
            let end: Int
            if idx + 1 < startIndices.count {
                let nextItem = startIndices[idx + 1]
                end = nextItem.index - nextItem.prefixLen
            } else {
                end = count
            }
            if end > start {
                nalUnits.append(data.subdata(in: start..<end))
            }
        }
        return nalUnits
    }

    private func configureFormatDescription(sps: Data, pps: Data) {
        sps.withUnsafeBytes { spsBuf in
            pps.withUnsafeBytes { ppsBuf in
                guard let spsBase = spsBuf.baseAddress, let ppsBase = ppsBuf.baseAddress else { return }
                var pointers: [UnsafePointer<UInt8>] = [
                    spsBase.assumingMemoryBound(to: UInt8.self),
                    ppsBase.assumingMemoryBound(to: UInt8.self)
                ]
                var sizes: [Int] = [sps.count, pps.count]
                var desc: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc
                )
                if status == noErr, let d = desc {
                    self.formatDesc = d
                    self.createDecompressionSession(desc: d)
                }
            }
        }
    }

    private func createDecompressionSession(desc: CMVideoFormatDescription) {
        let destinationAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: desc,
            decoderSpecification: nil,
            imageBufferAttributes: destinationAttrs as CFDictionary,
            decompressionSessionOut: &session
        )
        if status == noErr {
            self.decompressionSession = session
        }
    }

    private func decodeSlice(_ slice: Data, formatDesc: CMVideoFormatDescription, session: VTDecompressionSession) {
        var avccData = Data()
        var len = UInt32(slice.count).bigEndian
        withUnsafeBytes(of: &len) { avccData.append(contentsOf: $0) }
        avccData.append(slice)

        let count = avccData.count
        guard let pointer = malloc(count) else { return }
        avccData.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: count)

        var blockBuffer: CMBlockBuffer?
        let allocStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: pointer,
            blockLength: count,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard allocStatus == noErr, let block = blockBuffer else {
            free(pointer)
            return
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = count
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sample = sampleBuffer else { return }

        var flags: VTDecodeInfoFlags = []
        _ = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &flags
        ) { [weak self] status, _, imageBuffer, _, _, _ in
            guard status == noErr, let imageBuffer = imageBuffer else { return }
            var cgImage: CGImage?
            VTCreateCGImageFromCVPixelBuffer(imageBuffer, options: nil, imageOut: &cgImage)
            if let cg = cgImage {
                let nsImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                self?.onFrameDecoded?(nsImage)
            }
        }
    }
}
