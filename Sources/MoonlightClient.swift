import CLibMoonlight
import Foundation

// MARK: - Log Handler

/// Swift handler for Moonlight log messages
/// This function is called from C code after formatting variadic arguments
@_cdecl("swiftLogHandler")
func swiftLogHandler(_ message: UnsafePointer<CChar>) {
    let swiftString = String(cString: message)
    print("[Moonlight] \(swiftString)")
}

// Swift wrappers for C macros that don't automatically bridge

/// Creates an audio configuration value from channel count and mask
func MAKE_AUDIO_CONFIGURATION(channelCount: Int32, channelMask: Int32) -> Int32 {
    return ((channelMask << 16) | (channelCount << 8) | 0xCA)
}

/// Stereo audio configuration (2 channels)
let AUDIO_CONFIGURATION_STEREO = MAKE_AUDIO_CONFIGURATION(channelCount: 2, channelMask: 0x3)

/// 5.1 Surround audio configuration (6 channels)
let AUDIO_CONFIGURATION_51_SURROUND = MAKE_AUDIO_CONFIGURATION(channelCount: 6, channelMask: 0x3F)

/// 7.1 Surround audio configuration (8 channels)
let AUDIO_CONFIGURATION_71_SURROUND = MAKE_AUDIO_CONFIGURATION(channelCount: 8, channelMask: 0x63F)

/// Maximum channel count for audio configuration
let AUDIO_CONFIGURATION_MAX_CHANNEL_COUNT: Int32 = 8

/// Extracts channel count from audio configuration
func CHANNEL_COUNT_FROM_AUDIO_CONFIGURATION(_ x: Int32) -> Int32 {
    return (x >> 8) & 0xFF
}

/// Extracts channel mask from audio configuration
func CHANNEL_MASK_FROM_AUDIO_CONFIGURATION(_ x: Int32) -> Int32 {
    return (x >> 16) & 0xFFFF
}

/// Creates surround audio info from audio configuration
func SURROUNDAUDIOINFO_FROM_AUDIO_CONFIGURATION(_ x: Int32) -> Int32 {
    return (CHANNEL_MASK_FROM_AUDIO_CONFIGURATION(x) << 16)
        | CHANNEL_COUNT_FROM_AUDIO_CONFIGURATION(x)
}

// MARK: - Supporting Types
enum FrameType: Int32 {
    case idr = 1
    case p = 0
}

enum BufferType: Int32 {
    case vps = 3
    case sps = 1
    case pps = 2
    case picData = 0
}

struct DecodeBuffer {
    let type: BufferType
    let data: Data
}

struct DecodeUnit {
    let frameNumber: Int32
    let frameType: FrameType
    let fullLength: Int32
    let buffers: [DecodeBuffer]
}

class MoonlightClient {
    // Store callbacks as properties to prevent them from being deallocated
    private var storedAudioCallbacks: AUDIO_RENDERER_CALLBACKS?
    
    // Implementation of MoonlightClient
    func startStreaming(launchInfo: LaunchAppInfo, serverInfo: ServerInfo) {
        // Keep arrays alive throughout the function
        let localIP = Array(serverInfo.localIP.utf8CString)
        let appVersion = Array(serverInfo.appversion.utf8CString)
        let gfeVersion = Array(serverInfo.gfeVersion.utf8CString)
        let rtspUrl = Array(launchInfo.sessionUrl.utf8CString)
        
        // Use withUnsafeBufferPointer to safely access the pointers
        localIP.withUnsafeBufferPointer { localIPPtr in
            appVersion.withUnsafeBufferPointer { appVersionPtr in
                gfeVersion.withUnsafeBufferPointer { gfeVersionPtr in
                    rtspUrl.withUnsafeBufferPointer { rtspUrlPtr in
                        var serverInformation = SERVER_INFORMATION()
                        serverInformation.address = localIPPtr.baseAddress
                        serverInformation.serverInfoAppVersion = appVersionPtr.baseAddress
                        serverInformation.serverInfoGfeVersion = gfeVersionPtr.baseAddress
                        serverInformation.rtspSessionUrl = rtspUrlPtr.baseAddress
                        serverInformation.serverCodecModeSupport = serverInfo.serverCodecModeSupport

                        // Populate serverInformation with data from serverInfo and launchInfo
                        var streamConfiguration = STREAM_CONFIGURATION()
                        launchInfo.aesKey.withUnsafeBytes { bytes in
                            withUnsafeMutableBytes(of: &streamConfiguration.remoteInputAesKey) { dest in
                                dest.copyMemory(
                                    from: UnsafeRawBufferPointer(
                                        start: bytes.baseAddress!, count: min(bytes.count, dest.count)))
                            }
                        }
                        launchInfo.aesIV.withUnsafeBytes { bytes in
                            withUnsafeMutableBytes(of: &streamConfiguration.remoteInputAesIv) { dest in
                                dest.copyMemory(
                                    from: UnsafeRawBufferPointer(
                                        start: bytes.baseAddress!, count: min(bytes.count, dest.count)))
                            }
                        }
                        streamConfiguration.width = 2560
                        streamConfiguration.height = 1440
                        streamConfiguration.fps = 60
                        streamConfiguration.bitrate = 60000
                        streamConfiguration.packetSize = 1316
                        streamConfiguration.streamingRemotely = 0  // STREAM_CFG_AUTO
                        streamConfiguration.audioConfiguration = AUDIO_CONFIGURATION_STEREO  // Default audio configuration
                        streamConfiguration.supportedVideoFormats = VIDEO_FORMAT_H265  // Default video formats
                        streamConfiguration.clientRefreshRateX100 = 60  // Not specified
                        streamConfiguration.colorSpace = COLORSPACE_REC_709  // Default colorspace (Rec 709)
                        streamConfiguration.colorRange = COLOR_RANGE_LIMITED  // Default color range (Limited)
                        streamConfiguration.encryptionFlags = 0  // Disable encryption to debug audio

                        var rendererCallbacks = DECODER_RENDERER_CALLBACKS()
                        rendererCallbacks.submitDecodeUnit = { decodeUnit in
                            guard let decodeUnit = decodeUnit else {
                                return DR_NEED_IDR
                            }
                            // decodeUnit.pointee.bufferList
                            // return Decoder.shared.submitDecodeUnit(decodeUnit)

                            // Access the decode unit data
                            let frameType = decodeUnit.pointee.frameType
                            let frameNumber = decodeUnit.pointee.frameNumber

                            // print("Received frame \(frameNumber), type: \(frameType)")

                            // Process each buffer in the decode unit
                            var currentEntry = decodeUnit.pointee.bufferList
                            var bufferList = [DecodeBuffer]()
                            while currentEntry != nil {
                                let buffer = currentEntry!.pointee
                                let data = buffer.data
                                let length = buffer.length
                                let bufferData = Data(bytesNoCopy: data!, count: Int(length), deallocator: .none)
                                if let bufferType = BufferType(rawValue: buffer.bufferType) {
                                    bufferList.append(
                                        DecodeBuffer(type: bufferType, data: bufferData))
                                } else {
                                    print("Invalid frame type")
                                }

                                currentEntry = buffer.next
                            }
                            if let frameType = FrameType(rawValue: frameType) {
                                return Decoder.shared.submitDecodeUnit(
                                    DecodeUnit(
                                        frameNumber: frameNumber,
                                        frameType: frameType,
                                        fullLength: decodeUnit.pointee.fullLength,
                                        buffers: bufferList))
                            } else {
                                print("Invalid frame type")
                            }

                            return DR_NEED_IDR  // or DR_NEED_IDR if you need a keyframe
                        }
                        var clCallbacks = CONNECTION_LISTENER_CALLBACKS()
                        // Set the log message callback using the C helper function
                        clCallbacks.logMessage = unsafeBitCast(
                            getLogMessageCallbackPointer(),
                            to: ConnListenerLogMessage?.self
                        )
                        var arCallbacks = AUDIO_RENDERER_CALLBACKS()
        
                        // Initialize audio decoder with Opus configuration
                        arCallbacks.`init` = { audioConfiguration, opusConfig, context, arFlags in
                            guard let opusConfig = opusConfig else {
                                return -1
                            }
                            
                            let config = opusConfig.pointee
                            
                            // Convert mapping array to Swift array
                            let mappingTuple = config.mapping
                            let mapping: [UInt8] = [
                                mappingTuple.0, mappingTuple.1, mappingTuple.2, mappingTuple.3,
                                mappingTuple.4, mappingTuple.5, mappingTuple.6, mappingTuple.7
                            ]
                            
                            return AudioDecoder.shared.initialize(
                                sampleRate: config.sampleRate,
                                channelCount: config.channelCount,
                                streams: config.streams,
                                coupledStreams: config.coupledStreams,
                                samplesPerFrame: config.samplesPerFrame,
                                mapping: mapping
                            )
                        }
                        
                        // Start audio playback
                        arCallbacks.start = {
                            AudioDecoder.shared.start()
                        }
                        
                        // Stop audio playback
                        arCallbacks.stop = {
                            AudioDecoder.shared.stop()
                        }
                        
                        // Cleanup audio decoder
                        arCallbacks.cleanup = {
                            AudioDecoder.shared.cleanup()
                        }
                        
                        // Decode and play audio samples
                        arCallbacks.decodeAndPlaySample = { sampleBuffer, sampleLength in
                            if sampleLength == 0 {
                                AudioDecoder.shared.decodeAndPlaySample(Data())
                                return
                            }
                            
                            guard let sampleBuffer = sampleBuffer else {
                                return
                            }
                            
                            let data = Data(bytes: sampleBuffer, count: Int(sampleLength))
                            AudioDecoder.shared.decodeAndPlaySample(data)
                        }
                        
                        // Set capabilities to 0 so moonlight uses its decoder thread which handles
                        // decryption and RTP header stripping before calling our callback
                        arCallbacks.capabilities = 0
                        
                        // Store callbacks to prevent deallocation
                        self.storedAudioCallbacks = arCallbacks
                        
                        // Start streaming logic here
                        LiStartConnection(
                            &serverInformation, &streamConfiguration, &clCallbacks, &rendererCallbacks, &arCallbacks, nil, 0, nil, 0)
                    }
                }
            }
        }
    }
}
