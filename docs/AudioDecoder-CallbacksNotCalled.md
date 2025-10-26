# Audio Callbacks Not Being Called - Fix

## Problem
Audio packets are being received (log shows "Received first audio packet after 5200 ms"), but none of the audio callback functions are being invoked.

## Root Cause Analysis

### How Moonlight Handles Missing Callbacks
The Moonlight C library has a `fixupMissingCallbacks()` function in `FakeCallbacks.c` that checks each callback function pointer. If any callback is `NULL`, it replaces it with a fake placeholder that does nothing:

```c
if (*arCallbacks == NULL) {
    *arCallbacks = &fakeArCallbacks;  // Use fake callbacks that do nothing!
}
else {
    if ((*arCallbacks)->init == NULL) {
        (*arCallbacks)->init = fakeArInit;  // Replace NULL with fake
    }
    // ... checks all other callbacks
}
```

### The Swift Struct Initialization Issue
When creating a C struct in Swift:
```swift
var arCallbacks = AUDIO_RENDERER_CALLBACKS()
```

All function pointers are initialized to `nil` by default. Even after setting individual callbacks, if any field is left uninitialized (like `capabilities`), the struct might not be properly formed when passed to C code.

## The Fix

### 1. Set ALL Required Fields
Added the `capabilities` field initialization:
```swift
arCallbacks.capabilities = 0
```

This ensures the struct is fully initialized and won't be replaced with fake callbacks.

### 2. Debug Output
Added diagnostic prints to verify callbacks are set before calling `LiStartConnection`:
```swift
print("[Audio] Callbacks configured:")
print("  init: \(arCallbacks.init != nil ? "SET" : "NULL")")
print("  start: \(arCallbacks.start != nil ? "SET" : "NULL")")
// ... etc
```

## Expected Output After Fix

When you run the app, you should now see:

```
[Audio] Callbacks configured:
  init: SET
  start: SET
  stop: SET
  cleanup: SET
  decodeAndPlaySample: SET
Streaming started. Press ESC to exit.
[Moonlight] Received first video packet after 300 ms
[Moonlight] Received first audio packet after 5200 ms
[Audio] Init callback called, audioConfiguration: ...
[Audio] Opus config: 48000Hz, 2 channels, 1 streams
[Moonlight] Audio format: 48000 Hz, 2 channels, standard layout, interleaved: 0
[Moonlight] Audio engine started successfully
[Audio] Initialize result: 0
[Audio] Start callback called
[Moonlight] Audio playback ready (waiting for initial buffers)
[Moonlight] Received audio packet: 123 bytes
[Moonlight] Decoded packet: 240 samples (5 ms)
[Moonlight] Buffer enqueued, queue size: 1
```

## If Callbacks Still Show as NULL

If the debug output shows any callbacks as "NULL", it means the closure assignment didn't work. This could be due to:

1. **Swift-C interop issue**: Closures might not be properly converted to C function pointers
2. **Struct padding**: The struct layout might differ between Swift and C

### Alternative Fix: Use C Function Wrappers
If closures don't work, you'd need to create C function wrappers:

```c
// In CLibMoonlight or a new C file
void swift_audio_init_wrapper(int audioConfiguration, ...) {
    // Call Swift function via exported symbol
}
```

Then assign the C function pointers instead of Swift closures.

## Verification Steps

1. **Check callback configuration** - Should see all "SET"
2. **Check init called** - Should see "[Audio] Init callback called"
3. **Check start called** - Should see "[Audio] Start callback called"
4. **Check packets received** - Should see "[Moonlight] Received audio packet"
5. **Check decoding** - Should see "[Moonlight] Decoded packet"
6. **Check playback starts** - Should see "[Moonlight] Audio player node started"

If any step fails, that's where the issue is!
