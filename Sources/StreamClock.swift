import Foundation
import QuartzCore

/// Manages timing synchronization between audio and video streams
/// Establishes a common time base for presentation timestamps
class StreamClock: @unchecked Sendable {
    static let shared = StreamClock()
    
    // Time when the first frame was received (in CACurrentMediaTime units)
    private var streamStartTime: CFTimeInterval = 0
    
    // The presentation timestamp of the first frame (from the stream)
    private var firstPresentationTimeMs: UInt32 = 0
    
    // Whether the clock has been initialized
    private var isInitialized = false
    
    // Lock for thread-safe access
    private let lock = NSLock()
    
    private init() {}
    
    /// Initialize the clock with the first frame's timing information
    /// - Parameters:
    ///   - presentationTimeMs: The presentation timestamp from the first frame
    ///   - receiveTimeMs: When the first frame was received (not currently used but available)
    func initialize(presentationTimeMs: UInt32, receiveTimeMs: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        
        guard !isInitialized else {
            print("[StreamClock] Already initialized, ignoring re-initialization")
            return
        }
        
        streamStartTime = CACurrentMediaTime()
        firstPresentationTimeMs = presentationTimeMs
        isInitialized = true
        
        print("""
            [StreamClock] Initialized:
              - Stream start time: \(streamStartTime)
              - First presentation time: \(presentationTimeMs) ms
              - Receive time: \(receiveTimeMs) ms
            """)
    }
    
    /// Calculate the target presentation time in CACurrentMediaTime units
    /// - Parameter presentationTimeMs: The presentation timestamp from the stream
    /// - Returns: The absolute time when this frame should be displayed, or nil if not initialized
    func getTargetPresentationTime(presentationTimeMs: UInt32) -> CFTimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        
        guard isInitialized else {
            print("[StreamClock] Warning: Clock not initialized yet")
            return nil
        }
        
        // Calculate elapsed time since first frame in seconds
        let elapsedMs = Int32(presentationTimeMs) - Int32(firstPresentationTimeMs)
        let elapsedSeconds = Double(elapsedMs) / 1000.0
        
        // Target time = when stream started + elapsed time
        let targetTime = streamStartTime + elapsedSeconds
        
        return targetTime
    }
    
    /// Get the current stream time in milliseconds (relative to first frame)
    /// - Returns: Current stream position in ms, or nil if not initialized
    func getCurrentStreamTimeMs() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        
        guard isInitialized else {
            return nil
        }
        
        let now = CACurrentMediaTime()
        let elapsedSeconds = now - streamStartTime
        let elapsedMs = Int32(elapsedSeconds * 1000.0)
        
        return Int32(firstPresentationTimeMs) + elapsedMs
    }
    
    /// Calculate how far ahead or behind schedule a frame is
    /// - Parameter presentationTimeMs: The presentation timestamp from the stream
    /// - Returns: Milliseconds ahead (positive) or behind (negative) schedule, or nil if not initialized
    func getTimingOffset(presentationTimeMs: UInt32) -> Double? {
        guard let targetTime = getTargetPresentationTime(presentationTimeMs: presentationTimeMs) else {
            return nil
        }
        
        let now = CACurrentMediaTime()
        let offsetSeconds = targetTime - now
        
        return offsetSeconds * 1000.0 // Convert to milliseconds
    }
    
    /// Reset the clock (useful when starting a new stream)
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        isInitialized = false
        streamStartTime = 0
        firstPresentationTimeMs = 0
        
        print("[StreamClock] Reset")
    }
}
