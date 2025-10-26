# Log Callback Implementation

This document explains how the variadic `logMessage` callback was implemented for the Moonlight streaming client.

## Problem

The C library (`moonlight-common-c`) defines a variadic callback function:

```c
typedef void(*ConnListenerLogMessage)(const char* format, ...);
```

Swift cannot directly create closures or function pointers with variadic parameters (`...`).

## Solution

We implemented **Option 2: Trampoline Function** approach:

### 1. Created C Helper Files

**`CLibMoonlight/LogHelpers.h`**
- Declares `logMessageCallback()` - the C function that handles variadic parameters
- Declares `getLogMessageCallbackPointer()` - helper to get the function pointer for Swift

**`CLibMoonlight/LogHelpers.c`**
- Implements `logMessageCallback()` which:
  - Takes variadic parameters
  - Formats them using `vsnprintf()`
  - Calls into Swift via `swiftLogHandler()`
- Implements `getLogMessageCallbackPointer()` to return the function pointer

### 2. Updated Swift Code

**`Sources/MoonlightClient.swift`**
- Added `@_cdecl("swiftLogHandler")` function that receives formatted log messages
- Uses `getLogMessageCallbackPointer()` and `unsafeBitCast()` to assign the callback

### 3. Updated Build Configuration

**`Package.swift`**
- Changed `CLibMoonlight` from `.systemLibrary` to `.target` to compile the C source
- Added linker settings for `libmoonlight-common-c`

**`CLibMoonlight/module.modulemap`**
- Added `LogHelpers.h` header to the module

## Usage

When Moonlight logs a message, it will now:
1. Call `logMessageCallback()` with variadic args
2. Get formatted into a string
3. Pass to Swift's `swiftLogHandler()`
4. Print with `[Moonlight]` prefix

## Customization

To customize logging behavior, modify the `swiftLogHandler()` function in `MoonlightClient.swift`:

```swift
@_cdecl("swiftLogHandler")
func swiftLogHandler(_ message: UnsafePointer<CChar>) {
    let swiftString = String(cString: message)
    // Custom logging here - e.g., send to a logger, file, etc.
    print("[Moonlight] \(swiftString)")
}
```

## Build Notes

The build completed successfully with only warnings about:
- Dangling pointers (pre-existing in `startStreaming`)
- Search path not found (linker warning for moonlight-common-c)
- Library version mismatch (linking newer dylib)

These warnings don't affect the log callback functionality.
