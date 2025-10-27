import CoreMedia
import CoreVideo
import Foundation
import OSLog
import QuartzCore
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

/// A queued frame with its target presentation time
struct QueuedFrame {
    let imageBuffer: CVImageBuffer
    let targetPresentationTime: CFTimeInterval
    let frameNumber: Int32
    let presentationTimeMs: UInt32
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

    // Frame queue for pacing
    private var frameQueue: [QueuedFrame] = []
    private let queueLock = NSLock()
    fileprivate var currentDecodeUnit: DecodeUnit?  // Store current decode unit for callback
    
    // Display timer for frame pacing (macOS uses Timer, iOS would use CADisplayLink)
    private var displayTimer: Timer?
    private var isDisplayTimerActive = false
    
    // Queue statistics
    private var maxQueueDepth: Int = 0
    private var droppedFrames: Int = 0
    private var framesDisplayedEarly: Int = 0
    private var framesDisplayedLate: Int = 0
    private var totalTimingError: Double = 0.0
    private var framesDisplayed: Int = 0

    // Renderer reference (weak to avoid retain cycles)
    weak var renderer: Renderer?

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
        // Store current decode unit for callback access
        currentDecodeUnit = decodeUnit
        
        // Initialize StreamClock with first frame
        if Decoder.shared.frameCount == 0 {
            StreamClock.shared.initialize(
                presentationTimeMs: decodeUnit.presentationTimeMs,
                receiveTimeMs: decodeUnit.receiveTimeMs
            )
        }
        
        // Calculate timing information
        let targetTime = StreamClock.shared.getTargetPresentationTime(
            presentationTimeMs: decodeUnit.presentationTimeMs
        )
        let timingOffset = StreamClock.shared.getTimingOffset(
            presentationTimeMs: decodeUnit.presentationTimeMs
        )
        let currentStreamTime = StreamClock.shared.getCurrentStreamTimeMs()
        
        // Get queue depth for logging
        queueLock.lock()
        let queueDepth = frameQueue.count
        queueLock.unlock()
        
        // Log timing information occasionally (every 60 frames = ~1 second at 60fps)
        if decodeUnit.frameNumber % 60 == 0 {
            print("""
                [Timing] Frame \(decodeUnit.frameNumber):
                  - Presentation time: \(decodeUnit.presentationTimeMs) ms
                  - Target display time: \(targetTime.map { String(format: "%.3f", $0) } ?? "N/A")
                  - Timing offset: \(timingOffset.map { String(format: "%.1f ms", $0) } ?? "N/A")
                  - Current stream time: \(currentStreamTime.map { "\($0) ms" } ?? "N/A")
                  - Frame type: \(decodeUnit.frameType)
                  - Queue depth: \(queueDepth)
                """)
        }
        
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
        // Stop display timer
        stopDisplayTimer()
        
        if let session = session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        formatDescription = nil
        isSessionInitialized = false
        
        // Clear frame queue
        queueLock.lock()
        frameQueue.removeAll()
        queueLock.unlock()
    }
    
    // MARK: - Frame Queue Management
    
    /// Start the display timer for frame pacing
    func startDisplayTimer() {
        // Check if already starting/started (before thread check to avoid race)
        guard !isDisplayTimerActive else {
            print("[DisplayTimer] Already active")
            return
        }
        
        // Mark as active immediately to prevent duplicate starts
        isDisplayTimerActive = true
        
        print("[DisplayTimer] About to start timer, on main thread: \(Thread.isMainThread)")
        
        // Ensure we're on the main thread
        if Thread.isMainThread {
            print("[DisplayTimer] Already on main thread, creating timer directly")
            createTimerOnMainThread()
        } else {
            print("[DisplayTimer] Not on main thread, dispatching to main")
            DispatchQueue.main.async { [weak self] in
                print("[DisplayTimer] Inside async block on main thread: \(Thread.isMainThread)")
                self?.createTimerOnMainThread()
            }
        }
    }
    
    /// Create the timer - must be called on main thread
    private func createTimerOnMainThread() {
        print("[DisplayTimer] createTimerOnMainThread called, on main thread: \(Thread.isMainThread)")
        
        // Double-check we still need to start
        guard isDisplayTimerActive else {
            print("[DisplayTimer] Cancelled - no longer active")
            return
        }
        
        // Run at ~120 Hz (twice the typical 60fps) for better precision
        displayTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 120.0,
            repeats: true
        ) { [weak self] _ in
            self?.displayTimerCallback()
        }
        
        // Validate timer was created
        if let timer = displayTimer {
            print("[DisplayTimer] Timer created successfully, valid: \(timer.isValid)")
            RunLoop.main.add(timer, forMode: .common)
            print("[DisplayTimer] Started - checking for frames at 120 Hz")
        } else {
            print("[DisplayTimer] ERROR: Timer is nil!")
            isDisplayTimerActive = false
        }
    }
    
    /// Stop the display timer
    func stopDisplayTimer() {
        guard isDisplayTimerActive else { return }
        
        displayTimer?.invalidate()
        displayTimer = nil
        isDisplayTimerActive = false
        
        print("[DisplayTimer] Stopped")
    }
    
    /// Called by Timer at 120 Hz to check for frames ready to display
    @objc private func displayTimerCallback() {
        let now = CACurrentMediaTime()
        
        queueLock.lock()
        
        let queueSize = frameQueue.count
        
        // Debug: Always log when queue has frames
        if queueSize > 0 {
            let firstFrame = frameQueue.first!
            let timingError = now - firstFrame.targetPresentationTime
            print("[DisplayTimer] Callback - Queue: \(queueSize), Now: \(String(format: "%.3f", now)), First target: \(String(format: "%.3f", firstFrame.targetPresentationTime)), Error: \(String(format: "%.1f ms", timingError * 1000.0))")
        }
        
        // Check if we have frames ready to display
        while !frameQueue.isEmpty {
            let frame = frameQueue.first!
            let timingError = now - frame.targetPresentationTime
            
            // Display frame if:
            // 1. Its target time has passed (timingError >= 0)
            // 2. OR we're more than 1 frame late (to catch up)
            let shouldDisplay = timingError >= 0 || timingError < -0.033  // 33ms = ~2 frames
            
            if shouldDisplay {
                frameQueue.removeFirst()
                queueLock.unlock()
                
                // Render the frame
                renderer?.renderFrame(frame.imageBuffer)
                
                // Debug: Log first few frames
                if framesDisplayed < 10 {
                    print("[DisplayTimer] Rendered frame \(frame.frameNumber), timing error: \(String(format: "%.1f ms", timingError * 1000.0))")
                }
                
                // Track statistics
                framesDisplayed += 1
                totalTimingError += abs(timingError * 1000.0) // Convert to ms
                
                if timingError > 0 {
                    framesDisplayedLate += 1
                } else {
                    framesDisplayedEarly += 1
                }
                
                // Log every 60 frames (once per second at 60fps)
                if framesDisplayed % 60 == 0 {
                    let avgError = totalTimingError / Double(framesDisplayed)
                    print("""
                        [DisplayTimer] Stats after \(framesDisplayed) frames:
                          - Avg timing error: \(String(format: "%.2f ms", avgError))
                          - Early: \(framesDisplayedEarly), Late: \(framesDisplayedLate)
                          - Dropped: \(droppedFrames)
                          - Max queue depth: \(maxQueueDepth)
                        """)
                }
                
                queueLock.lock()
            } else {
                // Frame is not ready yet, stop checking
                break
            }
        }
        
        queueLock.unlock()
    }
    
    /// Add a decoded frame to the queue
    func enqueueFrame(
        _ imageBuffer: CVImageBuffer,
        frameNumber: Int32,
        presentationTimeMs: UInt32
    ) {
        guard let targetTime = StreamClock.shared.getTargetPresentationTime(
            presentationTimeMs: presentationTimeMs
        ) else {
            print("[Queue] Warning: Cannot enqueue frame \(frameNumber) - clock not initialized")
            return
        }
        
        let frame = QueuedFrame(
            imageBuffer: imageBuffer,
            targetPresentationTime: targetTime,
            frameNumber: frameNumber,
            presentationTimeMs: presentationTimeMs
        )
        
        queueLock.lock()
        frameQueue.append(frame)
        
        // Track max queue depth
        if frameQueue.count > maxQueueDepth {
            maxQueueDepth = frameQueue.count
        }
        
        let queueDepth = frameQueue.count
        let shouldStartTimer = !isDisplayTimerActive && queueDepth == 1
        queueLock.unlock()
        
        // Start display timer on first frame
        if shouldStartTimer {
            print("[Queue] Starting display timer (first frame enqueued)")
            startDisplayTimer()
        }
        
        // Log every frame initially to debug
        print("""
            [Queue] Enqueued frame \(frameNumber):
              - Target time: \(String(format: "%.3f", targetTime))
              - Queue depth: \(queueDepth)
              - Max depth: \(maxQueueDepth)
              - Timer active: \(isDisplayTimerActive)
            """)
    }
    
    /// Dequeue and render the next frame (DEPRECATED - now handled by displayTimerCallback)
    private func dequeueAndRenderNextFrame() {
        // This method is no longer used - frame pacing is handled by displayTimerCallback
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
    
    // Get current decode unit info for queueing
    let decoder = Decoder.shared
    guard let decodeUnit = decoder.currentDecodeUnit else {
        // Fallback: render immediately if no decode unit info
        decoder.renderer?.renderFrame(imageBuffer)
        return
    }
    
    // Enqueue frame with timing information
    decoder.enqueueFrame(
        imageBuffer,
        frameNumber: decodeUnit.frameNumber,
        presentationTimeMs: decodeUnit.presentationTimeMs
    )
}
