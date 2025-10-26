# Audio Decoder Glitch Fixes

## Problem
Audio was playing with glitches instead of smooth playback.

## Root Causes Identified

### 1. **Buffer Underruns**
The original implementation scheduled only one buffer at a time using completion handlers. This created gaps between buffers as the system had to wait for:
- Completion handler to fire
- Lock acquisition
- Next buffer retrieval
- Next buffer scheduling

### 2. **No Initial Buffering**
The player node started immediately without building up any buffer, leading to immediate underruns at startup.

### 3. **Incorrect Buffer Access**
Used `mutableAudioBufferList` with manual pointer manipulation instead of the cleaner `floatChannelData` property, which is the recommended approach for float PCM buffers.

## Solutions Applied

### 1. **Aggressive Buffer Scheduling**
- Schedule up to **5 buffers at once** instead of one at a time
- Each completion handler immediately tries to schedule more buffers
- Reduced gaps between buffer playback significantly

```swift
private func scheduleBuffers() {
    // Schedule up to 5 buffers at once to avoid gaps
    var buffersToSchedule: [AVAudioPCMBuffer] = []
    let scheduleCount = min(5, audioBufferQueue.count)
    
    for _ in 0..<scheduleCount {
        if !audioBufferQueue.isEmpty {
            buffersToSchedule.append(audioBufferQueue.removeFirst())
        }
    }
    
    // Schedule all buffers
    for buffer in buffersToSchedule {
        playerNode.scheduleBuffer(buffer) { [weak self] in
            self?.scheduleBuffers()
        }
    }
}
```

### 2. **Initial Buffer Building**
- Wait for **5 buffers (25ms)** before starting playback
- Prevents immediate underrun at stream start
- Provides smooth ramp-up

```swift
private let minBufferedFramesBeforeStart = 5  // Build up 25ms before starting

// Start player node once we have enough buffers
if !playerNode.isPlaying && queueSize >= minBufferedFramesBeforeStart {
    playerNode.play()
    logAudioMessage("Audio playback started with %d initial buffers", queueSize)
}
```

### 3. **Increased Buffer Queue**
- Increased from 10 to **20 buffers** (100ms total)
- Better handles network jitter
- Still low enough latency for gaming

### 4. **Proper Float Channel Data Access**
- Use `floatChannelData` property instead of manual AudioBufferList manipulation
- Cleaner, safer, and the recommended Apple approach

```swift
if let floatChannelData = pcmBuffer.floatChannelData {
    for channel in 0..<channelCount {
        let channelPointer = floatChannelData[channel]
        for frame in 0..<Int(samplesDecoded) {
            channelPointer[frame] = decodedSamples[frame * channelCount + channel]
        }
    }
}
```

### 5. **Enhanced Diagnostics**
- Log audio format details (sample rate, channels, interleaved status)
- Log first few decoded packets to verify decode is working
- Track number of buffers scheduled

## Deinterleaving Verification

Opus outputs **interleaved** samples:
```
[L0, R0, L1, R1, L2, R2, ...]
```

AVAudioPCMBuffer expects **non-interleaved** (separate channel arrays):
```
Channel 0: [L0, L1, L2, ...]
Channel 1: [R0, R1, R2, ...]
```

The deinterleaving formula:
```swift
channelPointer[frame] = decodedSamples[frame * channelCount + channel]
```

This correctly maps:
- `decodedSamples[0]` (L0) → Channel 0, Frame 0
- `decodedSamples[1]` (R0) → Channel 1, Frame 0
- `decodedSamples[2]` (L1) → Channel 0, Frame 1
- `decodedSamples[3]` (R1) → Channel 1, Frame 1

## Expected Improvements

1. **No more audio glitches** - Continuous buffer scheduling prevents gaps
2. **Smooth startup** - Initial buffering prevents early underruns  
3. **Better jitter tolerance** - Larger buffer queue handles network variations
4. **Cleaner code** - Using Apple's recommended APIs

## Testing Tips

Watch the console logs for:
```
[Moonlight] Audio format: 48000 Hz, 2 channels, standard layout, interleaved: 0
[Moonlight] Decoded packet: 240 samples (5 ms)
[Moonlight] Audio playback started with 5 initial buffers
```

If you still hear glitches, check:
- Network stability (ping to host)
- CPU usage (encoding/decoding overhead)
- System audio settings (sample rate mismatch)
