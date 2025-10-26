# Audio Troubleshooting Guide

## Issue: No Audio at All

### Root Cause Found
The audio decoder was rejecting buffers because `start()` had not been called yet. The state management was too strict:
- `isPlaying` was used to gate buffer enqueueing
- Buffers arriving before `start()` were silently dropped
- Player node never started because no buffers were queued

### Solution Applied
Separated state into two flags:
- **`isStarted`**: Tracks if `start()` callback was called (allows buffer enqueueing)
- **`isPlaying`**: Tracks if player node is actually playing audio

Flow now:
1. `init()` → Decoder initialized, ready to receive buffers
2. `start()` → Set `isStarted = true`, buffers can now be enqueued
3. First buffer arrives → Queue buffer
4. After 5 buffers → Start player node, set `isPlaying = true`

## Diagnostic Logging Added

### Callback Logging (MoonlightClient.swift)
```
[Audio] Init callback called, audioConfiguration: ...
[Audio] Opus config: 48000Hz, 2 channels, 1 streams
[Audio] Initialize result: 0
[Audio] Start callback called
[Audio] Received silence packet (or audio packet with size)
```

### Decoder Logging (AudioDecoder.swift)
```
[Moonlight] Audio format: 48000 Hz, 2 channels, standard layout, interleaved: 0
[Moonlight] Audio engine started successfully
[Moonlight] Audio playback ready (waiting for initial buffers)
[Moonlight] Received audio packet: 123 bytes
[Moonlight] Decoded packet: 240 samples (5 ms)
[Moonlight] Buffer enqueued, queue size: 1
[Moonlight] Scheduling 1 buffers (0 remain in queue)
[Moonlight] Total buffers scheduled so far: 1
[Moonlight] Audio player node started with 5 initial buffers
```

## Testing the Fix

### Expected Log Sequence
1. **Initialization**:
   ```
   [Audio] Init callback called
   [Moonlight] Audio format: 48000 Hz, 2 channels...
   [Moonlight] Audio engine started successfully
   ```

2. **Start**:
   ```
   [Audio] Start callback called
   [Moonlight] Audio playback ready (waiting for initial buffers)
   ```

3. **First Audio Packets**:
   ```
   [Moonlight] Received audio packet: 120 bytes
   [Moonlight] Decoded packet: 240 samples (5 ms)
   [Moonlight] Buffer enqueued, queue size: 1
   [Moonlight] Scheduling 1 buffers
   ```

4. **Playback Starts** (after 5 buffers):
   ```
   [Moonlight] Buffer enqueued, queue size: 5
   [Moonlight] Audio player node started with 5 initial buffers
   ```

### If Still No Audio

Check the logs for:

1. **Init not called**:
   - No `[Audio] Init callback called` message
   - Audio stream not negotiated with host
   - Check network/streaming setup

2. **Start not called**:
   - No `[Audio] Start callback called` message
   - Streaming started but audio stream not activated
   - Check Moonlight connection flow

3. **No packets received**:
   - No `[Moonlight] Received audio packet` messages
   - Audio stream not sending data
   - Check host audio configuration

4. **Decode errors**:
   - Look for `[Moonlight] Opus decode error` messages
   - Audio format mismatch
   - Check Opus configuration

5. **Buffer not scheduling**:
   - Buffers enqueued but not scheduled
   - Check for `[Moonlight] Scheduling X buffers` messages
   - Possible threading issue

6. **Player node not starting**:
   - Buffers scheduled but no `Audio player node started` message
   - Queue never reaches 5 buffers
   - Possible packet loss or timing issue

## Quick Debug Checklist

- [ ] See `[Audio] Init callback called`? → Decoder initialized
- [ ] See `[Audio] Start callback called`? → Audio stream started
- [ ] See `Received audio packet`? → Packets arriving
- [ ] See `Decoded packet: 240 samples`? → Decoding working
- [ ] See `Buffer enqueued, queue size: X`? → Buffers queuing
- [ ] See `Scheduling X buffers`? → Buffers being scheduled
- [ ] See `Audio player node started with 5 initial buffers`? → Playback started

If all checks pass but no audio:
- Check system audio output device
- Check volume levels (system and app)
- Check audio routing (AVAudioEngine might be on wrong output)
- Try disconnecting/reconnecting audio devices

## Audio Engine Routing Issue

If buffers are playing but no sound, the audio might be routed to the wrong device:

```swift
// In initialize(), after connecting playerNode:
let outputNode = audioEngine.outputNode
logAudioMessage("Audio output: \(outputNode.name ?? "unknown")")
```

To force specific output device, set before starting engine:
```swift
if let device = AVAudioSession.sharedInstance().currentRoute.outputs.first {
    logAudioMessage("Using audio device: \(device.portName)")
}
```
