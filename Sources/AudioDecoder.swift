import AVFoundation
import CLibOpus
import OSLog

private let logger = OSLog(subsystem: "com.twilight.decoder", category: "AudioDecoder")

// MARK: - Logging Helper
func logAudioMessage(_ format: String, _ args: CVarArg...) {
    let message = String(format: format, arguments: args)
    os_log("%{public}@", log: logger, type: .info, message)
}

// MARK: - Audio Decoder Class
class AudioDecoder: @unchecked Sendable {
    static let shared = AudioDecoder()

    // Opus decoder
    private var opusDecoder: OpaquePointer?

    // Audio engine and player
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    // Audio configuration
    private var sampleRate: Int = 48000
    private var channelCount: Int = 2
    private var samplesPerFrame: Int = 240  // 5ms at 48kHz

    // Audio format
    private var audioFormat: AVAudioFormat?

    // Buffer management for smoothing jitter
    private var audioBufferQueue: [AVAudioPCMBuffer] = []
    private let bufferQueueLock = NSLock()
    private let maxBufferedFrames = 10  // Keep max ~400ms buffered (40ms frames)
    private let minBufferedFramesBeforeStart = 3  // Build up ~120ms before starting

    // State
    private var isInitialized = false
    private var isPlaying = false
    private var isStarted = false  // Track if start() was called

    private init() {}

    // MARK: - Initialization
    func initialize(
        sampleRate: Int32,
        channelCount: Int32,
        streams: Int32,
        coupledStreams: Int32,
        samplesPerFrame: Int32,
        mapping: [UInt8]
    ) -> Int32 {
        guard !isInitialized else {
            logAudioMessage("Audio decoder already initialized")
            return 0
        }

        self.sampleRate = Int(sampleRate)
        self.channelCount = Int(channelCount)
        self.samplesPerFrame = Int(samplesPerFrame)

        logAudioMessage(
            "Initializing audio: %d Hz, %d channels, %d streams, %d coupled, %d samples/frame",
            sampleRate, channelCount, streams, coupledStreams, samplesPerFrame)

        // Create Opus multistream decoder
        var error: Int32 = 0
        opusDecoder = opus_multistream_decoder_create(
            sampleRate,
            channelCount,
            streams,
            coupledStreams,
            mapping,
            &error
        )

        guard error == OPUS_OK, opusDecoder != nil else {
            logAudioMessage("Failed to create Opus decoder: %d", error)
            return -1
        }

        // Create audio format
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: Double(sampleRate),
                channels: AVAudioChannelCount(channelCount))
        else {
            logAudioMessage("Failed to create audio format")
            cleanup()
            return -1
        }
        self.audioFormat = format
        
        logAudioMessage(
            "Audio format: %d Hz, %d channels, %@ layout, interleaved: %d",
            format.sampleRate,
            format.channelCount,
            format.isStandard ? "standard" : "non-standard",
            format.isInterleaved ? 1 : 0
        )

        // Set up audio engine
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)

        do {
            try audioEngine.start()
            logAudioMessage("Audio engine started successfully")
        } catch {
            logAudioMessage("Failed to start audio engine: %@", error.localizedDescription)
            cleanup()
            return -1
        }

        isInitialized = true
        return 0
    }

    // MARK: - Start/Stop
    func start() {
        guard isInitialized else {
            logAudioMessage("Cannot start: audio decoder not initialized")
            return
        }

        guard !isStarted else {
            logAudioMessage("Audio already started")
            return
        }

        // Mark as started - this allows buffers to be enqueued and playback to begin
        isStarted = true
        logAudioMessage("Audio playback ready (waiting for initial buffers)")
    }

    func stop() {
        guard isStarted else { return }

        if playerNode.isPlaying {
            playerNode.stop()
        }
        isStarted = false
        isPlaying = false

        // Clear buffered audio
        bufferQueueLock.lock()
        audioBufferQueue.removeAll()
        bufferQueueLock.unlock()

        logAudioMessage("Audio playback stopped")
    }

    // MARK: - Decode and Play
    func decodeAndPlaySample(_ data: Data) {
        guard isInitialized else { return }

        // Handle silence packets (zero length or null data)
        if data.isEmpty {
            enqueueSilence()
            return
        }
        
        // When capabilities=0, moonlight-common-c strips RTP headers and handles
        // decryption (if enabled), so we receive ready-to-decode Opus data
        decodeAndEnqueueOpus(data)
    }
    
    // MARK: - Opus Decoding Helper
    private func decodeAndEnqueueOpus(_ opusData: Data) {
        guard let opusDecoder = opusDecoder, let audioFormat = audioFormat else {
            return
        }
        
        // Calculate maximum decoded size
        // Opus can decode up to 120ms of audio in one packet, but typically 5-20ms
        // Safety factor: allocate for 120ms at max sample rate
        let maxFrameSize = (sampleRate * 120) / 1000  // 120ms worth of samples
        var decodedSamples = [Float](repeating: 0, count: maxFrameSize * channelCount)

        // Decode Opus packet to PCM
        let samplesDecoded = opusData.withUnsafeBytes { (rawBufferPointer: UnsafeRawBufferPointer) -> Int32
            in
            let bufferPointer = rawBufferPointer.bindMemory(to: UInt8.self)
            guard let baseAddress = bufferPointer.baseAddress else { return 0 }

            return decodedSamples.withUnsafeMutableBufferPointer { outBuffer in
                opus_multistream_decode_float(
                    opusDecoder,
                    baseAddress,
                    Int32(opusData.count),
                    outBuffer.baseAddress!,
                    Int32(maxFrameSize),
                    0  // decode_fec = 0
                )
            }
        }

        guard samplesDecoded > 0 else {
            if samplesDecoded < 0 {
                logAudioMessage("Opus decode error: %d", samplesDecoded)
            }
            return
        }

        // Create PCM buffer
        guard
            let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: audioFormat,
                frameCapacity: AVAudioFrameCount(samplesDecoded))
        else {
            logAudioMessage("Failed to create PCM buffer")
            return
        }

        pcmBuffer.frameLength = AVAudioFrameCount(samplesDecoded)

        // Copy decoded samples to PCM buffer
        // AVAudioPCMBuffer uses non-interleaved format, so we need to deinterleave
        // Opus outputs interleaved: [L0, R0, L1, R1, L2, R2, ...]
        // AVAudioPCMBuffer expects non-interleaved: Channel 0: [L0, L1, L2, ...], Channel 1: [R0, R1, R2, ...]
        
        if let floatChannelData = pcmBuffer.floatChannelData {
            for channel in 0..<channelCount {
                let channelPointer = floatChannelData[channel]
                for frame in 0..<Int(samplesDecoded) {
                    channelPointer[frame] = decodedSamples[frame * channelCount + channel]
                }
            }
        } else {
            logAudioMessage("Warning: No float channel data available")
        }

        // Enqueue the buffer
        enqueueBuffer(pcmBuffer)
    }

    // MARK: - Buffer Management
    private func enqueueBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isStarted else { return }
        
        bufferQueueLock.lock()
        
        // Limit buffer queue size to prevent excessive latency
        if audioBufferQueue.count >= maxBufferedFrames {
            audioBufferQueue.removeFirst()
        }
        
        audioBufferQueue.append(buffer)
        let queueSize = audioBufferQueue.count
        bufferQueueLock.unlock()

        // Start player node once we have enough buffers
        if !isPlaying && queueSize >= minBufferedFramesBeforeStart {
            playerNode.play()
            isPlaying = true
            scheduleBuffers()
        } else if isPlaying && queueSize > 3 {
            scheduleNextBuffer()
        }
    }

    private func scheduleBuffers() {
        bufferQueueLock.lock()
        
        // Schedule multiple buffers to keep playback smooth
        var buffersToSchedule: [AVAudioPCMBuffer] = []
        let targetScheduled = min(5, audioBufferQueue.count)
        
        for _ in 0..<targetScheduled {
            if !audioBufferQueue.isEmpty {
                buffersToSchedule.append(audioBufferQueue.removeFirst())
            }
        }
        
        bufferQueueLock.unlock()
        for buffer in buffersToSchedule {
            playerNode.scheduleBuffer(buffer, completionHandler: nil)
        }
    }
    
    private func scheduleNextBuffer() {
        // Simply call scheduleBuffers to handle any pending buffers
        scheduleBuffers()
    }

    private func enqueueSilence() {
        guard let audioFormat = audioFormat else { return }

        // Create silence buffer (samplesPerFrame samples of silence)
        guard
            let silenceBuffer = AVAudioPCMBuffer(
                pcmFormat: audioFormat,
                frameCapacity: AVAudioFrameCount(samplesPerFrame))
        else {
            return
        }

        silenceBuffer.frameLength = AVAudioFrameCount(samplesPerFrame)

        // Zero out all channels (floatChannelData is already zeroed by default)
        // No need to explicitly memset, but we'll do it for clarity
        if let floatChannelData = silenceBuffer.floatChannelData {
            for channel in 0..<channelCount {
                memset(floatChannelData[channel], 0, Int(samplesPerFrame) * MemoryLayout<Float>.size)
            }
        }

        enqueueBuffer(silenceBuffer)
    }

    // MARK: - Cleanup
    func cleanup() {
        stop()

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        audioEngine.detach(playerNode)

        if let decoder = opusDecoder {
            opus_multistream_decoder_destroy(decoder)
            opusDecoder = nil
        }

        audioFormat = nil
        isInitialized = false

        logAudioMessage("Audio decoder cleaned up")
    }

    deinit {
        cleanup()
    }
}
