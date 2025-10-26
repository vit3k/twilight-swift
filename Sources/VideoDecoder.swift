import CoreMedia
import CoreVideo
import Foundation
import OSLog
import VideoToolbox

private let logger = OSLog(subsystem: "com.twilight.decoder", category: "VideoDecoder")

func logMessage(_ format: String, _ args: CVarArg...) {
    let message = String(format: format, arguments: args)
    os_log("%{public}@", log: logger, type: .info, message)
}

struct FrameStats {
    var frameNumber: Int = 0
    var decodeTimeMs: Double = 0.0
    var prepareTimeMs: Double = 0.0
}

class Decoder: @unchecked Sendable {
    static let shared = Decoder()

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var isSessionInitialized = false

    // Statistics
    var frameCount: Int = 0
    var totalDecodingTime: Int64 = 0
    var currentFrameStartTime: Int64 = 0

    // Reusable buffers to avoid allocations per frame
    private var avccBuffer = Data()
    private var annexbBuffer = Data()
    
    // Pre-allocated temporary buffer for length prefixes
    private var lengthPrefixBuffer = Data(count: 4)

    // Timing
    private var decodeStart: Date?
    private var prepareDuration: TimeInterval = 0

    // Renderer reference (weak to avoid retain cycles)
    weak var renderer: MetalRenderer?

    private init() {}

    /// Strips Annex-B start codes (3 or 4 bytes) from a NAL buffer
    /// Returns the NAL payload without the start code
    private static func stripStartCode(_ nal: Data) -> Data {
        if nal.count >= 4 && nal[0] == 0x00 && nal[1] == 0x00 && nal[2] == 0x00 && nal[3] == 0x01 {
            return nal.subdata(in: 4..<nal.count)
        }
        if nal.count >= 3 && nal[0] == 0x00 && nal[1] == 0x00 && nal[2] == 0x01 {
            return nal.subdata(in: 3..<nal.count)
        }
        return nal
    }

    func initializeSession(vps: Data, sps: Data, pps: Data) {
        guard !isSessionInitialized else { return }

        // Strip start codes from parameter sets
        let vpsStripped = Self.stripStartCode(vps)
        let spsStripped = Self.stripStartCode(sps)
        let ppsStripped = Self.stripStartCode(pps)

        // Create format description
        var formatDesc: CMVideoFormatDescription?
        let status = vpsStripped.withUnsafeBytes { vpsPtr -> OSStatus in
            spsStripped.withUnsafeBytes { spsPtr -> OSStatus in
                ppsStripped.withUnsafeBytes { ppsPtr -> OSStatus in
                    let parameterSetPointers: [UnsafePointer<UInt8>] = [
                        vpsPtr.bindMemory(to: UInt8.self).baseAddress!,
                        spsPtr.bindMemory(to: UInt8.self).baseAddress!,
                        ppsPtr.bindMemory(to: UInt8.self).baseAddress!,
                    ]
                    let parameterSetSizes: [Int] = [
                        vpsStripped.count,
                        spsStripped.count,
                        ppsStripped.count,
                    ] 
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: parameterSetPointers,
                        parameterSetSizes: parameterSetSizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &formatDesc
                    )
                }
            }
        }

        guard status == noErr, let formatDesc = formatDesc else {
            logMessage("Failed to create format description: %d", status)
            return
        }

        self.formatDescription = formatDesc

        // Create decompression session
        var decompressionSession: VTDecompressionSession?
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: outputCallback,
            decompressionOutputRefCon: nil
        )

        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: &callback,
            decompressionSessionOut: &decompressionSession
        )

        guard sessionStatus == noErr, let decompressionSession = decompressionSession else {
            logMessage("Failed to create decompression session: %d", sessionStatus)
            return
        }

        self.session = decompressionSession
        self.isSessionInitialized = true
    }

    func decodeCurrentFrame() {
        guard isSessionInitialized, let session = session else {
            logMessage("Decompression session is not initialized.")
            return
        }

        guard !avccBuffer.isEmpty else {
            logMessage("No AVCC data to decode (empty buffer).")
            return
        }

        // Create block buffer (zero-copy reference)
        var blockBuffer: CMBlockBuffer?
        let dataSize = avccBuffer.count

        let blockStatus = avccBuffer.withUnsafeBytes {
            (bytes: UnsafeRawBufferPointer) -> OSStatus in
            let baseAddress = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: UnsafeMutableRawPointer(mutating: baseAddress),
                blockLength: dataSize,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataSize,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }

        guard blockStatus == noErr, let blockBuffer = blockBuffer else {
            logMessage("CMBlockBufferCreateWithMemoryBlock failed: %d", blockStatus)
            return
        }

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        let sampleSizes: [Int] = [dataSize]

        let sampleStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: sampleSizes,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sampleBuffer = sampleBuffer else {
            logMessage("CMSampleBufferCreate failed: %d", sampleStatus)
            return
        }

        // Decode frame
        var infoFlags: VTDecodeInfoFlags = []
        let decodeStart = Date()

        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )

        let decodeEnd = Date()
        let decodeMs = decodeEnd.timeIntervalSince(decodeStart) * 1000.0

        if decodeStatus != noErr {
            logMessage(
                "VTDecompressionSessionDecodeFrame failed: %d, infoFlags=0x%x", decodeStatus,
                infoFlags.rawValue)
        }

        // Update stats
        frameCount += 1
        renderer?.setStats(
            FrameStats(
                frameNumber: frameCount,
                decodeTimeMs: decodeMs,
                prepareTimeMs: prepareDuration * 1000.0
            ))
    }

    /// Write length prefix (big-endian) for AVCC format - optimized version
    private func writeLengthPrefix(
        to buffer: inout Data, length: Int, nalLengthSize: Int = 4
    ) {
        // Reuse pre-allocated buffer instead of creating new bytes each time
        lengthPrefixBuffer.withUnsafeMutableBytes { ptr in
            let bytes = ptr.bindMemory(to: UInt8.self)
            for i in 0..<nalLengthSize {
                bytes[nalLengthSize - 1 - i] = UInt8((length >> (8 * i)) & 0xFF)
            }
        }
        buffer.append(lengthPrefixBuffer.prefix(nalLengthSize))
    }

    /// Convert Annex-B formatted data to AVCC format - optimized version
    private func annexbToAvcc(_ data: Data, nalLengthSize: Int = 4) -> Data {
        guard !data.isEmpty else { return Data() }

        // Use existing buffer instead of creating new one
        var result = avccBuffer
        result.removeAll(keepingCapacity: true)

        // Direct byte access for better performance
        let bytes = data.withUnsafeBytes { $0.bindMemory(to: UInt8.self) }
        let count = data.count
        
        // Find first start code with optimized scanning
        var pos = 0
        var firstScPos: Int?
        var firstScLen = 0

        // Scan for first start code
        while pos + 2 < count {
            // Check for start of potential start code (0x00 0x00)
            if bytes[pos] == 0x00 && bytes[pos + 1] == 0x00 {
                if pos + 3 < count && bytes[pos + 2] == 0x00 && bytes[pos + 3] == 0x01 {
                    // 4-byte start code found
                    firstScPos = pos
                    firstScLen = 4
                    break
                } else if bytes[pos + 2] == 0x01 {
                    // 3-byte start code found
                    firstScPos = pos
                    firstScLen = 3
                    break
                }
            }
            pos += 1
        }

        // No start code found - treat entire buffer as single NAL
        guard let firstScPos = firstScPos else {
            if !data.isEmpty {
                writeLengthPrefix(to: &result, length: data.count, nalLengthSize: nalLengthSize)
                result.append(data)
            }
            return result
        }

        // Process NALs
        var nalStart = firstScPos + firstScLen
        var searchPos = nalStart

        while nalStart <= count {
            // Find next start code
            var nextScPos: Int?
            var nextScLen = 0
            var j = searchPos

            while j + 2 < count {
                // Check for start of potential start code
                if bytes[j] == 0x00 && bytes[j + 1] == 0x00 {
                    if j + 3 < count && bytes[j + 2] == 0x00 && bytes[j + 3] == 0x01 {
                        // 4-byte start code found
                        nextScPos = j
                        nextScLen = 4
                        break
                    } else if bytes[j + 2] == 0x01 {
                        // 3-byte start code found
                        nextScPos = j
                        nextScLen = 3
                        break
                    }
                }
                j += 1
            }

            let nalEnd = nextScPos ?? count

            // Write length + payload
            if nalEnd > nalStart {
                let payloadLen = nalEnd - nalStart
                writeLengthPrefix(to: &result, length: payloadLen, nalLengthSize: nalLengthSize)
                result.append(data[nalStart..<nalEnd])
            }

            guard let nextScPos = nextScPos else { break }
            nalStart = nextScPos + nextScLen
            searchPos = nalStart
        }

        return result
    }

    func submitDecodeUnit(_ decodeUnit: DecodeUnit) -> Int32 {
        // print("Decodeunit: \(decodeUnit)")
        let prepareStart = Date()
        
        // Clear buffers efficiently (keep capacity to avoid reallocation)
        annexbBuffer.removeAll(keepingCapacity: true)
        
        // Reserve capacity upfront to minimize reallocations
        let estimatedSize = Int(decodeUnit.fullLength)
        annexbBuffer.reserveCapacity(estimatedSize)

        if decodeUnit.frameType == .idr {
            // Extract VPS/SPS/PPS for session initialization
            var vps = Data()
            var sps = Data()
            var pps = Data()

            for buffer in decodeUnit.buffers {
                switch buffer.type {
                case .vps:
                    vps = buffer.data
                case .sps:
                    sps = buffer.data
                case .pps:
                    pps = buffer.data
                default:
                    break
                }
            }

            if !vps.isEmpty && !sps.isEmpty && !pps.isEmpty {
                initializeSession(vps: vps, sps: sps, pps: pps)
            }

            // Collect all PICDATA into Annex-B buffer (optimized: single pass)
            for buffer in decodeUnit.buffers where buffer.type == .picData {
                annexbBuffer.append(buffer.data)
            }

            // Convert to AVCC
            if !annexbBuffer.isEmpty {
                avccBuffer = annexbToAvcc(annexbBuffer)
            }

        } else if decodeUnit.frameType == .p {
            // Collect all PICDATA for P-frame
            for buffer in decodeUnit.buffers where buffer.type == .picData {
                annexbBuffer.append(buffer.data)
            }

            // Convert to AVCC
            if !annexbBuffer.isEmpty {
                avccBuffer = annexbToAvcc(annexbBuffer)
            }
        }

        let prepareEnd = Date()
        prepareDuration = prepareEnd.timeIntervalSince(prepareStart)

        decodeCurrentFrame()

        return 0  // DR_OK
    }

    // MARK: - Cleanup
    func cleanupSession() {
        if let session = session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        formatDescription = nil
        isSessionInitialized = false
    }

    deinit {
        cleanupSession()
    }
}

// MARK: - Decompression Output Callback
private let outputCallback: VTDecompressionOutputCallback = {
    (
        decompressionOutputRefCon: UnsafeMutableRawPointer?,
        sourceFrameRefCon: UnsafeMutableRawPointer?,
        status: OSStatus,
        infoFlags: VTDecodeInfoFlags,
        imageBuffer: CVImageBuffer?,
        presentationTimeStamp: CMTime,
        presentationDuration: CMTime
    ) in
    guard status == noErr else {
        logMessage("Decompression error: %d", status)
        return
    }

    guard let imageBuffer = imageBuffer else { return }
    
    // Send frame to renderer
    Decoder.shared.renderer?.renderFrame(imageBuffer)
}
