# Mouse Input Implementation

## Overview
Mouse input capture has been integrated into the `MetalRenderer` to allow sending mouse movements, button clicks, and scroll events to the streaming server.

## Features

### Mouse Movement
- **Relative mouse movement**: Sends delta X/Y values to server
- **Cursor hiding**: Hides the system cursor when mouse is captured
- **Mouse locking**: Disassociates mouse from cursor position for true relative movement

### Mouse Buttons
Supports all standard mouse buttons:
- Left button
- Right button
- Middle button
- X1 button (side button)
- X2 button (side button)

### Scrolling
- **Regular scroll**: Standard mouse wheel scrolling
- **High-resolution scroll**: Trackpad scrolling with fine granularity
- **Horizontal scroll**: Both regular and high-resolution horizontal scrolling (Sunshine extension)

## Usage

### Basic Usage
```swift
// Create renderer
let renderer = MetalRenderer(width: 1920, height: 1080, title: "Stream")

// Capture mouse input
renderer?.captureMouse()

// Run render loop
while renderer?.processEvents() == true {
    // Your rendering code...
}
```

### Keyboard Controls

- **ESC**: 
  - First press: Release mouse capture
  - Second press: Close window and exit
  
- **Cmd+M**: Toggle mouse capture on/off

### Automatic Mouse Release

Mouse capture is automatically released when:
- Window loses focus
- Window is closed
- User presses ESC

## Implementation Details

### Constants Used (from Limelight.h)
```c
// Button actions
#define BUTTON_ACTION_PRESS 0x07
#define BUTTON_ACTION_RELEASE 0x08

// Mouse buttons
#define BUTTON_LEFT 0x01
#define BUTTON_MIDDLE 0x02
#define BUTTON_RIGHT 0x03
#define BUTTON_X1 0x04
#define BUTTON_X2 0x05
```

### Limelight Functions Called
- `LiSendMouseMoveEvent(deltaX, deltaY)` - Relative mouse movement
- `LiSendMouseButtonEvent(action, button)` - Mouse button press/release
- `LiSendScrollEvent(amount)` - Vertical scroll
- `LiSendHighResScrollEvent(amount)` - High-resolution vertical scroll
- `LiSendHScrollEvent(amount)` - Horizontal scroll (Sunshine extension)
- `LiSendHighResHScrollEvent(amount)` - High-resolution horizontal scroll (Sunshine extension)

### Event Monitors
The implementation uses three NSEvent monitors:
1. **Mouse Movement Monitor**: Captures `.mouseMoved`, `.leftMouseDragged`, `.rightMouseDragged`, `.otherMouseDragged`
2. **Mouse Button Monitor**: Captures `.leftMouseDown`, `.leftMouseUp`, `.rightMouseDown`, `.rightMouseUp`, `.otherMouseDown`, `.otherMouseUp`
3. **Scroll Wheel Monitor**: Captures `.scrollWheel` events

### Window Delegate
A helper class `WindowDelegateHelper` handles window events:
- Releases mouse when window loses focus
- Releases mouse when window closes

## Technical Notes

### Platform-Specific
- Uses `CGAssociateMouseAndMouseCursorPosition()` to lock/unlock the cursor
- Uses `NSEvent.addLocalMonitorForEvents()` to capture input events
- Events are sent directly to Limelight functions

### Thread Safety
- All mouse capture/release operations are marked with `@MainActor`
- Must be called from the main thread

### Memory Management
- Event monitors are properly cleaned up in `releaseMouse()`
- Weak references are not needed as monitors don't capture self

## Best Practices

1. **Auto-capture on start**: Call `captureMouse()` immediately after creating the renderer for gaming scenarios
2. **Allow user control**: The Cmd+M toggle lets users temporarily release the mouse without closing
3. **Graceful release**: Always release mouse when window loses focus to prevent locked cursor issues

## Future Enhancements

Possible improvements:
- Absolute mouse positioning support (for touch-like scenarios)
- Keyboard input capture (currently not implemented)
- Gamepad/controller input
- Configurable mouse sensitivity
- Mouse acceleration settings
