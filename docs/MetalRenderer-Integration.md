# MetalRenderer Integration Guide

## Overview

The `MetalRenderer` is a Swift-based Metal renderer that displays decoded video frames (NV12 format) with an on-screen display showing decoding statistics.

## Architecture

```
┌─────────────────┐
│  TwilightApp    │ (Main Thread)
│   - Creates     │
│   - Runs loop   │
└────────┬────────┘
         │
         │ creates & owns
         ▼
┌─────────────────┐
│ MetalRenderer   │
│   - Window      │
│   - Metal view  │
│   - Frame queue │
└────────┬────────┘
         ▲
         │ weak reference
         │
┌────────┴────────┐
│    Decoder      │ (Decoder Thread)
│   - Decodes H265│
│   - Sends frames│
└─────────────────┘
```

## How It Works

### 1. **Initialization** (Main Thread)
```swift
guard let renderer = MetalRenderer(width: 2560, height: 1440, title: "Twilight Stream") else {
    print("Failed to create Metal renderer")
    exit(1)
}

// Connect decoder to renderer
Decoder.shared.renderer = renderer
```

### 2. **Frame Submission** (Decoder Thread)
When VideoToolbox decodes a frame, it calls the output callback which sends the frame to the renderer:

```swift
// In outputCallback (VideoDecoder.swift)
Decoder.shared.renderer?.renderFrame(imageBuffer)
```

The `renderFrame` method is **thread-safe** - it queues frames internally without blocking the decoder thread.

### 3. **Rendering Loop** (Main Thread)
```swift
while renderer.processEvents() {
    // Processes queued frames and window events
    // Returns false when window is closed
}
```

The `processEvents()` method:
- Dequeues and renders all pending frames
- Handles window events (keyboard, close button)
- Must be called from the **main thread**
- Returns `false` when the window should close

### 4. **Statistics Update** (Decoder Thread)
```swift
renderer?.setStats(
    FrameStats(
        frameNumber: frameCount,
        decodeTimeMs: decodeMs,
        prepareTimeMs: prepareDuration * 1000.0
    )
)
```

This is also thread-safe and updates the on-screen statistics overlay.

## Thread Safety

The renderer uses a **thread-safe frame queue** pattern:

- **Decoder Thread**: Calls `renderFrame()` and `setStats()` (non-blocking)
- **Main Thread**: Calls `processEvents()` to render queued frames
- Internal synchronization uses `NSLock` for thread safety

## Key Features

### Frame Queue
- Keeps up to 3 most recent frames
- Drops old frames if decoder is faster than renderer
- Prevents memory buildup

### NV12 to RGB Conversion
- Hardware-accelerated Metal shaders
- Proper video range (16-235) to full range (0-255) conversion
- BT.709 color space conversion

### On-Screen Display (OSD)
- Shows frame number, decode time, prepare time, total time, and FPS
- Semi-transparent black background
- Updates automatically when stats change

### Event Handling
- ESC key closes the window
- Window close button works properly
- Proper macOS app integration (appears in Dock)

## Example Usage

```swift
// 1. Create renderer on main thread
let renderer = MetalRenderer(width: 1920, height: 1080, title: "My Stream")!

// 2. Connect to decoder
Decoder.shared.renderer = renderer

// 3. Start streaming in background
Task.detached {
    // Your streaming code here
    moonlightClient.startStreaming(...)
}

// 4. Run event loop on main thread
while renderer.processEvents() {
    // Renderer handles everything
}
```

## Memory Management

- Uses Swift's ARC for most objects
- CoreVideo buffers use manual retain/release
- Proper cleanup in `deinit`
- Frame queue cleared on destruction

## Performance Considerations

1. **Zero-copy textures**: Uses `CVMetalTextureCache` for direct buffer-to-texture conversion
2. **Efficient shaders**: Full-screen quad with minimal overdraw
3. **Frame limiting**: Queue size prevents excessive memory usage
4. **Main thread rendering**: Required by Metal/AppKit, ensures smooth UI

## Customization

You can modify:
- Window size: Pass different `width`/`height` to initializer
- Frame queue size: Change `maxSize` in `FrameQueue`
- OSD position/style: Edit `createTextTexture()` function
- Color conversion: Modify fragment shader coefficients

## Troubleshooting

**No window appears:**
- Ensure `processEvents()` is called from main thread
- Check that NSApplication is properly initialized

**Frames not rendering:**
- Verify decoder is calling `renderFrame()`
- Check console for Metal errors
- Ensure pixel format is NV12 (420v or 420f)

**Performance issues:**
- Check frame statistics in OSD
- Verify hardware acceleration is working
- Monitor CPU/GPU usage

**Window won't close:**
- ESC key should always work
- Check event handling in `processEvents()`
