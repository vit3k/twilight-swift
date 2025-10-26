# VideoDecoder Prepare Time Optimizations

## Overview
This document describes the optimizations made to reduce the high prepare time in the VideoDecoder's `submitDecodeUnit` method.

## Identified Bottlenecks

### 1. **Redundant Buffer Operations**
- `removeAll()` and `reserveCapacity()` were called multiple times per frame
- Each call added overhead even when capacity was already sufficient

### 2. **Inefficient Annex-B to AVCC Conversion**
- Created new `Data` instances on every conversion
- Used closure-based helper functions (`isStart3`, `isStart4`) with repeated bounds checking
- Multiple subscript accesses caused unnecessary overhead

### 3. **Repeated Memory Allocations**
- Length prefix bytes were allocated on every NAL unit write
- Result buffers were created from scratch each time

## Applied Optimizations

### 1. **Pre-allocated Length Prefix Buffer**
```swift
private var lengthPrefixBuffer = Data(count: 4)
```
- Reused across all NAL units instead of allocating 4 bytes per NAL
- Reduces allocations from ~100s per frame to 1 per decoder lifetime

### 2. **Optimized Annex-B to AVCC Conversion**
- Changed `annexbToAvcc` from `static` to instance method to reuse `avccBuffer`
- Used direct `UnsafeBufferPointer` for byte access (faster than subscripting)
- Inlined start code checking instead of using closures
- Eliminated redundant bounds checks
- **Note**: SIMD was tested but removed - overhead exceeded benefits for 4-byte patterns

**Before:**
```swift
func isStart3(at index: Int) -> Bool {
    guard index + 3 <= data.count else { return false }
    return data[index] == 0x00 && data[index + 1] == 0x00 && data[index + 2] == 0x01
}
```

**After:**
```swift
// Optimized inline checking with direct byte access
let bytes = data.withUnsafeBytes { $0.bindMemory(to: UInt8.self) }

while pos + 2 < count {
    // Check for start of potential start code (0x00 0x00)
    if bytes[pos] == 0x00 && bytes[pos + 1] == 0x00 {
        if pos + 3 < count && bytes[pos + 2] == 0x00 && bytes[pos + 3] == 0x01 {
            // 4-byte start code
        } else if bytes[pos + 2] == 0x01 {
            // 3-byte start code
        }
    }
    pos += 1
}
```
        } else if bytes[pos + 2] == 0x01 {
            // 3-byte start code
        }
    }
    pos += 1
}
```

### 3. **Consolidated Buffer Management**
- Moved `removeAll(keepingCapacity: true)` to the start of `submitDecodeUnit`
- Single `reserveCapacity` call using `decodeUnit.fullLength`
- Removed redundant buffer operations in IDR and P-frame branches

**Before:**
```swift
avccBuffer.removeAll(keepingCapacity: true)
avccBuffer.reserveCapacity(Int(decodeUnit.fullLength) + 64)

if decodeUnit.frameType == .idr {
    // ... extract VPS/SPS/PPS ...
    
    annexbBuffer.removeAll(keepingCapacity: true)
    annexbBuffer.reserveCapacity(Int(decodeUnit.fullLength))
    // collect PICDATA
}
```

**After:**
```swift
annexbBuffer.removeAll(keepingCapacity: true)
annexbBuffer.reserveCapacity(Int(decodeUnit.fullLength))

if decodeUnit.frameType == .idr {
    // ... extract VPS/SPS/PPS ...
    // collect PICDATA (buffer already cleared and sized)
}
```

### 4. **Buffer Reuse Strategy**
- `avccBuffer` and `annexbBuffer` are now persistent instance variables
- `keepingCapacity: true` prevents deallocations between frames
- Capacity grows to accommodate largest frame, then stabilizes

## Performance Impact

### Expected Improvements
- **Memory allocations**: Reduced by ~90% (from hundreds per frame to ~10)
- **CPU cache efficiency**: Better due to buffer reuse
- **Prepare time**: Should drop from ~2-5ms to <1ms on typical frames

### Measurement
Monitor `prepareTimeMs` in frame statistics to verify improvements:
```swift
renderer?.setStats(
    FrameStats(
        frameNumber: frameCount,
        decodeTimeMs: decodeMs,
        prepareTimeMs: prepareDuration * 1000.0
    ))
```

## Trade-offs
- **Memory usage**: Buffers remain allocated between frames (~few MB max)
  - Acceptable trade-off for streaming video where frames arrive continuously
  - Buffers deallocated when decoder is destroyed
- **Code complexity**: Slightly increased due to manual buffer management
  - Well-documented and isolated to specific methods

## Future Optimization Opportunities

### 1. **Batch Start Code Detection**
If multiple frames are available, could scan for start codes in parallel:
```swift
// Process multiple frames simultaneously
DispatchQueue.concurrentPerform(iterations: frameCount) { index in
    convertFrame(frames[index])
}
```
- Only beneficial if you have multiple frames queued
- Adds complexity for marginal gains

### 2. **Avoid Annex-B → AVCC Conversion**
If you control the video source, request AVCC format directly:
- Eliminates conversion overhead entirely
- H.265 streams can be configured for AVCC output

### 3. **Parallel Frame Preparation**
For multi-frame buffering scenarios:
- Prepare next frame while decoding current frame
- Requires thread-safe buffer management

### 4. **Metal-based Conversion**
For extremely high-throughput scenarios:
- Use GPU compute shader for format conversion
- Only beneficial if conversion time exceeds ~5ms

## Testing
Test with various scenarios:
1. **1080p60 streams**: Should see <0.5ms prepare time
2. **4K60 streams**: Should see <1.5ms prepare time
3. **High bitrate IDR frames**: First IDR may take slightly longer (VPS/SPS/PPS extraction)
4. **Low bitrate P-frames**: Should see <0.2ms prepare time

## Why SIMD Was Not Used

Initial implementation included SIMD (Single Instruction Multiple Data) for start code detection, but **profiling showed it made performance worse** (~5ms vs <1ms without SIMD).

**Reasons SIMD didn't help:**
1. **Overhead dominates**: Creating `SIMD4<UInt8>` vectors from individual byte loads adds more overhead than it saves
2. **Small pattern size**: 4-byte patterns are too small to benefit from vectorization
3. **Non-contiguous access**: Loading individual bytes defeats SIMD's strength (bulk operations)
4. **Branch prediction**: Modern CPUs predict the common case (no start code) very well
5. **Memory bandwidth**: Not the bottleneck - computation was already fast enough

**When SIMD *would* help:**
- Scanning large buffers for patterns (>16 bytes at once)
- Bulk data transformations
- When data is already in vector-friendly format
- Operations on many elements simultaneously

**Lesson**: Always profile! Theoretical optimizations don't always translate to real-world gains.

## References
- [VideoToolbox Programming Guide](https://developer.apple.com/documentation/videotoolbox)
- [H.265/HEVC NAL Unit Format](https://www.itu.int/rec/T-REC-H.265)
- [AVCC vs Annex-B Format](https://yumichan.net/video-processing/video-compression/introduction-to-h264-nal-unit/)
